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

cat > /etc/modules-load.d/docker.conf <<EOF
aufs
overlay
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_sh
nf_conntrack
br_netfilter
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
(cat <<EOF
lxc.apparmor.profile: unconfined
lxc.cgroup2.devices.allow: a
lxc.cap.drop: 
lxc.mount.auto: "proc:rw sys:rw"
EOF
) | cat - >> /etc/pve/lxc/$id.conf

if [ $ceph == 1 ]; then
  (cat <<EOF
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
pct start $id

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
) | pct exec $id -- tee /etc/bash.bashrc
pct exec $id -- systemctl daemon-reload
pct exec $id -- systemctl enable k3s-lxc.service
pct exec $id -- systemctl start k3s-lxc.service
pct exec $id -- apt-get update
pct exec $id -- apt-get install -y curl
pct exec $id -- curl -fL ${rancher}/system-agent-install.sh | pct exec $id -- sh -s - --server ${rancher} --label 'cattle.io/os=linux' --token ${token} ${roles}
