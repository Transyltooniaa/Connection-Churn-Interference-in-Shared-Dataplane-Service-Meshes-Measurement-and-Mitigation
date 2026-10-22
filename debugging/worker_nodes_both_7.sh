echo "=== Runtime version ==="
containerd --version

echo "=== Effective cgroup configuration ==="
sudo containerd config dump | grep -n -B 8 -A 3 'SystemdCgroup'

echo "=== CRI plugin status ==="
sudo ctr plugins ls | grep -E 'io.containerd.(cri|grpc.v1.cri)'