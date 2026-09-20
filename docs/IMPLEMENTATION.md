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
