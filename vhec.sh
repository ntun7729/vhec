#!/usr/bin/env bash
set -Eeuo pipefail

APP="vhec"
STATE_DIR="${VHEC_STATE_DIR:-/etc/vhec}"
ENV_FILE="$STATE_DIR/vhec.env"
SERVER_CONFIG="$STATE_DIR/server.json"
CLIENT_CONFIG="$STATE_DIR/client-v2rayng.json"
CLIENT_LINK="$STATE_DIR/client-link.txt"
XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
CLOUDFLARED_BIN="${CLOUDFLARED_BIN:-/usr/local/bin/cloudflared}"
SELF="${BASH_SOURCE[0]}"

log() { printf '[vhec] %s\n' "$*"; }
die() { printf '[vhec] ERROR: %s\n' "$*" >&2; exit 1; }
need_root() { [ "$(id -u)" -eq 0 ] || die "run as root"; }
have() { command -v "$1" >/dev/null 2>&1; }

SOURCE_DIR="$(cd "$(dirname "$SELF")" 2>/dev/null && pwd || true)"
if [ -f "$SOURCE_DIR/lib/render.sh" ]; then
  LIB_DIR="$SOURCE_DIR/lib"
else
  LIB_DIR="/usr/local/lib/vhec"
fi
[ -f "$LIB_DIR/render.sh" ] && [ -f "$LIB_DIR/services.sh" ] || die "missing VHEC libraries"
# shellcheck source=/dev/null
. "$LIB_DIR/render.sh"
# shellcheck source=/dev/null
. "$LIB_DIR/services.sh"

install_packages() {
  local pkgs=(curl unzip jq openssl ca-certificates)
  if have apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y "${pkgs[@]}"
  elif have dnf; then
    dnf install -y "${pkgs[@]}"
  elif have yum; then
    yum install -y "${pkgs[@]}"
  elif have apk; then
    apk add --no-cache "${pkgs[@]}"
  else
    for p in curl unzip jq openssl; do have "$p" || die "missing $p and no supported package manager found"; done
  fi
}

arch_name() {
  case "$(uname -m)" in
    x86_64|amd64) printf '64' ;;
    aarch64|arm64) printf 'arm64-v8a' ;;
    armv7l|armv7) printf 'arm32-v7a' ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
}

cloudflared_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'amd64' ;;
    aarch64|arm64) printf 'arm64' ;;
    armv7l|armv7) printf 'arm' ;;
    *) die "unsupported architecture for cloudflared: $(uname -m)" ;;
  esac
}

install_xray() {
  if [ -x "$XRAY_BIN" ] && "$XRAY_BIN" version >/dev/null 2>&1; then
    log "Xray already installed: $($XRAY_BIN version | head -n1)"
    return
  fi
  local tmp arch
  tmp="$(mktemp -d)"
  arch="$(arch_name)"
  log "installing latest Xray-core"
  curl -fL --retry 3 "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${arch}.zip" -o "$tmp/xray.zip"
  unzip -q "$tmp/xray.zip" -d "$tmp/xray"
  install -m 0755 "$tmp/xray/xray" "$XRAY_BIN"
  [ -f "$tmp/xray/geoip.dat" ] && install -m 0644 "$tmp/xray/geoip.dat" /usr/local/share/xray/geoip.dat 2>/dev/null || true
  [ -f "$tmp/xray/geosite.dat" ] && install -m 0644 "$tmp/xray/geosite.dat" /usr/local/share/xray/geosite.dat 2>/dev/null || true
  rm -rf "$tmp"
}

install_cloudflared() {
  [ -x "$CLOUDFLARED_BIN" ] && return
  local a
  a="$(cloudflared_arch)"
  log "installing latest cloudflared"
  curl -fL --retry 3 "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${a}" -o "$CLOUDFLARED_BIN"
  chmod 0755 "$CLOUDFLARED_BIN"
}

random_path() {
  openssl rand -hex 12 | sed 's#^#/x/#'
}

generate_uuid() {
  "$XRAY_BIN" uuid 2>/dev/null | head -n1
}

generate_vlessenc() {
  local out idx
  out="$($XRAY_BIN vlessenc)"
  case "${VLESSENC_AUTH:-x25519}" in
    x25519|X25519) idx=1 ;;
    mlkem768|ml-kem-768|pq) idx=2 ;;
    *) die "VLESSENC_AUTH must be x25519 or mlkem768" ;;
  esac
  DECRYPTION="$(printf '%s\n' "$out" | sed -n 's/.*"decryption": "\([^"]*\)".*/\1/p' | sed -n "${idx}p")"
  ENCRYPTION="$(printf '%s\n' "$out" | sed -n 's/.*"encryption": "\([^"]*\)".*/\1/p' | sed -n "${idx}p")"
  [ -n "$DECRYPTION" ] && [ -n "$ENCRYPTION" ] || die "failed to parse xray vlessenc output"
}

generate_origin_tls() {
  if [ -s "$TLS_CERT_FILE" ] && [ -s "$TLS_KEY_FILE" ]; then
    return
  fi
  rm -f "$TLS_CERT_FILE" "$TLS_KEY_FILE"
  umask 077
  openssl req -x509 -nodes -newkey rsa:2048 -sha256 -days 3650 \
    -subj '/CN=localhost' \
    -keyout "$TLS_KEY_FILE" \
    -out "$TLS_CERT_FILE" >/dev/null 2>&1
  chmod 0600 "$TLS_KEY_FILE"
  chmod 0644 "$TLS_CERT_FILE"
}

configure_tls_origin() {
  TLS_ORIGIN_ENABLED=1
  TLS_PORT="${TLS_PORT:-8443}"
  case "$TLS_PORT" in *[!0-9]*|'') die "TLS_PORT must be numeric" ;; esac
  [ "$TLS_PORT" != "$PORT" ] || die "TLS_PORT must differ from PORT"
  TLS_CERT_FILE="${TLS_CERT_FILE:-$STATE_DIR/origin-cert.pem}"
  TLS_KEY_FILE="${TLS_KEY_FILE:-$STATE_DIR/origin-key.pem}"
  generate_origin_tls
}

install_cmd() {
  need_root
  install_packages
  mkdir -p "$STATE_DIR" /usr/local/share/xray
  chmod 0700 "$STATE_DIR" 2>/dev/null || true
  install_xray

  PORT="${PORT:-8080}"
  case "$PORT" in *[!0-9]*|'') die "PORT must be numeric" ;; esac
  PUBLIC_HOST="${PUBLIC_HOST:-}"
  UUID="${UUID:-$(generate_uuid)}"
  XHTTP_PATH="${XHTTP_PATH:-$(random_path)}"
  VLESSENC_AUTH="${VLESSENC_AUTH:-x25519}"
  OUTBOUND_TYPE="${OUTBOUND_TYPE:-direct}"
  OUTBOUND_HOST="${OUTBOUND_HOST:-}"
  OUTBOUND_PORT="${OUTBOUND_PORT:-}"
  OUTBOUND_USER="${OUTBOUND_USER:-}"
  OUTBOUND_PASS="${OUTBOUND_PASS:-}"
  HTTP_UDP_POLICY="${HTTP_UDP_POLICY:-block}"
  CF_DOMAIN="${CF_DOMAIN:-}"
  CF_PROTOCOL="${CF_PROTOCOL:-auto}"
  XHTTP_MODE="${XHTTP_MODE:-auto}"
  configure_tls_origin

  case "$XHTTP_MODE" in auto|packet-up|stream-up|stream-one) ;; *) die "XHTTP_MODE must be auto, packet-up, stream-up, or stream-one" ;; esac
  case "$OUTBOUND_TYPE" in direct|socks|http) ;; *) die "OUTBOUND_TYPE must be direct, socks, or http" ;; esac
  if [ "$OUTBOUND_TYPE" != direct ]; then
    [ -n "$OUTBOUND_HOST" ] && [ -n "$OUTBOUND_PORT" ] || die "OUTBOUND_HOST and OUTBOUND_PORT are required for $OUTBOUND_TYPE"
    case "$OUTBOUND_PORT" in *[!0-9]*|'') die "OUTBOUND_PORT must be numeric" ;; esac
  fi
  case "$HTTP_UDP_POLICY" in direct|block) ;; *) die "HTTP_UDP_POLICY must be direct or block" ;; esac

  if [ -n "${CF_TUNNEL_TOKEN:-}" ]; then
    CF_TUNNEL_TOKEN_SET=1
    LISTEN="${LISTEN:-127.0.0.1}"
    install_cloudflared
    umask 077
    printf '%s' "$CF_TUNNEL_TOKEN" > "$STATE_DIR/cloudflared.token"
    chmod 0600 "$STATE_DIR/cloudflared.token"
  else
    CF_TUNNEL_TOKEN_SET=0
    LISTEN="${LISTEN:-0.0.0.0}"
    rm -f "$STATE_DIR/cloudflared.token"
  fi

  generate_vlessenc
  write_env
  render_all

  if [ -r "$SELF" ]; then
    install -m 0755 "$SELF" /usr/local/sbin/vhec 2>/dev/null || true
    mkdir -p /usr/local/lib/vhec
    install -m 0644 "$LIB_DIR/render.sh" /usr/local/lib/vhec/render.sh
    install -m 0644 "$LIB_DIR/services.sh" /usr/local/lib/vhec/services.sh
  fi
  case "$(service_manager)" in
    systemd) write_systemd_units ;;
    openrc) write_openrc_units ;;
    fallback) log "no systemd/OpenRC detected; using a pidfile runner (not automatically persistent across reboot)" ;;
  esac
  restart_services
  show_cmd
}

outbound_cmd() {
  need_root; load_env
  local type="${1:-}" host="${2:-}" port="${3:-}" user="${4:-}" pass="${5:-}"
  case "$type" in
    direct)
      set_env_key OUTBOUND_TYPE direct
      set_env_key OUTBOUND_HOST ''
      set_env_key OUTBOUND_PORT ''
      set_env_key OUTBOUND_USER ''
      set_env_key OUTBOUND_PASS ''
      ;;
    socks|http)
      [ -n "$host" ] && [ -n "$port" ] || die "usage: vhec outbound $type HOST PORT [USER] [PASS]"
      case "$port" in *[!0-9]*|'') die "port must be numeric" ;; esac
      set_env_key OUTBOUND_TYPE "$type"
      set_env_key OUTBOUND_HOST "$host"
      set_env_key OUTBOUND_PORT "$port"
      set_env_key OUTBOUND_USER "$user"
      set_env_key OUTBOUND_PASS "$pass"
      ;;
    *) die "usage: vhec outbound direct | socks HOST PORT [USER] [PASS] | http HOST PORT [USER] [PASS]" ;;
  esac
  render_all
  restart_services
  show_cmd
}

cloudflare_cmd() {
  need_root; load_env
  local action="${1:-}" token="${2:-}" domain="${3:-}"
  case "$action" in
    enable)
      [ -n "$token" ] || die "usage: vhec cloudflare enable TOKEN [DOMAIN]"
      install_cloudflared
      PORT="${PORT:-8080}"
      configure_tls_origin
      umask 077; printf '%s' "$token" > "$STATE_DIR/cloudflared.token"; chmod 0600 "$STATE_DIR/cloudflared.token"
      set_env_key CF_TUNNEL_TOKEN_SET 1
      set_env_key LISTEN 127.0.0.1
      set_env_key XHTTP_MODE auto
      set_env_key TLS_ORIGIN_ENABLED 1
      set_env_key TLS_PORT "$TLS_PORT"
      set_env_key TLS_CERT_FILE "$TLS_CERT_FILE"
      set_env_key TLS_KEY_FILE "$TLS_KEY_FILE"
      [ -n "$domain" ] && set_env_key CF_DOMAIN "$domain"
      ;;
    disable)
      rm -f "$STATE_DIR/cloudflared.token"
      set_env_key CF_TUNNEL_TOKEN_SET 0
      set_env_key LISTEN 0.0.0.0
      set_env_key XHTTP_MODE auto
      ;;
    domain)
      [ -n "$token" ] || die "usage: vhec cloudflare domain DOMAIN"
      set_env_key CF_DOMAIN "$token"
      ;;
    *) die "usage: vhec cloudflare enable TOKEN [DOMAIN] | disable | domain DOMAIN" ;;
  esac
  render_all
  case "$(service_manager)" in systemd) write_systemd_units ;; openrc) write_openrc_units ;; esac
  restart_services
  show_cmd
}

mode_cmd() {
  need_root; load_env
  case "${1:-}" in auto|packet-up|stream-up|stream-one) set_env_key XHTTP_MODE "$1" ;; *) die "mode: auto|packet-up|stream-up|stream-one" ;; esac
  render_all; restart_services; show_cmd
}

udp_policy_cmd() {
  need_root; load_env
  case "${1:-}" in direct|block) set_env_key HTTP_UDP_POLICY "$1" ;; *) die "udp-policy: direct|block" ;; esac
  render_all; restart_services; show_cmd
}

show_cmd() {
  load_env
  printf '\nVHEC\n'
  printf '  inbound       VLESS Encryption + xtls-rprx-vision + XHTTP\n'
  printf '  plain origin  http://%s:%s\n' "$LISTEN" "$PORT"
  if [ "$TLS_ORIGIN_ENABLED" = 1 ]; then
    printf '  TLS/H2 origin https://%s:%s\n' "$LISTEN" "$TLS_PORT"
  fi
  printf '  XHTTP mode    %s\n' "$XHTTP_MODE"
  printf '  outbound      %s' "$OUTBOUND_TYPE"
  [ "$OUTBOUND_TYPE" = direct ] || printf ' -> %s:%s' "$OUTBOUND_HOST" "$OUTBOUND_PORT"
  printf '\n'
  printf '  HTTP UDP      %s\n' "$HTTP_UDP_POLICY"
  if [ "$CF_TUNNEL_TOKEN_SET" = 1 ]; then
    printf '  cloudflared   enabled (%s)\n' "${CF_DOMAIN:-domain-not-set}"
    if [ "$TLS_ORIGIN_ENABLED" = 1 ]; then
      printf '  CF origin     https://127.0.0.1:%s\n' "$TLS_PORT"
      printf '  CF settings   HTTP2 connection=On, No TLS Verify=On\n'
    else
      printf '  CF origin     http://127.0.0.1:%s\n' "$PORT"
    fi
    printf '  XHTTP path    %s\n' "$XHTTP_PATH"
  else
    printf '  cloudflared   disabled\n'
  fi
  printf '  server config %s\n' "$SERVER_CONFIG"
  printf '  client config %s\n' "$CLIENT_CONFIG"
  printf '  client link   %s\n\n' "$CLIENT_LINK"
  if [ "$CF_TUNNEL_TOKEN_SET" = 1 ] && [ -z "$CF_DOMAIN" ]; then
    printf 'Cloudflare Tunnel is running, but set the public hostname in the Cloudflare dashboard and then run:\n  vhec cloudflare domain proxy.example.com\n\n'
  fi
  if [ "$OUTBOUND_TYPE" = http ]; then
    printf 'HTTP outbound is TCP-only. Client FakeDNS is enabled in %s; UDP policy is %s.\n\n' "$CLIENT_CONFIG" "$HTTP_UDP_POLICY"
  fi
}

status_cmd() {
  load_env
  case "$(service_manager)" in
    systemd)
      systemctl --no-pager --full status vhec-xray.service || true
      [ "$CF_TUNNEL_TOKEN_SET" = 1 ] && systemctl --no-pager --full status vhec-cloudflared.service || true
      ;;
    openrc) rc-service vhec-xray status || true; [ "$CF_TUNNEL_TOKEN_SET" = 1 ] && rc-service vhec-cloudflared status || true ;;
    fallback) ps -fp "$(cat /run/vhec/xray.pid 2>/dev/null || echo 0)" || true; [ "$CF_TUNNEL_TOKEN_SET" = 1 ] && ps -fp "$(cat /run/vhec/cloudflared.pid 2>/dev/null || echo 0)" || true ;;
  esac
}

logs_cmd() {
  load_env
  case "$(service_manager)" in
    systemd)
      if [ "$CF_TUNNEL_TOKEN_SET" = 1 ]; then journalctl -u vhec-xray.service -u vhec-cloudflared.service -n 100 --no-pager; else journalctl -u vhec-xray.service -n 100 --no-pager; fi
      ;;
    *) tail -n 100 /var/log/vhec-xray.log /var/log/vhec-cloudflared.log 2>/dev/null || true ;;
  esac
}

client_cmd() {
  load_env
  cat "$CLIENT_LINK"
  printf '\nFull v2rayNG/Xray client JSON: %s\n' "$CLIENT_CONFIG"
}

usage() {
  cat <<'EOF_USAGE'
VHEC - VLESS Encryption + Vision + XHTTP

Commands:
  vhec install
  vhec outbound direct
  vhec outbound socks HOST PORT [USER] [PASS]
  vhec outbound http HOST PORT [USER] [PASS]
  vhec udp-policy direct|block
  vhec mode auto|packet-up|stream-up|stream-one
  vhec cloudflare enable TOKEN [DOMAIN]
  vhec cloudflare disable
  vhec cloudflare domain DOMAIN
  vhec render
  vhec restart
  vhec show
  vhec client
  vhec status
  vhec logs

Install environment variables:
  PORT=8080 TLS_PORT=8443 PUBLIC_HOST=1.2.3.4 XHTTP_MODE=auto
  OUTBOUND_TYPE=direct|socks|http OUTBOUND_HOST=... OUTBOUND_PORT=...
  OUTBOUND_USER=... OUTBOUND_PASS=... HTTP_UDP_POLICY=direct|block
  VLESSENC_AUTH=x25519|mlkem768
  CF_TUNNEL_TOKEN=... CF_DOMAIN=proxy.example.com CF_PROTOCOL=auto|quic|http2
EOF_USAGE
}

case "${1:-install}" in
  install) shift || true; install_cmd "$@" ;;
  outbound) shift; outbound_cmd "$@" ;;
  cloudflare) shift; cloudflare_cmd "$@" ;;
  mode) shift; mode_cmd "$@" ;;
  udp-policy) shift; udp_policy_cmd "$@" ;;
  render) need_root; render_all ;;
  restart) need_root; restart_services ;;
  show) show_cmd ;;
  client) client_cmd ;;
  status) status_cmd ;;
  logs) logs_cmd ;;
  -h|--help|help) usage ;;
  *) usage; exit 2 ;;
esac
