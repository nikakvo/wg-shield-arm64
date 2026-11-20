// WG Shield Arm64 - WebUI check (node, no browser): a tunnel row rendered for
// a name with quotes keeps the name out of its handler code.
//   node tests/webui_rows.js webroot/index.html
// With the output of `ctl.sh files` and the file names in it, the page's own
// parser (parseKV + fileRow) is checked on it as well:
//   node tests/webui_rows.js webroot/index.html FILES_OUTPUT NAME...
// The outside-link check reads every page next to index.html (help.html too).
// Prints one "ok"/"FAIL" line per check; exit 1 on a failure.
const fs = require('fs'), path = require('path'), vm = require('vm');
const html = fs.readFileSync(process.argv[2], 'utf8');
const js = html.slice(html.indexOf('<script>') + 8, html.lastIndexOf('</script>'));
// the page script runs against a do-nothing DOM; only its functions are used
const stub = new Proxy(function () {}, { get: (t, k) => k === Symbol.toPrimitive ? () => '' : stub, apply: () => stub, construct: () => stub, set: () => true });
const ctx = { document: stub, window: stub, localStorage: stub, navigator: stub, location: stub, setInterval: () => 0, setTimeout: () => 0, console };
vm.createContext(ctx);
vm.runInContext(js, ctx);
const dec = s => s.replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&');
let fail = 0;
const check = (d, ok) => { console.log((ok ? '  ok   ' : '  FAIL ') + d); if (!ok) fail++; };
const name = `it's "x" <b>&`;
const st = { active: name, state: 'up', handshake_age: '5', awg_kernel: '1' };
for (const fav of [false, true]) {
  const row = vm.runInContext('tunRow', ctx)({ name, ep: '203.0.113.1:51820', addr: '10.2.0.2/32', valid: '1', v6: '0', type: 'wireguard', fav, cc: '' }, st, false);
  const els = [...row.matchAll(/<(button|input)\b([^>]*)>/g)].map(m => Object.fromEntries([...m[2].matchAll(/([a-z-]+)="([^"]*)"/g)].map(a => [a[1], dec(a[2])])));
  const h = els.filter(e => e.onclick || e.onchange);
  check(`fav=${fav}: three handlers`, h.length === 3);
  check(`fav=${fav}: no handler contains the name`, h.every(e => { const c = e.onclick || e.onchange; return !c.includes("it's") && !c.includes('"x"'); }));
  check(`fav=${fav}: the name reaches each handler whole`, h.every(e => e['data-n'] === name));
  check(`fav=${fav}: handler code is valid JS`, h.every(e => { try { new Function(e.onclick || e.onchange); return true; } catch (x) { return false; } }));
}
// outside sites: never loaded in this WebView, which carries the root bridge -
// no link to one (any quoting), no new window, no script navigation, on any page
const dir = path.dirname(process.argv[2]), far = '(?:https?:)?//';
const nav = [
  new RegExp(`<a\\b[^>]*\\bhref\\s*=\\s*["']?${far}`, 'i'),
  new RegExp('\\btarget\\s*=\\s*["\']?_blank', 'i'),
  new RegExp(`\\blocation(?:\\.href)?\\s*=\\s*["'\`]${far}`, 'i'),
  new RegExp(`\\blocation\\.(?:assign|replace)\\s*\\(\\s*["'\`]${far}`, 'i'),
  new RegExp(`\\bwindow\\.open\\s*\\(\\s*["'\`]${far}`, 'i'),
];
for (const f of fs.readdirSync(dir).filter(n => /\.html?$/i.test(n)).sort()) {
  const t = fs.readFileSync(path.join(dir, f), 'utf8');
  check(`${f}: no link or script navigates the WebUI to an outside site`, !nav.some(r => r.test(t)));
}
if (process.argv[3]) {
  const want = process.argv.slice(4).sort();
  const r = vm.runInContext('parseKV', ctx)(fs.readFileSync(process.argv[3], 'utf8'));
  const rows = r.file.map(l => vm.runInContext('fileRow', ctx)(l));
  const got = rows.map(x => x.name).sort();
  check(`files: names whole (${JSON.stringify(got)})`, JSON.stringify(got) === JSON.stringify(want));
  check('files: size, time and count are numbers', rows.length > 0 && rows.every(x => /^\d+$/.test(x.size) && /^\d+$/.test(x.mtime) && /^\d+$/.test(x.n)));
}
// openExt: the outside site goes to the browser through am start; when that
// fails (no root bridge, an exception, a non-zero exit, am's "Error:" line)
// the page says so (toast), in both forms of ksu.exec. Async: every check
// below must have run before the exit, else that is a failure too.
let asyncDone = false;
process.on('exit', () => { if (!asyncDone) { console.log('  FAIL the openExt checks did not finish'); process.exitCode = 1; } });
(async () => {
  const oe = vm.runInContext('typeof openExt === "function" ? openExt : null', ctx);
  check('openExt exists', !!oe);
  if (!oe) return;
  const toasts = [];
  ctx.toast = (m, t) => { toasts.push([String(m), t]); };
  // the hook sees the page's own toasts (Backup with no tunnels always toasts)
  await vm.runInContext('doBackup', ctx)(null);
  check('the toast hook sees the page\'s toasts', toasts.length === 1 && toasts[0][1] === 'err');
  ctx.window = {};                       // callbackExec keeps its callback here
  let cmd = null, ans = null;
  // ans: [errno, stdout, stderr] for the callback form, a string for the legacy one
  ctx.ksu = { exec: (c, o, cb) => {
    cmd = c;
    if (ans instanceof Error) throw ans;
    if (cb) { Promise.resolve().then(() => ctx.window[cb](...ans)); return; }
    return ans;
  } };
  const run = async (url, a, mode) => {
    vm.runInContext(`EXEC_MODE = ${JSON.stringify(mode || 'callback')}`, ctx);
    cmd = null; ans = a; toasts.length = 0;
    let r, threw = false;
    try { r = await oe(url); } catch (e) { threw = true; }
    return { cmd, r, threw, err: toasts.filter(t => t[1] === 'err').map(t => t[0]) };
  };
  const ok = 'Starting: Intent { act=android.intent.action.VIEW dat=https://www.example.org/... }\n';
  const nf = 'Error: Activity not started, unable to resolve Intent { act=android.intent.action.VIEW }\n';
  let x = await run('https://www.example.org/', [0, ok, '']);
  check('an outside site opens in the browser (am start VIEW)', /^am start -a android\.intent\.action\.VIEW -d 'https:\/\/www\.example\.org\/'( 2>&1)?$/.test(x.cmd) && x.err.length === 0);
  x = await run("https://x.example.org/'; reboot; '", [0, ok, '']);
  check('a URL with a quote is refused', x.cmd === null);
  x = await run('javascript:alert(1)', [0, ok, '']);
  check('a URL that is not https is refused', x.cmd === null);
  x = await run('https://www.example.org/', [1, '', 'Exception occurred while executing: ...\n']);
  check('am start ends non-zero: an error toast', x.err.length === 1 && !x.threw);
  x = await run('https://www.example.org/', [0, nf, '']);
  check('am start prints "Error: Activity not started": an error toast naming it', x.err.length === 1 && /Activity not started/.test(x.err[0]));
  x = await run('https://www.example.org/', new Error('bridge gone'));
  check('ksu.exec throws: an error toast, no exception out of openExt', x.err.length === 1 && !x.threw);
  x = await run('https://www.example.org/', nf, 'legacy');
  check('legacy form, "Error:" in the output: an error toast', x.err.length === 1 && /Activity not started/.test(x.err[0]));
  x = await run('https://www.example.org/', ok, 'legacy');
  check('legacy form, the browser opens: no toast', x.cmd !== null && x.err.length === 0);
  delete ctx.ksu;
  x = await run('https://www.example.org/', [0, ok, '']);
  check('no root bridge: an error toast', x.err.length === 1 && !x.threw);
})().catch(e => check(`openExt checks: no exception (${e && e.message})`, false))
  .finally(() => { asyncDone = true; process.exit(fail ? 1 : 0); });
