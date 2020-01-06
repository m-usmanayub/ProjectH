kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/static/mandatory.yaml

# Select the relevant required file as per the Load Balancer Deployment
# kubectl apply -f ./ingress/ing-svc-np.yaml
# kubectl apply -f . ingress/ing-svc-lb.yaml

# configure ingress.yaml first before running this command
# kubectl apply -f ./ingress/ingress.yaml