sudo grep -nEi \
  'clusterrolebinding|bootstrap.*admin|forbidden|rate limiter|timed out|error' \
  kubeadm-init.log | tail -80

sudo kubectl config view \
  --kubeconfig=/etc/kubernetes/admin.conf \
  --minify \
  -o jsonpath='{.contexts[0].context.user}{"\n"}{.users[0].user.client-certificate-data}' \
  | head -1

sudo openssl x509 \
  -in <(sudo kubectl config view \
    --kubeconfig=/etc/kubernetes/admin.conf \
    --raw -o jsonpath='{.users[0].user.client-certificate-data}' \
    | base64 -d) \
  -noout -subject

