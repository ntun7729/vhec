# vhec

VLESS Encryption + `xtls-rprx-vision` + XHTTP with optional Cloudflare Tunnel and selectable direct / SOCKS / HTTP egress.

The Docker path is designed for NAT servers: **you do not need `PUBLIC_HOST`, port forwarding, or a published Docker port when Cloudflare Tunnel is enabled**.

## GHCR image

GitHub Actions builds and publishes a multi-architecture image for `linux/amd64` and `linux/arm64`:

```text
ghcr.io/ntun7729/vhec:latest
```

Every push to `main` publishes `latest` plus a commit-SHA tag. Git tags such as `v1.2.3` also produce version tags.

If the GHCR package is private, authenticate Docker before pulling it. If you make the package public, anonymous pulls work.

## NAT + Cloudflare Tunnel: recommended setup

Create a remotely managed Cloudflare Tunnel, add a public hostname, and point its service to:

```text
http://127.0.0.1:8080
```

The XHTTP path is carried in the client request; do not append it to the Cloudflare origin URL.

Copy the example environment file:

```bash
cp .env.example .env
```

At minimum set:

```dotenv
CF_TUNNEL_TOKEN=eyJ...
CF_DOMAIN=proxy.example.com
```

Then run:

```bash
docker compose up -d
```

No `ports:` section is needed. `cloudflared` and Xray run in the same container/network namespace, so Cloudflare reaches Xray on container loopback.

### Docker run equivalent

```bash
docker run -d \
  --name vhec \
  --restart unless-stopped \
  -e CF_TUNNEL_TOKEN='eyJ...' \
  -e CF_DOMAIN='proxy.example.com' \
  -v vhec-state:/etc/vhec \
  ghcr.io/ntun7729/vhec:latest
```

Get the generated client link:

```bash
docker exec vhec cat /etc/vhec/client-link.txt
```

Get the full v2rayNG/Xray client config with FakeDNS:

```bash
docker exec vhec cat /etc/vhec/client-v2rayng.json
```

## Why `PUBLIC_HOST` is not needed with Cloudflare

With `CF_TUNNEL_TOKEN` set:

- Xray defaults to `127.0.0.1:8080`.
- `cloudflared` makes the outbound connection to Cloudflare, so NAT/firewall inbound reachability is irrelevant.
- generated clients connect to `CF_DOMAIN:443` with TLS + XHTTP.
- `PUBLIC_HOST` is ignored as the client endpoint.

`PUBLIC_HOST` only exists for **direct, non-Cloudflare** installs where you want the script to generate a ready-to-import client pointing at a public IP/domain.

## Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `CF_TUNNEL_TOKEN` | empty | Cloudflare remotely managed Tunnel token. When set, Cloudflare mode is enabled and no public server IP is required. |
| `CF_DOMAIN` | empty | Public hostname attached to the Cloudflare Tunnel, for example `proxy.example.com`. The tunnel can start without it, but generated client files use a placeholder until it is set. |
| `CF_PROTOCOL` | `auto` | cloudflared transport: `auto`, `quic`, or `http2`. |
| `PORT` | `8080` | Xray XHTTP origin port inside the container/server. With Cloudflare you normally do not publish this port. |
| `LISTEN` | `127.0.0.1` with CF, otherwise `0.0.0.0` | Xray listen address. Keep the Cloudflare default unless you intentionally need another container/process to reach Xray. |
| `PUBLIC_HOST` | empty | Direct-mode client endpoint only. Not required when `CF_TUNNEL_TOKEN` is set. |
| `XHTTP_MODE` | `auto` with CF, otherwise `stream-one` | XHTTP mode: `auto`, `packet-up`, `stream-up`, or `stream-one`. |
| `UUID` | generated | VLESS user UUID. If omitted in Docker it is generated once and persisted in the `/etc/vhec` volume. |
| `XHTTP_PATH` | generated | Random XHTTP path. Persisted with the Docker identity when omitted. |
| `VLESSENC_AUTH` | `x25519` | VLESS Encryption authentication pair: `x25519` or `mlkem768`. The generated key pair is persisted. |
| `OUTBOUND_TYPE` | `direct` | Server egress: `direct`, `socks`, or `http`. |
| `OUTBOUND_HOST` | empty | Required when `OUTBOUND_TYPE=socks` or `http`. Proxy hostname/IP. |
| `OUTBOUND_PORT` | empty | Required when `OUTBOUND_TYPE=socks` or `http`. Proxy port. |
| `OUTBOUND_USER` | empty | Optional SOCKS/HTTP proxy username. |
| `OUTBOUND_PASS` | empty | Optional SOCKS/HTTP proxy password. |
| `HTTP_UDP_POLICY` | `block` in Docker | Xray HTTP outbound is TCP-only. `block` rejects non-DNS UDP; `direct` bypasses the HTTP proxy for UDP. |
| `VHEC_STATE_DIR` | `/etc/vhec` | Directory holding generated identity, server config, client config, and link. Mount it persistently in Docker. |

Advanced: `DECRYPTION` and `ENCRYPTION` may be supplied together to use an existing VLESS Encryption pair. Normally leave both unset and let the container generate/persist them.

## Egress examples

### Direct egress

```dotenv
OUTBOUND_TYPE=direct
```

### SOCKS5 egress

```dotenv
OUTBOUND_TYPE=socks
OUTBOUND_HOST=10.0.0.2
OUTBOUND_PORT=1080
OUTBOUND_USER=
OUTBOUND_PASS=
```

### HTTP egress

```dotenv
OUTBOUND_TYPE=http
OUTBOUND_HOST=10.0.0.2
OUTBOUND_PORT=3128
OUTBOUND_USER=user
OUTBOUND_PASS=pass
HTTP_UDP_POLICY=block
```

Xray's HTTP outbound is TCP-only. FakeDNS preserves/restores domains; it does not make an HTTP proxy carry UDP.

For HTTP egress:

- DNS arriving through the VLESS inbound is routed to Xray's DNS outbound first.
- `HTTP_UDP_POLICY=block` prevents other UDP from bypassing your HTTP proxy.
- `HTTP_UDP_POLICY=direct` deliberately sends other UDP directly from the server.

## FakeDNS / v2rayNG

The generated `/etc/vhec/client-v2rayng.json` includes:

- `dns.servers: ["fakedns", ...]`
- top-level Xray `fakeDns`
- inbound `fakedns` sniffing with `routeOnly: false`

The intended path is:

```text
DNS query -> FakeIP -> FakeDNS sniffing restores hostname
          -> VLESS carries hostname -> server sniffing restores/preserves hostname
          -> HTTP outbound -> upstream HTTP proxy resolves hostname
```

If you import only `/etc/vhec/client-link.txt` into v2rayNG instead of the full JSON, enable both **Local DNS** and **Fake DNS** in v2rayNG.

## Persistent Docker identity

Mount `/etc/vhec` as a volume. On first start the container generates and stores:

```text
/etc/vhec/identity.json
/etc/vhec/vhec.env
/etc/vhec/server.json
/etc/vhec/client-v2rayng.json
/etc/vhec/client-link.txt
/etc/vhec/cloudflared.token   # only when CF is enabled
```

`identity.json` keeps the UUID, XHTTP path, and VLESS Encryption pair stable across container recreation. Without a persistent volume, a recreated container can generate a new client identity.

To change runtime settings such as egress in Docker, change the environment variables and recreate the container:

```bash
docker compose up -d --force-recreate
```

## Host installer

The original host installer remains available for systemd/OpenRC/non-container use.

### Cloudflare/NAT host install

`PUBLIC_HOST` is not required:

```bash
sudo \
  CF_TUNNEL_TOKEN='eyJ...' \
  CF_DOMAIN='proxy.example.com' \
  bash ./vhec.sh install
```

### Direct public host install

Only direct mode needs a public endpoint for a usable generated client link:

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

Two workflows are included:

- `validate.yml`: shell syntax, real-current-Xray integration smoke test, and Docker build validation.
- `publish-container.yml`: logs in to GHCR with `GITHUB_TOKEN`, builds `linux/amd64` + `linux/arm64`, and pushes `ghcr.io/ntun7729/vhec`.

The publish workflow grants `contents: read` and `packages: write`; no separate GHCR password secret is needed inside GitHub Actions.

## Security notes

- Keep `.env` out of Git. It contains the Cloudflare token and may contain upstream proxy credentials.
- The Cloudflare token is written root-only inside the state volume and is not embedded in the Xray/client JSON.
- Direct `security=none` XHTTP is protected by VLESS Encryption but is not TLS/REALITY camouflage.
- Cloudflare mode adds normal client-to-Cloudflare TLS and keeps Xray on loopback by default.
- `HTTP_UDP_POLICY=direct` is an intentional proxy bypass for non-DNS UDP; use `block` if that is unacceptable.
