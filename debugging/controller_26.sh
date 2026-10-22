sudo kubectl --kubeconfig=/etc/kubernetes/super-admin.conf \
  apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: kubeadm:kubeadm-config-reader
  namespace: kube-system
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  resourceNames: ["kubeadm-config"]
  verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: kubeadm:kubeadm-config-reader
  namespace: kube-system
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: kubeadm:kubeadm-config-reader
subjects:
- kind: Group
  name: system:bootstrappers
  apiGroup: rbac.authorization.k8s.io
EOF

sudo kubectl --kubeconfig=/etc/kubernetes/super-admin.conf \
  -n kube-system get configmap kubeadm-config