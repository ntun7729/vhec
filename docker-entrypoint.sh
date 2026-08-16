#!/usr/bin/env bash
set -Eeuo pipefail

# Container mode is intentionally silent. Xray, cloudflared, the status server,
# and entrypoint diagnostics all inherit /dev/null for stdout/stderr.
exec >/dev/null 2>&1

STATE_DIR="${VHEC_STATE_DIR:-/etc/vhec}"
ENV_FILE="$STATE_DIR/vhec.env"
SERVER_CONFIG="$STATE_DIR/server.json"
CLIENT_CONFIG="$STATE_DIR/client-v2rayng.json"
CLIENT_LINK="$STATE_DIR/client-link.txt"
IDENTITY_FILE="$STATE_DIR/identity.json"
TOKEN_FILE="$STATE_DIR/cloudflared.token"
XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
CLOUDFLARED_BIN="${CLOUDFLARED_BIN:-/usr/local/bin/cloudflared}"
WEB_BIN="${WEB_BIN:-/usr/local/bin/vhec-web}"

die() { printf '[vhec] ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[vhec] %s\n' "$*"; }

mkdir -p "$STATE_DIR"
chmod 0700 "$STATE_DIR" 2>/dev/null || true
# shellcheck source=/dev/null
. /usr/local/lib/vhec/render.sh

generate_vlessenc() {
  local out idx
  out="$($XRAY_BIN vlessenc)"
  case "$VLESSENC_AUTH" in
    x25519|X25519) idx=1; VLESSENC_AUTH=x25519 ;;
    mlkem768|ml-kem-768|pq) idx=2; VLESSENC_AUTH=mlkem768 ;;
    *) die "VLESSENC_AUTH must be x25519 or mlkem768" ;;
  esac
  DECRYPTION="$(printf '%s\n' "$out" | sed -n 's/.*"decryption": "\([^"]*\)".*/\1/p' | sed -n "${idx}p")"
  ENCRYPTION="$(printf '%s\n' "$out" | sed -n 's/.*"encryption": "\([^"]*\)".*/\1/p' | sed -n "${idx}p")"
  [ -n "$DECRYPTION" ] && [ -n "$ENCRYPTION" ] || die "failed to parse xray vlessenc output"
}

VLESSENC_AUTH="${VLESSENC_AUTH:-x25519}"
case "$VLESSENC_AUTH" in
  x25519|X25519) VLESSENC_AUTH=x25519 ;;
  mlkem768|ml-kem-768|pq) VLESSENC_AUTH=mlkem768 ;;
  *) die "VLESSENC_AUTH must be x25519 or mlkem768" ;;
esac

stored_auth=''
if [ -f "$IDENTITY_FILE" ]; then
  stored_auth="$(jq -r '.vlessencAuth // empty' "$IDENTITY_FILE")"
  UUID="${UUID:-$(jq -r '.uuid // empty' "$IDENTITY_FILE") }"
  UUID="${UUID% }"
  XHTTP_PATH="${XHTTP_PATH:-$(jq -r '.xhttpPath // empty' "$IDENTITY_FILE") }"
  XHTTP_PATH="${XHTTP_PATH% }"
fi

UUID="${UUID:-$($XRAY_BIN uuid | head -n1)}"
XHTTP_PATH="${XHTTP_PATH:-/x/$(openssl rand -hex 12)}"
case "$XHTTP_PATH" in /*) ;; *) XHTTP_PATH="/$XHTTP_PATH" ;; esac

if [ -n "${DECRYPTION:-}" ] || [ -n "${ENCRYPTION:-}" ]; then
  [ -n "${DECRYPTION:-}" ] && [ -n "${ENCRYPTION:-}" ] || die "DECRYPTION and ENCRYPTION must be provided together"
elif [ -f "$IDENTITY_FILE" ] && [ "$stored_auth" = "$VLESSENC_AUTH" ]; then
  DECRYPTION="$(jq -r '.decryption // empty' "$IDENTITY_FILE")"
  ENCRYPTION="$(jq -r '.encryption // empty' "$IDENTITY_FILE")"
  [ -n "$DECRYPTION" ] && [ -n "$ENCRYPTION" ] || generate_vlessenc
else
  generate_vlessenc
fi

PORT="${PORT:-8080}"
case "$PORT" in *[!0-9]*|'') die "PORT must be numeric" ;; esac
PUBLIC_HOST="${PUBLIC_HOST:-}"
OUTBOUND_TYPE="${OUTBOUND_TYPE:-direct}"
OUTBOUND_HOST="${OUTBOUND_HOST:-}"
OUTBOUND_PORT="${OUTBOUND_PORT:-}"
OUTBOUND_USER="${OUTBOUND_USER:-}"
OUTBOUND_PASS="${OUTBOUND_PASS:-}"
HTTP_UDP_POLICY="${HTTP_UDP_POLICY:-block}"
CF_DOMAIN="${CF_DOMAIN:-}"
CF_PROTOCOL="${CF_PROTOCOL:-auto}"

if [ -n "${CF_TUNNEL_TOKEN:-}" ]; then
  CF_TUNNEL_TOKEN_SET=1
  LISTEN="${LISTEN:-127.0.0.1}"
  XHTTP_MODE="${XHTTP_MODE:-auto}"
  umask 077
  printf '%s' "$CF_TUNNEL_TOKEN" > "$TOKEN_FILE"
  chmod 0600 "$TOKEN_FILE"
else
  CF_TUNNEL_TOKEN_SET=0
  LISTEN="${LISTEN:-0.0.0.0}"
  XHTTP_MODE="${XHTTP_MODE:-stream-one}"
  rm -f "$TOKEN_FILE"
fi

case "$XHTTP_MODE" in auto|packet-up|stream-up|stream-one) ;; *) die "XHTTP_MODE must be auto, packet-up, stream-up, or stream-one" ;; esac
case "$OUTBOUND_TYPE" in direct|socks|http) ;; *) die "OUTBOUND_TYPE must be direct, socks, or http" ;; esac
if [ "$OUTBOUND_TYPE" != direct ]; then
  [ -n "$OUTBOUND_HOST" ] && [ -n "$OUTBOUND_PORT" ] || die "OUTBOUND_HOST and OUTBOUND_PORT are required for $OUTBOUND_TYPE"
  case "$OUTBOUND_PORT" in *[!0-9]*|'') die "OUTBOUND_PORT must be numeric" ;; esac
fi
case "$HTTP_UDP_POLICY" in direct|block) ;; *) die "HTTP_UDP_POLICY must be direct or block" ;; esac

identity_tmp="$(mktemp)"
jq -n \
  --arg uuid "$UUID" \
  --arg path "$XHTTP_PATH" \
  --arg auth "$VLESSENC_AUTH" \
  --arg dec "$DECRYPTION" \
  --arg enc "$ENCRYPTION" \
  '{uuid:$uuid,xhttpPath:$path,vlessencAuth:$auth,decryption:$dec,encryption:$enc}' > "$identity_tmp"
install -m 0600 "$identity_tmp" "$IDENTITY_FILE"
rm -f "$identity_tmp"

write_env
render_all

cleanup() {
  local rc=$?
  local pid
  trap - EXIT INT TERM
  for pid in "${web_pid:-}" "${xray_pid:-}" "${cf_pid:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done
  for pid in "${web_pid:-}" "${xray_pid:-}" "${cf_pid:-}"; do
    [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
  done
  exit "$rc"
}
trap cleanup EXIT INT TERM

socat TCP-LISTEN:30,bind=0.0.0.0,reuseaddr,fork EXEC:"$WEB_BIN" &
web_pid=$!

"$XRAY_BIN" run -config "$SERVER_CONFIG" &
xray_pid=$!

pids=("$web_pid" "$xray_pid")
if [ "$CF_TUNNEL_TOKEN_SET" = 1 ]; then
  "$CLOUDFLARED_BIN" tunnel --no-autoupdate --protocol "$CF_PROTOCOL" run --token-file "$TOKEN_FILE" &
  cf_pid=$!
  pids+=("$cf_pid")
fi

set +e
wait -n "${pids[@]}"
rc=$?
set -e
exit "$rc"
