// WG Shield Arm64 - WebUI check (node, no browser): a tunnel row rendered for
// a name with quotes keeps the name out of its handler code.
//   node tests/webui_rows.js webroot/index.html
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
process.exit(fail ? 1 : 0);
