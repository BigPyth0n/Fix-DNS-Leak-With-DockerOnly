#!/bin/bash
set -euo pipefail

# بررسی دسترسی root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (use sudo)."
    exit 1
fi

# ========== نصب ابزارهای ضروری ==========
if ! command -v dig &> /dev/null; then
    echo "dig not found. Installing dnsutils..."
    apt install -y dnsutils
fi

# ========== نصب خودکار Docker ==========
if ! command -v docker &> /dev/null; then
    echo "Docker not found. Installing Docker..."
    apt update -y
    apt install -y ca-certificates curl gnupg
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt update -y
    apt-cache policy docker-ce
    apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    echo "Docker installation completed."
else
    echo "Docker is already installed."
fi

# ========== راه‌اندازی DNS proxy با cloudflared ==========
if ! docker ps -a --format '{{.Names}}' | grep -q "^cloudflared$"; then
    echo "Starting cloudflared DNS proxy container..."
    docker run -d \
        --name cloudflared \
        --restart unless-stopped \
        -p 127.0.0.1:53:53/udp \
        cloudflare/cloudflared:latest proxy-dns
    echo "cloudflared container started."
else
    echo "cloudflared container already exists. Skipping."
fi

# ========== تست DNS ==========
cat > dns-test.sh <<'EOF'
#!/bin/bash
set -euo pipefail
echo "== DNS wiring =="
echo -n "/etc/resolv.conf -> "; readlink -f /etc/resolv.conf
echo

echo "== cloudflared socket =="
ss -tulnp | grep -E "127\.0\.0\.1:53" || echo "cloudflared NOT listening on 127.0.0.1:53"
echo

echo "== dig direct to local resolver =="
dig +time=2 +tries=1 +short @127.0.0.1 google.com || echo "dig @127.0.0.1 failed"
echo

echo "== system path resolution =="
dig +time=2 +tries=1 +short google.com || echo "dig system path failed"
echo

echo "== whoami via Cloudflare (TXT) =="
echo -n "127.0.0.1 -> "; dig +short TXT whoami.cloudflare @127.0.0.1 || true
echo -n "1.1.1.1   -> "; dig +short TXT whoami.cloudflare @1.1.1.1 || true
echo

echo "== resolvectl summary =="
if command -v resolvectl &> /dev/null; then
    resolvectl status 2>/dev/null | sed -n '1,120p' || echo "resolvectl status failed"
else
    echo "resolvectl not available"
fi
echo

echo "== dnsleaktest style lookups =="
for i in {1..5}; do
  echo -n "test$i: "
  dig +short @127.0.0.1 test$i.dnsleaktest.com || true
done
EOF
chmod +x dns-test.sh
./dns-test.sh
