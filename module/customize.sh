#!/system/bin/sh
# Status Bar Guard — installer logic.
# Sourced by the KernelSU / KernelSU Next / Magisk installer AFTER the module
# files have been extracted into $MODPATH, so everything here is a post-step.
#
# Guarantees:
#   * the running daemon is stopped before its script is replaced
#   * runtime scripts in /data/adb/statusbarguard are always refreshed
#   * the user's live apps.conf / config are NEVER overwritten

# ui_print exists in both installers; provide a fallback for plain-shell runs.
type ui_print >/dev/null 2>&1 || ui_print() { echo "$1"; }

[ -n "$MODPATH" ] || MODPATH=/data/adb/modules/statusbarguard
DATA=/data/adb/statusbarguard

ui_print " "
ui_print "*******************************"
ui_print "  Status Bar Guard  v2.6.1"
ui_print "*******************************"
ui_print " "

# --- stop a running daemon so it does not fight the file replacement ---
if [ -f "$DATA/daemon.pid" ]; then
  kill "$(cat "$DATA/daemon.pid" 2>/dev/null)" 2>/dev/null
fi
for p in /proc/[0-9]*; do
  c=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)
  case "$c" in
    *statusbarguard/daemon.sh*) kill "${p#/proc/}" 2>/dev/null ;;
  esac
done
sleep 1

# --- refresh runtime scripts (code: always overwrite) ---
mkdir -p "$DATA"
cp -f "$MODPATH/daemon.sh"       "$DATA/daemon.sh"
cp -f "$MODPATH/refresh-dump.sh" "$DATA/refresh-dump.sh"
chmod 0755 "$DATA/daemon.sh" "$DATA/refresh-dump.sh"
ui_print "- runtime scripts updated"

# --- user config (data: seed only when absent) ---
if [ -f "$DATA/apps.conf" ]; then
  ui_print "- keeping your existing apps.conf"
else
  cp -f "$MODPATH/apps.conf.example" "$DATA/apps.conf"
  ui_print "- installed apps.conf.example"
fi
if [ -f "$DATA/config" ]; then
  ui_print "- keeping your existing config"
else
  cp -f "$MODPATH/config.example" "$DATA/config"
  ui_print "- installed config.example (MODE=auto)"
fi

# --- the zip ships webroot/index.html; make sure it is readable ---
[ -f "$MODPATH/webroot/index.html" ] && chmod 0644 "$MODPATH/webroot/index.html"

# --- start now; service.sh will start it again on boot ---
( sh "$DATA/daemon.sh" ) &
sleep 1
if [ -f "$DATA/daemon.pid" ]; then
  ui_print "- daemon running (pid $(cat "$DATA/daemon.pid"))"
else
  ui_print "- daemon starting (it will report its pid shortly)"
fi
ui_print " "
ui_print "- Open the WebUI to pick apps."
ui_print "- Log: $DATA/statusbarguard.log"
ui_print " "
