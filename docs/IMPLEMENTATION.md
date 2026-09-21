# Implementation notes

Deep-dive material for contributors. The README keeps only the essentials.

---

## KernelSU WebUI bridge

The bridge differs between hosts, so `app.js` auto-detects the available shape.

| Host | API shape |
|---|---|
| **KsuWebUI** (`io.github.a13e300.ksuwebui`) | `ksu.exec(cmd)` returns **stdout synchronously as a string**. Passing a callback **throws a Java exception**. |
| **KernelSU manager** | `ksu.exec(cmd, {}, callback(errno, stdout, stderr))` |

Two further quirks worth knowing:

- **Multi-line output is unreliable** through the bridge — only the last line survived in testing. Shell commands therefore end with `tr "\n" "\001"` and JavaScript splits on `\u0001`.
- **`ksu.moduleInfo()` returns the *module* directory** (`/data/adb/modules/<id>`), not the data directory. The UI probes for `daemon.sh` and switches to `/data/adb/<id>` when it finds it there instead.

### Trust but verify

Because the bridge can fail silently, **Save & apply** writes `apps.conf` and then reads it back, comparing the result against what the UI holds. A mismatch raises a visible banner showing both lists. This was added after a real incident: a save wrote the header with *literal* `\n` text instead of real newlines, leaving the app list silently empty while the UI looked correct.

### External assets do not load

The WebView does not load sibling files from `webroot/`, so `build.py` inlines CSS, JS and metadata into a single self-contained `index.html`. A page split across `app.css` / `app.js` simply renders nothing.

### CSS gotcha

A rule such as `.boot{display:grid}` **overrides the `hidden` attribute**, so the loading screen never disappears. The stylesheet therefore begins with:

```css
[hidden]{display:none !important}
```

---

## Pull-to-refresh

Implemented to match Material's *swipe to refresh*:

- A faint **track circle** with a coloured **arc** on top (`stroke-dasharray` / `stroke-dashoffset`), using the **real circumference** (`2πr`) rather than the `pathLength` attribute — `pathLength` collapsed the arc into two blobs in this WebView.
- The arc **grows** with pull distance and **creeps** around the track.
- The indicator **descends and scales** with the pull (Material geometry), turning **green** once past the threshold.
- Releasing past the threshold triggers the refresh; the arc then animates its dash *and* the ring rotates — the classic indeterminate sweep.
- Motion is smoothed with **`requestAnimationFrame` exponential interpolation**, so it feels weighted rather than snapping to the finger.
- The gesture is claimed with a **non-passive `touchmove` + `preventDefault()`** once a genuine pull is detected at `scrollTop <= 0`. Normal scrolling is untouched.

**Gotcha:** a CSS animation replaces the entire `transform` property, so positioning the spinner and animating its rotation *on the same element* cancels one of them out. The fix is two layers: an outer element that JS positions, and an inner element that CSS animates.

---

## Icon and label pipeline — **retired in v2.3**

> **No longer used by the WebUI.** Since v2.3 the app list shows package names
> only and derives the user/system split from `pm list packages -3` / `-s` at
> runtime. Nothing in the shipped UI reads `appmeta.js`, so `build.py` no longer
> inlines it and the zip dropped from ~750 KB to ~16 KB. The notes below are
> kept because the extraction problems are subtle and worth not re-discovering
> if icons are ever brought back. `tools/gen_meta.py` and the package dump in
> `refresh-dump.sh` still work, they are simply not on the WebUI's path.

`appmeta.js` is **generated, never committed** — it contains the device's installed app list and icons, which is private data. It is listed in `.gitignore`.

Resolution order, most accurate first:

1. **ARSC resolution** — read `android:icon` from the manifest and resolve it through the resource table. This yields the *same file the launcher renders*, including obfuscated names like `res/bfc.png`.
2. **Adaptive icons** — for `mipmap-anydpi-v26` XML icons, resolve the background (colour *or* raster) and foreground layers, composite them on a 108 dp canvas, then crop to the visible 72/108 dp area exactly as the launcher does.
3. **`androguard`'s resolver**
4. **Zip scan** of `res/mipmap*` / `res/drawable*`
5. **Letter avatar** — deterministic HSL colour, for apps whose icons are vector-only

> **Use `androguard`, not `pyaxmlparser`.** The latter resolves resource-based labels incorrectly — it reported *"Android Music"* for Apple Music, while `androguard` correctly returns *"Apple Music"*. It also handles localised labels (`cn.com.omnimind.bot` → 小万).

**Limitation:** icons are not themed. They are rendered the way the launcher renders its *default* icon set; launcher-side icon theming (themed/monochrome icons) is internal to the launcher and would require hooking it.

---

## Why the flags work (and what does not)

| Attempt | Result |
|---|---|
| `policy_control immersive.full=*` | Only toggles *visual* UI flags and does not unhook the shade gesture. On OxygenOS 16 the parser is **gone** — silently ignored. |
| `cmd statusbar send-disable-flag expansion …` | `expansion` **is not a valid token**. The command fails silently, which makes it look like a vendor override. The correct token is `statusbar-expansion`. |
| `appops set … MOUSE_POINTER_CAPTURE allow` | No such AppOps gate; pointer capture needs no permission. |
| Shrinking the X11 canvas (e.g. `3392x2380`) | The Android hardware cursor is not bounded by an app's canvas — it still reaches physical `y=0`. |
| Game Assistant / Game Space | Modern builds removed "add non-game apps"; `pm set-app-category` does not exist in AOSP. |

The working mechanism is the correct AOSP flag plus a daemon that applies it contextually:

| Goal | Mechanism |
|---|---|
| Block the shade (mouse *or* finger) | `cmd statusbar send-disable-flag statusbar-expansion` → AOSP `DISABLE_EXPAND` |
| Blank the bar contents | `cmd statusbar send-disable-flag system-icons clock notification-icons` |

`send-disable-flag` is global and **transient** (cleared whenever SystemUI restarts), which is exactly why a polling daemon is needed to re-assert it.

### The state cache is not enough (fixed in v2.4)

Polling alone does **not** re-assert. The daemon keeps the applied state in a
shell variable and sends a flag only when `want != state`:

```sh
if [ "$want" != "$state" ]; then ... state="$want"; fi
```

The device can be reset to `0x0` by something the daemon cannot observe — most
commonly a SystemUI restart (reboot, crash, theme/DPI change, an ANR kill). The
cache still says `SHADE`/`FULL`, so `want == state` and the daemon **never
sends the flag again**. Protection is silently off until the foreground app
changes. Verified on device: with `MODE=global` and the daemon alive, clearing
the flags by hand left them at `0x0` indefinitely.

v2.4 closes this two ways:

| Guard | Mechanism | Latency |
|---|---|---|
| **SystemUI watchdog** | compare `pidof com.android.systemui` each cycle; a change resets `state=9` | one poll |
| **Heartbeat** | while a flag set is active, re-send it every `HEARTBEAT=15` cycles (≈30 s) | ≤30 s |

The heartbeat also repairs clears from *any* other source, not just SystemUI.
It is deliberately silent (no log line) so the activity log stays readable, and
the beat counter resets on every successful apply so it cannot fight a
legitimate state change.

### Latency: why we tune the interval instead of using `am monitor` (v2.5)

v2.5 is a latency release, and the obvious design — drive the daemon from
`am monitor`'s activity event stream instead of polling — was prototyped on the
device and **rejected on evidence**. The findings are worth keeping:

**1. The query is already cheap, so there is no CPU win to chase.**
`dumpsys window | grep -m1 mCurrentFocus | sed -n …` costs **≈13 ms**, because
`grep -m1` exits after the first match, the pipe closes, and `dumpsys` dies on
SIGPIPE instead of finishing a full window dump. At a 2 s interval that is
**~0.65 % of one core**. Measured total daemon cost (self + waited-for children,
read from `/proc/<pid>/stat`): **0.53 %** of one core at 2 s. A single-process
rewrite (`dumpsys | sed -n '/mCurrentFocus/{…;q;}'`) was *slower* — 14.2 ms vs
13.4 ms per call — because `sed` reads the whole stream. So the parse stays.

**2. `am monitor` is a trigger, not an authoritative source.**
It streams `** Activity starting: <pkg>` / `** Activity resuming: <pkg>` live
(verified unbuffered). But those are *activity* events, not focus: launching
Settings emitted `Activity starting: com.android.settings` followed by
`Activity resuming: com.google.android.permissioncontroller`, and the real
`mCurrentFocus` was the permissioncontroller Safety Center window. So any
event-driven design still has to confirm with `dumpsys`.

**3. The mksh plumbing does not hold up.** All of these were tested on the
device (`/system/bin/sh` is mksh):

| Pattern | Result |
|---|---|
| `read -u 9` | unsupported — hangs, or errors `read: read-only: 9` |
| `read -t 1 line <&9` on a regular file | works |
| `read -t 1 line <&9` on a FIFO | timeout and EOF are **indistinguishable** (`rc=1` both) |
| `exec 8<> ctl.fifo` to hold `am monitor`'s stdin open | **`am monitor` dies**: `Failure calling service activity: Failed transaction (2147483646)` |
| `sleep N \| am monitor \| while read` | mksh **waits for every pipeline member** — verified `sleep 20 \| sh -c 'exit 0'` took 20 s, so the daemon wedges when the monitor dies |
| `tail -f /dev/null \| am monitor` | works, but the holder never exits, so the same wedge applies on restart |

The only stdin holder that keeps `am monitor` alive is a pipe from another
process, and that is exactly the case mksh refuses to tear down early. Making
that robust needs pid-hunting and `pkill` heuristics — too much fragility for a
module that has to survive on a daily driver.

**4. What shipped instead.** `POLL` is configurable and defaults to **0.5 s**.
Measured end-to-end reaction (protected app foreground → HOME → restore,
3 runs each):

| `POLL` | reaction |
|---|---|
| 2 s (old default) | 1087 / 941 / 942 ms |
| 0.5 s (new default) | 658 / 688 / 181 ms |

(The floor is the measurement harness, not the daemon.) CPU rises from ~0.53 %
to ~1.7 % of one core — a fair trade for 4× lower worst-case latency.
`HEARTBEAT_SECS` is now expressed in seconds and converted to ticks with `awk`,
so it stays 30 s whatever `POLL` is set to.

### CPU: the daemon forks nothing (v2.6.1)

The daemon used to spend almost all of its CPU on `fork()`, not on work. Measured
on the Pad 3: **one process spawn costs ~13–17 ms of CPU**, so a loop that spawns
9 processes per cycle is expensive no matter how trivial each one is.

Measured cost, same device, same 0.5 s poll, all via `utime+stime+cutime+cstime`
from `/proc/<pid>/stat`:

| Version | What changed | CPU (one core) |
|---|---|---|
| v2.5 | 9 spawns/cycle: `dumpsys`, `grep`, `sed`, `pidof`, 2× (`echo`+`sed`) for apps.conf, `sleep` | **13.5 %** |
| v2.5.1 | parse with parameter expansion (no `sed`/`echo`), throttle `pidof` — but still forks `sleep` | 10.8 % |
| v2.5.2 | builtin `read -t` against a held-open FIFO replaces the `sleep` fork | 7.0 % |
| v2.6 | read a growing logcat log with builtins each cycle | 3.9 % |
| **v2.6.1** | feed keeps a **one-line** `focus.now`; a cycle is a single builtin `read` | **0.68 %** |

Two discoveries made this possible:

**1. `sleep` costs more than the query.** `sleep 0.5` forks `/system/bin/sleep`:
**17 ms** of CPU. The query was only 13 ms. A FIFO held open read-write
(`exec 9<> fifo`) never EOFs, so the shell builtin `read -t 0.5 <&9` is an exact
timer costing **1 ms**. (`read -u 9` is unsupported in this mksh; `<&9` works.)

**2. There is a real focus event log.** `am_focused_activity` does *not* exist on
OxygenOS 16, but the `input_focus` tag does, and it carries the package:

```
I input_focus: [Focus entering <hash> <pkg>/<activity>,reason=Window became focusable...]
```

`logcat -b events -s input_focus` blocks on the log socket — measured **0 CPU
over 20 s** — and streams live. A background pipeline writes just the package to
`focus.now`:

```sh
{ logcat -b events -s input_focus </dev/null 2>/dev/null | while IFS= read -r l; do
    case "$l" in
      *"Focus entering "*) t=${l#*Focus entering }; t=${t#* }
        case "$t" in */*) printf '%s\n' "${t%%/*}" > "$FOCUSNOW" ;; esac;;
    esac
  done; } >/dev/null 2>&1 &
```

The consumer exits when logcat does, so this pipeline cannot wedge (unlike
`sleep N | …`, which mksh waits for forever). The daemon then does one builtin
`read -r fg < "$FOCUSNOW"` per cycle.

**Safety net.** Every `RESYNC_SECS` (default 30), or whenever the feed yields
nothing, the daemon falls back to the authoritative
`dumpsys window | grep -m1 mCurrentFocus` query. If the feed dies it is detected
with the builtin `kill -0` and restarted; if it cannot be started at all, the
daemon degrades to exactly v2.5.2 behaviour.

**Why not simply poll faster?** Because the old cost scaled with the cycle rate.
Now that a cycle is nearly free, `POLL` can be lowered for better latency at
little cost — 0.5 s remains the default because it is already imperceptible.

### Matching the foreground app

The daemon extracts the package token from `mCurrentFocus` and compares it **exactly**:

```sh
fg=$(dumpsys window | grep -m1 mCurrentFocus | sed -n 's/.*u0 \([A-Za-z0-9._]*\)\/.*/\1/p')
```

An earlier version used a shell `case` substring match (`case "$fg" in *"$pkg"*`), which is unsafe: an entry like `com.termux` would also match `com.termux.x11` and any window whose title happened to embed the string. Exact comparison removes that class of bug.

### Single-instance guard

The daemon writes `daemon.pid` and, on start, kills any stale instance whose `/proc/<pid>/cmdline` still points at the script. Without it, two copies can fight over the flag state.

---

## Environment constraints (development notes)

These are specific to the Android/Alpine setup this project was developed in, but they explain some choices in the scripts.

- `/sdcard` is a **FUSE mount** that proot cannot write to; deliver files via a root shell instead.
- The workspace filesystem stores git objects in a hidden overlay layer: git reads and writes them fine, but any other tool (`cp`, `tar`) gets *Operation not permitted*. A `.git` directory therefore **cannot be copied out** — ship a working tree, or a `git bundle` (single file), and let the user `git init`/`git clone` on the target.
- `input swipe` is too coarse for gesture testing; use `input draganddrop x1 y1 x2 y2 <duration>` in the background so a screenshot can be taken mid-gesture.
- The display sleeps during long sessions and `screencap` then returns a fully **black** PNG. Wake first with `input keyevent KEYCODE_WAKEUP`.

---

## Repository layout

```
status-bar-guard/
├── module/                     # KernelSU module payload (deployed to /data/adb)
│   ├── module.prop             # module metadata (version lives here)
│   ├── customize.sh            # installer: preserves user config, stops old daemon
│   ├── service.sh              # boot hook — starts the daemon
│   ├── uninstall.sh            # restores the shade, removes config
│   ├── daemon.sh               # the foreground-watching loop
│   ├── refresh-dump.sh         # dumps installed packages (legacy: fed gen_meta.py)
│   ├── config.example          # MODE=auto|global|off
│   ├── apps.conf.example       # one package name per line
│   └── META-INF/com/google/android/
│       ├── update-binary       # installer stub (Magisk + KernelSU)
│       └── updater-script      # contains the #MAGISK marker
├── webui/                      # WebUI sources
│   ├── index.html              # markup (assets are inlined at build time)
│   ├── app.css                 # styles
│   ├── app.js                  # logic: bridge, app list, pull-to-refresh
│   └── build.py                # inlines CSS/JS → dist/index.html
├── tools/
│   └── gen_meta.py             # legacy: generated appmeta.js (labels + icons); unused since v2.3
├── .github/workflows/
│   └── release.yml             # builds the flashable zip on every push
├── build_zip.sh                # assembles the flashable module zip
├── docs/                       # screenshots + these notes
├── README.md
├── LICENSE
└── .gitignore
```
