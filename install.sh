
roles=""

if [ "${worker}" == "1" ]; then
  roles="${roles} --worker"
fi

if [ "${mgmt}" == "1" ]; then
  roles="${roles} --etcd --controlplane"
fi

worker=${worker:-1}
mgmt=${mgmt:-1}

default_prefix="node"
if [ "${worker}" == "1" ] && [ "${mgmt}" == "1" ]; then
  default_prefix="node"
else
  if [ "${worker}" == "1" ]; then
    default_prefix="worker"
  else
    default_prefix="mgmt"
  fi
fi

default_node="${default_prefix}-$(openssl rand -hex 3)"
host_ip_addr=$(hostname -I | awk '{print $1}')
default_storage=$(pvesm status --content rootdir | grep active | cut -d' ' -f1)
default_hostname=${default_node}.k8s.$(hostname -d)
default_id=$(pvesh get /cluster/nextid)
default_bridge=$(brctl show | awk 'NR>1 {print $1}' | grep vmbr | head -n1)
default_bridge=vmbr40
default_rancher=https://k8s.$(hostname -d)
firewall=${firewall:-1}


if [ -z "${token}" ]; then
  echo "Need token"
  exit 1
fi

if [ -z "${bridge}" ]; then
  bridge=${default_bridge}
fi

ip=${ip:-dhcp}
ip6=${ip6:-}
default_network="name=eth0,firewall=${firewall},bridge=${bridge}"

if [ "${ip}" ]; then
  default_network="${default_network},ip=${ip}"
fi

if [ "${ip6}" ]; then
  default_network="${default_network},ip6=${ip6}"
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

pct create $id $storage:vztmpl/$image --cores 2 --memory 4096 --swap 2048 --rootfs ${storage}:${size} --hostname=$hostname --onboot 1
(cat <<EOF
lxc.apparmor.profile: unconfined
lxc.cgroup2.devices.allow: a
lxc.cap.drop: 
lxc.mount.auto: "proc:rw sys:rw"
EOF
) | cat - >> /etc/pve/lxc/$id.conf
pct start $id
pct set $id --net0 $network
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
pct exec $id -- systemctl daemon-reload
pct exec $id -- systemctl enable k3s-lxc.service
pct exec $id -- systemctl start k3s-lxc.service
pct exec $id -- apt-get update
pct exec $id -- apt-get install -y curl
pct exec $id -- curl -fL ${rancher}/system-agent-install.sh | sudo  sh -s - --server ${rancher} --label 'cattle.io/os=linux' --token ${token} ${roles}
