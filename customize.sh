# WG Shield Arm64 - installer (runs in the manager, busybox ash)
SKIPUNZIP=0

ui_print "- WG Shield Arm64"
[ "$ARCH" = arm64 ] || abort "! arm64 only (this device: $ARCH)"

if /system/bin/ip link add wgs-probe type wireguard 2>/dev/null; then
    /system/bin/ip link del wgs-probe 2>/dev/null
    ui_print "- Kernel WireGuard: yes"
else
    abort "! This kernel has no WireGuard support (CONFIG_WIREGUARD) - not installed"
fi

DATA=/data/adb/wg-shield
CONF=/data/adb/wg-shield.conf
mkdir -p "$DATA/tunnels" /data/adb/wg-shield-state
chmod 700 "$DATA" "$DATA/tunnels"
if [ ! -f "$CONF" ]; then
    printf '%s\n' "# WG Shield Arm64 settings - edit with ctl.sh" "ACTIVE=" "LAST=" "KILLSWITCH=1" > "$CONF"
    ui_print "- Settings created (kill switch on)"
else
    ui_print "- Settings and tunnels kept"
fi
chmod 600 "$CONF"

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/system/bin/wg" 0 0 0755
for f in ctl.sh service.sh post-fs-data.sh action.sh uninstall.sh; do
    set_perm "$MODPATH/$f" 0 0 0755
done

n=$(ls "$DATA/tunnels"/*.conf 2>/dev/null | wc -l)
ui_print "- Imported tunnels: $n"
ui_print ""
ui_print "  Import the WireGuard app export (menu > Export tunnels):"
ui_print "  su -c 'sh /data/adb/modules/wg-shield/ctl.sh import /sdcard/Download/<file>.zip'"
ui_print "  Then: ctl.sh list / ctl.sh up <name> / ctl.sh status"
ui_print "  Disconnect the WireGuard app first - one key, one tunnel."
