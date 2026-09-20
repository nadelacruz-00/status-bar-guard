#!/system/bin/sh
# Status Bar Guard daemon v2.2
# Applies statusbar disable-flags based on the foreground app.
#   FULL  = shade blocked + bar blanked (a picked app is foreground)
#   SHADE = shade blocked only (MODE=global)
#   NONE  = everything restored
CFG=/data/adb/statusbarguard/config
APPS=/data/adb/statusbarguard/apps.conf
LOG=/data/adb/statusbarguard/statusbarguard.log
PIDF=/data/adb/statusbarguard/daemon.pid

log(){ echo "$(date '+%m-%d %H:%M:%S') $1" >> "$LOG"; }

# --- single-instance guard: kill any older copy of this script ---
if [ -f "$PIDF" ]; then
  OLDPID=$(cat "$PIDF" 2>/dev/null)
  if [ -n "$OLDPID" ] && [ "$OLDPID" != "$$" ] && [ -d "/proc/$OLDPID" ]; then
    CMD=$(tr '\0' ' ' < "/proc/$OLDPID/cmdline" 2>/dev/null)
    case "$CMD" in
      *statusbarguard/daemon.sh*)
        kill "$OLDPID" 2>/dev/null && log "killed stale daemon pid=$OLDPID";;
    esac
  fi
fi
echo $$ > "$PIDF"

FULL=statusbar-expansion\ system-icons\ clock\ notification-icons
SHADE=statusbar-expansion
state=9
log "daemon v2.2 start (pid $$)"

while true; do
  MODE=auto
  [ -f "$CFG" ] && . "$CFG"

  want=NONE
  if [ "$MODE" = global ]; then
    want=SHADE
  elif [ "$MODE" = auto ]; then
    # exact package match: extract the package token from mCurrentFocus
    fg=$(dumpsys window 2>/dev/null | grep -m1 mCurrentFocus \
         | sed -n 's/.*u0 \([A-Za-z0-9._]*\)\/.*/\1/p')
    if [ -n "$fg" ] && [ -f "$APPS" ]; then
      while IFS= read -r pkg; do
        pkg=$(echo "$pkg" | sed 's/#.*//;s/[[:space:]]//g')
        [ -z "$pkg" ] && continue
        if [ "$fg" = "$pkg" ]; then want=FULL; break; fi
      done < "$APPS"
    fi
  fi

  if [ "$want" != "$state" ]; then
    case "$want" in
      FULL)  if cmd statusbar send-disable-flag $FULL >/dev/null 2>&1; then state=FULL;  log "picked app fg ($fg) -> bar blanked + shade blocked"; fi;;
      SHADE) if cmd statusbar send-disable-flag $SHADE >/dev/null 2>&1; then state=SHADE; log "global mode -> shade blocked"; fi;;
      NONE)  if cmd statusbar send-disable-flag none >/dev/null 2>&1;  then state=NONE;  log "restored (no picked app fg)"; fi;;
    esac
  fi
  sleep 2
done