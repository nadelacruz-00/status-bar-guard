#!/system/bin/sh
CFG=/data/adb/statusbarguard/config
APPS=/data/adb/statusbarguard/apps.conf
LOG=/data/adb/statusbarguard/statusbarguard.log
log(){ echo "$(date '+%m-%d %H:%M:%S') $1" >> "$LOG"; }
FULL=statusbar-expansion\ system-icons\ clock\ notification-icons
SHADE=statusbar-expansion
state=9
log "daemon start (statusbarguard)"
while true; do
  MODE=auto
  [ -f "$CFG" ] && . "$CFG"
  want=NONE
  if [ "$MODE" = global ]; then want=SHADE
  elif [ "$MODE" = auto ]; then
    fg=$(dumpsys window 2>/dev/null | grep -m1 mCurrentFocus)
    if [ -f "$APPS" ]; then
      while IFS= read -r pkg; do
        pkg=$(echo "$pkg" | sed 's/#.*//;s/[[:space:]]//g')
        [ -z "$pkg" ] && continue
        case "$fg" in *"$pkg"*) want=FULL; break;; esac
      done < "$APPS"
    fi
  fi
  if [ "$want" != "$state" ]; then
    case "$want" in
      FULL)  if cmd statusbar send-disable-flag $FULL >/dev/null 2>&1; then state=FULL; log "picked app fg -> bar blanked + shade blocked"; fi;;
      SHADE) if cmd statusbar send-disable-flag $SHADE >/dev/null 2>&1; then state=SHADE; log "global mode -> shade blocked"; fi;;
      NONE)  if cmd statusbar send-disable-flag none >/dev/null 2>&1; then state=NONE; log "restored (no picked app fg)"; fi;;
    esac
  fi
  sleep 2
done
