// Replays PortalSyncEngine._waitForPageChange against the LIVE portal, using
// the same signature (url|size|readyState), the same 250ms poll, the same
// "changed then stable twice" rule and the same 3s starting-window bail-out.
// Proves the algorithm on the real thing without running the app.
const WebSocket = require('ws');
let ws, id = 0;
const pending = new Map();

function send(method, params) {
  return new Promise((res, rej) => {
    const n = ++id;
    pending.set(n, { res, rej });
    ws.send(JSON.stringify({ id: n, method, params }));
  });
}
async function evalJs(expression) {
  const r = await send('Runtime.evaluate', {
    expression, returnByValue: true, awaitPromise: true,
  });
  if (r.exceptionDetails) return null;          // context destroyed mid-nav
  return r.result && r.result.value;
}
const sleep = (ms) => new Promise(r => setTimeout(r, ms));

const SIG = '(function(){return location.href+"|"+document.documentElement.outerHTML.length+"|"+document.readyState;})()';
const CLASSIFY = `(function(){var h=document.documentElement.outerHTML;
  return JSON.stringify({report:(h.match(/REPORTTITLE" value="([^"]*)"/)||[])[1]||null,
  chars:h.length,
  isList:/Page\\s+\\d+\\s+of\\s+\\d+/i.test(h)&&/account no/i.test(h)});})()`;

/** The engine's algorithm, verbatim. */
async function waitForPageChange(before, timeoutMs) {
  const start = Date.now(), deadline = start + timeoutMs;
  let changed = false, last = before, stable = 0;
  while (Date.now() < deadline) {
    await sleep(250);
    const now = await evalJs(SIG);
    if (!now) continue;                          // navigating: context gone
    if (!changed) {
      if (now !== before) { changed = true; last = now; }
      continue;                                  // no early bail: see engine
    }
    if (!now.endsWith('|complete')) { stable = 0; last = now; continue; }
    if (now === last) { if (++stable >= 2) return { ok: true, ms: Date.now() - start }; }
    else { stable = 0; last = now; }
  }
  return { ok: changed, ms: Date.now() - start, why: 'timeout' };
}

async function click(sel, label) {
  const r = await evalJs(`(function(){var e=document.querySelectorAll(${JSON.stringify(sel)});
    for(var i=0;i<e.length;i++){if(e[i].disabled)continue;(e[i].closest('a')||e[i]).click();return 'true';}
    return 'false';})()`);
  console.log(`  click ${label}: ${r === 'true' ? 'landed' : 'nothing to click'}`);
  return r === 'true';
}

(async () => {
  const t = (await (await fetch('http://localhost:9222/json')).json())
    .find(x => x.type === 'page');
  ws = new WebSocket(t.webSocketDebuggerUrl, { perMessageDeflate: false, maxPayload: 64e6 });
  ws.on('message', b => {
    const m = JSON.parse(b.toString());
    const p = pending.get(m.id);
    if (p) { pending.delete(m.id); m.error ? p.rej(m.error) : p.res(m.result); }
  });
  await new Promise(r => ws.on('open', r));

  const ENQUIRE = 'a[name="HREF_Agent Enquire & Update Screen"], a[id="Agent Enquire & Update Screen"], a[name*="Enquire"], a[id*="Enquire"]';

  // Start from a known place: the dashboard, exactly like the walk does.
  console.log('reset to dashboard');
  await click('#Dashboard, a[name="HREF_Dashboard"]', 'Dashboard');
  await sleep(4000);

  for (const [sel, label] of [['#Accounts, a[name="HREF_Accounts"]', 'Accounts'],
                              [ENQUIRE, 'Enquire']]) {
    const before = await evalJs(SIG);
    console.log(`\nbefore ${label}: ${String(before).split('|').slice(1).join(' | ')}`);
    await click(sel, label);
    const r = await waitForPageChange(before, 25000); // _clickPatience
    console.log(`  waitForPageChange -> ${r.ok ? 'CHANGED' : 'no change'} in ${r.ms}ms${r.why ? ' (' + r.why + ')' : ''}`);
    const c = JSON.parse(await evalJs(CLASSIFY));
    console.log(`  now: ${c.report} ${c.chars} chars  isList=${c.isList}`);
  }
  process.exit(0);
})();
