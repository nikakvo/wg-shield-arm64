# Changelog

## 2.0

AmneziaWG tunnels, next to WireGuard.

* **AmneziaWG** - a config with AmneziaWG settings (`Jc`, `Jmin`, `Jmax`, `S1`-`S4`, `H1`-`H4`, `I1`-`I5`, `HeaderProtectionKey`, `ContentPaddingAddition`, `RandomTrailers` and the rest of AmneziaWG 3.1) is run as an AmneziaWG tunnel; any other config stays plain WireGuard, exactly as before. No switch to set: the type is read from the file
* **Same tunnel, same protection** - both types use `wgs0`, the same routing, kill switch, pause and boot guard, and work the same with DNSCrypt Proxy and VPN Hotspot (no update of those needed). Switching between a WireGuard and an AmneziaWG tunnel creates `wgs0` again with the other type; the kill switch stays closed meanwhile
* **`awg` tool** - amneziawg-tools 3.1.20260812, static arm64, next to `wg` in `system/bin/`
* **Kernels without AmneziaWG** - WireGuard tunnels work as usual. AmneziaWG tunnels can be imported, but their switch is greyed out and the row says *AmneziaWG is not in this kernel*; if one was active, it shows *error* with a direct connection. The installer says whether the kernel has AmneziaWG
* **HeaderProtectionKey** is checked on import like the other keys and never shown: not in the WebUI, the log, the status or the Report (which hides it from `awg show`)
* **WebUI** - *AWG* badge on AmneziaWG tunnels, *Type* row on the Dashboard (WireGuard / AmneziaWG with the kernel's AmneziaWG version), clearer error banners; Help explains AmneziaWG
* **Status file** - new key `type=wireguard|amneziawg` (all other keys unchanged)
* Manager description shows *(AmneziaWG)* while such a tunnel runs
* Texts use a plain hyphen instead of the long dash

Tested on Poco F6 Pro, Xiaomi.eu ROM (HyperOS 3, Android 16), kernel [GKI_Kernel_SukiSU](https://github.com/nikakvo/GKI_Kernel_SukiSU) with AmneziaWG 3.1.20260812 built in: a self-hosted AmneziaWG 3.1 server and Proton VPN WireGuard configs, switching between them, Telegram and normal calls, SMS, hotspot devices through the tunnel (VPN Hotspot 1.0-r15), DNS through DNSCrypt Proxy 2.1.18-r23, kill switch.

---

## 1.0-r4

One folder for everything.

* **One folder.** Settings (`/data/adb/wg-shield.conf`) and the runtime state (`/data/adb/wg-shield-state/`) used to sit next to `/data/adb/wg-shield/`. Now everything is inside it: `settings.conf`, `tunnels/` (unchanged), `logs/` and `state/`. The update moves everything at the first boot and keeps any change made between flashing and rebooting. Tunnels and keys stay where they were
* **Status file** for the other modules is now `/data/adb/wg-shield/state/status`. VPN Hotspot 1.0-r15 and DNSCrypt Proxy 2.1.18-r23 read it there. While an older VPN Hotspot (or DNSCrypt) is installed, WG Shield also keeps a copy at the old place, so hotspot devices keep going through the tunnel; once both are updated the old folder is removed
* Reads VPN Hotspot's status from its new folder too (Networking set row)
* README: command-line examples use the full form `su -c '/system/bin/sh …/ctl.sh …'`

---

## 1.0-r3

Works with DNSCrypt Proxy Arm64 2.1.18-r22.

* **DNSCrypt row in Networking set** - DNSCrypt Proxy r22 keeps all its files in one folder, `/data/adb/dnscrypt-proxy/`. WG Shield now reads its state and IP mode from there (and still from the old places of older versions), so the row shows *working* again instead of *unknown*
* **IPv6 follows DNSCrypt's IP mode again** - DNSCrypt r22's *IPv4 only* keeps IPv6 on in the kernel (the carrier's VoLTE network needs it) and blocks it in its firewall instead. WG Shield used to read "kernel IPv6 on" as "the phone has IPv6" and put the tunnel's IPv6 on `wgs0` (nothing leaked - DNSCrypt's firewall dropped it - but the Dashboard said *through the tunnel*). It now reads DNSCrypt's IP mode too: in IPv4 only, IPv6 is *off on this phone* and the tunnel carries IPv4 only, as before

Tested on Poco F6 Pro, Xiaomi.eu ROM (HyperOS 3, Android 16), kernel [GKI_Kernel_SukiSU](https://github.com/nikakvo/GKI_Kernel_SukiSU), with DNSCrypt Proxy 2.1.18-r22.

---

## 1.0-r2

**Module**
- New card banner in the root manager (SukiSU-Ultra and other managers that support module banners).

No functional changes - tunnel, kill switch and WebUI work exactly as in 1.0-r1. Updating is optional.

Tested on Poco F6 Pro, Xiaomi.eu ROM (HyperOS 3, Android 16), kernel [GKI_Kernel_SukiSU](https://github.com/nikakvo/GKI_Kernel_SukiSU) (WireGuard built in), with Proton VPN WireGuard configs. Part of a set with DNSCrypt Proxy Arm64, ipset-arm64 and VPN Hotspot Arm64.

---

## 1.0-r1

First release. An always-on kernel WireGuard tunnel for the phone, without an app.

* **Kernel WireGuard, invisible to Android** - one interface (`wgs0`) and plain policy routing in front of Android's own rules (priorities 5000–5021, table 51820). No `VpnService`, no netd VPN network: that is what the WireGuard app does in root mode, and on the test phone it broke Telegram calls (no UDP through the tunnel). With WG Shield, Telegram calls, normal calls, SMS and MMS work with the tunnel up
* **Tunnels** - import the WireGuard app's export zip or single `.conf` files from Download (WebUI or `ctl.sh import`). Proton VPN configs work as downloaded: `DNS`, `PostUp`, `Table` and comments are ignored, a missing `PersistentKeepalive` becomes 25 s. Keys are checked on import (a key replaced by `*****` is refused with the reason in the log) and never shown anywhere
* **One switch per tunnel** - one on at a time, the interface stays `wgs0`; all off = your normal connection
* **Kill switch** (on by default) - a tunnel that is on but gets no handshake for 180 s (WireGuard's own limit) is *down*: no internet at all, never the plain connection. An `unreachable` route under the tunnel's route keeps it closed even if the interface disappears. When a tunnel was on at shutdown, traffic is blocked from early boot until it is up
* **Turning it off is not a failure** - off, pause (15 min / 1 h / 4 h) and "cannot be built at all" (error) give the normal connection
* **IPv4 and IPv6** - a tunnel with an IPv6 address and `::/0` carries IPv6 too; without it, the phone's IPv6 is blocked while the tunnel is on, so nothing goes around it. Follows DNSCrypt Proxy's IP mode: in `ipv4` mode the tunnel carries IPv4 only; switching to `dual` or `compat` is picked up within seconds
* **Follows the network** - Wi-Fi ↔ mobile data, and Android's new network number on every reconnect, within seconds. Traffic bound to other networks (IMS / VoLTE, MMS) keeps Android's routing; the Wi-Fi LAN and hotspot devices stay local
* **Host-name endpoints** (e.g. a home server on dynamic DNS) - looked up with Quad9 outside the tunnel when it starts, and again when it stops answering
* **Steps aside for VPN apps** - while WireGuard, Proton VPN, v2rayNG or any other Android VPN is connected, WG Shield pauses and comes back when it disconnects
* **Watchdog** - every 10 s (2 s during the first minute after boot); repairs rules others remove, quiet during shutdown, log with boot-relative times before the clock is set
* **Status file for the other modules** - `/data/adb/wg-shield-state/status`; VPN Hotspot (1.0-r13) routes hotspot devices through the tunnel, DNSCrypt Proxy (2.1.18-r20) shows it
* **WebUI** - route strip, exit address on demand, tunnels with switches, import from Download and delete the export, kill switch, pause, log, report without keys, help
* **Action button** - tunnel on / off from the root manager
* **CLI** - `ctl.sh status | list | import | up | switch | down | remove | pause | resume | set killswitch | log | diag`
* **`wg`** - wireguard-tools v1.0.20250521, static arm64, reproducible with `build.sh`

### Development builds (tested on device, not published)

* Stage 0: manual prototype - policy routing instead of a netd VPN; Telegram call, normal call, SMS, Wi-Fi ↔ mobile and kill switch confirmed
* Stage 1: module core, CLI, watchdog, boot guard, automatic pause for VPN apps
* Stage 2: WebUI and Help; import of single `.conf` files, host-name endpoints; skipped imports logged with the reason
* Stage 3: IPv6 through the tunnel; key check on import; `wg` errors logged with keys cut out; status for VPN Hotspot and DNSCrypt Proxy; a route animation that no longer stalls while the page refreshes
