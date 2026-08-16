#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VHEC=/usr/local/sbin/vhec

cleanup() {
  if [ -f /run/vhec/xray.pid ]; then
    sudo kill "$(cat /run/vhec/xray.pid)" 2>/dev/null || true
  fi
}
on_error() {
  echo "--- vhec-xray status ---" >&2
  sudo systemctl --no-pager --full status vhec-xray.service >&2 || true
  echo "--- vhec-xray journal ---" >&2
  sudo journalctl -u vhec-xray.service -n 80 --no-pager >&2 || true
}
trap cleanup EXIT
trap on_error ERR

sudo env PUBLIC_HOST=203.0.113.10 PORT=24443 TLS_PORT=24444 HTTP_UDP_POLICY=block bash "$ROOT/vhec.sh" install

sudo jq -e '
  (.inbounds | length) == 2 and
  .inbounds[0].protocol == "vless" and
  .inbounds[0].settings.clients[0].flow == "xtls-rprx-vision" and
  .inbounds[0].streamSettings.network == "xhttp" and
  .inbounds[0].streamSettings.security == "none" and
  .inbounds[0].streamSettings.xhttpSettings.mode == "auto" and
  .inbounds[0].sniffing.routeOnly == false and
  .inbounds[1].port == 24444 and
  .inbounds[1].streamSettings.security == "tls" and
  .inbounds[1].streamSettings.tlsSettings.alpn[0] == "h2" and
  .inbounds[1].streamSettings.xhttpSettings.mode == "auto" and
  .outbounds[0].protocol == "freedom"
' /etc/vhec/server.json >/dev/null

sudo test -s /etc/vhec/origin-cert.pem
sudo test -s /etc/vhec/origin-key.pem
for _ in $(seq 1 20); do
  if timeout 4 openssl s_client -connect 127.0.0.1:24444 -servername localhost -alpn h2 </dev/null 2>/dev/null | grep -q 'ALPN protocol: h2'; then
    break
  fi
  sleep 0.5
done
timeout 4 openssl s_client -connect 127.0.0.1:24444 -servername localhost -alpn h2 </dev/null 2>/dev/null | grep -q 'ALPN protocol: h2'

sudo jq -e '
  .dns.servers[0] == "fakedns" and
  .fakeDns[0].ipPool == "198.18.0.0/15" and
  .inbounds[0].sniffing.destOverride[0] == "fakedns" and
  .inbounds[0].sniffing.routeOnly == false and
  .outbounds[0].streamSettings.network == "xhttp" and
  .outbounds[0].streamSettings.xhttpSettings.mode == "auto" and
  .outbounds[0].streamSettings.xhttpSettings.host == "203.0.113.10"
' /etc/vhec/client-v2rayng.json >/dev/null

sudo grep -q 'type=xhttp' /etc/vhec/client-link.txt
sudo grep -q 'flow=xtls-rprx-vision' /etc/vhec/client-link.txt
sudo grep -q 'mode=auto' /etc/vhec/client-link.txt

sudo "$VHEC" outbound http 127.0.0.1 18080
sudo "$VHEC" udp-policy block
sudo jq -e '
  .outbounds[0].protocol == "http" and
  .outbounds[0].settings.address == "127.0.0.1" and
  .routing.rules[0].outboundTag == "dns-out" and
  .routing.rules[1].network == "udp" and
  .routing.rules[1].outboundTag == "block"
' /etc/vhec/server.json >/dev/null

sudo "$VHEC" udp-policy direct
sudo jq -e '.routing.rules[1].network == "udp" and .routing.rules[1].outboundTag == "direct"' \
  /etc/vhec/server.json >/dev/null

sudo "$VHEC" outbound socks 127.0.0.1 1080
sudo jq -e '.outbounds[0].protocol == "socks" and .outbounds[0].settings.port == 1080' \
  /etc/vhec/server.json >/dev/null

sudo "$VHEC" outbound direct
sudo jq -e '.outbounds[0].protocol == "freedom"' /etc/vhec/server.json >/dev/null

sudo /usr/local/bin/xray run -test -config /etc/vhec/server.json
sudo /usr/local/bin/xray run -test -config /etc/vhec/client-v2rayng.json

echo "VHEC smoke test passed"
