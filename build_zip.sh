#!/usr/bin/env bash
#
# Build a flashable KernelSU / KernelSU Next / Magisk module zip.
#
#   ./build_zip.sh            # build dist/status-bar-guard-<version>-<sha>.zip
#
# The zip layout is the module directory itself, plus META-INF and a prebuilt
# single-file WebUI:
#
#   status-bar-guard-v<version>-<sha>.zip
#   ├── META-INF/com/google/android/update-binary
#   ├── META-INF/com/google/android/updater-script
#   ├── module.prop
#   ├── customize.sh
#   ├── service.sh, uninstall.sh
#   ├── daemon.sh, refresh-dump.sh
#   ├── config.example, apps.conf.example
#   └── webroot/index.html
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

PY="${PYTHON:-python3}"
command -v "$PY" >/dev/null 2>&1 || PY=python

VER="$(sed -n 's/^version=//p' module/module.prop | head -1)"
[ -n "$VER" ] || { echo "! could not read version= from module/module.prop" >&2; exit 1; }
SHA="$(git rev-parse --short HEAD 2>/dev/null || echo nogit)"
NAME="status-bar-guard-${VER}-${SHA}"
OUT="$ROOT/dist/${NAME}.zip"

echo "==> building $NAME"

# ── 1. single-file WebUI ────────────────────────────────────────────────────
# appmeta.js is generated from a real device and is gitignored; CI (and a fresh
# clone) has no such file. Stub it so the build still produces a working UI —
# the app list falls back to prettified package names + letter avatars, and
# users regenerate the real metadata on-device via pull-to-refresh.
if [ ! -f webui/appmeta.js ]; then
  echo "    webui/appmeta.js missing -> stubbing empty APP_META"
  printf 'window.APP_META = {};\n' > webui/appmeta.js
fi
"$PY" webui/build.py

# ── 2. stage the module tree ────────────────────────────────────────────────
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R module/. "$STAGE/"
rm -rf "$STAGE/webroot"          # module/ has none, but never ship a stale one

mkdir -p "$STAGE/META-INF/com/google/android"
cp installer/META-INF/com/google/android/update-binary "$STAGE/META-INF/com/google/android/"
cp installer/META-INF/com/google/android/updater-script "$STAGE/META-INF/com/google/android/"

mkdir -p "$STAGE/webroot"
cp webui/dist/index.html "$STAGE/webroot/index.html"

for f in module.prop customize.sh service.sh uninstall.sh daemon.sh refresh-dump.sh; do
  [ -f "$STAGE/$f" ] || { echo "! missing $f in the staged module" >&2; exit 1; }
done

# ── 3. zip it (python, so no external zip dependency and exact modes) ───────
mkdir -p "$ROOT/dist"
STAGE="$STAGE" OUT="$OUT" "$PY" - <<'PY'
import os, stat, zipfile

stage = os.environ["STAGE"]
out = os.environ["OUT"]

EXEC = {
    "META-INF/com/google/android/update-binary",
    "customize.sh", "service.sh", "uninstall.sh",
    "daemon.sh", "refresh-dump.sh",
}

entries = []
for dirpath, dirnames, filenames in os.walk(stage):
    dirnames.sort()
    for fn in sorted(filenames):
        full = os.path.join(dirpath, fn)
        rel = os.path.relpath(full, stage).replace(os.sep, "/")
        entries.append((rel, full))
entries.sort()

with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for rel, full in entries:
        mode = 0o755 if rel in EXEC else 0o644
        zi = zipfile.ZipInfo(rel, date_time=(1980, 1, 1, 0, 0, 0))
        zi.external_attr = (stat.S_IFREG | mode) << 16
        zi.compress_type = zipfile.ZIP_DEFLATED
        with open(full, "rb") as fh:
            z.writestr(zi, fh.read())

print(f"    {len(entries)} files -> {out}")
for rel, _ in entries:
    print(f"      {rel}")
PY

echo "==> done: dist/${NAME}.zip  ($(du -h "$OUT" | cut -f1))"
