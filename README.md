# vhec

A small Linux installer/manager for this stack:

```text
VLESS Encryption (0-RTT client profile)
  + xtls-rprx-vision
  + XHTTP
  + optional Cloudflare Tunnel
  + selectable direct / SOCKS / HTTP egress
```

Both generated Xray configs are checked with `xray run -test` before they are installed. Server configuration replacement is atomic.

## Why this layout

- **XHTTP instead of WebSocket**: current Xray maps `network: "xhttp"` to XHTTP/SplitHTTP and supports `auto`, `packet-up`, `stream-up`, and `stream-one`.
- **VLESS Encryption + Vision**: the inbound uses a real `decryption` value from `xray vlessenc` and `flow: "xtls-rprx-vision"`.
- **Changeable egress**: switch between direct, SOCKS5, and HTTP proxy without rebuilding the inbound.
- **FakeDNS client profile**: generated v2rayNG/Xray JSON includes FakeDNS and FakeDNS sniffing so domain names survive Android VPN/TUN handling and can reach a chained HTTP proxy as domains.
- **Destination-aware server sniffing**: HTTP Host/TLS SNI/QUIC sniffing uses `routeOnly: false`, allowing Xray to restore the domain as the destination instead of using it only for routing.
- **Cloudflare Tunnel optional**: with a tunnel token, Xray binds to loopback and `cloudflared` exposes it. The token is root-only and is not written into Xray/client JSON.

## Install

The repository is private, so clone/download it with your authenticated GitHub account first.

Direct XHTTP:

```bash
sudo PUBLIC_HOST=203.0.113.10 bash ./vhec.sh install
```

With an HTTP egress proxy:

```bash
sudo \
  PUBLIC_HOST=203.0.113.10 \
  OUTBOUND_TYPE=http \
  OUTBOUND_HOST=127.0.0.1 \
  OUTBOUND_PORT=8081 \
  OUTBOUND_USER='user' \
  OUTBOUND_PASS='pass' \
  HTTP_UDP_POLICY=direct \
  bash ./vhec.sh install
```

With a SOCKS egress proxy:

```bash
sudo \
  PUBLIC_HOST=203.0.113.10 \
  OUTBOUND_TYPE=socks \
  OUTBOUND_HOST=127.0.0.1 \
  OUTBOUND_PORT=1080 \
  bash ./vhec.sh install
```

### VLESS Encryption authentication

Default:

```bash
VLESSENC_AUTH=x25519
```

Optional ML-KEM-768 authentication:

```bash
sudo VLESSENC_AUTH=mlkem768 PUBLIC_HOST=203.0.113.10 bash ./vhec.sh install
```

`xray vlessenc` emits both authentication choices in current Xray-core. Do not mix the server value from one pair with the client value from the other.

## Cloudflare Tunnel

For a remotely managed Cloudflare Tunnel:

```bash
sudo \
  CF_TUNNEL_TOKEN='eyJ...' \
  CF_DOMAIN='proxy.example.com' \
  bash ./vhec.sh install
```

When `CF_TUNNEL_TOKEN` is present:

- Xray binds to `127.0.0.1` by default.
- XHTTP defaults to `mode: auto` for CDN/tunnel compatibility.
- `cloudflared` is installed and run with a root-only token file.
- the generated client connects to `CF_DOMAIN:443` with TLS + XHTTP.

In the Cloudflare dashboard, configure the remotely managed tunnel public hostname:

```text
Hostname: proxy.example.com
Service:  http://127.0.0.1:8080
```

Do **not** append the XHTTP path to the tunnel service URL. The request path is carried by the client and checked by Xray.

A tunnel token does not tell the script which public hostname you assigned. If you install with a token but no `CF_DOMAIN`, set it later:

```bash
sudo vhec cloudflare domain proxy.example.com
```

Enable Cloudflare after a direct installation:

```bash
sudo vhec cloudflare enable 'eyJ...' proxy.example.com
```

Disable it:

```bash
sudo vhec cloudflare disable
```

## Change outbound at any time

Direct:

```bash
sudo vhec outbound direct
```

SOCKS5:

```bash
sudo vhec outbound socks 127.0.0.1 1080
sudo vhec outbound socks proxy.example.com 1080 user pass
```

HTTP:

```bash
sudo vhec outbound http 127.0.0.1 8080
sudo vhec outbound http proxy.example.com 3128 user pass
```

The new server JSON and generated client JSON are validated by Xray before service restart.

## HTTP outbound, UDP, and FakeDNS

Xray's HTTP outbound is **TCP-only**. FakeDNS fixes domain handling; it does not make an HTTP proxy carry UDP.

For HTTP egress, choose what happens to non-DNS UDP traffic:

```bash
# send UDP directly from the VPS
sudo vhec udp-policy direct

# or reject UDP instead of bypassing the HTTP egress
sudo vhec udp-policy block
```

Port-53 traffic arriving through the VLESS inbound is handled first by Xray's `dns` outbound, so DNS does not depend on the HTTP proxy's UDP support.

The generated client file contains the standard Xray FakeDNS pool. The top-level Xray key is `fakeDns`; the DNS server/sniffer token remains lowercase `fakedns`:

```json
{
  "dns": {
    "servers": ["fakedns", "1.1.1.1"],
    "queryStrategy": "UseIPv4"
  },
  "fakeDns": [
    {
      "ipPool": "198.18.0.0/15",
      "poolSize": 65535
    }
  ]
}
```

The local inbound sniffers include `fakedns` with `routeOnly: false`. On the server, HTTP/TLS/QUIC sniffing also uses `routeOnly: false`. Together this preserves or recovers the original hostname before the HTTP egress receives the destination.

### v2rayNG settings

If you import the normal VLESS share link instead of using `/etc/vhec/client-v2rayng.json`, enable **both** of these in v2rayNG:

```text
Settings -> Local DNS -> enabled
Settings -> Fake DNS -> enabled
```

Current v2rayNG only adds its generated FakeDNS section when **Local DNS and Fake DNS are both enabled**.

The intended flow is:

```text
DNS query -> FakeIP -> FakeDNS sniffing restores hostname
          -> VLESS carries hostname -> server sniffing preserves hostname
          -> HTTP outbound -> upstream HTTP proxy resolves hostname
```

The server's own resolver uses local-mode DoH (`1.1.1.1` / `8.8.8.8`) so resolving the egress proxy endpoint does not create an HTTP-outbound DNS loop.

## XHTTP mode

Direct installs default to:

```text
stream-one
```

Cloudflare Tunnel installs default to:

```text
auto
```

Change it at any time:

```bash
sudo vhec mode auto
sudo vhec mode stream-one
sudo vhec mode stream-up
sudo vhec mode packet-up
```

Benchmark on your actual path. RAW/TCP may be cheaper inside Xray, but ISP/CDN/middlebox behavior can make XHTTP faster on a particular route.

## Generated files

```text
/etc/vhec/vhec.env             private state
/etc/vhec/server.json          Xray server config
/etc/vhec/client-v2rayng.json  full client JSON with FakeDNS
/etc/vhec/client-link.txt      VLESS link
/etc/vhec/cloudflared.token    Cloudflare token, only when enabled
```

Show current state:

```bash
sudo vhec show
sudo vhec client
sudo vhec status
sudo vhec logs
```

## Service support

- systemd: persistent service is installed and enabled.
- OpenRC: background init scripts with pidfiles are installed.
- other init systems/containers: a pidfile + `nohup` fallback is used, but it is not automatically persistent across reboot.

Service detection checks the actual init system rather than assuming systemd just because `systemctl` happens to be installed.

## Security notes

- Direct `security=none` XHTTP is protected by **VLESS Encryption**, but it is not TLS/REALITY camouflage.
- Cloudflare Tunnel adds normal client-to-Cloudflare TLS and keeps the Xray listener on loopback.
- HTTP egress itself is unencrypted unless the upstream path is otherwise protected. Do not send proxy credentials to an untrusted HTTP proxy over an exposed network.
- Keep `/etc/vhec` root-only; it contains VLESS Encryption keys and may contain proxy credentials.
- `udp-policy direct` intentionally bypasses an HTTP proxy for non-DNS UDP. Use `block` if that bypass is unacceptable.

## Validation

GitHub Actions runs a smoke test against a real current Xray-core binary. It validates direct/SOCKS/HTTP egress generation, both HTTP UDP policies, FakeDNS client configuration, XHTTP + Vision fields, and both generated JSON files with `xray run -test`.

## Upstream references

- Xray-core: <https://github.com/XTLS/Xray-core>
- Xray configuration docs: <https://xtls.github.io/en/config/>
- Xray FakeDNS docs: <https://xtls.github.io/en/config/fakedns.html>
- Xray HTTP outbound docs: <https://xtls.github.io/en/config/outbounds/http.html>
- v2rayNG: <https://github.com/2dust/v2rayNG>
- Cloudflare Tunnel tokens: <https://developers.cloudflare.com/tunnel/advanced/tunnel-tokens/>
