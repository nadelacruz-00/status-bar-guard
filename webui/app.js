/* Status Bar Guard — logic (KernelSU WebUI) */
'use strict';
const SEP = '\u0001';

let DIR = '/data/adb/statusbarguard';
let APPS = DIR + '/apps.conf', CFG = DIR + '/config', LOG = DIR + '/statusbarguard.log';
let pkgs = [], picked = new Set(), pending = new Set(), dirty = false, style = 'detect', apiLabel = '?';
let showSystem = false; /* set from lsGet() below once helpers are defined */
/* packages reported by `pm list packages -s` but not by -3: the system apps.
   Filled by load(); the rows read it through isSys(). */
let SYS = new Set();

const $ = (id) => document.getElementById(id);
/* null-safe helpers: a missing element must never abort boot */
const on = (id, ev, fn) => { const el = $(id); if (el) el.addEventListener(ev, fn); return el; };
const txt = (id, v) => { const el = $(id); if (el) el.textContent = v; };
function lsGet(k) { try { return localStorage.getItem(k); } catch (e) { return null; } }
function lsSet(k, v) { try { localStorage.setItem(k, v); } catch (e) {} }

/* ---------- bridge: supports KsuWebUI (sync string) and KernelSU manager (callback) ---------- */
function br() {
  try { if (typeof ksu !== 'undefined' && ksu && typeof ksu.exec === 'function') return ksu; } catch (e) {}
  try { if (typeof KernelSU !== 'undefined' && KernelSU && typeof KernelSU.exec === 'function') return KernelSU; } catch (e) {}
  return null;
}
function norm(o) {
  if (o && typeof o === 'object' && typeof o.then !== 'function') {
    return {
      errno: Number(o.errno !== undefined ? o.errno : (o.code !== undefined ? o.code : 0)) || 0,
      stdout: String(o.stdout !== undefined ? o.stdout : (o.output !== undefined ? o.output : '')),
      stderr: String(o.stderr || o.error || '')
    };
  }
  if (typeof o === 'string') {
    try { const j = JSON.parse(o); if (j && typeof j === 'object' && j.errno !== undefined) return norm(j); } catch (e) {}
    return { errno: 0, stdout: o, stderr: '' };
  }
  return { errno: -1, stdout: '', stderr: 'unrecognized result' };
}
function execCb(api, cmd) {
  return new Promise((res) => {
    let done = false;
    const fin = (o) => { if (done) return; done = true; res(norm(o)); };
    try {
      const r = api.exec(cmd, {}, (e, o, s) => fin({ errno: e, stdout: o, stderr: s }));
      if (r && typeof r.then === 'function') { r.then(fin).catch(() => fin({ errno: -1, stdout: '', stderr: 'rejected' })); return; }
      if (typeof r === 'string' || (r && typeof r === 'object')) return fin(r);
      setTimeout(() => fin({ errno: -1, stdout: '', stderr: 'no callback' }), 2500);
    } catch (e) { fin({ errno: -1, stdout: '', stderr: String(e && e.message || e) }); }
  });
}
async function detect() {
  const api = br();
  if (!api) { apiLabel = 'none'; return; }
  try { const r = api.exec('echo __bg__'); if (typeof r === 'string') { style = 'sync'; apiLabel = 'ksu.exec (sync)'; return; } } catch (e) {}
  const t = await execCb(api, 'echo __bg__');
  if ((t.stdout || '').indexOf('__bg__') >= 0) { style = 'cb'; apiLabel = 'ksu.exec (callback)'; return; }
  style = 'cb'; apiLabel = 'ksu.exec (cb?)';
}
async function sh(cmd) {
  const api = br();
  if (!api) return { errno: -1, stdout: '', stderr: 'no bridge' };
  if (style === 'sync') { try { return norm(api.exec(cmd)); } catch (e) { return { errno: -1, stdout: '', stderr: String(e && e.message || e) }; } }
  if (style === 'cb') return execCb(api, cmd);
  await detect(); return sh(cmd);
}

/* ---------- helpers ---------- */
function lines(s) {
  const t = String(s == null ? '' : s);
  const raw = t.indexOf(SEP) >= 0 ? t.split(SEP) : t.split('\n');
  return raw.map((x) => x.trim()).filter(Boolean);
}
/* User vs system is read straight from `pm list packages -s|-3` (see load()),
   so it never depends on pre-built per-app metadata. */
function isSys(p) { return SYS.has(p); }
function esc(s) { return String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])); }
function toast(msg) {
  const t = $('toast'); t.textContent = msg; t.hidden = false;
  clearTimeout(toast._t); toast._t = setTimeout(() => { t.hidden = true; }, 2200);
  try { if (window.ksu && typeof ksu.toast === 'function') ksu.toast(msg); } catch (e) {}
}
function banner(msg) { const b = $('banner'); if (!msg) { b.hidden = true; return; } b.textContent = msg; b.hidden = false; }
function fgPkg(l) { const m = /u0\s+([A-Za-z0-9_.]+\/[A-Za-z0-9_.$]+)/.exec(l || ''); return m ? m[1].split('/')[0] : '?'; }

/* ---------- state ---------- */
function counts() {
  let u = 0, s = 0;
  pkgs.forEach((p) => { isSys(p) ? s++ : u++; });
  return { u, s };
}
/* ---------- pull-to-refresh (Material "swipe to refresh") ----------
   Drag down at the very top of the app list:
     • ring fades/rotates in with pull distance
     • release past THRESHOLD -> refresh runs, ring spins until done, then fades
     • release before         -> ring springs back and hides
   Works with touch and mouse (pointer events). */
const PTR_THRESHOLD = 64;   /* px of (damped) pull that arms the trigger */
const PTR_MAX = 130;        /* damped pull cap */
const PTR_DAMP = 0.5;       /* resistance factor */
const PTR_RING_REST = 44;   /* how far above the list edge the resting indicator hides */
const PTR_BUSY_Y = 48;      /* where the spinner parks while refreshing */
const PTR_TRAVEL = 0.9;     /* fraction of the pull the indicator travels */
const PTR_C = 125.66;       /* circumference of the arc: 2*pi*20 */
const PTR_EASE = 0.22;      /* per-frame smoothing -> fluid, weighted motion */
let ptr = null;             /* {startY, armed} while a pull is in progress */

/* --- smoothed rendering: JS only sets targets, the painter interpolates every frame --- */
let ptrTarget = 0, ptrShown = 0, ptrRAF = null, ptrBusyOn = false;

function ptrBox(){ return $('ptrBox'); }
function ptrArc(){ const b = ptrBox(); return b ? b.querySelector('.ptrArc') : null; }

function ptrPaint(d){
  const box = ptrBox(); if (!box) return;
  const prog = Math.min(1, d / PTR_THRESHOLD);
  const y = d * PTR_TRAVEL - PTR_RING_REST;
  const scale = .62 + .38 * prog;
  box.style.opacity = String(Math.min(1, d / 22));
  box.style.transform = 'translateY(' + y.toFixed(2) + 'px) scale(' + scale.toFixed(3) + ')';
  box.classList.toggle('armed', d >= PTR_THRESHOLD);
  /* while dragging, the arc grows and creeps around the track; the busy animation overrides both */
  if (!ptrBusyOn){
    const a = ptrArc();
    if (a){
      const len = 14 + 84 * prog;
      a.style.strokeDasharray = len.toFixed(1) + ' ' + (PTR_C - len).toFixed(1);
      a.style.strokeDashoffset = (-d * 0.55).toFixed(1);
    }
    const ring = $('ptrRing');
    if (ring) ring.style.transform = 'rotate(' + (d * 1.15).toFixed(1) + 'deg)';
  }
}
function ptrFrame(){
  ptrRAF = null;
  ptrShown += (ptrTarget - ptrShown) * PTR_EASE;
  if (Math.abs(ptrTarget - ptrShown) < 0.35) ptrShown = ptrTarget;
  ptrPaint(ptrShown);
  if (ptrShown !== ptrTarget) ptrRAF = requestAnimationFrame(ptrFrame);
}
function ptrTo(v){ ptrTarget = v; if (!ptrRAF) ptrRAF = requestAnimationFrame(ptrFrame); }
function ptrSnap(v){ ptrTarget = ptrShown = v; ptrPaint(v); }

/* Material geometry: the indicator descends from the top edge and grows as you pull */
function ptrApply(dist){
  if (ptrBusyOn) return;
  ptrTo(Math.min(PTR_MAX, Math.max(0, dist)));
}
function ptrReset(){
  const box = ptrBox(); if (!box) return;
  box.classList.remove('armed','busy');
  ptrBusyOn = false;
  const ring = $('ptrRing'); if (ring) ring.style.transform = '';
  const a = ptrArc(); if (a){ a.style.strokeDasharray = ''; a.style.strokeDashoffset = ''; }
  ptrTo(0);                                   /* smoothed spring-back, no snap */
}
function ptrBusy(on){
  const box = ptrBox(); if (!box) return;
  if (on){
    ptrBusyOn = true;
    box.classList.remove('armed');
    box.classList.add('busy');                /* CSS now owns the sweep + spin */
    ptrSnap(PTR_BUSY_Y);
    box.style.opacity = '1';
    box.style.transform = 'translateY(' + PTR_BUSY_Y + 'px) scale(1)';
  } else {
    box.classList.remove('busy');
    ptrBusyOn = false;
    const ring = $('ptrRing'); if (ring) ring.style.transform = '';
    const a = ptrArc(); if (a){ a.style.strokeDasharray = ''; a.style.strokeDashoffset = ''; }
    ptrTo(0);
  }
}
async function ptrRunRefresh(){
  try{
    toast('Re-scanning installed apps…');
    await sh('sh ' + DIR + '/refresh-dump.sh');
    await load();
    await refreshStatus();
    toast('App list updated');
  } finally {
    ptrBusy(false);
  }
}
function ptrBusyState(){ return ptrBusyOn; }

function bindPTR(){
  const list = $('applist');
  if (!list) return;

  /* --- touch (primary, phones/tablets): non-passive so we can claim the pull --- */
  list.addEventListener('touchstart', (e) => {
    if (ptrBusyState()) return;
    if (list.scrollTop <= 0 && e.touches.length === 1) {
      ptr = { startY: e.touches[0].clientY, tracking: false, armed: false };
    }
  }, { passive: true });

  list.addEventListener('touchmove', (e) => {
    if (!ptr) return;
    const dy = e.touches[0].clientY - ptr.startY;
    if (list.scrollTop > 0 || dy <= 0) {           /* not a pull: hand back to native scroll */
      if (ptr.tracking) { ptrReset(); ptr = null; }
      return;
    }
    if (!ptr.tracking && dy > 8) ptr.tracking = true;
    if (!ptr.tracking) return;
    e.preventDefault();                            /* claim the gesture: no native scroll/pan */
    const dist = Math.min(PTR_MAX, dy * PTR_DAMP);
    ptrApply(dist);
    ptr.armed = dist >= PTR_THRESHOLD;
  }, { passive: false });

  const touchFinish = () => {
    if (!ptr) return;
    const wasArmed = ptr.armed;
    ptr = null;
    if (wasArmed && !ptrBusyState()) { ptrBusy(true); ptrRunRefresh(); }
    else ptrReset();
  };
  list.addEventListener('touchend', touchFinish, { passive: true });
  list.addEventListener('touchcancel', touchFinish, { passive: true });

  /* --- mouse (desktop/trackpad testing): pointer events, no native panning involved --- */
  list.addEventListener('pointerdown', (e) => {
    if (e.pointerType === 'touch' || ptrBusyState()) return;
    if (list.scrollTop <= 0) ptr = { startY: e.clientY, tracking: false, armed: false };
  });
  list.addEventListener('pointermove', (e) => {
    if (!ptr || e.pointerType === 'touch') return;
    const dy = e.clientY - ptr.startY;
    if (list.scrollTop > 0 || dy <= 0) { if (ptr.tracking) { ptrReset(); ptr = null; } return; }
    ptr.tracking = true;
    const dist = Math.min(PTR_MAX, dy * PTR_DAMP);
    ptrApply(dist);
    ptr.armed = dist >= PTR_THRESHOLD;
  });
  const mouseFinish = () => {
    if (!ptr) return;
    const wasArmed = ptr.armed;
    ptr = null;
    if (wasArmed && !ptrBusyState()) { ptrBusy(true); ptrRunRefresh(); }
    else ptrReset();
  };
  list.addEventListener('pointerup', mouseFinish);
  list.addEventListener('pointercancel', mouseFinish);
}

function syncState() {
  txt('selCount', pending.size);
  dirty = [...pending].sort().join(',') !== [...picked].sort().join(',');
  const dot = $('dirtyDot');
  if (dot) dot.className = 'dot' + (dirty ? ' dirty' : '');
  txt('dirtyText', dirty ? 'Unsaved changes' : 'Saved');
  const sv = $('save');
  if (sv) sv.disabled = !dirty;
}

/* ---------- render ---------- */
/* A row is the package name and nothing else. System apps carry a badge and a
   stripe so the two kinds stay distinguishable, including in "Selected",
   where both are mixed together. */
function rowHTML(p) {
  const on = pending.has(p);
  const sys = isSys(p);
  return '<label class="row' + (on ? ' on' : '') + (sys ? ' sys' : '') + '" data-pkg="' + esc(p) + '">' +
    '<span class="pkg">' + esc(p) + '</span>' +
    (sys ? '<span class="badge sys">system</span>' : '<span class="badge usr">user</span>') +
    '<input type="checkbox" data-pkg="' + esc(p) + '"' + (on ? ' checked' : '') + '>' +
    '</label>';
}
function render() {
  const q = ($('search').value || '').toLowerCase().trim();
  const pool = pkgs.filter((p) => showSystem || !isSys(p));
  const match = (p) => !q || p.toLowerCase().includes(q);
  const cmp = (a, b) => a.localeCompare(b);
  const sel = [...pending].filter(match).sort(cmp);
  const rest = pool.filter((p) => !pending.has(p) && match(p)).sort(cmp);
  let html = '';
  if (sel.length) html += '<div class="sect">Selected · ' + sel.length + '</div>' + sel.map(rowHTML).join('');
  if (rest.length) html += '<div class="sect">' + (sel.length ? 'All apps · ' : '') + rest.length +
    (showSystem ? '' : ' · user apps') + '</div>' + rest.map(rowHTML).join('');
  if (!sel.length && !rest.length) html = '';
  const box = $('applist');
  if (box) {
    box.innerHTML = html;
    box.querySelectorAll('input[type=checkbox]').forEach((cb) => {
      cb.addEventListener('change', () => {
        const p = cb.dataset.pkg;
        if (cb.checked) pending.add(p); else pending.delete(p);
        render();
      });
    });
  }
  if ($('empty')) $('empty').hidden = !!(sel.length || rest.length);
  if ($('clearSearch')) $('clearSearch').hidden = !q;
  const c = counts();
  txt('pkgCount', c.u + (showSystem ? ' + ' + c.s + ' sys' : ''));
  txt('sysCount', '(' + c.s + ')');
  syncState();
}

/* ---------- data ---------- */
async function initPaths() {
  let modDir = '/data/adb/modules/statusbarguard', fromInfo = false;
  try {
    if (window.ksu && typeof ksu.moduleInfo === 'function') {
      const j = JSON.parse(norm(ksu.moduleInfo()).stdout);
      if (j && j.moduleDir) { modDir = j.moduleDir; fromInfo = true; }
    }
  } catch (e) {}
  const cand = modDir.replace('/modules/', '/');
  const t = await sh('test -f ' + cand + '/daemon.sh && echo yes');
  DIR = (String(t.stdout).indexOf('yes') >= 0) ? cand : modDir;
  apiLabel += (fromInfo ? ' · modDir' : '') + ' · ' + (DIR.indexOf('/modules/') >= 0 ? 'MODULE(!)' : 'data');
  APPS = DIR + '/apps.conf'; CFG = DIR + '/config'; LOG = DIR + '/statusbarguard.log';
}
async function refreshStatus() {
  const d = await sh("ps -A -o args 2>/dev/null | grep -c 'statusbarguard/daemon.sh$'");
  const alive = parseInt((d.stdout || '0').trim(), 10) > 0;
  const pill = $('daemonPill');
  if (pill) { pill.textContent = alive ? 'daemon running' : 'daemon stopped'; pill.className = 'pill ' + (alive ? 'ok' : 'bad'); }

  const f = await sh('dumpsys window 2>/dev/null | grep -m1 mCurrentFocus');
  const fp = fgPkg(f.stdout);
  txt('focusPill', 'foreground: ' + (fp === '?' ? '?' : fp));

  const m = await sh("grep '^MODE=' " + CFG + ' 2>/dev/null | cut -d= -f2');
  const mode = ((m.stdout || '').trim()) || 'auto';
  const r = document.querySelector('input[name=mode][value="' + mode + '"]'); if (r) r.checked = true;
  txt('modeHint', mode === 'auto' ? 'list below decides' : (mode === 'global' ? 'always blocked' : 'always allowed'));

  const lg = await sh('tail -n 12 ' + LOG + ' 2>/dev/null | tr "\\n" "' + SEP + '"');
  txt('log', lines(lg.stdout).join('\n') || '(no activity yet)');
  txt('apiPill', 'bridge: ' + apiLabel);
}
async function load() {
  banner('');
  const p = await sh('pm list packages -3 2>/dev/null | sed "s/^package://" | sort | tr "\\n" "' + SEP + '"');
  const user = lines(p.stdout);
  const s = await sh('pm list packages -s 2>/dev/null | sed "s/^package://" | sort | tr "\\n" "' + SEP + '"');
  const sysm = lines(s.stdout);
  /* Classify from pm itself: listed by -s but not by -3 => system app.
     Anything in both stays "user", which matches how pm treats an updated
     system app that the user could uninstall. */
  const uset = new Set(user);
  SYS = new Set(sysm.filter((x) => !uset.has(x)));
  pkgs = user.concat([...SYS]);
  const a = await sh('grep -vE "^[[:space:]]*(#|$)" ' + APPS + ' 2>/dev/null | tr "\\n" "' + SEP + '"');
  picked = new Set(lines(a.stdout));
  pending = new Set(picked);
  if (!pkgs.length) banner('Could not read the app list.\nbridge: ' + apiLabel + '\nerrno: ' + p.errno + '\n' + (p.stderr || ''));
  render();
}

/* ---------- wiring ---------- */
function bind() {
  if ($('app')) $('app').hidden = false;
  if ($('boot')) $('boot').hidden = true;
  /* measure AFTER the container is visible, otherwise the list has zero height */
  on('search', 'input', render);
  on('clearSearch', 'click', () => { const s = $('search'); if (s) { s.value = ''; render(); s.focus(); } });
  on('clear', 'click', () => { pending.clear(); render(); toast('Cleared — press Save to apply'); });
  const sys = on('sysToggle', 'change', () => {
    showSystem = !!sys.checked;
    lsSet('sbg_show_system', showSystem ? '1' : '0');
    render();
  });
  if (sys) sys.checked = showSystem;
  /* single, unambiguous refresh: re-scan packages on the Android side, then re-read config + status. */
  document.querySelectorAll('input[name=mode]').forEach((r) => r.addEventListener('change', async () => {
    const m = document.querySelector('input[name=mode]:checked').value;
    await sh("sed -i 's/^MODE=.*/MODE=" + m + "/' " + CFG);
    toast('Mode: ' + m); await refreshStatus();
  }));
  on('save', 'click', async () => {
    const list = [...pending].filter((p) => /^[A-Za-z0-9_.]+$/.test(p)).sort();
    const q = (s) => "'" + String(s).replace(/'/g, "'\\''") + "'";
    let cmd = "printf '%s\\n' " + q('# Apps: while any of these is in the foreground, the status bar is blanked and the shade is blocked.') +
      ' ' + q('# One package name per line. Managed by the Status Bar Guard WebUI.') + ' > ' + APPS;
    if (list.length) cmd += " && printf '%s\\n' " + list.map(q).join(' ') + ' >> ' + APPS;
    const r = await sh(cmd);
    if (r.errno !== 0 && r.stderr) { toast('Save FAILED: ' + r.stderr); return; }
    /* trust but verify: read back what the daemon will actually see */
    const rb = await sh('grep -vE "^[[:space:]]*(#|$)" ' + APPS + ' 2>/dev/null | sort | tr "\\n" "' + SEP + '"');
    const saved = lines(rb.stdout).sort();
    const same = saved.length === list.length && saved.every((p, i) => p === list[i]);
    if (!same) {
      banner('SAVE MISMATCH — the file on disk does not match this UI.\n' +
        'UI:    ' + (list.join(', ') || '(empty)') + '\n' +
        'Disk:  ' + (saved.join(', ') || '(empty)'));
      toast('Save failed verification');
    } else {
      toast(list.length ? 'Saved ' + list.length + ' app(s) — applies in ~2s' : 'Saved (empty list) — nothing suppressed');
    }
    await load(); await refreshStatus();
  });
  bindPTR();
  setInterval(() => { if (!dirty) refreshStatus(); }, 8000);
}

/* ---------- boot (never leaves a blank page) ---------- */
(async () => {
  try {
    showSystem = lsGet('sbg_show_system') === '1';
    await detect();
    await initPaths();
    await load();
    await refreshStatus();
    bind();
  } catch (e) {
    const b = $('boot');
    if (b) { b.hidden = false; b.textContent = 'Boot error: ' + ((e && e.message) || e); }
    const bn = $('banner');
    if (bn) { bn.hidden = false; bn.textContent = 'Boot error: ' + ((e && e.stack) || e); }
  }
})();
