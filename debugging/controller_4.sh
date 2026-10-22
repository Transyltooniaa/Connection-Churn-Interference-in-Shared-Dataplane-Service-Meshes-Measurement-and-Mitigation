cat /etc/os-release
uname -r
stat -fc %T /sys/fs/cgroup
sudo systemctl is-active containerd
sudo containerd --version