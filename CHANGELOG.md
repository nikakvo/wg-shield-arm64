# Changelog

Tested on Poco F6 Pro, Xiaomi.eu ROM (HyperOS 3, Android 16), kernel [GKI_Kernel_SukiSU](https://github.com/nikakvo/GKI_Kernel_SukiSU) (WireGuard built in), with Proton VPN WireGuard configs. Part of a set with DNSCrypt Proxy Arm64, ipset-arm64 and VPN Hotspot Arm64.

## 1.0-r1

First release. An always-on kernel WireGuard tunnel for the phone, without an app.

* **Kernel WireGuard, invisible to Android** — one interface (`wgs0`) and plain policy routing in front of Android's own rules (priorities 5000–5021, table 51820). No `VpnService`, no netd VPN network: that is what the WireGuard app does in root mode, and on the test phone it broke Telegram calls (no UDP through the tunnel). With WG Shield, Telegram calls, normal calls, SMS and MMS work with the tunnel up
* **Tunnels** — import the WireGuard app's export zip or single `.conf` files from Download (WebUI or `ctl.sh import`). Proton VPN configs work as downloaded: `DNS`, `PostUp`, `Table` and comments are ignored, a missing `PersistentKeepalive` becomes 25 s. Keys are checked on import (a key replaced by `*****` is refused with the reason in the log) and never shown anywhere
* **One switch per tunnel** — one on at a time, the interface stays `wgs0`; all off = your normal connection
* **Kill switch** (on by default) — a tunnel that is on but gets no handshake for 180 s (WireGuard's own limit) is *down*: no internet at all, never the plain connection. An `unreachable` route under the tunnel's route keeps it closed even if the interface disappears. When a tunnel was on at shutdown, traffic is blocked from early boot until it is up
* **Turning it off is not a failure** — off, pause (15 min / 1 h / 4 h) and "cannot be built at all" (error) give the normal connection
* **IPv4 and IPv6** — a tunnel with an IPv6 address and `::/0` carries IPv6 too; without it, the phone's IPv6 is blocked while the tunnel is on, so nothing goes around it. Follows DNSCrypt Proxy's IP mode: in `ipv4` mode the tunnel carries IPv4 only; switching to `dual` or `compat` is picked up within seconds
* **Follows the network** — Wi-Fi ↔ mobile data, and Android's new network number on every reconnect, within seconds. Traffic bound to other networks (IMS / VoLTE, MMS) keeps Android's routing; the Wi-Fi LAN and hotspot devices stay local
* **Host-name endpoints** (e.g. a home server on dynamic DNS) — looked up with Quad9 outside the tunnel when it starts, and again when it stops answering
* **Steps aside for VPN apps** — while WireGuard, Proton VPN, v2rayNG or any other Android VPN is connected, WG Shield pauses and comes back when it disconnects
* **Watchdog** — every 10 s (2 s during the first minute after boot); repairs rules others remove, quiet during shutdown, log with boot-relative times before the clock is set
* **Status file for the other modules** — `/data/adb/wg-shield-state/status`; VPN Hotspot (1.0-r13) routes hotspot devices through the tunnel, DNSCrypt Proxy (2.1.18-r20) shows it
* **WebUI** — route strip, exit address on demand, tunnels with switches, import from Download and delete the export, kill switch, pause, log, report without keys, help
* **Action button** — tunnel on / off from the root manager
* **CLI** — `ctl.sh status | list | import | up | switch | down | remove | pause | resume | set killswitch | log | diag`
* **`wg`** — wireguard-tools v1.0.20250521, static arm64, reproducible with `build.sh`

### Development builds (tested on device, not published)

* Stage 0: manual prototype — policy routing instead of a netd VPN; Telegram call, normal call, SMS, Wi-Fi ↔ mobile and kill switch confirmed
* Stage 1: module core, CLI, watchdog, boot guard, automatic pause for VPN apps
* Stage 2: WebUI and Help; import of single `.conf` files, host-name endpoints; skipped imports logged with the reason
* Stage 3: IPv6 through the tunnel; key check on import; `wg` errors logged with keys cut out; status for VPN Hotspot and DNSCrypt Proxy; a route animation that no longer stalls while the page refreshes
