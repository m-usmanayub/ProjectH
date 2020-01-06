# Always check for the latest version before deployment
kubectl apply -f https://raw.githubusercontent.com/google/metallb/v0.8.3/manifests/metallb.yaml

#Always customize the metallb-config.yaml file before exeucting the below command
kubectl apply -f ./metallb/metallb-config.yaml
