# Kubernetes Cluster on Hetzner Cloud Servers

# Intial Configuration

## Intall the hcloud-cli
```shell
https://github.com/hetznercloud/cli/releases/download/v1.14.0/hcloud-linux-amd64-v1.14.0.tar.gz
```
Extrace the package and copy the hcloud file to /usr/local/bin
```shell
tar xvf hcloud-linux-amd64-v1.14.0.tar.gz
cp hcloud /usr/local/bin
```

### Create a Token

Create a project named kubernetes in the Cloud Console

To create a Hetzner Cloud API token log in to the web interface, and navigate to your project -> Access -> API tokens and create a new token. You will not be able to fetch the secret key again later on, so don't close the popup before you have copied the token.

### Use a context

Before you can start using the hcloud-cli you need to have a context available. A context is a specific API Token from the Hetzner Cloud Console

Create a hcloud-cli context with the command hcloud context create and add a free choosable name or use an existing project as context
```
hcloud context use kubernetes
```
___
## Create a network and subnet
```shell
hcloud network create --name kubernetes --ip-range 192.168.0.0/16
hcloud network add-subnet kubernetes --network-zone eu-central --type server --ip-range 192.168.0.0/16
```
## Create Three Servers
```shell
hcloud server create --name master-01 --type cx11 --image ubuntu-18.04
hcloud server create --name worker-01 --type cx11 --image ubuntu-18.04
hcloud server create --name worker-02 --type cx11 --image ubuntu-18.04
```
## Attach the Servers to Network
```shell
hcloud server attach-to-network master-01 --network kubernetes --ip 192.168.1.11
hcloud server attach-to-network worker-01 --network kubernetes --ip 192.168.1.21
hcloud server attach-to-network worker-02 --network kubernetes --ip 192.168.1.22
```
## Create a Floating IP Address
```shell
hcloud floating-ip create --type ipv4 --home-location
```
## Upgrade the servers
```shell
apt update -y && apt upgrade -y
```
## Configure Floating IP on Each Worker Node 
> This is needed due to a limitation of LoadBalancer type not available in Hetzner Cloud.
> (Check if needed)

Configure the floating IP address received in the previous floating IP command on each worker node. This will be used for deploying the LoadBalancer Service Type using MetalLB Load Balancer.

Create a file 
```shell
vim /etc/network/interfaces.d/60-floating-ip.cfg
iface eth0:1 inet static
  address <IP ADDRESS>
  netmask 32
```
Restart Networking Service
```
systemctl restart networking.service
```

## Disable Firewall and swap
```shell
sudo systemctl stop ufw && systemctl disable ufw 
## Turn of swap
swapoff -a
```
> Also disable swap in /etc/fstab

# Kubernetes Installation

Kubernetes will be installed using kubeadm.

The interface between Kubernetes and the Hetzner Cloud will be the [Hetzner Cloud Controller Manager](https://github.com/hetznercloud/hcloud-cloud-controller-manager) and the [Hetzner Cloud Container Storage Interface](https://github.com/hetznercloud/csi-driver). Both tools are provided by the Hetzner Cloud team.

Create an initial Kubelet configuration file so that it can read the configuration file while starting
```shell
mkdir -p /etc/systemd/system/kubelet.service.d/
vim /etc/systemd/system/kubelet.service.d/20-hetzner-cloud.conf
[Service]
Environment="KUBELET_EXTRA_ARGS=--cloud-provider=external"
```
> This will make sure, that kubelet is started with the `cloud-provider = external` flag
___
## Install Docker
```shell
Install Docker CE
## Set up the repository:
### Install packages to allow apt to use a repository over HTTPS
apt-get update && apt-get install apt-transport-https ca-certificates curl software-properties-common

### Add Docker’s official GPG key
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -

### Add Docker apt repository.
add-apt-repository \
  "deb [arch=amd64] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) \
  stable"

## Install Docker CE.
apt-get update && apt-get install docker-ce=18.06.2~ce~3-0~ubuntu

# Setup daemon.
cat > /etc/docker/daemon.json <<EOF
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2"
}
EOF

mkdir -p /etc/systemd/system/docker.service.d

# Restart docker
systemctl daemon-reload
systemctl restart docker
```
___
## Install kubeadm, kubectl and kubelet
```shell
sudo apt-get update && sudo apt-get install -y apt-transport-https curl
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
cat <<EOF | sudo tee /etc/apt/sources.list.d/kubernetes.list
deb https://apt.kubernetes.io/ kubernetes-xenial main
EOF
sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
```

You need to make sure that the system can actually forward traffic between the nodes and pods. Set the following sysctl settings on each server
```shell
cat <<EOF >>/etc/sysctl.conf
# Allow IP forwarding for kubernetes
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
net.ipv6.conf.default.forwarding = 1
EOF

sysctl -p
```
***
## Initialize Control Plane
> This deployment method will configure 1 master node however configurations are compatible for creating a high availability master plan cluster.
```shell
kubeadm config images pull # download the images first

kubeadm init \
  --pod-network-cidr=10.244.0.0/16 \
  --kubernetes-version=v1.16.3 \
  --upload-certs \
  --apiserver-cert-extra-sans <lb_ip> \
  --control-plane-endpoint <lb_ip:6443>
```
When the initialisation is complete begin with setting up the required master components in the cluster. For ease of use configure the kubeconfig of the root user to use the admin config of the Kubernetes cluster
```
master$ mkdir -p /root/.kube
master$ cp -i /etc/kubernetes/admin.conf /root/.kube/config
```
The cloud controller manager and the container storage interface require two secrets in the kube-system namespace containing access tokens for the Hetzner Cloud API
```shell
master$ cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: hcloud
  namespace: kube-system
stringData:
  token: "<hetzner_api_token>"
  network: "<hetzner_network_id>"
---
apiVersion: v1
kind: Secret
metadata:
  name: hcloud-csi
  namespace: kube-system
stringData:
  token: "<hetzner_api_token>"
EOF
```

> Both services can use the same token, but if you want to be able to revoke them independent from each other, you need to create two tokens.

> To create a Hetzner Cloud API token log in to the web interface, and navigate to your project -> Access -> API tokens and create a new token. You will not be able to fetch the secret key again later on, so don't close the popup before you have copied the token.

### Deploy Hetzner Cloud Controller Manager 
```shell
kubectl apply -f https://raw.githubusercontent.com/hetznercloud/hcloud-cloud-controller-manager/master/deploy/v1.5.0-networks.yaml
```

### Deploy CNI Plugin
```
kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/2140ac876ef134e0ed5af15c65e414cf26827915/Documentation/kube-flannel.yml
```

As Kubernetes with the external cloud provider flag activated will add a taint to uninitialized nodes, the cluster critical pods need to be patched to tolerate these

```shell
master$ kubectl -n kube-system patch daemonset kube-flannel-ds-amd64 --type json -p '[{"op":"add","path":"/spec/template/spec/tolerations/-","value":{"key":"node.cloudprovider.kubernetes.io/uninitialized","value":"true","effect":"NoSchedule"}}]'
master$ kubectl -n kube-system patch deployment coredns --type json -p '[{"op":"add","path":"/spec/template/spec/tolerations/-","value":{"key":"node.cloudprovider.kubernetes.io/uninitialized","value":"true","effect":"NoSchedule"}}]'
```

### Deploy the CSI Storage Driver
```
kubectl apply -f https://raw.githubusercontent.com/kubernetes/csi-api/release-1.14/pkg/crd/manifests/csidriver.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes/csi-api/release-1.14/pkg/crd/manifests/csinodeinfo.yaml
kubectl apply -f https://raw.githubusercontent.com/hetznercloud/csi-driver/master/deploy/kubernetes/hcloud-csi.yml
```

Your control plane is now ready to use. Fetch the kubeconfig from the master server to be able to use kubectl locally ()
```shell
local$ scp root@<master ip>:/etc/kubernetes/admin.conf ${HOME}/.kube/config
```
___
## Join Worker Nodes

In the kubeadm init process a join command for the worker nodes was printed. Use that command or use the following method. 
```
kubeadm token create --print-join-command
kubeadm join master:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>
```

# Additional Tasks

## Loading Balancing using MetalLB

Configure MetalLB Load Balancer using files in metallb folders

### Setup floating IP failover (Needed for MetalLB) 
 > Need to check if it is needed anymore.

 > Reference: [Click Here](https://github.com/cbeneke/hcloud-fip-controller)  

As the floating IP is bound to one server only, a little controller needs to be deployed which will run in the cluster and reassign the floating IP to another server, if the currently assigned node becomes NotReady.

If you do not ensure, that the floating IP is always associated to a node in status Ready your cluster will not be high available, as the traffic can be routed to a (potentially) broken node.

To deploy the Hetzner Cloud floating IP controller create the following resources
```shell
kubectl create namespace fip-controller
kubectl apply -f https://raw.githubusercontent.com/cbeneke/hcloud-fip-controller/master/deploy/rbac.yaml
kubectl apply -f https://raw.githubusercontent.com/cbeneke/hcloud-fip-controller/master/deploy/deployment.yaml
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: fip-controller-config
  namespace: fip-controller
data:
  config.json: |
    {
      "hcloudFloatingIPs": [ "<floatingip>" ],
      "nodeAddressType": "external"
    }
---
apiVersion: v1
kind: Secret
metadata:
  name: fip-controller-secrets
  namespace: fip-controller
stringData:
  HCLOUD_API_TOKEN: <hetzner_api_token>
EOF
```
If you did not set up the hcloud cloud controller, the external IP of the nodes might be announced as internal IP of the nodes in the Kubernetes cluster. In that event you must change nodeAddressType in the config to internal for the floating IP controller to work correctly.

> Please be aware, that the project is still in development and the config might be changed drastically in the future. Refer to the GitHub repository for config options etc.
___
## Configure Ingress

Ingress will help save Floating IP addresses by providing Path Based routing for applications.  

Use the configurations in ingress folder to deploy Ingress Controller, Ingress and Ingress Service

___

## Configure HAProxy

If MetalLB is not deployed, then HAProxy can be used to send the traffic to ingress with NodePort service that will eventually route the traffic to respective services.

> HAProxy must be configured in a separate virtual machine having a frontend IP address.
