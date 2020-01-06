# High Availability for Kubernetes Control Plane

## First steps 

### Create load balancer for kube-apiserver

> Note: There are many configurations for load balancers. The following example is only one option. Your cluster requirements may need a different configuration.

Create a kube-apiserver load balancer with a name that resolves to DNS.

In a cloud environment you should place your control plane nodes behind a TCP forwarding load balancer. This load balancer distributes traffic to all healthy control plane nodes in its target list. The health check for an apiserver is a TCP check on the port the kube-apiserver listens on (default value :6443).

> It is not recommended to use an IP address directly in a cloud environment.

The load balancer must be able to communicate with all control plane nodes on the apiserver port. It must also allow incoming traffic on its listening port.

HAProxy can be used as a load balancer.

Make sure the address of the load balancer always matches the address of kubeadm’s ControlPlaneEndpoint.

Add the first control plane nodes to the load balancer and test the connection:
```shell
nc -v LOAD_BALANCER_IP PORT
```
A connection refused error is expected because the apiserver is not yet running. A timeout, however, means the load balancer cannot communicate with the control plane node. If a timeout occurs, reconfigure the load balancer to communicate with the control plane node.
Add the remaining control plane nodes to the load balancer target group.

## Stacked control plane and etcd nodes

### Steps for the first control plane node

Initialize the control plane:
```shell
sudo kubeadm init --control-plane-endpoint "LOAD_BALANCER_DNS:LOAD_BALANCER_PORT" --upload-certs
```
You can use the `--kubernetes-version` flag to set the Kubernetes version to use. It is recommended that the versions of kubeadm, kubelet, kubectl and Kubernetes match.

The `--control-plane-endpoint` flag should be set to the address or DNS and port of the load balancer.

The `--upload-certs` flag is used to upload the certificates that should be shared across all the control-plane instances to the cluster. If instead, you prefer to copy certs across control-plane nodes manually or using automation tools, please remove this flag and refer to Manual certificate distribution section below.

> Note: The kubeadm init flags --config and --certificate-key cannot be mixed, therefore if you want to use the kubeadm configuration you must add the certificateKey field in the appropriate config locations (under InitConfiguration and JoinConfiguration: controlPlane).

> Note: Some CNI network plugins like Calico require a CIDR such as 192.168.0.0/16 and some like Weave do not. See the CNI network documentation. To add a pod CIDR pass the flag --pod-network-cidr, or if you are using a kubeadm configuration file set the podSubnet field under the networking object of ClusterConfiguration.

The output looks similar to:
```
...
You can now join any number of control-plane node by running the following command on each as a root:

kubeadm join 192.168.0.200:6443 --token 9vr73a.a8uxyaju799qwdjv --discovery-token-ca-cert-hash sha256:7c2e69131a36ae2a042a339b33381c6d0d43887e2de83720eff5359e26aec866 --control-plane --certificate-key f8902e114ef118304e561c3ecd4d0b543adc226b7a07f675f56564185ffe0c07

Please note that the certificate-key gives access to cluster sensitive data, keep it secret!
As a safeguard, uploaded-certs will be deleted in two hours; If necessary, you can use kubeadm init phase upload-certs to reload certs afterward.

Then you can join any number of worker nodes by running the following on each as root:  

kubeadm join 192.168.0.200:6443 --token 9vr73a.a8uxyaju799qwdjv --discovery-token-ca-cert-hash sha256:7c2e69131a36ae2a042a339b33381c6d0d43887e2de83720eff5359e26aec866  
Copy this output to a text file. You will need it later to join control plane and worker nodes to the cluster.
```
When `--upload-certs` is used with kubeadm init, the certificates of the primary control plane are encrypted and uploaded in the kubeadm-certs Secret.

To re-upload the certificates and generate a new decryption key, use the following command on a control plane node that is already joined to the cluster:
```shell
sudo kubeadm init phase upload-certs --upload-certs
```
You can also specify a custom `--certificate-key` during init that can later be used by join. To generate such a key you can use the following command:
```
kubeadm alpha certs certificate-key
```
Note: The kubeadm-certs Secret and decryption key expire after two hours.

Caution: As stated in the command output, the certificate key gives access to cluster sensitive data, keep it secret!

Apply the CNI plugin of your choice: Follow the instructions to install the CNI provider. Make sure the configuration corresponds to the Pod CIDR specified in the kubeadm configuration file if applicable.

> Note: Since kubeadm version 1.15 you can join multiple control-plane nodes in parallel. Prior to this version, you must join new control plane nodes sequentially, only after the first node has finished initializing.

### For each additional control plane node you should:

Execute the join command that was previously given to you by the kubeadm init output on the first node. It should look something like this:
```shell
sudo kubeadm join 192.168.0.200:6443 --token 9vr73a.a8uxyaju799qwdjv --discovery-token-ca-cert-hash sha256:7c2e69131a36ae2a042a339b33381c6d0d43887e2de83720eff5359e26aec866 --control-plane --certificate-key f8902e114ef118304e561c3ecd4d0b543adc226b7a07f675f56564185ffe0c07
```
The `--control-plane` flag tells kubeadm join to create a new control plane.  
The `--certificate-key` ... will cause the control plane certificates to be downloaded from the kubeadm-certs Secret in the cluster and be decrypted using the given key.
