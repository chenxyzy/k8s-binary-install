#!/bin/bash
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.ipv4.ip_forward = 1
EOF

# Apply sysctl params without reboot
sudo sysctl --system

# 新的k8s部署文档中没有写，但是也很关键，如果没有这个配置公网访问会出现异常。
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

# 因为网络环境的问题，所有要在github上下载的文件我都提前准备好了，所以注释了所有的curl操作。
curl -L -O 'https://github.com/containerd/containerd/releases/download/v1.7.22/containerd-1.7.22-linux-amd64.tar.gz'
sudo tar Cxzvf /usr/local containerd-1.7.21-linux-amd64.tar.gz
curl -L -o /usr/local/lib/systemd/system/containerd.service 'https://raw.githubusercontent.com/containerd/containerd/main/containerd.service'
sudo mkdir -p /usr/local/lib/systemd/system/
sudo cp containerd.service /usr/local/lib/systemd/system/containerd.service
sudo systemctl daemon-reload
sudo systemctl enable --now containerd
curl -L -O 'https://github.com/opencontainers/runc/releases/download/v1.1.15/runc.amd64'
sudo install -m 755 runc.amd64 /usr/local/sbin/runc

#curl -L -O 'https://github.com/containernetworking/plugins/releases/download/v1.5.1/cni-plugins-linux-amd64-v1.5.1.tgz'
#mkdir -p /opt/cni/bin
#tar Cxzvf /opt/cni/bin cni-plugins-linux-amd64-v1.1.1.tgz

CNI_PLUGINS_VERSION="v1.5.1"
ARCH="amd64"
DEST="/opt/cni/bin"
sudo mkdir -p "$DEST"
curl -L "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VERSION}/cni-plugins-linux-${ARCH}-${CNI_PLUGINS_VERSION}.tgz" | sudo tar -C "$DEST" -xz
cat cni-plugins-linux-${ARCH}-${CNI_PLUGINS_VERSION}.tgz | sudo tar -C "$DEST" -xz

DOWNLOAD_DIR="/usr/local/bin"
sudo mkdir -p "$DOWNLOAD_DIR"

CRICTL_VERSION="v1.31.1"
ARCH="amd64"
curl -L "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${ARCH}.tar.gz" | sudo tar -C $DOWNLOAD_DIR -xz
cat crictl-${CRICTL_VERSION}-linux-${ARCH}.tar.gz | sudo tar -C $DOWNLOAD_DIR -xz

RELEASE="v1.31.1"
ARCH="amd64"
sudo cp {kubeadm,kubelet} $DOWNLOAD_DIR
cd $DOWNLOAD_DIR
sudo curl -L --remote-name-all https://dl.k8s.io/release/${RELEASE}/bin/linux/${ARCH}/{kubeadm,kubelet}
sudo chmod +x {kubeadm,kubelet}
cd -
RELEASE_VERSION="master"
curl -sSL "https://raw.githubusercontent.com/kubernetes/release/${RELEASE_VERSION}/cmd/krel/templates/latest/kubelet/kubelet.service" | sed "s:/usr/bin:${DOWNLOAD_DIR}:g" | sudo tee /usr/lib/systemd/system/kubelet.service
# cat kubelet.service | sed "s:/usr/bin:${DOWNLOAD_DIR}:g" | sudo tee /usr/lib/systemd/system/kubelet.service
sudo mkdir -p /usr/lib/systemd/system/kubelet.service.d
curl -sSL "https://raw.githubusercontent.com/kubernetes/release/${RELEASE_VERSION}/cmd/krel/templates/latest/kubeadm/10-kubeadm.conf" | sed "s:/usr/bin:${DOWNLOAD_DIR}:g" | sudo tee /usr/lib/systemd/system/kubelet.service.d/10-kubeadm.conf
# cat 10-kubeadm.conf | sed "s:/usr/bin:${DOWNLOAD_DIR}:g" | sudo tee /usr/lib/systemd/system/kubelet.service.d/10-kubeadm.conf

curl -LO "https://dl.k8s.io/release/${RELEASE}/bin/linux/amd64/kubectl"
chmod +x kubectl
mkdir -p ~/.local/bin
cp ./kubectl ~/.local/bin/kubectl

sudo systemctl enable --now kubelet

# 这里的操作是要到k8s的仓库去拉取镜像，网络原因我也是导出到了本地。不过我在cloudflare上搭建了镜像代理服务器后面应该不需要执行了。
# sudo ctr -n k8s.io i import coredns:v1.11.1.tar
# sudo ctr -n k8s.io i import etcd:3.5.15-0.tar
# sudo ctr -n k8s.io i import kube-apiserver:v1.31.0.tar
# sudo ctr -n k8s.io i import kube-controller-manager:v1.31.0.tar
# sudo ctr -n k8s.io i import kube-proxy:v1.31.0.tar
# sudo ctr -n k8s.io i import kube-scheduler:v1.31.0.tar
# sudo ctr -n k8s.io i import pause:3.10.tar

sudo mkdir -p /etc/containerd/
sudo containerd config default | sudo tee /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup *= *false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo sed -i 's@sandbox_image *= *"registry.k8s.io/pause:3.8"@sandbox_image = "registry.k8s.io/pause:3.10"@g' /etc/containerd/config.toml
sudo sed -i 's@\<config_path = ""@config_path = "/etc/containerd/certs.d"@g' /etc/containerd/config.toml
sudo mkdir -p /etc/containerd/certs.d/_default
cat <<EOF | sudo tee /etc/containerd/certs.d/_default/hosts.toml
[host."https://docker.505345784.xyz"]
  capabilities = ["pull", "resolve"]
EOF
sudo systemctl restart containerd
sudo apt install -y socat conntrack
sudo kubeadm init --kubernetes-version 1.31.0

mkdir -p $HOME/.kube
sudo cp -rf /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

cat <<EOF | sudo tee /etc/cni/net.d/10-containerd-net.conflist
{
 "cniVersion": "1.0.0",
 "name": "containerd-net",
 "plugins": [
   {
     "type": "bridge",
     "bridge": "cni0",
     "isGateway": true,
     "ipMasq": true,
     "promiscMode": true,
     "ipam": {
       "type": "host-local",
       "ranges": [
         [{
           "subnet": "10.88.0.0/16"
         }],
         [{
           "subnet": "2001:db8:4860::/64"
         }]
       ],
       "routes": [
         { "dst": "0.0.0.0/0" },
         { "dst": "::/0" }
       ]
     }
   },
   {
     "type": "portmap",
     "capabilities": {"portMappings": true},
     "externalSetMarkChain": "KUBE-MARK-MASQ"
   }
 ]
}
EOF

sudo systemctl restart containerd

# sudo ctr -n k8s.io i import --platform linux/amd64 kafka.tar
# sudo ctr -n k8s.io i import --platform linux/amd64 minio.tar
# sudo ctr -n k8s.io i import --platform linux/amd64 mysql.tar
# sudo ctr -n k8s.io i import --platform linux/amd64 nacos.tar
# sudo ctr -n k8s.io i import --platform linux/amd64 nginx.tar
# sudo ctr -n k8s.io i import --platform linux/amd64 openjdk.tar
# sudo ctr -n k8s.io i import --platform linux/amd64 redis.tar
# sudo ctr -n k8s.io i import --platform linux/amd64 seata.tar
# sudo ctr -n k8s.io i import --platform linux/amd64 kkfileview.tar

kubectl taint nodes --all node-role.kubernetes.io/control-plane-
