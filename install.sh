#!/usr/bin/env bash
set -Eeuo pipefail

REPO="${VHEC_REPO:-ntun7729/vhec}"
REF="${VHEC_REF:-main}"
SOURCE_DIR="${VHEC_SOURCE_DIR:-}"
TMP_DIR=""

log() { printf '[vhec-install] %s\n' "$*"; }
die() { printf '[vhec-install] ERROR: %s\n' "$*" >&2; exit 1; }
need_root() { [ "$(id -u)" -eq 0 ] || die "run with sudo/root"; }

cleanup() {
  [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"
}
trap cleanup EXIT

need_root

if [ -r /dev/tty ]; then
  TTY=/dev/tty
else
  TTY=''
fi

ask() {
  local var="$1" label="$2" default="${3:-}" value="${!var:-}"
  if [ -n "$value" ]; then return; fi
  if [ -z "$TTY" ]; then
    printf -v "$var" '%s' "$default"
    return
  fi
  if [ -n "$default" ]; then
    printf '%s [%s]: ' "$label" "$default" >"$TTY"
  else
    printf '%s: ' "$label" >"$TTY"
  fi
  IFS= read -r value <"$TTY" || true
  printf -v "$var" '%s' "${value:-$default}"
}

ask_secret() {
  local var="$1" label="$2" value="${!var:-}"
  if [ -n "$value" ]; then return; fi
  if [ -z "$TTY" ]; then return; fi
  printf '%s: ' "$label" >"$TTY"
  IFS= read -r -s value <"$TTY" || true
  printf '\n' >"$TTY"
  printf -v "$var" '%s' "$value"
}

TMP_DIR="$(mktemp -d)"
mkdir -p "$TMP_DIR/lib"

fetch_file() {
  local path="$1" dest="$2"
  if [ -n "$SOURCE_DIR" ]; then
    cp "$SOURCE_DIR/$path" "$dest"
    return
  fi
  command -v curl >/dev/null 2>&1 || die "curl is required to download VHEC"
  local url="https://raw.githubusercontent.com/${REPO}/${REF}/${path}"
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    curl -fsSL --retry 3 -H "Authorization: Bearer ${GITHUB_TOKEN}" "$url" -o "$dest"
  else
    curl -fsSL --retry 3 "$url" -o "$dest"
  fi
}

log "downloading VHEC host installer"
fetch_file vhec.sh "$TMP_DIR/vhec.sh"
fetch_file lib/render.sh "$TMP_DIR/lib/render.sh"
fetch_file lib/services.sh "$TMP_DIR/lib/services.sh"
chmod 0755 "$TMP_DIR/vhec.sh"

CF_TUNNEL_TOKEN="${CF_TUNNEL_TOKEN:-}"
CF_DOMAIN="${CF_DOMAIN:-}"
CF_PROTOCOL="${CF_PROTOCOL:-auto}"
XHTTP_MODE="${XHTTP_MODE:-auto}"
OUTBOUND_TYPE="${OUTBOUND_TYPE:-}"
OUTBOUND_HOST="${OUTBOUND_HOST:-}"
OUTBOUND_PORT="${OUTBOUND_PORT:-}"
OUTBOUND_USER="${OUTBOUND_USER:-}"
OUTBOUND_PASS="${OUTBOUND_PASS:-}"
HTTP_UDP_POLICY="${HTTP_UDP_POLICY:-block}"
VLESSENC_AUTH="${VLESSENC_AUTH:-x25519}"
PORT="${PORT:-8080}"
TLS_PORT="${TLS_PORT:-8443}"

ask_secret CF_TUNNEL_TOKEN "Cloudflare Tunnel token (leave empty for no tunnel)"
if [ -n "$CF_TUNNEL_TOKEN" ]; then
  ask CF_DOMAIN "Cloudflare public hostname" "${CF_DOMAIN:-}"
fi
ask OUTBOUND_TYPE "Outbound type: direct, http, or socks" "direct"
case "$OUTBOUND_TYPE" in
  direct)
    OUTBOUND_HOST=''
    OUTBOUND_PORT=''
    OUTBOUND_USER=''
    OUTBOUND_PASS=''
    ;;
  http|socks)
    ask OUTBOUND_HOST "${OUTBOUND_TYPE^^} proxy host/IP" "${OUTBOUND_HOST:-}"
    ask OUTBOUND_PORT "${OUTBOUND_TYPE^^} proxy port" "${OUTBOUND_PORT:-}"
    [ -n "$OUTBOUND_HOST" ] || die "proxy host is required for $OUTBOUND_TYPE"
    [ -n "$OUTBOUND_PORT" ] || die "proxy port is required for $OUTBOUND_TYPE"
    case "$OUTBOUND_PORT" in *[!0-9]*|'') die "proxy port must be numeric" ;; esac
    ask OUTBOUND_USER "Proxy username (optional)" "${OUTBOUND_USER:-}"
    if [ -n "$OUTBOUND_USER" ]; then
      ask_secret OUTBOUND_PASS "Proxy password"
    fi
    ;;
  *) die "OUTBOUND_TYPE must be direct, http, or socks" ;;
esac

case "$XHTTP_MODE" in auto|packet-up|stream-up|stream-one) ;; *) die "invalid XHTTP_MODE: $XHTTP_MODE" ;; esac
case "$CF_PROTOCOL" in auto|quic|http2) ;; *) die "invalid CF_PROTOCOL: $CF_PROTOCOL" ;; esac
case "$HTTP_UDP_POLICY" in direct|block) ;; *) die "invalid HTTP_UDP_POLICY: $HTTP_UDP_POLICY" ;; esac
case "$VLESSENC_AUTH" in x25519|X25519|mlkem768|ml-kem-768|pq) ;; *) die "invalid VLESSENC_AUTH: $VLESSENC_AUTH" ;; esac
case "$PORT" in *[!0-9]*|'') die "PORT must be numeric" ;; esac
case "$TLS_PORT" in *[!0-9]*|'') die "TLS_PORT must be numeric" ;; esac
[ "$PORT" != "$TLS_PORT" ] || die "PORT and TLS_PORT must differ"

log "installing directly on this Linux host (Docker is not used)"
export CF_TUNNEL_TOKEN CF_DOMAIN CF_PROTOCOL XHTTP_MODE
export OUTBOUND_TYPE OUTBOUND_HOST OUTBOUND_PORT OUTBOUND_USER OUTBOUND_PASS
export HTTP_UDP_POLICY VLESSENC_AUTH PORT TLS_PORT
bash "$TMP_DIR/vhec.sh" install

printf '\nOne-click host installation complete.\n'
if [ -n "$CF_TUNNEL_TOKEN" ]; then
  printf 'Cloudflare origin: https://127.0.0.1:%s\n' "$TLS_PORT"
  printf 'Cloudflare route settings: HTTP2 connection = On, No TLS Verify = On\n'
fi
printf 'Client link: sudo vhec client\n'
printf 'Status:      sudo vhec status\n'
printf 'Settings:    sudo vhec show\n'
