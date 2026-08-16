# vhec

A small Linux installer/manager for this stack:

```text
VLESS Encryption (0-RTT client profile)
  + xtls-rprx-vision
  + XHTTP
  + optional Cloudflare Tunnel
  + selectable direct / SOCKS / HTTP egress
```

The server config is generated atomically and checked with `xray run -test` before replacing the active config.

## Why this layout

- **XHTTP instead of WebSocket**: current Xray maps `network: "xhttp"` to SplitHTTP/XHTTP and supports `auto`, `packet-up`, `stream-up`, and `stream-one` modes.
- **VLESS Encryption + Vision**: the generated inbound uses a real `decryption` key from `xray vlessenc` and `flow: "xtls-rprx-vision"`.
- **Changeable egress**: switch between direct, SOCKS5, and HTTP proxy without rebuilding the inbound.
- **FakeDNS client profile**: generated v2rayNG/Xray JSON includes FakeDNS and FakeDNS sniffing so domain names survive Android VPN/TUN handling and can reach a chained HTTP proxy as domains.
- **Cloudflare Tunnel optional**: when a tunnel token is supplied, Xray binds to loopback and `cloudflared` exposes it. The token is stored in a root-only file and is not written into Xray/client JSON.

## Install

The repository is private, so clone/download it with your authenticated GitHub account first.

Direct XHTTP:

```bash
sudo PUBLIC_HOST=203.0.113.10 ./vhec.sh install
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
  ./vhec.sh install
```

With a SOCKS egress proxy:

```bash
sudo \
  PUBLIC_HOST=203.0.113.10 \
  OUTBOUND_TYPE=socks \
  OUTBOUND_HOST=127.0.0.1 \
  OUTBOUND_PORT=1080 \
  ./vhec.sh install
```

### VLESS Encryption authentication

Default:

```bash
VLESSENC_AUTH=x25519
```

Optional ML-KEM-768 authentication:

```bash
sudo VLESSENC_AUTH=mlkem768 PUBLIC_HOST=203.0.113.10 ./vhec.sh install
```

`xray vlessenc` still uses the hybrid VLESS Encryption profile; this option selects which generated authentication pair is used.

## Cloudflare Tunnel

For a remotely managed Cloudflare Tunnel:

```bash
sudo \
  CF_TUNNEL_TOKEN='eyJ...' \
  CF_DOMAIN='proxy.example.com' \
  ./vhec.sh install
```

When `CF_TUNNEL_TOKEN` is present:

- Xray binds to `127.0.0.1` by default.
- XHTTP defaults to `mode: auto` for better CDN/tunnel compatibility.
- `cloudflared` is installed and run with a root-only token file.
- the generated client connects to `CF_DOMAIN:443` with TLS + XHTTP.

In the Cloudflare dashboard, configure the remotely-managed tunnel public hostname:

```text
Hostname: proxy.example.com
Service:  http://127.0.0.1:8080
```

Do **not** append the XHTTP path to the tunnel service URL. The request path is carried by the client and checked by Xray.

A tunnel token authenticates `cloudflared`, but it does not tell this script which public hostname you configured. If you install with a token but no `CF_DOMAIN`, set it later:

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

The new JSON is validated before it replaces the old server config, then the service is restarted.

## HTTP outbound, UDP, and FakeDNS

Xray's HTTP outbound is **TCP-only**. FakeDNS fixes domain handling; it does not turn an HTTP proxy into a UDP proxy.

For HTTP egress, choose what happens to UDP traffic:

```bash
# send UDP directly from the VPS
sudo vhec udp-policy direct

# or reject UDP instead of leaking/bypassing the HTTP egress
sudo vhec udp-policy block
```

The generated client file contains:

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

and the local inbound sniffers include `fakedns`. This lets Xray recover the original hostname from a FakeIP before sending the request through VLESS.

If you use a normal v2rayNG profile instead of the generated custom JSON, enable **FakeDNS** in v2rayNG when using an HTTP egress chain. The important core behavior is:

```text
DNS query -> FakeIP -> FakeDNS sniffing restores hostname
          -> VLESS carries hostname -> server HTTP outbound
          -> upstream HTTP proxy resolves the hostname
```

The server also hijacks tunneled TCP/UDP port-53 queries into Xray's DNS outbound. Its own resolver uses local-mode DoH (`1.1.1.1` / `8.8.8.8`) so resolving the egress proxy endpoint does not create an HTTP-outbound DNS loop.

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

`auto` is the safer default for a CDN/tunnel path because Xray can select a compatible behavior for the negotiated HTTP transport. Benchmark on your actual path; the theoretically cheapest mode is not always the fastest through an ISP/CDN.

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

- systemd: persistent services are installed and enabled.
- OpenRC: init scripts are installed.
- other init systems/containers: a pidfile + `nohup` fallback is used, but it is not automatically persistent across reboot.

## Security notes

- Direct `security=none` XHTTP is protected by **VLESS Encryption**, but it is not TLS/REALITY camouflage.
- Cloudflare Tunnel adds normal client-to-Cloudflare TLS and keeps the Xray listener on loopback.
- HTTP egress itself is unencrypted unless the upstream path is otherwise protected. Do not send credentials to an untrusted HTTP proxy over an exposed network.
- Keep `/etc/vhec` root-only; it contains the VLESS Encryption keys and possibly proxy credentials.

## Upstream references

- Xray XHTTP implementation: <https://github.com/XTLS/Xray-core>
- Xray configuration docs: <https://xtls.github.io/en/config/>
- Xray FakeDNS docs: <https://xtls.github.io/en/config/fakedns.html>
- Xray HTTP outbound docs: <https://xtls.github.io/en/config/outbounds/http.html>
- Cloudflare Tunnel token docs: <https://developers.cloudflare.com/tunnel/advanced/tunnel-tokens/>
