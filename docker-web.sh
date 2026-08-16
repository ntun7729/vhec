#!/usr/bin/env bash
set -u

STATE_DIR="${VHEC_STATE_DIR:-/etc/vhec}"
LINK_FILE="$STATE_DIR/client-link.txt"

IFS= read -r request || exit 0
request="${request%$'\r'}"
method="${request%% *}"
rest="${request#* }"
path="${rest%% *}"

while IFS= read -r line; do
  [ "$line" = $'\r' ] || [ -z "$line" ] && break
done

status='200 OK'
case "$path" in
  /healthz)
    body=$'ok\n'
    ;;
  /v)
    if [ -s "$LINK_FILE" ]; then
      body="$(cat "$LINK_FILE")"$'\n'
    else
      status='503 Service Unavailable'
      body=$'starting\n'
    fi
    ;;
  *)
    status='404 Not Found'
    body=$'not found\n'
    ;;
esac

case "$method" in
  GET|HEAD) ;;
  *)
    status='405 Method Not Allowed'
    body=$'method not allowed\n'
    ;;
esac

length="$(LC_ALL=C printf '%s' "$body" | wc -c | tr -d ' ')"
printf 'HTTP/1.1 %s\r\n' "$status"
printf 'Content-Type: text/plain; charset=utf-8\r\n'
printf 'Content-Length: %s\r\n' "$length"
printf 'Cache-Control: no-store\r\n'
printf 'Connection: close\r\n\r\n'
[ "$method" = HEAD ] || printf '%s' "$body"
