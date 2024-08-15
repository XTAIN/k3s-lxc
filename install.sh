#!/bin/bash


worker=${worker:-0}
mgmt=${mgmt:-0}

if [ "${worker}" == "0" ] && [ "${mgmt}" == "0" ]; then
  worker=1
  mgmt=1
fi

roles=""

if [ "${worker}" == "1" ]; then
  roles="${roles} --worker"
fi

if [ "${mgmt}" == "1" ]; then
  roles="${roles} --etcd --controlplane"
fi

default_prefix="node"
if [ "${worker}" == "1" ] && [ "${mgmt}" == "1" ]; then
  cores=${cores:-4}
  memory=${memory:-8192}
  swap=${swap:-4096}
  default_prefix="node"
else
  if [ "${worker}" == "1" ]; then
    default_prefix="worker"
    cores=${cores:-4}
    memory=${memory:-8192}
    swap=${swap:-4096}
  else
    default_prefix="mgmt"
     cores=${cores:-2}
     memory=${memory:-4096}
     swap=${swap:-2048}
  fi
fi

default_domain=$(hostname -d)
if [ -z "${default_domain}" ]; then
  default_domain=xtain.net
fi
default_node="${default_prefix}-$(openssl rand -hex 3)"
host_ip_addr=$(hostname -I | awk '{print $1}')
default_storage=$(pvesm status --content rootdir | grep active | cut -d' ' -f1 | head -n1)
image_storage=local-btrfs
image=$(ls /var/lib/pve/local-btrfs/template/cache/ | grep "ubuntu-" | sort -r | head -n1)

if [ -z "${image}" ]; then
  echo "no image found";
  exit 1
fi

default_hostname=${default_node}.${cluster}.k8s.${default_domain}
default_id=$(pvesh get /cluster/nextid)
#default_bridge=$(brctl show | awk 'NR>1 {print $1}' | grep vmbr | head -n1)
default_bridge=vmbr40
default_rancher=https://k8s.${default_domain}
firewall=${firewall:-0}
size=${size:-64}
data_size=${size:-16}
loop_disk_size=${loop_disk_size:-64}
nameserver=${nameserver:-8.8.8.8}

if [ -z "${token}" ]; then
  echo "Need token"
  exit 1
fi

if [ -z "${cluster}" ]; then
  echo "Need cluster"
  exit 1
fi

if [ -z "${bridge}" ]; then
  bridge=${default_bridge}
fi

ip=${ip:-dhcp}
ip6=${ip6:-}
default_network="name=eth0,firewall=${firewall},bridge=${bridge}"
default_network_internal="name=eth1,firewall=${firewall},bridge=${bridge}"

if [[ ${ip} =~ ^[0-9]+$ ]]; then
  ip_hex=$(printf '%x' ${ip})
  ip_internal="10.128.0.${ip}"
  ip="185.186.24.${ip}"
  ip6="2a0b:6c80:101:326::b9ba:18${ip_hex}/32,gw6=2a0b:6c80::1"
  ip_internal="${ip_internal}/8"
  ip="${ip}/24,gw=185.186.24.1"
fi

if [ "${ip}" ]; then
  default_network="${default_network},ip=${ip}"
fi

if [ "${ip6}" ]; then
  default_network="${default_network},ip6=${ip6}"
fi

if [ "${ip_internal}" ]; then
  network_internal="${default_network_internal},ip=${ip_internal}"
fi

if [ -z "${rancher}" ]; then
  rancher=${default_rancher}
fi
if [ -z "${hostname}" ]; then
  hostname=${default_hostname}
fi
if [ -z "${network}" ]; then
  network=${default_network}
fi
if [ -z "${storage}" ]; then
  storage=${default_storage}
fi
if [ -z "${id}" ]; then
  id=${default_id}
fi

if [ -z "${loop_disk_storage}" ]; then
  loop_disk_storage=${storage}
fi

if [ -z "${data_storage}" ]; then
  data_storage=${storage}
fi

cat > /etc/modules-load.d/docker.conf <<EOF
aufs
overlay
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_sh
nf_conntrack
br_netfilter
iscsi_tcp
rbd
options nf_conntrack hashsize=196608
EOF

cat > /etc/sysctl.d/100-docker.conf  <<EOF
net.netfilter.nf_conntrack_max=786432
EOF

sysctl net.netfilter.nf_conntrack_max=786432

while read p; do
  modprobe "$p"
done </etc/modules-load.d/docker.conf

if pct status $id || qm status $id; then
   echo "VM with $id already exists." > /dev/stderr
   exit 1
fi

pct create $id $image_storage:vztmpl/$image --cores ${cores} --memory ${memory} --swap ${swap} --rootfs ${storage}:${size} --hostname=$hostname --onboot 1
pct set $id -mp0 ${data_storage}:$data_size,mp=/data,backup=1 -mp1 /mnt/pve/cephfs/k8s/${cluster},mp=/shared
(cat <<EOF
lxc.apparmor.profile: unconfined
lxc.cgroup2.devices.allow: a
lxc.cgroup.devices.allow: a
lxc.cap.drop: 
lxc.mount.auto: "proc:rw sys:rw"
EOF
) | cat - >> /etc/pve/lxc/$id.conf
if [ "$loop_disk" ]; then
  for i in {0..255}; do if [ -e /dev/loop$i ]; then continue; fi; mknod /dev/loop$i b 7 $i; chown --reference=/dev/loop0 /dev/loop$i; chmod --reference=/dev/loop0 /dev/loop$i; done
  pct set $id -mp1 ${loop_disk_storage}:$loop_disk_size,mp=/var/loop-disk,backup=1
    (cat <<EOF
lxc.cgroup.devices.allow: b 7:* rwm
lxc.cgroup.devices.allow: c 10:237 rwm
lxc.cgroup2.devices.allow: b 7:* rwm
lxc.cgroup2.devices.allow: c 10:237 rwm
lxc.mount.entry: /dev/loop-control dev/loop-control none bind,create=file 0 0
lxc.mount.entry = /dev/loop0 dev/loop0 none bind,create=file 0 0
EOF
) | cat - >> /etc/pve/lxc/$id.conf
  END=255
  for ((i=0;i<=END;i++)); do
      (cat <<EOF
lxc.mount.entry = /dev/loop${i} dev/loop${i} none bind,create=file 0 0
EOF
) | cat - >> /etc/pve/lxc/$id.conf
  done
fi

pct set $id --net0 $network
if [ "$nameserver" ]; then
  pct set $id --nameserver $nameserver
fi

if [ "${network_internal}" ]; then
  pct set $id --net1 $network_internal
fi
pct set $id --net2 "name=kubevip,firewall=${firewall},bridge=${bridge}"
pct start $id


if [ "$loop_disk" ]; then
  (cat <<EOF
#!/bin/bash

# Pfade zur Datei und zum Symlink
file="/var/loop-disk/image.raw"
link_path="/var/run/loop-disk"

# Verzeichnisse der Datei und des Symlinks
file_dir=\$(dirname "\$file")
link_dir=\$(dirname "\$link_path")

# Überprüfen und ggf. Erstellen des Verzeichnisses der Datei
if [ ! -d "\$file_dir" ]; then
    mkdir -p "\$file_dir"
    if [ \$? -ne 0 ]; then
        echo "Fehler beim Erstellen des Verzeichnisses \$file_dir."
        exit 1
    fi
    echo "Verzeichnis \$file_dir wurde erstellt."
fi

# Überprüfen und ggf. Erstellen des Verzeichnisses des Symlinks
if [ ! -d "\$link_dir" ]; then
    mkdir -p "\$link_dir"
    if [ \$? -ne 0 ]; then
        echo "Fehler beim Erstellen des Verzeichnisses \$link_dir."
        exit 1
    fi
    echo "Verzeichnis \$link_dir wurde erstellt."
fi

# Überprüfen, ob die Datei existiert
if [ ! -f "\$file" ]; then
    # Überprüfen, ob das Verzeichnis als separates Dateisystem gemountet ist
    mount_point=\$(findmnt -n -o TARGET --target "\$file_dir")
    if [ "\$mount_point" == "/" ]; then
        echo "Verzeichnis \$file_dir ist Teil des Root-Dateisystems."
        exit 1
    fi

    echo "Datei \$file existiert nicht. Erstelle eine neue Datei."

    # Freien Speicherplatz im Verzeichnis ermitteln
    free_space=\$(df --output=avail "\$file_dir" | tail -n 1)
    # 95% des freien Speicherplatzes berechnen (in 1K-Blöcken)
    file_size=\$((free_space * 95 / 100))
    
    # Datei mit der berechneten Größe erstellen
    truncate -s "\${file_size}K" "\$file"
    if [ \$? -ne 0 ]; then
        echo "Fehler beim Erstellen der Datei \$file."
        exit 1
    fi
    echo "Datei \$file wurde mit der Größe von 95% des freien Speicherplatzes erstellt."
fi

# Überprüfen, ob die Datei bereits einem Loop-Device zugeordnet ist
loop_device=\$(losetup -j "\$file" | awk -F: '{print \$1}')

# Wenn die Datei noch keinem Loop-Device zugeordnet ist, ein neues Loop-Device erstellen
if [ -z "\$loop_device" ]; then
    loop_device=\$(losetup -f)
    losetup "\$loop_device" "\$file"
    # Überprüfen, ob die Verbindung erfolgreich war
    if [ \$? -ne 0 ]; then
        echo "Fehler beim Verbinden von \$file als Loop-Device."
        exit 1
    fi
    echo "Datei \$file wurde als \$loop_device verbunden."
else
    echo "Datei \$file ist bereits als \$loop_device verbunden."
fi

# Symlink erstellen oder aktualisieren
if [ -L "\$link_path" ]; then
    current_target=\$(readlink "\$link_path")
    if [ "\$current_target" != "\$loop_device" ]; then
        ln -sf "\$loop_device" "\$link_path"
        echo "Symlink \$link_path wurde aktualisiert und zeigt jetzt auf \$loop_device."
    else
        echo "Symlink \$link_path zeigt bereits auf \$loop_device."
    fi
else
    ln -sf "\$loop_device" "\$link_path"
    echo "Symlink \$link_path wurde erstellt und zeigt auf \$loop_device."
fi
EOF
) | pct exec $id -- tee /usr/local/bin/loop-disk
  pct exec $id -- chmod +x /usr/local/bin/loop-disk
  (cat <<EOF
[Unit]
Description=Enshures loop-disk is mounted
After=basic.target

[Service]
Restart=no
Type=oneshot
ExecStart=/usr/local/bin/loop-disk
Environment=

[Install]
WantedBy=multi-user.target
EOF
) | pct exec $id -- tee /etc/systemd/system/loop-disk.service
  pct exec $id -- systemctl daemon-reload
  pct exec $id -- systemctl enable loop-disk.service
  pct exec $id -- systemctl start loop-disk.service
fi

pct exec $id -- mkdir -p /var/lib/rancher/k3s/server/manifests
pct exec $id -- mkdir -p /etc/rancher/k3s
(cat <<EOF
#!/bin/sh -e

if [ ! -e /dev/kmsg ]; then
    ln -s /dev/console /dev/kmsg
fi

mount --make-rshared /
EOF
) | pct exec $id -- tee /usr/local/bin/k3s-lxc
pct exec $id -- chmod +x /usr/local/bin/k3s-lxc
(cat <<EOF
[Unit]
Description=Adds k3s compatability
After=basic.target

[Service]
Restart=no
Type=oneshot
ExecStart=/usr/local/bin/k3s-lxc
Environment=

[Install]
WantedBy=multi-user.target
EOF
) | pct exec $id -- tee /etc/systemd/system/k3s-lxc.service
(cat <<EOF
export PATH="/var/lib/rancher/rke2/bin/:\$PATH"
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
export CRI_CONFIG_FILE=/var/lib/rancher/rke2/agent/etc/crictl.yaml

alias ctr="/var/lib/rancher/rke2/bin/ctr --address /run/k3s/containerd/containerd.sock"
EOF
) | pct exec $id -- tee -a /etc/bash.bashrc
pct exec $id -- systemctl daemon-reload
pct exec $id -- systemctl enable k3s-lxc.service
pct exec $id -- systemctl start k3s-lxc.service
pct exec $id -- apt-get update
pct exec $id -- apt-get install -y curl open-iscsi 
pct exec $id -- curl -fL ${rancher}/system-agent-install.sh | pct exec $id -- sh -s - --server ${rancher} --label 'cattle.io/os=linux' --token ${token} ${roles}
