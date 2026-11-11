<p align="center"><img src="readme-banner.png" alt="WG Shield Arm64"></p>

<p align="center">
  <img src="https://img.shields.io/badge/ARM64-only-7dd3fc?style=flat-square" />
  <img src="https://img.shields.io/badge/v2.8-blue?style=flat-square" />
  <img src="https://img.shields.io/badge/SukiSU%20%2F%20KernelSU%20%2F%20Magisk-compatible-brightgreen?style=flat-square" />
  <img src="https://img.shields.io/badge/WireGuard%20%2B%20AmneziaWG-kernel-7dd3fc?style=flat-square" />
  <img src="https://img.shields.io/badge/WebUI-built%20in-7dd3fc?style=flat-square" />
</p>

# WG Shield - arm64

An always-on **WireGuard or AmneziaWG tunnel in the kernel, without an app**. It starts at boot, survives killing apps from recents, follows Wi-Fi ↔ mobile data by itself, has a **kill switch** - while a tunnel is on but not working, nothing leaves the phone around it - and **fixes a dead tunnel by itself** within seconds. Import your tunnels (Proton VPN configs work as downloaded, AmneziaWG configs are recognised by themselves), switch one on, done.

Android sees no VPN - no key icon, no `VpnService`, nothing an app can detect or trip over. Calls over the mobile network (VoLTE, Wi-Fi calling), SMS and MMS keep using the carrier's own networks.

<img width="300" alt="WG Shield WebUI" src="https://raw.githubusercontent.com/nikakvo/wg-shield-arm64/main/wg-shield-arm64.jpg" />

---

## Why

- A normal VPN app dies when you clear recents; Android's *Always-on VPN* then locks you out until the app comes back
- The WireGuard app **with root** (kernel backend) stays up, but builds an Android VPN network by hand - and on this phone that broke Telegram calls (no UDP through the tunnel: it rings, never connects)
- WG Shield does neither: it is plain Linux routing below Android, run by a watchdog. Telegram calls, normal calls and SMS work with the tunnel up (tested on the device)

---

## Features

- **Kernel WireGuard, no app** - one interface, `wgs0`, whichever tunnel is on
- **AmneziaWG too** - a config with AmneziaWG settings (`Jc`, `S1`-`S4`, `H1`-`H4`, `I1`-`I5`, `HeaderProtectionKey`…) runs as an AmneziaWG tunnel, any other as plain WireGuard. Nothing to choose: the type is read from the file, the tunnel row shows an **AWG** badge. Same routing, kill switch and networking set for both
- **Every tunnel a switch** - import the WireGuard app's export zip or single `.conf` files (WireGuard or AmneziaWG); one tunnel on at a time, all off = your normal connection
- **Country boxes** - the Tunnels tab groups your tunnels by country: flag, code and count (`🇧🇬 BG · 7`), tap one to see only its tunnels. The country comes from the name (`wg-BG-14` → BG); names without a code go to **Others**. The tunnel that is on always stays at the top; a WireGuard / AmneziaWG filter when you have both
- **Favorites** - a ★ on any tunnel puts it in the **Favorites** box, the first one
- **Backup and restore** - one tap saves every tunnel (and your stars) to `/storage/emulated/0/wg-shield/wg-shield-backup.zip`, the same kind of zip the WireGuard app exports; it stays when the module is removed, so a reinstall or a **Clear all** is undone with **Restore**. One backup, a new one replaces it
- **Speed test** - one tap measures every **server address** in a box: how fast it connects and the ping through it, with the fastest marked. Several "servers" of a VPN provider often run on one machine (same server address, different exit addresses); the test groups them, measures them once and shows that they belong together. It runs on a second, temporary tunnel interface - the tunnel that is on and the kill switch are not touched, nothing is switched for you
- **Kill switch** - tunnel on but not answering (no handshake for 180 s, WireGuard's own limit) → no internet at all, never the plain connection; from the first second of boot when a tunnel was on
- **Self-healing** - the tunnel is pinged through itself every 30 s (or 5 s); no answer = noticed within about 40 s (10 s with 5 s), not after WireGuard's 3 minutes. It is restarted twice at once, and with **Auto-switch** on, your other tunnels are tried - the same country first (`wg-BG-14` → other BG tunnels), then any other, never one on a server address that already failed, the fastest by the last speed test first. The kill switch holds the whole time
- **One notification** when the tunnel could not be fixed (or after a switch to another tunnel), saying what was tried - you learn you have no internet without opening the manager
- **Checks profile: Battery or Always** - Battery (default) checks only while the screen is on and checks at once when it comes on; Always checks day and night (hotspot devices, background apps)
- **Check every: 5 s, 30 s or Off** - how often the tunnel is pinged (30 s by default); Off sends no pings at all and leaves it to WireGuard's 3-minute rule
- **Restart WG Shield** - one button (or `ctl.sh restart`) restarts the watchdog and rebuilds the tunnel when something looks stuck, without a reboot; the kill switch holds meanwhile
- **Your choice is not a failure** - turn the tunnel off or pause it (15 min / 1 h / 4 h) and the phone simply uses your connection
- **IPv4 and IPv6** - a tunnel with an IPv6 address and `::/0` carries IPv6 too; one without blocks IPv6 while it is on, so nothing goes around it
- **Wi-Fi ↔ mobile data** - followed the moment Android switches: the watchdog watches Android's network rules and acts at once, not on its next check
- **Every internet network, not only the current one** - mobile data kept up in the background while you are on Wi-Fi, a Wi-Fi Android is still checking: whatever an app or Android sends over them goes through the tunnel too. A new network is caught the moment Android creates it. Only Android's own network check and the login page of a hotel / airport Wi-Fi go out on the network itself, so a broken Wi-Fi is never taken for a working one and a login page can open
- **Host-name endpoints** - a home server on dynamic DNS works; the name is looked up again if the tunnel stops answering
- **LAN DNS through the tunnel** (opt-in) - while the tunnel is up, lookups sent to a resolver on your Wi-Fi (the router) go to the tunnel's DNS too, so the router does not see them
- **Steps aside for VPN apps** - connect WireGuard, Proton VPN or v2rayNG and WG Shield pauses itself, until that VPN disconnects
- **Local stays local** - your Wi-Fi LAN (router, printer, SSH from a laptop) and hotspot devices are reached directly
- **Private keys stay private** - stored root-only, never shown in the WebUI, the log, the status or the report (the same for AmneziaWG's `HeaderProtectionKey`)
- **Action button** in the root manager - tunnel on / off without opening anything
- **WebUI** - route at a glance, exit address on demand, tunnels, import, kill switch, pause, log, report, help

---

## How it works

```
app on the phone
      ↓
routing rules 5000–5022  (before Android's own, which start at 10000)
      ↓
wgs0 - the kernel tunnel (WireGuard or         table 51820: default dev wgs0
       AmneziaWG), encrypted
      ↓                                                    + unreachable (kill switch)
your Wi-Fi or mobile network → VPN server → internet
```

| Rule | What for |
|---|---|
| 5000 | The tunnel's own encrypted packets to the server go out through your network |
| 5010–5013 | Local destinations stay local: Wi-Fi LAN, hotspot devices, the local range of every other network |
| 5014 | Android's own network check (NetworkStack) and the captive portal login page stay on the network they are for |
| 5020 | Everything not bound to one network → the tunnel |
| 5021 | Everything bound to the current default network → the tunnel |
| 5022 | Everything bound to another internet network (mobile data in the background, a Wi-Fi not yet in use) → the tunnel |

During a speed test two more rules exist for a few seconds per server: 4990 (the test interface's own packets to that server go out through your network) and 4991 (pings bound to the test interface use its table 51821). Both, the interface `wgt0` and the table are removed right after each server.

Carrier service networks keep Android's routing - that is how IMS (VoLTE, Wi-Fi calling) and MMS keep working. Which network is which comes from Android itself: restricted networks (IMS and the like) are never touched, networks without internet (MMS only) are left alone after one look at `dumpsys connectivity`. No firewall (iptables) rules at all: nothing can conflict with Android's firewall lock or with the other modules' chains.

`wgs0` is created with the type of the tunnel that is on (`wireguard` or `amneziawg`) and set up with the matching tool (`wg` or `awg`). Switching between the two types creates `wgs0` again; the `unreachable` route keeps the kill switch closed meanwhile.

A watchdog follows Android's network rules as they change (`ip monitor`): a new network goes through the tunnel within a fraction of a second, a new default network is followed at once. On top of that it checks every 10 seconds (every 2 s during the first minute after boot): the right tunnel loaded, every rule in place. Rules are changed without a gap - the new ones are in place before the old ones go - so the kill switch never opens. Anything off is put back and logged.

---

## Requirements

| | |
|---|---|
| CPU | arm64 |
| Kernel | WireGuard built in (`CONFIG_WIREGUARD`) - the installer checks and stops if it is missing |
| Kernel, for AmneziaWG | AmneziaWG built in or loaded (`CONFIG_AMNEZIAWG`, `/sys/module/amneziawg`) - optional: without it only AmneziaWG tunnels cannot start (their switch is greyed out), WireGuard tunnels work as usual |
| Root | SukiSU Ultra or KernelSU (WebUI built in) · APatch · Magisk (WebUI via MMRL or KSU WebUI Standalone) |
| Android | 12+ (tested on 16) |
| Tunnels | wg-quick format (WireGuard or AmneziaWG): one `[Peer]`, `AllowedIPs` with `0.0.0.0/0`, an `Endpoint` as an IPv4 address or a host name |

### Tested on

Poco F6 Pro (vermeer), Xiaomi.eu ROM (HyperOS 3, Android 16), custom kernel [GKI_Kernel_SukiSU](https://github.com/nikakvo/GKI_Kernel_SukiSU) (SukiSU Ultra, WireGuard and AmneziaWG 3.1.20260812 built in), with Proton VPN WireGuard configs (IPv4 and IPv4 + IPv6) and a self-hosted AmneziaWG 3.1 server - on Wi-Fi and on mobile data, together with DNSCrypt Proxy Arm64, ipset-arm64 and VPN Hotspot Arm64. Other devices, ROMs and kernels should work (the routing is Android's own netd layout) but are not tested - reports welcome.

---

## Installation

1. Flash `wg-shield-arm64-vX.X.zip` in your root manager, reboot
2. WireGuard app: **⋮ → Export tunnels** (a zip in Download) - or download `.conf` files from your VPN provider. An AmneziaWG config: put the `.conf` file in Download
3. WebUI → **Tunnels → Import from Download → Import**, then delete the file there (**✕**) - it holds your private keys
4. Disconnect the tunnel in the WireGuard / AmneziaWG app (one key, one tunnel)
5. Switch a tunnel on - the route at the top shows **Phone → tunnel → Internet**

Tunnels and settings are kept on update.

---

## WebUI

| Tab | |
|---|---|
| Dashboard | Route strip · exit address (tap **Check**) · tunnel: type, server, handshake, traffic, IPv6, network, the other networks · the networking set · watchdog |
| Tunnels | Country boxes (+ Favorites, Others) · WireGuard / AmneziaWG filter · every tunnel with a switch (one at a time), ★, an **AWG** badge for AmneziaWG tunnels, and **✕**; the tunnel that is on at the top (green pulsing dot on its box) · **Clear all** deletes every tunnel at once · **Backup** / **Restore** / delete the backup · **Test** a box: results grouped by server address, fastest marked · import from Download, delete the export |
| Settings | Kill switch · Kill switch on error · LAN DNS through the tunnel · checks profile (Battery / Always) · check every 5 s / 30 s / off · Auto-switch on failure · Notification + test · pause 15 min / 1 h / 4 h, resume · Check now · Report (no keys) · Restart |
| Log | Filterable by level |

---

## States

| State | Meaning |
|---|---|
| **Protected** | The tunnel is up and answers |
| **Connecting** | Just switched on, waiting for the first handshake (or for a network) |
| **Recovering** | The tunnel stopped answering - a restart or another tunnel is being tried; the banner says which step |
| **Checking** | After a restart or a switch: handshake done, waiting for an answer through the tunnel (a few seconds) |
| **Down** | Nothing answers through the tunnel (or no handshake for 180 s) and self-healing could not fix it - kill switch on: no internet; off: direct until it answers again |
| **Paused** | You paused it, or a VPN app is connected - direct connection |
| **Error** | The tunnel cannot be built (file gone, kernel refused it, an AmneziaWG tunnel on a kernel without AmneziaWG) - direct connection, the banner says why. With **Kill switch on error** on (Settings, `ctl.sh set ks_error 1`; off by default) and the kill switch on: no internet, like **Down** - until the tunnel can be built, another one is switched on, or the tunnel is turned off |
| **Off** | No tunnel switched on - your normal connection |

---

## IPv6

| DNSCrypt Proxy IP mode | Tunnel with IPv4 only | Tunnel with IPv4 + IPv6 |
|---|---|---|
| `ipv4` (IPv6 off for the phone) | IPv4 | IPv4 - the IPv6 part is not used |
| `compat` | IPv6 blocked | IPv6 through the tunnel |
| `dual` | IPv6 blocked, apps use IPv4 | **full IPv6 through the tunnel** |

Nothing leaks in any combination. Switching the IP mode while a tunnel runs is picked up within seconds. Proton's commented-out IPv6 `Endpoint` line is only another way to reach the server - leave it commented.

---

## The networking set

Five modules built to work together - each one works on its own, and each adds a layer for the phone **and everyone on its hotspot**:

| | Module | What it adds |
|---|---|---|
| 🟢 | [DNSCrypt Proxy Arm64](https://github.com/nikakvo/dnscrypt-proxy-android-arm64-only) | Encrypted DNS with ad / tracker blocklists - for the phone and for hotspot devices |
| 🔵 | [ipset-arm64](https://github.com/nikakvo/ipset_arm64) | IP blocklists (FireHOL, Spamhaus) in the kernel - stops connections to hard-coded IP addresses, which DNS blocking cannot see |
| 🟡 | [VPN Hotspot Arm64](https://github.com/nikakvo/vpn-hotspot-arm64) | Sends hotspot, USB and Bluetooth devices through the phone's VPN, with kill switch |
| 🩵 | **WG Shield Arm64** *(this module)* | Always-on kernel WireGuard / AmneziaWG for the phone, with kill switch - no app |
| 🩷 | [LAN Cloak Arm64](https://github.com/nikakvo/lan-cloak-arm64) | What the local network sees of the phone: clean DHCP, no announcements |

```
app on the phone  /  device on your hotspot
   │  DNS      → DNSCrypt Proxy   encrypted, filtered
   │  traffic  → ipset            listed networks dropped
   │  hotspot  → VPN Hotspot      into the tunnel (kill switch)
   ▼  tunnel   → WG Shield        kernel WireGuard / AmneziaWG, always on (kill switch)
internet
```

- **DNS stays with DNSCrypt Proxy** - while DNSCrypt Proxy is on, WG Shield leaves DNS alone (the `DNS =` line of a config is not used); DNSCrypt's own queries simply travel inside the tunnel. Its System tab shows *Through WG Shield · tunnel*
- **Without DNSCrypt Proxy, apps use the tunnel's DNS** - app DNS (port 53) that goes into the tunnel is sent to the first IPv4 server of the config's `DNS =` line (and IPv6 DNS to its first IPv6 server while the tunnel carries IPv6). With several IPv4 servers in the line the next one takes over when the one in use stops answering (IPv4 only; see Notes). Without this, name lookups fail on mobile data: Android asks the carrier's resolvers through the tunnel, and they do not answer queries arriving from the VPN server. A resolver on your Wi-Fi (the router) stays local, as before; carrier services (VoLTE / IMS, MMS), Android's network check and the captive portal login keep their network's DNS. A config without `DNS =` leaves DNS to the network. While DNSCrypt Proxy takes the phone's DNS, WG Shield does nothing with DNS (while DNSCrypt Proxy is paused, the tunnel's DNS answers). The Dashboard *DNS* row and the status key `dns=` show which one answers
- **LAN DNS through the tunnel** (Settings, off by default; `ctl.sh set landns 1`) - a resolver on your Wi-Fi sees every name the phone looks up. With this on, and only while the tunnel is up, plain DNS (port 53, IPv4) that leaves through the Wi-Fi - or another network that goes through the tunnel - is sent to the tunnel's DNS as well (nat chain `wgs_dns`, and `wgs_dnss` gives those queries the tunnel's own source address). Names only the router knows (`printer.lan`) stop resolving meanwhile. While the tunnel is connecting or down, also with the kill switch on, the router is asked again and sees the lookups made then: Android's network check and a login page need the network's own resolver, and their lookups cannot be told apart from an app's (so while the tunnel is up they go to the tunnel's DNS too; on a new Wi-Fi with a login page the prompt can come late, until WG Shield has noticed that the tunnel does not answer there). Not redirected: carrier services, a network Android is still checking, a resolver reached over IPv6 (on a Wi-Fi with IPv6 the router can still see lookups), Private DNS. Nothing is done while DNSCrypt Proxy takes the phone's DNS. The *DNS* row shows `+ LAN` while it is active, the status key `dns_lan=` lists the interfaces
- **Hotspot devices follow the tunnel** - WireGuard or AmneziaWG alike: VPN Hotspot (1.0-r13 or newer) reads WG Shield's status: through the tunnel when it is up, direct when you turn it off or pause it, blocked when it fails
- **ipset** blocks as always; a tunnel server must never be in its lists (check it with its *Check* tool)
- **LAN Cloak** - hides what the Wi-Fi network itself sees of the phone (DHCP, announcements); the tunnel covers the rest. WG Shield's Dashboard shows its state
- **No firewall conflicts** - WG Shield uses routing only; the others read the firewall without taking Android's lock

---

## Files

| Path | |
|---|---|
| `/data/adb/wg-shield/` | Everything the module keeps, in one folder: |
| `  settings.conf` | Settings: active and last tunnel, kill switch, checks profile and interval, auto-switch, notification, LAN DNS through the tunnel, kill switch on error |
| `  tunnels/` | Imported tunnels with their keys, root only (`0600`) |
| `  favorites` | Favorite tunnel names, one per line |
| `  speedtest` | Last speed test result per server address (the auto-switch order uses it) |
| `  logs/wg-shield.log` | Log |
| `  state/` | Runtime state, cleared at boot; `status` is read by the sibling modules |
| `/storage/emulated/0/wg-shield/wg-shield-backup.zip` | The backup (WebUI **Backup**): one `.conf` per tunnel, `favorites.txt`, `backup-info.txt`. Kept when the module is removed. Holds private keys, like an export in Download |
| `system/bin/wg` | `wg` from [wireguard-tools](https://git.zx2c4.com/wireguard-tools/) v1.0.20260223, static arm64 - also on the path: `su -c '/system/bin/wg show wgs0'` |
| `system/bin/awg` | `awg` from [amneziawg-tools](https://github.com/amnezia-vpn/amneziawg-tools) 3.1.20260812, static arm64 - for an AmneziaWG tunnel: `su -c '/system/bin/awg show wgs0'` (that output includes the header protection key - do not share it; `ctl.sh diag` hides it) |

### Status file (for other modules)

`/data/adb/wg-shield/state/status`, rewritten atomically on every watchdog pass (up to 1.0-r3: `/data/adb/wg-shield-state/status` - a copy is kept there only while VPN Hotspot older than 1.0-r15 or DNSCrypt Proxy older than 2.1.18-r23 is installed):

```
state=up|handshaking|down|paused|off|error
reason=…            iface=wgs0            table=51820         type=wireguard|amneziawg
tunnel=<name>       endpoint=<ip:port>    endpoint_host=<host:port, if a name>
handshake_age=<s>   killswitch=1|0        ipv6=tunnel|blocked|off
default_net=…       android_vpn=…         updated=<epoch>
recover=restart N/2|switch <name>|failed|  recover_from=<tunnel>
profile=battery|always  checks=5|30|off   autoswitch=0|1    notify=0|1
dns=tunnel|dnscrypt|network  dns_server=<the tunnel's DNS in use, IPv4 [IPv6]>
landns=0|1          dns_lan=<interfaces whose DNS goes to the tunnel's DNS too, empty when none>
ks_error=0|1        (1 and killswitch=1: state=error blocks traffic like state=down)
```

---

## Command line

```sh
# from Termux
su -c '/system/bin/sh /data/adb/modules/wg-shield/ctl.sh status'
su -c '/system/bin/sh /data/adb/modules/wg-shield/ctl.sh list'
su -c '/system/bin/sh /data/adb/modules/wg-shield/ctl.sh import /sdcard/Download/wireguard-export.zip'
su -c '/system/bin/sh /data/adb/modules/wg-shield/ctl.sh import /sdcard/Download/amneziawg.conf'
su -c '/system/bin/sh /data/adb/modules/wg-shield/ctl.sh up [name]'   # last used when no name
su -c '/system/bin/sh /data/adb/modules/wg-shield/ctl.sh switch <name>'
su -c '/system/bin/sh /data/adb/modules/wg-shield/ctl.sh down'   # normal connection
su -c '/system/bin/sh /data/adb/modules/wg-shield/ctl.sh pause <minutes>'
su -c '/system/bin/sh /data/adb/modules/wg-shield/ctl.sh resume'
su -c '/system/bin/sh /data/adb/modules/wg-shield/ctl.sh set killswitch 0|1'
su -c '/system/bin/sh /data/adb/modules/wg-shield/ctl.sh set ks_error 0|1'   # kill switch also when the tunnel cannot be built (error)
su -c '/system/bin/sh /data/adb/modules/wg-shield/ctl.sh set profile battery|always'
su -c '/system/bin/sh /data/adb/modules/wg-shield/ctl.sh set checks 5|30|off'
su -c '/system/bin/sh /data/adb/modules/wg-shield/ctl.sh set autoswitch 0|1'
su -c '/system/bin/sh /data/adb/modules/wg-shield/ctl.sh set notify 0|1'
su -c '/system/bin/sh /data/adb/modules/wg-shield/ctl.sh set landns 0|1'   # LAN DNS through the tunnel
su -c '/system/bin/sh /data/adb/modules/wg-shield/ctl.sh notifytest'   # how the notification looks
su -c '/system/bin/sh /data/adb/modules/wg-shield/ctl.sh restart'   # watchdog + tunnel again
su -c '/system/bin/sh /data/adb/modules/wg-shield/ctl.sh remove <name>'
su -c '/system/bin/sh /data/adb/modules/wg-shield/ctl.sh removeall'   # delete every imported tunnel (the tunnel turns off)
su -c '/system/bin/sh /data/adb/modules/wg-shield/ctl.sh backup'   # save all tunnels to /storage/emulated/0/wg-shield/wg-shield-backup.zip (replaces the old one)
su -c '/system/bin/sh /data/adb/modules/wg-shield/ctl.sh restore'   # import the tunnels of the backup
su -c '/system/bin/sh /data/adb/modules/wg-shield/ctl.sh backupinfo'   # is there a backup, how many tunnels, when
su -c '/system/bin/sh /data/adb/modules/wg-shield/ctl.sh delbackup'   # delete the backup
su -c '/system/bin/sh /data/adb/modules/wg-shield/ctl.sh fav add <name>'   # favorite; fav del <name> removes it
su -c '/system/bin/sh /data/adb/modules/wg-shield/ctl.sh test BG'   # speed test of a box: a country code, others or favorites
su -c '/system/bin/sh /data/adb/modules/wg-shield/ctl.sh log [lines|clear]'
su -c '/system/bin/sh /data/adb/modules/wg-shield/ctl.sh diag'   # report, no keys
```

---

## Verify

```
curl https://ifconfig.me          → the VPN's address
```

Then block the server for a moment (the first command reads the tunnel's server address from the status file and remembers it for the undo): internet stops at once - nothing goes around the tunnel.

```sh
su -c 'e=$(/system/bin/sed -n "s/^endpoint=\([^:]*\):.*/\1/p" /data/adb/wg-shield/state/status); echo $e > /data/local/tmp/wgs-block; /system/bin/iptables -I OUTPUT -d $e -j DROP'
su -c '/system/bin/iptables -D OUTPUT -d $(/system/bin/cat /data/local/tmp/wgs-block) -j DROP'   # undo
```

Within about 40 seconds (10 with Check every 5 s) the banner shows *restart 1 of 2*, then the recovery steps; after that comes the notification (or, with Auto-switch, another tunnel takes over).

---

## Notes

- **The ping** goes through the tunnel only (bound to `wgs0`, to 1.1.1.1 / 8.8.8.8), so it shows nothing new to your network. A server that never answers a ping is not called dead for that - for such a tunnel WireGuard's own 180 s rule decides
- **The speed test** sends, per server address, one WireGuard handshake and a few pings to 1.1.1.1 through that server - nothing outside a tunnel. A server can take a few seconds before it answers a key it has not seen for a while; the test waits up to 10 seconds for the answers
- **Notifications** are posted through Android's shell, so they appear as *Shell* / *Command line*; HyperOS shows them when the screen comes on
- **Host-name endpoints** are looked up with one plain DNS query outside the tunnel to Cloudflare (`1.1.1.1`, `1.0.0.1`), then Google (`8.8.8.8`) (the tunnel is not up yet); the same resolvers DNSCrypt Proxy lets root query directly
- **Several DNS servers** - `DNS = 10.2.0.1, 10.2.0.2`: the first IPv4 server is used. Together with the tunnel check (so not with the screen off in the Battery profile, and not with the checks off), at most once a minute, the server in use is asked for `example.com` through the tunnel; any DNS answer counts. No reply twice in a row: the next server of the line is used (the log says so, `dns_server=` shows it), after the last one the first again. A tunnel that is loaded again starts with the first server. Needs the root manager's busybox (`nslookup`, `timeout`). Of the IPv6 servers only the first is used
- **The exit address** (Dashboard **Check**, `ctl.sh exitip`) is asked over HTTPS with Android's `/system/bin/curl`, certificate checked: `ipinfo.io/json`, then `ipwho.is`. Only without `curl` or when both fail it is asked over plain HTTP as before (`ip-api.com`, then `ipinfo.io`); the output key `proto=https|http` says which it was (`via=` is the tunnel's interface when the request went through the tunnel, as before)
- **DNS already under way when the DNS redirect changes** - when the tunnel's DNS is turned on or off or changes, a DNS flow that already exists keeps its old address translation until the kernel forgets it (UDP about 30 s, longer while it keeps getting answers). Android's resolver uses a new port for every query, so new lookups follow at once. Android has no tool to clear only those kernel entries (no `conntrack` in toybox or busybox), so WG Shield does not try
- **Same LAN on both sides** - addresses of your own Wi-Fi network always stay local; a home VPN that uses the same range (both `192.168.1.x`) cannot reach its devices while you are on that Wi-Fi
- **Need internet now?** Action button (off), or disable the module in the root manager and reboot - nothing of it stays active

---

## Uninstall

Remove the module in your root manager and reboot. The tunnel and every rule are removed, then settings, log and **all imported tunnels with their keys** are deleted. A backup in `/storage/emulated/0/wg-shield/` is kept - delete it in the WebUI before removing the module, or by hand, if you do not want it.

---

## Build `wg` and `awg`

`build.sh` (in this repo) downloads wireguard-tools v1.0.20260223 and amneziawg-tools (pinned to commit `ee0f0a9aa34ff0a0da4b3433b9512781cfe02843`, 3.1.20260812) and builds both as static arm64 binaries with [zig](https://ziglang.org):

```sh
bash build.sh                 # → out/wg and out/awg, copy to system/bin/
ZIG=/path/to/zig bash build.sh
```

The build is reproducible with zig 0.16.0. SHA-256 of the files in the release:

| File | SHA-256 |
|---|---|
| `wg` | `92efd615c43f6668826ee84338a05587b24e5ad5dc3a5586f9312ca825b827da` |
| `awg` | `db3c9a3e384e8bf779fd72408db59b7e061ce214f570438f0e6a87f9fa559a04` |

---

## License

The module (scripts, WebUI) is [MIT](LICENSE). `system/bin/wg` (wireguard-tools) and `system/bin/awg` (amneziawg-tools) are GPL-2.0 - see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

"WireGuard" and the "WireGuard" logo are registered trademarks of Jason A. Donenfeld. WG Shield is not affiliated with or endorsed by the WireGuard or AmneziaWG projects.
