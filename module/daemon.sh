#!/system/bin/sh
# Status Bar Guard daemon v2.6.1
# Applies statusbar disable-flags based on the foreground app.
#   FULL  = shade blocked + bar blanked (a picked app is foreground)
#   SHADE = shade blocked only (MODE=global)
#   NONE  = everything restored
#
# v2.6.1 removes the last hot cost. Profiling on this device showed a process
# spawn costs ~13-17 ms of CPU, so every earlier version burned CPU on forking:
#
#   v2.5   9 spawns/cycle (dumpsys, grep, sed, pidof, 2x echo|sed, sleep)   13.5%
#   v2.5.1 parse via parameter expansion, throttle pidof, still forks sleep   10.8%
#   v2.5.2 builtin `read -t` on a held-open FIFO replaces the sleep fork       7.0%
#   v2.6   read a growing logcat log with builtins each cycle                  3.9%
#   v2.6.1 feed maintains a ONE-LINE "current focus" file; a cycle is a single
#          builtin `read`                                                    <0.5%
#
# How it works: a background pipeline tails the `input_focus` event tag, which
# logs the real input focus WITH the package name --
#   I input_focus: [Focus entering <hash> <pkg>/<activity>,reason=...]
# -- and writes just the package to focus.now. `logcat` blocks on the log socket
# (measured 0 CPU over 20 s), and the pipeline's consumer exits when logcat does,
# so nothing wedges. The daemon then reads focus.now with one builtin `read`.
# A dumpsys query still runs every RESYNC_SECS as an authoritative cross-check,
# and takes over completely if the feed is unavailable.
CFG=/data/adb/statusbarguard/config
APPS=/data/adb/statusbarguard/apps.conf
LOG=/data/adb/statusbarguard/statusbarguard.log
PIDF=/data/adb/statusbarguard/daemon.pid
TIMER=/data/adb/statusbarguard/daemon.fifo
FOCUSNOW=/data/adb/statusbarguard/focus.now
FEEDPIDF=/data/adb/statusbarguard/feed.pid

# Defaults; all are overridable from $CFG.
POLL=0.5              # seconds between checks
HEARTBEAT_SECS=30     # re-assert an ACTIVE flag set at least this often
SUI_CHECK_SECS=10     # how often to look for a SystemUI restart
RESYNC_SECS=30        # how often to cross-check with dumpsys

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

# --- builtin timer: a FIFO held open read-write never EOFs, so `read -t` on it
#     is a pure shell sleep with no fork. ---
TIMER_OK=0
rm -f "$TIMER" 2>/dev/null
if mkfifo "$TIMER" 2>/dev/null; then
  if exec 9<> "$TIMER" 2>/dev/null; then TIMER_OK=1; fi
fi

# --- background focus feed: logcat -> one-line focus.now ---
FEED_OK=0
start_feed() {
  if [ -f "$FEEDPIDF" ]; then
    read -r p < "$FEEDPIDF" 2>/dev/null
    [ -n "$p" ] && kill "$p" 2>/dev/null
  fi
  rm -f "$FOCUSNOW" 2>/dev/null
  : > "$FOCUSNOW" 2>/dev/null
  { logcat -b events -s input_focus </dev/null 2>/dev/null | while IFS= read -r l; do
      case "$l" in
        *"Focus entering "*)
          t=${l#*Focus entering }     # "<hash> <pkg>/<activity>,reason=..."
          t=${t#* }                   # drop the window hash
          case "$t" in
            */*) printf '%s\n' "${t%%/*}" > "$FOCUSNOW" ;;
          esac;;
      esac
    done; } >/dev/null 2>&1 &
  echo $! > "$FEEDPIDF"
}
feed_alive() {
  [ -f "$FEEDPIDF" ] || return 1
  read -r p < "$FEEDPIDF" 2>/dev/null
  [ -n "$p" ] || return 1
  kill -0 "$p" 2>/dev/null
}
focus_query() {   # authoritative, forks (dumpsys + grep)
  fq_line=$(dumpsys window 2>/dev/null | grep -m1 mCurrentFocus)
  case "$fq_line" in
    *"u0 "*)
      fq_line=${fq_line##*u0 }    # ## = greedy, matching the old sed's ".*u0 "
      case "$fq_line" in
        */*) printf '%s' "${fq_line%%/*}" ;;
      esac;;
  esac
}

trap 'exec 9<&- 2>/dev/null; rm -f "$TIMER" 2>/dev/null
      if [ -f "$FEEDPIDF" ]; then read -r p < "$FEEDPIDF"; [ -n "$p" ] && kill "$p" 2>/dev/null; fi' \
      EXIT INT TERM HUP

start_feed
sleep 1
feed_alive && FEED_OK=1

FULL=statusbar-expansion\ system-icons\ clock\ notification-icons
SHADE=statusbar-expansion
state=9
beats=0
cyc=0
rcyc=0
last_poll=""
last_hb=""
last_sui=""
last_resync=""
HB_TICKS=60
SUI_EVERY=20
RESYNC_EVERY=60
last_fg=$(focus_query)
sui=$(pidof com.android.systemui 2>/dev/null)
log "daemon v2.6.1 start (pid $$) timer=$TIMER_OK feed=$FEED_OK initial_fg=${last_fg:-none}"

while true; do
  # --- config is re-read every cycle so MODE / POLL apply without a restart ---
  MODE=auto
  [ -f "$CFG" ] && . "$CFG"
  [ -z "$POLL" ] && POLL=0.5
  [ -z "$HEARTBEAT_SECS" ] && HEARTBEAT_SECS=30
  [ -z "$SUI_CHECK_SECS" ] && SUI_CHECK_SECS=10
  [ -z "$RESYNC_SECS" ] && RESYNC_SECS=30
  if [ "$POLL|$HEARTBEAT_SECS|$SUI_CHECK_SECS|$RESYNC_SECS" != "$last_poll|$last_hb|$last_sui|$last_resync" ]; then
    # Convert seconds to tick counts once per config change, not per cycle.
    HB_TICKS=$(awk -v h="$HEARTBEAT_SECS" -v p="$POLL" \
      'BEGIN{ t=int(h/p); if(t<1) t=1; print t }')
    SUI_EVERY=$(awk -v s="$SUI_CHECK_SECS" -v p="$POLL" \
      'BEGIN{ t=int(s/p); if(t<1) t=1; print t }')
    RESYNC_EVERY=$(awk -v s="$RESYNC_SECS" -v p="$POLL" \
      'BEGIN{ t=int(s/p); if(t<1) t=1; print t }')
    last_poll="$POLL"; last_hb="$HEARTBEAT_SECS"
    last_sui="$SUI_CHECK_SECS"; last_resync="$RESYNC_SECS"
    log "poll ${POLL}s, heartbeat ${HEARTBEAT_SECS}s (${HB_TICKS} ticks), sui ${SUI_CHECK_SECS}s, resync ${RESYNC_SECS}s"
  fi

  # --- keep the feed alive (kill -0 is a builtin, so this is free) ---
  if [ "$FEED_OK" = 1 ]; then
    feed_alive || { FEED_OK=0; log "focus feed died -> restarting"; }
  fi
  if [ "$FEED_OK" = 0 ]; then
    start_feed
    sleep 1
    if feed_alive; then FEED_OK=1; log "focus feed started"; fi
  fi

  # --- SystemUI watchdog: a restart wipes every disable-flag ---
  cyc=$((cyc + 1))
  if [ "$cyc" -ge "$SUI_EVERY" ]; then
    cyc=0
    nowsui=$(pidof com.android.systemui 2>/dev/null)
    if [ "$nowsui" != "$sui" ]; then
      sui="$nowsui"
      state=9
      beats=0
      log "systemui restarted (pid ${nowsui:-none}) -> re-asserting"
    fi
  fi

  want=NONE
  if [ "$MODE" = global ]; then
    want=SHADE
  elif [ "$MODE" = auto ]; then
    # --- foreground package: one builtin read, no fork ---
    fg=""
    if [ "$FEED_OK" = 1 ] && [ -f "$FOCUSNOW" ]; then
      read -r fg < "$FOCUSNOW" 2>/dev/null
    fi

    # Safety net: on the RESYNC schedule, or whenever the feed gave us nothing
    # (startup, or a broken feed), use the authoritative dumpsys query.
    rcyc=$((rcyc + 1))
    if [ -z "$fg" ] || [ "$rcyc" -ge "$RESYNC_EVERY" ]; then
      rcyc=0
      fg=$(focus_query)
    fi
    [ -z "$fg" ] && fg="$last_fg"
    last_fg="$fg"

    if [ -n "$fg" ] && [ -f "$APPS" ]; then
      while IFS= read -r pkg; do
        case "$pkg" in ''|'#'*) continue ;; esac   # skip blank / comment lines
        pkg=${pkg%%#*}                             # trailing comment
        pkg=${pkg//[[:space:]]/}                   # any stray whitespace
        [ -z "$pkg" ] && continue
        if [ "$fg" = "$pkg" ]; then want=FULL; break; fi
      done < "$APPS"
    fi
  fi

  # Re-assert when the desired state changed, or periodically while a flag set
  # is active so a silent clear (SystemUI restart, another tool, a vendor
  # override) is repaired within HEARTBEAT_SECS.
  beats=$((beats + 1))
  reason=""
  if [ "$want" != "$state" ]; then
    reason=change
  elif [ "$want" != NONE ] && [ "$beats" -ge "$HB_TICKS" ]; then
    reason=heartbeat
  fi

  if [ -n "$reason" ]; then
    case "$want" in
      FULL)
        if cmd statusbar send-disable-flag $FULL >/dev/null 2>&1; then
          state=FULL; beats=0
          [ "$reason" = change ] && log "picked app fg ($fg) -> bar blanked + shade blocked"
        fi;;
      SHADE)
        if cmd statusbar send-disable-flag $SHADE >/dev/null 2>&1; then
          state=SHADE; beats=0
          [ "$reason" = change ] && log "global mode -> shade blocked"
        fi;;
      NONE)
        if cmd statusbar send-disable-flag none >/dev/null 2>&1; then
          state=NONE; beats=0
          [ "$reason" = change ] && log "restored (no picked app fg)"
        fi;;
    esac
  fi

  # --- wait: builtin when the timer fifo is available, fork otherwise ---
  if [ "$TIMER_OK" = 1 ]; then
    read -r -t "$POLL" _ <&9
    rc=$?
    if [ "$rc" -ne 142 ] && [ "$rc" -ne 0 ]; then
      sleep "$POLL"          # timer fd lost its writer -> fall back to a fork
    fi
  else
    sleep "$POLL"
  fi
done