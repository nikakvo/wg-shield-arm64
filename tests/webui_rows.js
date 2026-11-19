// WG Shield Arm64 - WebUI check (node, no browser): a tunnel row rendered for
// a name with quotes keeps the name out of its handler code.
//   node tests/webui_rows.js webroot/index.html
// With the output of `ctl.sh files` and the file names in it, the page's own
// parser (parseKV + fileRow) is checked on it as well:
//   node tests/webui_rows.js webroot/index.html FILES_OUTPUT NAME...
// Prints one "ok"/"FAIL" line per check; exit 1 on a failure.
const fs = require('fs'), vm = require('vm');
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
// outside sites: never loaded in this WebView, which carries the root bridge
check('no link navigates the WebUI to an outside site', !/<a\b[^>]*\bhref="(https?:)?\/\//i.test(html));
const oe = vm.runInContext('typeof openExt === "function" ? openExt : null', ctx);
check('openExt exists', !!oe);
if (oe) {
  let cmd = null;
  ctx.ksu = { exec: (c) => { cmd = c; } };
  oe('https://www.example.org/');
  check('an outside site opens in the browser (am start VIEW)', cmd === "am start -a android.intent.action.VIEW -d 'https://www.example.org/'");
  cmd = null; oe("https://x.example.org/'; reboot; '");
  check('a URL with a quote is refused', cmd === null);
  cmd = null; oe('javascript:alert(1)');
  check('a URL that is not https is refused', cmd === null);
  delete ctx.ksu;
}
if (process.argv[3]) {
  const want = process.argv.slice(4).sort();
  const r = vm.runInContext('parseKV', ctx)(fs.readFileSync(process.argv[3], 'utf8'));
  const rows = r.file.map(l => vm.runInContext('fileRow', ctx)(l));
  const got = rows.map(x => x.name).sort();
  check(`files: names whole (${JSON.stringify(got)})`, JSON.stringify(got) === JSON.stringify(want));
  check('files: size, time and count are numbers', rows.length > 0 && rows.every(x => /^\d+$/.test(x.size) && /^\d+$/.test(x.mtime) && /^\d+$/.test(x.n)));
}
process.exit(fail ? 1 : 0);
