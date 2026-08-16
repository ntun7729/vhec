write_env() {
  umask 077
  : > "$ENV_FILE"
  local k
  for k in PORT LISTEN PUBLIC_HOST UUID XHTTP_PATH XHTTP_MODE VLESSENC_AUTH DECRYPTION ENCRYPTION OUTBOUND_TYPE OUTBOUND_HOST OUTBOUND_PORT OUTBOUND_USER OUTBOUND_PASS HTTP_UDP_POLICY CF_TUNNEL_TOKEN_SET CF_DOMAIN CF_PROTOCOL; do
    printf '%s=' "$k" >> "$ENV_FILE"
    printf '%q' "${!k}" >> "$ENV_FILE"
    printf '\n' >> "$ENV_FILE"
  done
  chmod 0600 "$ENV_FILE"
}

load_env() {
  [ -f "$ENV_FILE" ] || die "not installed; run: vhec install"
  # shellcheck disable=SC1090
  set -a; . "$ENV_FILE"; set +a
}

set_env_key() {
  local key="$1" value="$2" tmp
  tmp="$(mktemp)"
  {
    grep -v "^${key}=" "$ENV_FILE" || true
    printf '%s=' "$key"
    printf '%q' "$value"
    printf '\n'
  } > "$tmp"
  install -m 0600 "$tmp" "$ENV_FILE"
  rm -f "$tmp"
}

make_egress_json() {
  case "$OUTBOUND_TYPE" in
    direct)
      jq -cn '{tag:"egress",protocol:"freedom",settings:{targetStrategy:"UseIP"}}'
      ;;
    socks|http)
      [ -n "$OUTBOUND_HOST" ] || die "OUTBOUND_HOST is required for $OUTBOUND_TYPE"
      [ -n "$OUTBOUND_PORT" ] || die "OUTBOUND_PORT is required for $OUTBOUND_TYPE"
      jq -cn --arg proto "$OUTBOUND_TYPE" --arg h "$OUTBOUND_HOST" --argjson p "$OUTBOUND_PORT" --arg u "$OUTBOUND_USER" --arg pw "$OUTBOUND_PASS" '
        {tag:"egress",protocol:$proto,settings:{address:$h,port:$p},streamSettings:{sockopt:{domainStrategy:"UseIP"}}}
        | if ($u|length)>0 then .settings.user=$u | .settings.pass=$pw else . end'
      ;;
    *) die "OUTBOUND_TYPE must be direct, socks, or http" ;;
  esac
}

render_server() {
  load_env
  local egress rules udp_rule tmp
  egress="$(make_egress_json)"
  rules='[{"type":"field","inboundTag":["vless-xhttp"],"port":"53","network":"tcp,udp","outboundTag":"dns-out"}]'

  if [ "$OUTBOUND_TYPE" = "http" ]; then
    case "$HTTP_UDP_POLICY" in
      direct) udp_rule='{"type":"field","inboundTag":["vless-xhttp"],"network":"udp","outboundTag":"direct"}' ;;
      block) udp_rule='{"type":"field","inboundTag":["vless-xhttp"],"network":"udp","outboundTag":"block"}' ;;
      *) die "HTTP_UDP_POLICY must be direct or block" ;;
    esac
    rules="$(jq -cn --argjson a "$rules" --argjson r "$udp_rule" '$a + [$r]')"
  fi
  rules="$(jq -cn --argjson a "$rules" '$a + [{type:"field",inboundTag:["vless-xhttp"],outboundTag:"egress"}]')"

  tmp="$(mktemp)"
  jq -n \
    --arg listen "$LISTEN" \
    --argjson port "$PORT" \
    --arg uuid "$UUID" \
    --arg dec "$DECRYPTION" \
    --arg path "$XHTTP_PATH" \
    --arg mode "$XHTTP_MODE" \
    --argjson egress "$egress" \
    --argjson rules "$rules" '
    {
      log:{loglevel:"warning",dnsLog:false},
      dns:{
        servers:["https+local://1.1.1.1/dns-query","https+local://8.8.8.8/dns-query"],
        queryStrategy:"UseIPv4",
        useSystemHosts:true
      },
      inbounds:[{
        tag:"vless-xhttp",
        listen:$listen,
        port:$port,
        protocol:"vless",
        settings:{clients:[{id:$uuid,flow:"xtls-rprx-vision"}],decryption:$dec},
        streamSettings:{
          network:"xhttp",
          security:"none",
          xhttpSettings:{path:$path,mode:$mode}
        },
        sniffing:{enabled:true,destOverride:["http","tls","quic"],routeOnly:false}
      }],
      outbounds:[
        $egress,
        {tag:"dns-out",protocol:"dns",settings:{}},
        {tag:"direct",protocol:"freedom",settings:{targetStrategy:"UseIP"}},
        {tag:"block",protocol:"blackhole",settings:{}}
      ],
      routing:{domainStrategy:"AsIs",rules:$rules}
    }' > "$tmp"

  "$XRAY_BIN" run -test -config "$tmp" >/dev/null
  install -m 0600 "$tmp" "$SERVER_CONFIG"
  rm -f "$tmp"
}

client_endpoint() {
  if [ "$CF_TUNNEL_TOKEN_SET" = "1" ]; then
    if [ -n "$CF_DOMAIN" ]; then printf '%s' "$CF_DOMAIN"; else printf '%s' "CHANGE-ME.example.com"; fi
  else
    if [ -n "$PUBLIC_HOST" ]; then printf '%s' "$PUBLIC_HOST"; else printf '%s' "SERVER_IP"; fi
  fi
}

render_client() {
  load_env
  local host cport sec mode tmp uri_host uri_path uri_enc uri_sni
  host="$(client_endpoint)"
  if [ "$CF_TUNNEL_TOKEN_SET" = "1" ]; then
    cport=443
    sec=tls
    mode="${XHTTP_MODE:-auto}"
  else
    cport="$PORT"
    sec=none
    mode="$XHTTP_MODE"
  fi

  tmp="$(mktemp)"
  jq -n \
    --arg host "$host" --argjson port "$cport" --arg uuid "$UUID" --arg enc "$ENCRYPTION" \
    --arg path "$XHTTP_PATH" --arg mode "$mode" --arg sec "$sec" --arg sni "$host" '
    {
      log:{loglevel:"warning"},
      dns:{servers:["fakedns","1.1.1.1"],queryStrategy:"UseIPv4"},
      fakedns:[{ipPool:"198.18.0.0/15",poolSize:65535}],
      inbounds:[
        {tag:"socks-in",listen:"127.0.0.1",port:10808,protocol:"socks",settings:{udp:true},sniffing:{enabled:true,destOverride:["fakedns","http","tls","quic"],routeOnly:false}},
        {tag:"http-in",listen:"127.0.0.1",port:10809,protocol:"http",settings:{},sniffing:{enabled:true,destOverride:["fakedns","http","tls"],routeOnly:false}}
      ],
      outbounds:[{
        tag:"proxy",
        protocol:"vless",
        settings:{vnext:[{address:$host,port:$port,users:[{id:$uuid,encryption:$enc,flow:"xtls-rprx-vision"}]}]},
        streamSettings:({network:"xhttp",security:$sec,xhttpSettings:{host:$host,path:$path,mode:$mode}}
          + if $sec=="tls" then {tlsSettings:{serverName:$sni,alpn:["h2","http/1.1"]}} else {} end)
      },{tag:"direct",protocol:"freedom",settings:{}}],
      routing:{domainStrategy:"AsIs",rules:[{type:"field",ip:["198.18.0.0/15"],outboundTag:"proxy"}]}
    }' > "$tmp"

  "$XRAY_BIN" run -test -config "$tmp" >/dev/null
  install -m 0600 "$tmp" "$CLIENT_CONFIG"
  rm -f "$tmp"

  uri_host="$host"
  case "$uri_host" in *:*) uri_host="[$uri_host]" ;; esac
  uri_path="$(jq -rn --arg v "$XHTTP_PATH" '$v|@uri')"
  uri_enc="$(jq -rn --arg v "$ENCRYPTION" '$v|@uri')"
  uri_sni="$(jq -rn --arg v "$host" '$v|@uri')"
  if [ "$sec" = "tls" ]; then
    printf 'vless://%s@%s:%s?encryption=%s&flow=xtls-rprx-vision&type=xhttp&path=%s&mode=%s&security=tls&sni=%s&host=%s#vhec-xhttp\n' \
      "$UUID" "$uri_host" "$cport" "$uri_enc" "$uri_path" "$mode" "$uri_sni" "$uri_sni" > "$CLIENT_LINK"
  else
    printf 'vless://%s@%s:%s?encryption=%s&flow=xtls-rprx-vision&type=xhttp&path=%s&mode=%s&security=none#vhec-xhttp\n' \
      "$UUID" "$uri_host" "$cport" "$uri_enc" "$uri_path" "$mode" > "$CLIENT_LINK"
  fi
  chmod 0600 "$CLIENT_LINK"
}

render_all() {
  render_server
  render_client
}
