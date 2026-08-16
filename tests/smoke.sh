#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VHEC=/usr/local/sbin/vhec

cleanup() {
  if [ -f /run/vhec/xray.pid ]; then
    sudo kill "$(cat /run/vhec/xray.pid)" 2>/dev/null || true
  fi
}
trap cleanup EXIT

sudo env PUBLIC_HOST=203.0.113.10 PORT=24443 HTTP_UDP_POLICY=block bash "$ROOT/vhec.sh" install

sudo jq -e '
  .inbounds[0].protocol == "vless" and
  .inbounds[0].settings.clients[0].flow == "xtls-rprx-vision" and
  .inbounds[0].streamSettings.network == "xhttp" and
  .inbounds[0].streamSettings.xhttpSettings.mode == "stream-one" and
  .inbounds[0].sniffing.routeOnly == false and
  .outbounds[0].protocol == "freedom"
' /etc/vhec/server.json >/dev/null

sudo jq -e '
  .dns.servers[0] == "fakedns" and
  .fakeDns[0].ipPool == "198.18.0.0/15" and
  .inbounds[0].sniffing.destOverride[0] == "fakedns" and
  .inbounds[0].sniffing.routeOnly == false and
  .outbounds[0].streamSettings.network == "xhttp" and
  .outbounds[0].streamSettings.xhttpSettings.host == "203.0.113.10"
' /etc/vhec/client-v2rayng.json >/dev/null

sudo grep -q 'type=xhttp' /etc/vhec/client-link.txt
sudo grep -q 'flow=xtls-rprx-vision' /etc/vhec/client-link.txt

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
