# vhec

VLESS Encryption + `xtls-rprx-vision` + XHTTP with Cloudflare Tunnel and selectable direct / SOCKS / HTTP egress.

The Docker path is designed for NAT servers: **you do not need `PUBLIC_HOST`, port forwarding, or a published Docker port when Cloudflare Tunnel is enabled**.

## GHCR image

GitHub Actions builds and publishes a multi-architecture image for `linux/amd64` and `linux/arm64`:

```text
ghcr.io/ntun7729/vhec:latest
```

Every push to `main` publishes `latest` plus a commit-SHA tag. Git tags such as `v1.2.3` also produce version tags.

## Docker origin layout

The Docker image runs two XHTTP origins with the same UUID, VLESS Encryption keys, XHTTP path, and server-side XHTTP mode:

```text
http://127.0.0.1:8080    plain XHTTP origin for testing / HTTP-only ingress
https://127.0.0.1:8443   TLS + HTTP/2-capable origin for Cloudflare Tunnel
```

`XHTTP_MODE=auto` is the default. The generated VLESS link also uses `mode=auto`. You can change the client-side XHTTP mode in v2rayNG to `packet-up`, `stream-up`, or `stream-one` without changing the server default.

The TLS origin uses a self-signed certificate generated on first start and persisted in `/etc/vhec`.

## NAT + Cloudflare Tunnel: recommended setup

Create a remotely managed Cloudflare Tunnel, add a published application/public hostname, and point its service to:

```text
https://127.0.0.1:8443
```

Under the route's **Additional application settings** enable:

```text
HTTP2 connection: On
No TLS Verify: On
```

The HTTPS origin is intentional. Cloudflare's HTTP/2-origin option requires an HTTPS origin, and `No TLS Verify` allows `cloudflared` to use the container's persistent self-signed certificate.

Do not append the XHTTP path to the Cloudflare origin URL. The path is carried by the XHTTP client request.

The old/plain origin remains available at `http://127.0.0.1:8080`, so HTTP-only ingress or testing platforms can still expose port `8080`. Packetized upload is the most compatible path when an intermediary downgrades the origin connection to HTTP/1.1.

Copy the example environment file:

```bash
cp .env.example .env
```

At minimum set:

```dotenv
CF_TUNNEL_TOKEN=eyJ...
CF_DOMAIN=proxy.example.com
```

A typical HTTP-egress setup is:

```dotenv
XHTTP_MODE=auto
OUTBOUND_TYPE=http
OUTBOUND_HOST=10.0.0.2
OUTBOUND_PORT=3128
OUTBOUND_USER=
OUTBOUND_PASS=
```

Then run:

```bash
docker compose up -d
```

No host `ports:` section is needed. `cloudflared` and Xray run in the same container/network namespace, so Cloudflare reaches Xray on container loopback.

### Docker run equivalent

```bash
docker run -d \
  --name vhec \
  --restart unless-stopped \
  --add-host host.docker.internal:host-gateway \
  -e CF_TUNNEL_TOKEN='eyJ...' \
  -e CF_DOMAIN='proxy.example.com' \
  -v vhec-state:/etc/vhec \
  ghcr.io/ntun7729/vhec:latest
```

Get the generated VLESS link:

```bash
docker exec vhec cat /etc/vhec/client-link.txt
```

Or from the small status server on container port `30`:

```text
GET /healthz -> ok
GET /v       -> generated VLESS link
```

Get the full v2rayNG/Xray client config with FakeDNS:

```bash
docker exec vhec cat /etc/vhec/client-v2rayng.json
```

Normal container stdout/stderr is intentionally suppressed, so `docker logs vhec` stays empty.

## Why `PUBLIC_HOST` is not needed with Cloudflare

With `CF_TUNNEL_TOKEN` set:

- Xray binds its origins to loopback by default.
- `cloudflared` makes the outbound connection to Cloudflare, so NAT/firewall inbound reachability is irrelevant.
- generated clients connect to `CF_DOMAIN:443` with normal outer TLS + XHTTP.
- `PUBLIC_HOST` is ignored as the client endpoint.

`PUBLIC_HOST` only exists for direct, non-Cloudflare installs where you want the script to generate a ready-to-import client pointing at a public IP/domain.

## Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `CF_TUNNEL_TOKEN` | empty | Cloudflare remotely managed Tunnel token. Enables Cloudflare/NAT mode. |
| `CF_DOMAIN` | empty | Public hostname attached to the Cloudflare Tunnel, for example `proxy.example.com`. |
| `CF_PROTOCOL` | `auto` | cloudflared transport: `auto`, `quic`, or `http2`. |
| `PORT` | `8080` | Plain HTTP XHTTP origin. Useful for testing and HTTP-only ingress. |
| `TLS_PORT` | `8443` | Internal self-signed TLS XHTTP origin intended for Cloudflare with HTTP2 connection enabled. |
| `LISTEN` | `127.0.0.1` with CF, otherwise `0.0.0.0` | Xray listen address for both Docker origins. |
| `PUBLIC_HOST` | empty | Direct-mode client endpoint only. Not required with Cloudflare. |
| `XHTTP_MODE` | `auto` | Server and generated-client default: `auto`, `packet-up`, `stream-up`, or `stream-one`. Keep `auto` normally and change the client mode in v2rayNG when testing. |
| `UUID` | generated | VLESS UUID, generated once and persisted in `/etc/vhec`. |
| `XHTTP_PATH` | generated | Random XHTTP path, persisted with the Docker identity. |
| `VLESSENC_AUTH` | `x25519` | VLESS Encryption authentication pair: `x25519` or `mlkem768`. |
| `OUTBOUND_TYPE` | `direct` | Server egress: `direct`, `socks`, or `http`. |
| `OUTBOUND_HOST` | empty | Required for SOCKS/HTTP egress. Proxy hostname/IP. |
| `OUTBOUND_PORT` | empty | Required for SOCKS/HTTP egress. Proxy port. |
| `OUTBOUND_USER` | empty | Optional proxy username. Leave empty for an anonymous proxy. |
| `OUTBOUND_PASS` | empty | Optional proxy password. Leave empty for an anonymous proxy. |
| `HTTP_UDP_POLICY` | `block` in Docker | HTTP outbound is TCP-only. `block` rejects non-DNS UDP; `direct` bypasses the HTTP proxy for UDP. |
| `VHEC_STATE_DIR` | `/etc/vhec` | Persistent state directory. |

Advanced: `DECRYPTION` and `ENCRYPTION` may be supplied together to use an existing VLESS Encryption pair. Normally leave both unset.

## Egress examples

### Direct

```dotenv
OUTBOUND_TYPE=direct
```

### Anonymous SOCKS5

```dotenv
OUTBOUND_TYPE=socks
OUTBOUND_HOST=10.0.0.2
OUTBOUND_PORT=1080
OUTBOUND_USER=
OUTBOUND_PASS=
```

### Anonymous HTTP

```dotenv
OUTBOUND_TYPE=http
OUTBOUND_HOST=10.0.0.2
OUTBOUND_PORT=3128
OUTBOUND_USER=
OUTBOUND_PASS=
HTTP_UDP_POLICY=block
```

Username/password are optional for both SOCKS5 and HTTP. They are omitted from the generated Xray outbound when `OUTBOUND_USER` is empty.

In Docker, `127.0.0.1`, `localhost`, `0.0.0.0`, and `::1` as an outbound proxy host are translated to the Docker host gateway. This lets a proxy on the NAT host work when it is reachable from the Docker bridge. A host proxy that listens strictly on host loopback only may still need to listen on the Docker bridge or another reachable host address.

Xray's HTTP outbound is TCP-only. FakeDNS preserves/restores domains; it does not make an HTTP proxy carry UDP.

## FakeDNS / v2rayNG

The generated `/etc/vhec/client-v2rayng.json` includes FakeDNS and sniffing so domain names can survive through the VLESS path and reach an upstream HTTP proxy as domains.

If you import only `/etc/vhec/client-link.txt` into v2rayNG instead of the full JSON, enable both **Local DNS** and **Fake DNS** in v2rayNG.

The generated link uses `mode=auto`. To compare modes, edit the profile in v2rayNG and switch only the XHTTP mode; the server can remain on `auto`.

## Persistent Docker state

Mount `/etc/vhec` as a volume. On first start the container generates and stores:

```text
/etc/vhec/identity.json
/etc/vhec/vhec.env
/etc/vhec/server.json
/etc/vhec/client-v2rayng.json
/etc/vhec/client-link.txt
/etc/vhec/origin-cert.pem
/etc/vhec/origin-key.pem
/etc/vhec/cloudflared.token   # only when CF is enabled
```

`identity.json` keeps the UUID, XHTTP path, and VLESS Encryption pair stable. The self-signed TLS certificate is also reused across container recreation.

To apply runtime setting changes:

```bash
docker compose pull
docker compose up -d --force-recreate
```

## Host installer

The original host installer remains available for systemd/OpenRC/non-container use. The dual-origin self-signed TLS setup described above is the Docker deployment path; the host installer keeps its existing host-oriented behavior.

### Cloudflare/NAT host install

```bash
sudo \
  CF_TUNNEL_TOKEN='eyJ...' \
  CF_DOMAIN='proxy.example.com' \
  bash ./vhec.sh install
```

### Direct public host install

```bash
sudo PUBLIC_HOST=203.0.113.10 bash ./vhec.sh install
```

Change host egress later with:

```bash
sudo vhec outbound direct
sudo vhec outbound socks HOST PORT [USER] [PASS]
sudo vhec outbound http HOST PORT [USER] [PASS]
sudo vhec udp-policy block
sudo vhec udp-policy direct
```

## GitHub Actions

- `validate.yml` checks shell syntax, current Xray config validity, Docker startup, the plain + TLS XHTTP origins, HTTP/2 ALPN on `8443`, persistent identity/certificate state, anonymous proxy rendering, `/healthz`, `/v`, and silent Docker logs.
- `publish-container.yml` publishes `linux/amd64` + `linux/arm64` images to GHCR.

## Security notes

- Keep `.env` out of Git. It contains the Cloudflare token and may contain upstream proxy credentials.
- The Cloudflare token is written root-only inside the state volume and is not embedded in client configs.
- The generated TLS private key is stored root-only in `/etc/vhec`.
- `No TLS Verify` is intended only for the loopback `cloudflared -> Xray` origin connection using the generated self-signed certificate.
- Do not publish the `8443` origin directly to the Internet just because it has TLS; it is an internal Cloudflare origin.
- `HTTP_UDP_POLICY=direct` intentionally bypasses the HTTP proxy for non-DNS UDP; use `block` if that bypass is unacceptable.
