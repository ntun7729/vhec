service_manager() {
  if have systemctl && [ "$(ps -p 1 -o comm= 2>/dev/null | tr -d ' ')" = "systemd" ]; then
    printf systemd
  elif have rc-service && have rc-update; then
    printf openrc
  else
    printf fallback
  fi
}

write_systemd_units() {
  cat > /etc/systemd/system/vhec-xray.service <<EOF_UNIT
[Unit]
Description=VHEC Xray
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$XRAY_BIN run -config $SERVER_CONFIG
Restart=on-failure
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF_UNIT

  load_env
  cat > /etc/systemd/system/vhec-cloudflared.service <<EOF_UNIT
[Unit]
Description=VHEC Cloudflare Tunnel
After=network-online.target vhec-xray.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=$CLOUDFLARED_BIN tunnel --no-autoupdate --protocol $CF_PROTOCOL run --token-file $STATE_DIR/cloudflared.token
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF_UNIT
  systemctl daemon-reload
  systemctl enable vhec-xray.service >/dev/null
}

write_openrc_units() {
  cat > /etc/init.d/vhec-xray <<EOF_RC
#!/sbin/openrc-run
command="$XRAY_BIN"
command_args="run -config $SERVER_CONFIG"
command_background="no"
pidfile="/run/vhec-xray.pid"
depend() { need net; }
EOF_RC
  chmod 0755 /etc/init.d/vhec-xray
  rc-update add vhec-xray default >/dev/null 2>&1 || true

  cat > /etc/init.d/vhec-cloudflared <<EOF_RC
#!/sbin/openrc-run
command="$CLOUDFLARED_BIN"
command_args="tunnel --no-autoupdate --protocol $CF_PROTOCOL run --token-file $STATE_DIR/cloudflared.token"
command_background="no"
pidfile="/run/vhec-cloudflared.pid"
depend() { need net; after vhec-xray; }
EOF_RC
  chmod 0755 /etc/init.d/vhec-cloudflared
}

fallback_start() {
  mkdir -p /run/vhec
  if [ -f /run/vhec/xray.pid ]; then kill "$(cat /run/vhec/xray.pid)" 2>/dev/null || true; fi
  nohup "$XRAY_BIN" run -config "$SERVER_CONFIG" >>/var/log/vhec-xray.log 2>&1 & echo $! >/run/vhec/xray.pid
  if [ -f /run/vhec/cloudflared.pid ]; then kill "$(cat /run/vhec/cloudflared.pid)" 2>/dev/null || true; rm -f /run/vhec/cloudflared.pid; fi
  if [ "$CF_TUNNEL_TOKEN_SET" = "1" ]; then
    nohup "$CLOUDFLARED_BIN" tunnel --no-autoupdate --protocol "$CF_PROTOCOL" run --token-file "$STATE_DIR/cloudflared.token" >>/var/log/vhec-cloudflared.log 2>&1 & echo $! >/run/vhec/cloudflared.pid
  fi
}

restart_services() {
  load_env
  case "$(service_manager)" in
    systemd)
      systemctl restart vhec-xray.service
      if [ "$CF_TUNNEL_TOKEN_SET" = "1" ]; then
        systemctl enable vhec-cloudflared.service >/dev/null
        systemctl restart vhec-cloudflared.service
      else
        systemctl disable --now vhec-cloudflared.service >/dev/null 2>&1 || true
      fi
      ;;
    openrc)
      rc-service vhec-xray restart || rc-service vhec-xray start
      if [ "$CF_TUNNEL_TOKEN_SET" = "1" ]; then
        rc-update add vhec-cloudflared default >/dev/null 2>&1 || true
        rc-service vhec-cloudflared restart || rc-service vhec-cloudflared start
      else
        rc-service vhec-cloudflared stop >/dev/null 2>&1 || true
        rc-update del vhec-cloudflared default >/dev/null 2>&1 || true
      fi
      ;;
    fallback) fallback_start ;;
  esac
}
