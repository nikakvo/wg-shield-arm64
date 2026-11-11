# Changelog

## Unreleased

* **The host-name endpoint lookup opens the way around the tunnel only for itself** - while a name was looked up (up to 6 s per resolver, again at most once a minute while the tunnel does not answer), rule 5001 sent every packet of the phone to the resolver's address around the tunnel. Since 2.8 these are 1.1.1.1, 1.0.0.1 and 8.8.8.8, which apps and Android's Private DNS use as well (DoT / DoH): such a connection left the tunnel for that moment, with the kill switch on too. Now the rule takes only root's DNS query (`uidrange 0-0 dport 53`); with an `ip` that does not know `dport` in rules, root's packets only; without `uidrange` as before
* **An IPv6 DNS server written in a long form is used** - `DNS = FD00:0:0:0::53` (capitals, zeros not shortened) was set up, then not recognised in the rule list (ip6tables prints `fd00::53`), removed again, and IPv6 DNS was left to the network with a warning. The rules are now compared as ip6tables prints them
* **Addresses with leading zeros are refused** at import (`Endpoint = 010.1.1.1:51820`, `Address = 10.2.0.02/32`, the same in `DNS =`): one tool reads `010` as 10, another as 8 (octal), and iptables refuses it
* **LAN DNS through the tunnel** (Settings, off by default; `ctl.sh set landns 0|1`) - a resolver on your Wi-Fi (the router) stays local, so the router sees every name the phone looks up. With the setting on, and only while the tunnel is up, plain DNS (port 53, IPv4) that leaves through the Wi-Fi or another network that goes through the tunnel is sent to the tunnel's DNS too; nat `POSTROUTING` chain `wgs_dnss` gives those queries the tunnel's own source address. Names only the router knows (`printer.lan`) stop resolving meanwhile. While the tunnel is connecting or down - also with the kill switch on - the router is asked again and sees the lookups: Android's network check and a login page need the network's resolver, and their lookups cannot be told apart from an app's. Carrier services, a network Android is still checking, the lookup of a host-name endpoint and a resolver reached over IPv6 are left alone; nothing is done while DNSCrypt Proxy takes DNS. The chain is rebuilt when the networks change, checked as the kernel lists it, repaired when someone else changes it. Dashboard *DNS* row: `+ LAN`; status keys `landns=` and `dns_lan=`
* **Several DNS servers: the next one takes over** - of `DNS = 10.2.0.1, 10.2.0.2` only the first IPv4 server was ever used; when it stopped answering, every lookup failed although the tunnel was up. Now all IPv4 servers of the line are kept. When the tunnel check found the tunnel answering, and at most once a minute, the server in use is asked one question through the tunnel (`example.com`, busybox `nslookup`, 3 s); any DNS answer counts, also "no such name". No reply twice in a row: the redirect goes to the next server of the line (a warning in the log, `dns_server=` shows the one in use), after the last one to the first again. A tunnel that is loaded again starts with the first server. With several servers the chain starts with a `RETURN` for each of them, so the question reaches the server it is meant for. No checks (screen off in the Battery profile, checks off) = no question. Of the IPv6 servers only the first is used
* **The exit address is asked over HTTPS** - `exitip` (Dashboard **Check**) asked `ip-api.com` over plain HTTP: anyone between the VPN server and that service could read and change the answer. Now Android's `curl` asks over HTTPS, certificate checked - `ipinfo.io/json` (address, city, country, `org`), then `ipwho.is` (address, city, country, `isp`). Only without `curl`, or when both fail, the old plain-HTTP requests are used. The output keeps its keys and adds `proto=https|http`; the WebUI says when it was plain HTTP
* **Kill switch on error** (Settings, off by default; `ctl.sh set ks_error 0|1`) - a tunnel that cannot be built (its file missing or no longer valid, `setconf` refused, the tool or the kernel support missing) removes everything and the phone goes direct, kill switch or not. With the setting on and the kill switch on, traffic stays blocked then the way a down tunnel blocks it: the unreachable route in table 51820 with the capture rules 5020-5022, IPv6 unreachable, the local rules kept (LAN, hotspot, Android's network check, login page), no `wgs0`, no endpoint rule, no DNS redirect. From the first tick after boot too. Log: `state: error (...) - kill switch blocks traffic`; the module description and the WebUI banner say the same. It ends when the tunnel can be built, another tunnel is switched on, or the tunnel is turned off; a pause, a VPN app and turning the tunnel off never block. Status key `ks_error=`
* **Test harness** - the host-name endpoint lookup (new case `resolve`); the IPv6 DNS case without ip6tables failed on a PC since 2.7 (the test left `ip6tables-save` working); `-k dns6` alone runs

---
## 2.8

No more Quad9.

* **Host-name endpoints are looked up at Cloudflare, then Google** (`1.1.1.1`, `1.0.0.1`, `8.8.8.8`) instead of Quad9 - Quad9 stops answering in some countries (France from 24 November 2026). These are the addresses DNSCrypt Proxy 2.1.20-r4 lets root query directly; with an older DNSCrypt Proxy installed, Quad9 is still asked first so such a tunnel keeps starting
* **The self-healing ping goes to 1.1.1.1, then 8.8.8.8** (was 9.9.9.9) - still only through the tunnel
* Help: self-healing, host-name endpoints

Tested on Poco F6 Pro, Xiaomi.eu ROM (HyperOS 3, Android 16), kernel [GKI_Kernel_SukiSU](https://github.com/nikakvo/GKI_Kernel_SukiSU), with DNSCrypt Proxy 2.1.20-r4: a tunnel with a host-name server, a blocked server noticed by the ping and fixed by a restart, Proton and AmneziaWG tunnels, hotspot laptop through the tunnel, reboot.

---
## 2.7

Name lookups on mobile data without DNSCrypt Proxy, a faster first handshake, and a set of fixes - most of them found and written by [ivangotoy](https://github.com/ivangotoy) (pull request #1). Thank you!

* **Name lookups work on mobile data without DNSCrypt Proxy** - Android asks the resolvers of the network it is on. On mobile data the tunnel carried those queries to the carrier's resolvers, which do not answer queries coming from the VPN server: every lookup timed out while the tunnel itself was up. Now app DNS (port 53) that goes into the tunnel is sent to the first IPv4 server of the config's `DNS =` line (nat chain `wgs_dns`, `-o wgs0` only), and IPv6 DNS to its first IPv6 server while the tunnel carries IPv6. Only DNS that already goes into the tunnel is touched: a resolver on your Wi-Fi (the router) stays local as before, and carrier services (VoLTE / IMS, MMS), Android's network check and the captive portal login keep their network's DNS. A config without `DNS =` leaves DNS to the network. While DNSCrypt Proxy takes the phone's DNS (its redirect to 127.0.0.1), WG Shield does nothing with DNS; while DNSCrypt Proxy is paused, the tunnel's DNS answers. The rules are read with `iptables-save`, so WG Shield never holds the iptables lock that VPN apps and other modules need. Removed when the tunnel is off, paused, an app VPN is on, or the tunnel failed with the kill switch off; repaired if someone else changes it
* **Dashboard → Tunnel → DNS** shows who answers DNS: the tunnel's DNS (with its address), DNSCrypt Proxy, or the network's. Status keys `dns=` and `dns_server=`; the Report lists the DNS rules
* **The first handshake of a new server is not lost** - on a switch to another tunnel, a recovery step on another server, and when a host-name endpoint moves, the rule that sends the tunnel's own packets around the tunnel (5000) now knows the new server before WireGuard contacts it. Before, the first handshake could go into the tunnel itself and WireGuard tried again only after about 5 s
* **Settings changes no longer race the watchdog** - `up`, `switch`, `down`, `remove`, `removeall` and every `set` change `settings.conf` under the watchdog lock. Before, a change made while the watchdog was busy could be overwritten by it (the auto-switch saves the tunnel it switched to), so a `down` or `set killswitch` could be undone silently
* **Taking over the lock of a crashed process is safe** - two processes that both noticed a dead lock holder could both end up holding the lock; now only one wins
* **Tunnel files are checked more strictly** - the endpoint port must be 1-65535, and an IPv4 endpoint and the `Address` must be real addresses. Before, for example `Endpoint = 999.1.1.1:99999` was imported and failed only when the tunnel started
* **Zip entries with spaces in their name are imported** - a `.conf` such as `my vpn.conf` inside an export zip or the backup was skipped; now it is imported (as `my_vpn`)
* **Busybox of APatch and Magisk is found too**, not only KernelSU's - needed for host-name endpoints, `exitip` and `restart`
* **The status file keeps backslashes** in values (written with `printf`, not `echo`)
* **WebUI** - the star, ✕ and switch of a tunnel row and the country boxes read the tunnel name from the page data instead of inline code, so no name can break them
* **`wg` updated to wireguard-tools v1.0.20260223** (was v1.0.20250521); the commands WG Shield uses did not change. `awg` unchanged
* **Help** - section 6 (Import: the `DNS` line) and section 8 (DNSCrypt Proxy) describe the tunnel's DNS

Tested on Poco F6 Pro, Xiaomi.eu ROM (HyperOS 3, Android 16), kernel [GKI_Kernel_SukiSU](https://github.com/nikakvo/GKI_Kernel_SukiSU), Proton VPN WireGuard tunnels: switching servers (handshake at once), DNSCrypt Proxy paused on mobile data (tunnel's DNS answers, sites load) and on Wi-Fi (Wi-Fi validated after off / on), DNSCrypt Proxy resumed (DNS rules removed), WebUI tunnel controls, hotspot laptop through the tunnel, calls / SMS / VoLTE, reboot.

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
