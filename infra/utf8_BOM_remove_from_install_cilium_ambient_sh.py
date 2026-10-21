from pathlib import Path

p = Path("infra/install-cilium-ambient.sh")
data = p.read_bytes()

if data.startswith(b"\xef\xbb\xbf"):
    data = data[3:]

data = data.replace(b"\r\n", b"\n")
p.write_bytes(data)

print("Removed UTF-8 BOM and normalized line endings.")