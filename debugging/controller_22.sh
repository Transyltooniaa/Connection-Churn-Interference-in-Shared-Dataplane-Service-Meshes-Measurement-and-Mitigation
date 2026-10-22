sudo openssl x509 \
  -in /etc/kubernetes/pki/apiserver-kubelet-client.crt \
  -noout -subject -issuer

sudo kubectl \
  --server=https://100.96.31.124:6443 \
  --certificate-authority=/etc/kubernetes/pki/ca.crt \
  --client-certificate=/etc/kubernetes/pki/apiserver-kubelet-client.crt \
  --client-key=/etc/kubernetes/pki/apiserver-kubelet-client.key \
  auth can-i create clusterrolebindings

