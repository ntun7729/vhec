# syntax=docker/dockerfile:1.7

FROM debian:bookworm-slim AS downloader
ARG TARGETARCH
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl unzip \
 && rm -rf /var/lib/apt/lists/*
RUN set -eux; \
    arch="${TARGETARCH:-amd64}"; \
    case "$arch" in \
      amd64) xray_arch='64'; cf_arch='amd64' ;; \
      arm64) xray_arch='arm64-v8a'; cf_arch='arm64' ;; \
      *) echo "unsupported TARGETARCH: $arch" >&2; exit 1 ;; \
    esac; \
    mkdir -p /out /tmp/xray; \
    curl -fL --retry 3 "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${xray_arch}.zip" -o /tmp/xray.zip; \
    unzip -q /tmp/xray.zip -d /tmp/xray; \
    install -m 0755 /tmp/xray/xray /out/xray; \
    curl -fL --retry 3 "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cf_arch}" -o /out/cloudflared; \
    chmod 0755 /out/cloudflared

FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends bash ca-certificates jq openssl socat tini \
 && rm -rf /var/lib/apt/lists/*

COPY --from=downloader /out/xray /usr/local/bin/xray
COPY --from=downloader /out/cloudflared /usr/local/bin/cloudflared
COPY lib/render.sh /usr/local/lib/vhec/render.sh
COPY docker-entrypoint.sh /usr/local/bin/vhec-entrypoint
COPY docker-web.sh /usr/local/bin/vhec-web
RUN chmod 0755 /usr/local/bin/vhec-entrypoint /usr/local/bin/vhec-web \
 && mkdir -p /etc/vhec \
 && chmod 0700 /etc/vhec

LABEL org.opencontainers.image.source="https://github.com/ntun7729/vhec"
LABEL org.opencontainers.image.description="VLESS Encryption + Vision + XHTTP with optional Cloudflare Tunnel and selectable egress"

VOLUME ["/etc/vhec"]
EXPOSE 30
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 CMD printf 'GET /healthz HTTP/1.0\r\nHost: localhost\r\n\r\n' | socat - TCP:127.0.0.1:30,connect-timeout=2 2>/dev/null | tail -n 1 | grep -qx 'ok'
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/vhec-entrypoint"]
