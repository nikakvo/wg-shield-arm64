# Changelog

## Unreleased

Fixes found with a new offline test harness; no change for working setups.

* **Settings changes no longer race the watchdog** - `up`, `switch`, `down`, `remove`, `removeall` and every `set` now change `settings.conf` under the watchdog lock. Before, a change made while a tick was running could be overwritten by the tick (the auto-switch saves the tunnel it switched to), so a `down` or `set killswitch` could be undone silently
* **Tunnel files are checked more strictly** - the endpoint port must be 1-65535 and an IPv4 endpoint and the `Address` must be real addresses (four numbers 0-255, prefix 0-32). Before, for example `Endpoint = 999.1.1.1:99999` was imported and only failed later at `wg setconf`, with an error state
* **`wg` updated to wireguard-tools v1.0.20260223** (was v1.0.20250521) - upstream changes in the `wg` binary: two `syncconf` fixes (preshared keys and persistent keepalive removed from a config are now removed from the interface too) and a const-correctness cleanup; WG Shield uses `setconf`, `show` and `set`, which did not change. Rebuilt with `build.sh` (zig 0.16.0), reproducible: SHA-256 `92efd615c43f6668826ee84338a05587b24e5ad5dc3a5586f9312ca825b827da`. `awg` unchanged (already the newest amneziawg-tools commit)
* **Busybox found on APatch and Magisk too** - the scripts looked only for KernelSU's `/data/adb/ksu/bin/busybox`; now also `/data/adb/ap/bin/busybox` (APatch) and `/data/adb/magisk/busybox` (Magisk), the first one present. Without it a tunnel with a host-name endpoint could never be resolved (`nslookup` and `timeout` come only from busybox), and `exitip` and `restart` lost their busybox fallbacks
* **Name lookups work on mobile data** - with the tunnel on and no DNSCrypt Proxy, Android kept asking the network's own resolvers. On Wi-Fi those are on the LAN and stayed local, but a carrier's resolvers were reached through the tunnel and do not answer queries coming from the VPN server: every lookup timed out and apps showed no data, while the tunnel itself was up. App DNS (udp/tcp 53) that the routing sends into the tunnel or out of a network the tunnel captures (the default network and every other network that goes through the tunnel - so also a resolver on the Wi-Fi LAN, such as the router) now goes to the first IPv4 server of the config's `DNS =` line while the tunnel carries traffic (iptables nat chain `wgs_dns`, matched by the output interface). A query redirected from a LAN resolver would leave the tunnel with the Wi-Fi source address, which the VPN server does not accept: DNS leaving `wgs0` for the tunnel's DNS gets the tunnel's own address (SNAT, nat chain `wgs_dnss`). Carrier service networks (IMS, MMS) keep their own resolvers, also when they share an interface with a captured network (matched by their network mark), and Android's network check, the captive portal login, the host-name endpoint lookup (Quad9) and local resolvers keep theirs. Removed when the tunnel is off, paused, failed without kill switch, or DNSCrypt Proxy is on; repaired when someone else removes it (after a reboot it is set up as new, without that warning); a config without `DNS =` leaves DNS to the network as before
* **IPv6 DNS servers of a config are used** - while the tunnel carries IPv6, IPv6 app DNS goes to the first IPv6 server of the `DNS =` line the same way (ip6tables nat chains `wgs_dns` / `wgs_dnss`). Before, IPv6 resolvers of the network were reached through the tunnel and did not answer, so every lookup waited for them before trying IPv4. Without IPv6 in the tunnel IPv6 DNS into it stays blocked as before; without ip6tables nat one warning and IPv6 DNS is left to the network
* **The first handshake of a new endpoint is not lost** - on a switch to another tunnel, a recovery step on another server, and when a host-name endpoint moves, the rule that sends the tunnel's own UDP around the tunnel (5000) now knows the new endpoint before WireGuard gets it; the rule of the old endpoint goes at the same moment. Before, the rule followed only later in the same pass, so the first handshake could be routed into the tunnel itself and dropped, and WireGuard tried again only after about 5 s
* **Taking over the lock of a crashed process is atomic** - when the process holding the watchdog lock had died, two processes that both noticed it could both end up holding the lock (the second moved the first one's fresh lock away). Now only one wins the takeover, and it checks that the lock is still the dead holder's before replacing it
* **Zip entries with spaces in their name are imported** - a `.conf` such as `my vpn.conf` inside an export zip or the backup was split at the space and skipped as "file not found"; now every entry is taken whole (the tunnel name is sanitized as before: `my_vpn`)
* **The status file keeps backslashes** - written with `printf` instead of `echo`: under mksh (the WebUI's shell) `echo` interpreted a backslash in a value, e.g. in an error quoting a tunnel file's raw `Endpoint`, and could cut or merge lines of `state/status`
* **WebUI: a tunnel name with a quote cannot break its buttons** - the star, delete and on/off controls of a tunnel row (and the country boxes) took the name inside their `onclick` code, where an HTML-escaped `'` turns back into a quote; they now read it from a `data-` attribute. Imported names are sanitized anyway, so only a file put into the tunnels folder by hand could have hit it
* **Test harness** - `bash tests/harness.sh` runs the module scripts on a Linux PC inside a private user and network namespace (`unshare -n --map-auto`, else `unshare -rn`; no root, nothing outside is touched): import, up, handshake, kill switch, routing, validation, locking, backup and restore. `WGS_TEST_BB=/path/to/busybox` runs the same cases with busybox ash and its applets; `WGS_TEST_SH=/path/to/mksh` with mksh (the WebUI's shell). Also covered: recovery restarts and auto-switch (same country, a failed server address skipped, giving up and going back), pause / resume, removing the tunnel that is on, losing the default network, a second network (mobile data) captured with Android's own checks and the captive portal login kept on their network, restricted carrier networks left alone, the watchdog's `ip monitor` capture of a new network, `restart`, the busybox lookup, the DNS redirect (IPv4 and IPv6, with the host's real iptables / ip6tables where usable), the endpoint rule before the first handshake, two processes taking over a dead lock, zip entries with spaces, backslashes in the status file, and the WebUI's tunnel rows (with node)

---

## 2.6

Backup and restore of your tunnels.

* **Backup** (Tunnels tab, new section) - saves every tunnel and your stars to `/storage/emulated/0/wg-shield/wg-shield-backup.zip` - the same kind of zip the WireGuard app exports (one `.conf` per tunnel, plus `favorites.txt` and `backup-info.txt`), so the WireGuard / AmneziaWG app can import it too. One backup: a new one replaces it (tap twice when one exists); the new zip is unpacked again and compared file by file before it takes the old one's place, so a failed backup never destroys the previous one. The section shows how many tunnels the backup has, when it was saved and its size
* **Restore** (tap twice) - imports the tunnels of the backup and gives the backed-up favorites their star again; a tunnel with the same name is replaced, the others stay, the tunnel that is on is not changed
* **The backup survives** removing or reinstalling the module and **Clear all**; **✕** (tap twice) deletes it
* Command line: `backup`, `restore`, `backupinfo`, `delbackup`; the Report shows whether there is a backup
* **Help** - *Backup and restore* in section 6, the commands in section 10, the backup folder and uninstall note in section 12

Tested on Poco F6 Pro, Xiaomi.eu ROM (HyperOS 3, Android 16), kernel [GKI_Kernel_SukiSU](https://github.com/nikakvo/GKI_Kernel_SukiSU), 77 Proton VPN WireGuard tunnels and a self-hosted AmneziaWG server: backup of 78 tunnels from the WebUI and the terminal, replacing it, favorites in the backup, Clear all then Restore, the zip in Import from Download, the zip opened in a file manager and in the WireGuard app, deleting the backup.

---

## 2.5

Two small touches in the Tunnels tab.

* **Clear all** (Tunnels tab, at the right above the boxes, tap twice) - deletes every imported tunnel at once, with their keys and stars, instead of one ✕ at a time. The tunnel that was on turns off (normal connection) until you import and switch one on again. Speed test results are kept
* **The dot of the tunnel that is on is green and pulses** while it is protected (orange while it connects or is paused, red when it is down), so the box of the working tunnel stands out
* Command line: `removeall`
* **Help** - *Clear all* and the dot colours in section 6, `removeall` in section 10

Tested on Poco F6 Pro, Xiaomi.eu ROM (HyperOS 3, Android 16), 78 tunnels: Clear all from the WebUI, importing the exports again, the green dot.

---

## 2.4

Your tunnels by country, favorites, and a speed test that shows which tunnels share a server.

* **Country boxes** (Tunnels tab) - a box per country with its flag, code and count (`🇧🇬 BG · 7`) above the list; tap one to see only its tunnels, tap it again (or *Show all*) to see all. The country comes from the name - the first part of two capital letters (`wg-BG-14` → BG), the same rule Auto-switch uses; names without one are in **Others**. A dot marks the box of the tunnel that is on; the page remembers the box you picked
* **The tunnel that is on stays at the top** of the list, whatever box is picked; tunnels are sorted by number (`BG-14` before `BG-100`)
* **Favorites** - a ★ on every row; your favorites are in the **Favorites** box, the first one. Deleting a tunnel removes its star, importing it again keeps it
* **WireGuard / AmneziaWG filter** above the boxes when you have both kinds
* **Speed test** - **Test** in a box measures every server address in it once: how fast the first handshake comes ("connects in") and the average ping through the server. The rows are then grouped by server address, the fastest first and marked; each group says how old its result is. Nothing is switched for you. VPN providers often run several "servers" on one machine (with Proton, `BG-14`, `BG-18`, `BG-20` and `BG-24` can share one server address and leave through different exit addresses) - the groups show which tunnels usually fail together. The test uses a second, temporary tunnel interface next to the running one; the tunnel that is on and the kill switch are not touched, and everything temporary is removed right after (also when a test is stopped)
* **Auto-switch picks smarter** - a server address that already failed in an attempt is never tried again (before, the other tunnels of that address were tried last); inside the same country and then among the others, the fastest address of the last speed test goes first
* Command line: `fav add|del <name>`, `test <country code | others | favorites>`; the Report lists favorites and the last test results
* **Help** - country boxes, favorites, filter and speed test in section 6, the new Auto-switch order in section 7, `fav` and `test` in section 10

Tested on Poco F6 Pro, Xiaomi.eu ROM (HyperOS 3, Android 16), kernel [GKI_Kernel_SukiSU](https://github.com/nikakvo/GKI_Kernel_SukiSU), 77 Proton VPN WireGuard tunnels in 21 countries and a self-hosted AmneziaWG server: boxes and flags, favorites from the WebUI and the terminal, filter, remembered box after reopening the manager, speed test of several countries, Favorites and Others (AmneziaWG) with the tunnel on, nothing left behind after a test, Auto-switch skipping the tunnels of a failed server address.

---

## 2.3

Fewer checks by default, your choice how often, and a restart button.

* **Check every: 5 s, 30 s or Off** (Settings, new) - how often the tunnel is pinged. **30 s** is the new default (120 pings an hour instead of 720; a dead tunnel is found in about 40 seconds). **5 s** is the 2.2 behaviour (found in about 10 seconds). **Off** sends no pings at all: only WireGuard's own 3-minute rule watches the tunnel, the self-healing and the notification still work, just later. A missed ping is tried again at once before anything happens; a recovery in progress, a network change and the screen coming on still check at once. Battery / Always works with every interval
* **Restart WG Shield** (Settings → Maintenance, tap twice) - stops the watchdog, builds the tunnel again with a new connection to the server and starts the watchdog again, for when something looks stuck. A few seconds, no reboot; the tunnel, settings, a pause or "off" stay as they are, and the kill switch keeps blocking meanwhile
* Command line: `set checks 5|30|off`, `restart`
* Status file: new key `checks=` (all other keys unchanged)
* **Help** - *Check every* in section 7, `set checks` and `restart` in section 10, *Something looks stuck* in Troubleshooting

Tested on Poco F6 Pro, Xiaomi.eu ROM (HyperOS 3, Android 16), kernel [GKI_Kernel_SukiSU](https://github.com/nikakvo/GKI_Kernel_SukiSU), Proton VPN WireGuard: default 30 s interval, server blocked with 30 s, 5 s and Off (restarts, switch to another tunnel), Restart from the WebUI and from the terminal (watchdog keeps running after the terminal is closed), Restart while paused, normal use without false alarms.

---

## 2.2

A tunnel that stops working is noticed within seconds and fixed by itself.

* **Noticed within about 10 seconds** - every 5 s the module pings through the tunnel (1.1.1.1, then 9.9.9.9, never around it). No answer to two tries = the tunnel does not work - until now that showed only after WireGuard's own 3 minutes without a handshake (still there as a second check). Only an answer counts: traffic coming in alone does not prove that the way out works. A server that never answers a ping is not called dead for that
* **Self-healing** - a dead tunnel is restarted twice at once (new handshake from a new port, a host-name server looked up again), 10 seconds per step. A step counts as fixed only when an answer comes back through the tunnel, not just a handshake. The kill switch holds the whole time
* **Auto-switch on failure** (Settings, off by default) - if the restarts do not help, your other tunnels are tried, at most 5: first the same country (`wg-BG-14` → the other `*-BG-*` tunnels), then any other; tunnels on another server address first. The first one that answers stays on. Nothing helped: back to the tunnel you picked, which stays down and keeps being checked
* **One notification** (Settings, on by default) when a switch to another tunnel was needed or nothing helped, saying what was tried - so you know you have no internet without opening the manager. When the tunnel answers again, it is replaced with that news. **Send a test notification** shows how it looks. Posted through Android's shell, no extra app
* **Checks profile** (Settings) - **Battery** (default): checks only while the screen is on, nothing at all with the screen off, and a check the moment the screen comes on. **Always**: day and night, for devices on your hotspot or apps that work in the background. A recovery that has started is always followed to the end
* Switching a tunnel yourself, pausing or turning it off stops a recovery at once; a new network starts a new attempt
* **WebUI** - banner and Dashboard → Tunnel → *Self-healing* show the step (restart 1 of 2, trying wg-BG-28, checking it answers, nothing helped); new states *Recovering* and *Checking*
* **Help** - Self-healing, Checks profile and Notification in section 7, *No notification* in Troubleshooting
* Command line: `set autoswitch 0|1`, `set notify 0|1`, `set profile battery|always`, `notifytest`; the Report shows a recovery in progress
* Status file: new keys `recover=`, `recover_from=`, `profile=`, `autoswitch=`, `notify=`; reason `no_answer` (all other keys unchanged)

Tested on Poco F6 Pro, Xiaomi.eu ROM (HyperOS 3, Android 16), kernel [GKI_Kernel_SukiSU](https://github.com/nikakvo/GKI_Kernel_SukiSU), Proton VPN WireGuard: server blocked (one and both server addresses of a country) with Auto-switch off and on, restart that fixes it, switch to another tunnel, nothing helps + notification, back up + notification, Battery profile with the screen off and on, Always profile with the screen off, normal use without false alarms.

---

## 2.1-r1

LAN Cloak joins the networking set.

* **LAN Cloak row** in Dashboard → Networking set: shows whether [LAN Cloak Arm64](https://github.com/nikakvo/lan-cloak-arm64) is installed and what it does right now (cloaked, off, error, disabled). LAN Cloak hides what the Wi-Fi network itself sees of the phone; the tunnel covers the rest. WG Shield only reads LAN Cloak's status - routing, kill switch and tunnels are unchanged
* **WebUI opens quickly every time** - after closing and quickly reopening it, the page could wait several seconds before showing anything. The root manager sometimes drops the page's very first command; the page now asks again after a moment instead of waiting for the lost answer
* The report (`ctl.sh diag`) lists LAN Cloak with the other modules
* Help → *With the other modules of the set* and the README describe the five modules

---

## 2.1

Nothing goes around the tunnel when the network changes.

* **Every internet network goes through the tunnel** - until now only the network Android used at the moment did. Android keeps more than one network up: mobile data stays connected in the background while you are on Wi-Fi, and a new Wi-Fi is up for a few seconds before Android uses it. Apps and Android itself send traffic over such a network on purpose - Google's push service connected over a new Wi-Fi a split second after Android had checked it, outside the tunnel. Now that traffic goes through the tunnel as well, and a new network is caught the moment Android creates it
* **Android's network check and the hotel / airport login page stay on their network** - only these two never go through the tunnel (on every network), so a broken Wi-Fi is never taken for a working one and a captive portal login page can open
* **Carrier services untouched** - IMS (VoLTE, Wi-Fi calling) and MMS-only networks keep Android's routing, as before
* **Network changes followed at once** - the watchdog watches Android's network rules and acts the moment they change, instead of on its next check (up to 10 s)
* **No gap while rules change** - new rules are in place before the old ones go, so the kill switch never opens for a moment; rules are set in one go (faster) and checked afterwards
* **Rules of a network that is gone are always removed** - they are written with the table number, which stays valid after Android forgets the network's name
* **WebUI** - opens faster (the tunnel list is read only when a file changed); Dashboard → Tunnel → *Other networks* shows what goes where
* **Report** - lists every network with where an app's and Android's traffic bound to it goes
* Status file: new key `nets=` (all other keys unchanged)

Tested on Poco F6 Pro, Xiaomi.eu ROM (HyperOS 3, Android 16), kernel [GKI_Kernel_SukiSU](https://github.com/nikakvo/GKI_Kernel_SukiSU): Proton VPN WireGuard on Wi-Fi with mobile data in the background, Wi-Fi switched off and on many times (captured with tcpdump: only Android's network check on the Wi-Fi, nothing else), calls, SMS, Telegram calls, hotspot devices through the tunnel (VPN Hotspot 1.0-r15), DNS through DNSCrypt Proxy, kill switch.

---

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
