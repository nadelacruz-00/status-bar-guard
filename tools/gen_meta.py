#!/usr/bin/env python3
"""appmeta.js v5 — icons from the LAUNCHER'S OWN SOURCE (ARSC-resolved).

Per app, icon resolution order:
  1. manifest android:icon -> ARSC resource id -> resolved value
       • raster path            -> use it directly            (exact, same file the launcher loads)
       • adaptive XML           -> byte-scan its resource refs, resolve each layer:
             - '#AARRGGBB' colour  -> background fill
             - raster path         -> background/foreground layer
             (vector-XML layers are skipped: rasterising Android VectorDrawable faithfully
              needs a full AXML+path renderer; those apps keep their legacy raster icon)
           -> composite on a 108dp canvas, crop the visible 72/108 centre  (what the launcher shows)
  2. anydpi-v26 adaptive XML found by filename (same pipeline as 1)
  3. androguard APK.get_app_icon()
  4. zip scan of res/mipmap|drawable
  5. letter avatar (hue stored)

Inputs : pkg_paths_all.tsv, pkgs_system.txt, pkgs_user.txt
Output : appmeta.js -> window.APP_META = {pkg:{label,icon,hue,sys}}, window.APP_META_BUILD
"""
import base64, datetime, hashlib, io, json, os, re, struct, sys, zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
TSV = os.path.join(HERE, 'pkg_paths_all.tsv')
SYS = os.path.join(HERE, 'pkgs_system.txt')
USR = os.path.join(HERE, 'pkgs_user.txt')
OUT = os.path.join(HERE, 'appmeta.js')
SIZE = 80

os.environ.setdefault('LOGURU_LEVEL', 'ERROR')
try:
    from loguru import logger
    logger.remove()
except Exception:
    pass
try:
    from androguard.core.apk import APK
    HAS_AG = True
except Exception:
    HAS_AG = False
from PIL import Image

DENSITY = ['anydpi-v26', 'xxxhdpi', 'xxhdpi', 'xhdpi', 'hdpi', 'mdpi', 'ldpi', 'nodpi']
IMG_RE = re.compile(r'^res/(mipmap|drawable)[^/]*/.*\.(png|webp|jpg)$', re.I)
RASTER_RE = re.compile(r'\.(png|webp|jpg)$', re.I)
ONLY_USER = '--user-only' in sys.argv


# ---------------- basics ----------------
def fallback_label(pkg):
    a = pkg.split('.')
    leaf = '.'.join(a[2:]) if len(a) > 2 else (a[1] if len(a) > 1 else pkg)
    return re.sub(r'[._-]+', ' ', leaf).strip().title()


def rank(name):
    for i, d in enumerate(DENSITY):
        if d in name:
            return i
    return len(DENSITY)


def hue(pkg):
    return int(hashlib.md5(pkg.encode()).hexdigest()[:6], 16) % 360


def load_set(path):
    try:
        with open(path) as f:
            return {l.strip() for l in f if l.strip()}
    except Exception:
        return set()


def read_zip(path, name):
    try:
        with zipfile.ZipFile(path) as zf:
            if name in zf.namelist():
                return zf.read(name)
    except Exception:
        pass
    return None


def encode(im):
    try:
        im = im.convert('RGBA')
        if min(im.size) < 8:
            return None
        buf = io.BytesIO()
        im.resize((SIZE, SIZE), Image.LANCZOS).save(buf, 'PNG', optimize=True)
        return base64.b64encode(buf.getvalue()).decode('ascii')
    except Exception:
        return None


def square(im):
    w, h = im.size
    if w == h:
        return im
    s = min(w, h)
    return im.crop(((w - s) // 2, (h - s) // 2, (w - s) // 2 + s, (h - s) // 2 + s))


def encode_raw(raw, trim=True):
    try:
        im = square(Image.open(io.BytesIO(raw)).convert('RGBA'))
        if min(im.size) < 8:
            return None
        if trim:
            bbox = im.getbbox()
            if bbox and (bbox[2] - bbox[0]) > 8 and (bbox[3] - bbox[1]) > 8:
                im = im.crop(bbox)
        return encode(im)
    except Exception:
        return None


def scan_zip(path):
    try:
        with zipfile.ZipFile(path) as zf:
            names = zf.namelist()
            c = [n for n in names if IMG_RE.match(n) and re.search(r'ic_launcher[_a-z0-9]*\.(png|webp|jpg)$', n, re.I)]
            if not c:
                c = [n for n in names if IMG_RE.match(n) and re.search(r'(launcher|app_?icon)', n, re.I)]
            if not c:
                c = [n for n in names if IMG_RE.match(n)]
            for n in sorted(c, key=rank):
                raw = read_zip(path, n)
                if raw:
                    out = encode_raw(raw)
                    if out:
                        return out
    except Exception:
        pass
    return None


# ---------------- ARSC resolution ----------------
def _rid(v):
    if v is None:
        return None
    s = str(v).strip()
    hexish = s.startswith('@') or s.lower().startswith('0x')
    s = s.lstrip('@')
    if s.lower().startswith('0x'):
        s = s[2:]
    try:
        return int(s, 16) if hexish else int(s)
    except Exception:
        try:
            return int(s, 16)
        except Exception:
            return None


def resolve(arsc, rid):
    """-> list of resolved values (str rgb colour, str resource path, ...)"""
    vals = []
    for fn in ('get_resolved_res_configs', 'get_res_configs'):
        try:
            res = getattr(arsc, fn)(rid)
        except Exception:
            continue
        try:
            for item in res:
                if isinstance(item, (list, tuple)) and len(item) >= 2:
                    v = item[1]
                else:
                    v = item
                if isinstance(v, (list, tuple)):
                    for x in v:
                        if isinstance(x, str):
                            vals.append(x)
                elif isinstance(v, str):
                    vals.append(v)
        except Exception:
            pass
        if vals:
            break
    return vals


def pick_raster(vals):
    r = [v for v in vals if RASTER_RE.search(v)]
    return sorted(r, key=rank)[0] if r else None


def parse_color(v):
    if not isinstance(v, str) or not v.startswith('#'):
        return None
    h = v.lstrip('#')
    try:
        if len(h) == 8:
            a, r, g, b = (int(h[i:i + 2], 16) for i in (0, 2, 4, 6))
            return (r, g, b, a if a else 255)
        if len(h) == 6:
            r, g, b = (int(h[i:i + 2], 16) for i in (0, 2, 4))
            return (r, g, b, 255)
    except Exception:
        return None
    return None


def refs_in_axml(data):
    """resource ids referenced by an adaptive-icon XML, in declaration order"""
    out = []
    for i in range(0, max(0, len(data) - 4)):
        v = struct.unpack('<I', data[i:i + 4])[0]
        if 0x7F000000 <= v <= 0x7FFFFFFF and v not in out:
            out.append(v)
    return out


def compose_adaptive(path, arsc, xml_bytes):
    """returns base64 PNG or None"""
    bg_c = bg_p = fg_p = None
    for rid in refs_in_axml(xml_bytes)[:8]:
        vals = resolve(arsc, rid)
        col = next((parse_color(v) for v in vals if parse_color(v)), None)
        rst = pick_raster(vals)
        if col and bg_c is None and bg_p is None:
            bg_c = col
            continue
        if rst:
            if bg_p is None:
                bg_p = rst
            elif fg_p is None:
                fg_p = rst
    if not (bg_c or bg_p) or not fg_p:
        return None                      # vector-only foreground -> caller falls back
    canvas = 108
    out = Image.new('RGBA', (canvas, canvas), (0, 0, 0, 0))
    if bg_c:
        out.paste(Image.new('RGBA', (canvas, canvas), bg_c), (0, 0))
    if bg_p:
        raw = read_zip(path, bg_p)
        if raw:
            try:
                out.alpha_composite(square(Image.open(io.BytesIO(raw)).convert('RGBA')).resize((canvas, canvas), Image.LANCZOS))
            except Exception:
                bg_c = None
    raw = read_zip(path, fg_p)
    if not raw:
        return None
    try:
        out.alpha_composite(square(Image.open(io.BytesIO(raw)).convert('RGBA')).resize((canvas, canvas), Image.LANCZOS))
    except Exception:
        return None
    n = int(round(canvas * 72.0 / 108.0))
    o = (canvas - n) // 2
    vis = out.crop((o, o, o + n, o + n))
    if vis.getbbox() is None:
        return None
    return encode(vis)


def icon_via_arsc(apk, path):
    arsc = apk.get_android_resources()
    if arsc is None:
        return None
    rid = _rid(apk.get_attribute_value('application', 'icon'))
    if rid is None:
        return None
    vals = resolve(arsc, rid)
    # (a) direct raster resolution = exactly what the launcher loads
    rst = pick_raster(vals)
    if rst:
        raw = read_zip(path, rst)
        if raw:
            out = encode_raw(raw, trim=False)
            if out:
                return out
    # (b) adaptive XML
    xmls = [v for v in vals if isinstance(v, str) and v.lower().endswith('.xml')]
    if not xmls:
        xmls = [n for n in _zip_xmls(path) if 'anydpi' in n and re.search(r'ic_launcher', n, re.I)]
    for x in xmls[:3]:
        data = read_zip(path, x)
        if not data:
            continue
        out = compose_adaptive(path, arsc, data)
        if out:
            return out
    return None


def _zip_xmls(path):
    try:
        with zipfile.ZipFile(path) as zf:
            return zf.namelist()
    except Exception:
        return []


# ---------------- main ----------------
def main():
    syspkgs, usrpkgs = load_set(SYS), load_set(USR)
    rows = []
    with open(TSV) as f:
        for line in f:
            pkg, _, path = line.rstrip('\n').partition('\t')
            if pkg and path:
                rows.append((pkg.strip(), path.strip()))
    if ONLY_USER:
        rows = [(p, q) for (p, q) in rows if p in usrpkgs]

    meta = {}
    st = dict(arsc=0, adaptive=0, api=0, scan=0, noicon=0, unread=0)
    for i, (pkg, path) in enumerate(rows, 1):
        is_sys = pkg in syspkgs and pkg not in usrpkgs
        label, icon, src = None, None, '-'
        if not os.path.exists(path):
            st['unread'] += 1
            meta[pkg] = {'label': fallback_label(pkg), 'icon': None, 'hue': hue(pkg), 'sys': is_sys}
            print(f'[{i}/{len(rows)}] {pkg} UNREADABLE', flush=True)
            continue
        ag = None
        if HAS_AG:
            try:
                ag = APK(path)
                label = (ag.get_app_name() or '').strip()
            except Exception:
                ag = None
        if ag is not None:
            try:
                icon = icon_via_arsc(ag, path)
                if icon:
                    src = 'arsc'
                    st['arsc'] += 1
            except Exception:
                pass
            if not icon:
                try:
                    ip = ag.get_app_icon()
                    if ip and RASTER_RE.search(ip):
                        raw = read_zip(path, ip)
                        if raw:
                            icon = encode_raw(raw)
                            if icon:
                                src = 'api'
                                st['api'] += 1
                except Exception:
                    pass
        if not icon:
            icon = scan_zip(path)
            if icon:
                src = 'scan'
                st['scan'] += 1
            else:
                st['noicon'] += 1
        if not label or label.lower() in ('unknown', pkg.lower()):
            label = fallback_label(pkg)
        meta[pkg] = {'label': label, 'icon': icon, 'hue': hue(pkg), 'sys': is_sys}
        print(f'[{i}/{len(rows)}] {"SYS" if is_sys else "USR"} {pkg} -> "{label}" {src}', flush=True)

    with open(OUT, 'w') as f:
        f.write('/* auto-generated v5: launcher-source icons (ARSC-resolved + adaptive compositing) */\n')
        f.write("window.APP_META_BUILD = '%s';\n" % datetime.datetime.now().strftime('%Y-%m-%d %H:%M'))
        f.write('window.APP_META = ')
        json.dump(meta, f, ensure_ascii=False, separators=(',', ':'))
        f.write(';\n')
    have = sum(1 for v in meta.values() if v['icon'])
    nsys = sum(1 for v in meta.values() if v['sys'])
    print(f"\nwrote {OUT} ({os.path.getsize(OUT)/1024:.0f} KB) · {len(meta)} pkgs · {have} icons "
          f"(arsc {st['arsc']} / api {st['api']} / scan {st['scan']}) · sys {nsys} · user {len(meta)-nsys} · "
          f"no icon {st['noicon']} · unreadable {st['unread']}")


if __name__ == '__main__':
    main()