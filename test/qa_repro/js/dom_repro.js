const { JSDOM } = require('jsdom');
const X = require('./extract');

let pass = 0, fail = 0;
const results = [];
function check(id, desc, fn) {
  let ok, note = '';
  try { note = fn(); ok = true; } catch (e) { ok = false; note = e.message; }
  ok ? pass++ : fail++;
  results.push({ id, desc, ok, note });
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${id}  ${desc}${note ? '\n        → ' + note : ''}`);
}
function assert(c, m) { if (!c) throw new Error(m); }

function dom(html) {
  const d = new JSDOM(`<!doctype html><html><body>${html}</body></html>`,
    { runScripts: 'outside-only', url: 'https://dopagent.indiapost.gov.in/login' });
  return d;
}
const run = (d, js) => d.window.eval(js);

// ── J2 (FIXED) ─ _clickLinkByText must resolve DOWN to the anchor ───────────
check('J2-1', 'menu anchor WITHOUT name/id=Enquire: the anchor is clicked, not its cell', () => {
  const d = dom(`<table><tr>
     <td id="cell"><a id="link" href="/AgentRDActSummaryAllListing">Agent Enquire &amp; Update Screen</a></td>
   </tr></table>`);
  const w = d.window;
  let navigated = false, tdTargeted = false;
  w.document.getElementById('link').addEventListener('click', () => { navigated = true; });
  w.document.getElementById('cell').addEventListener('click', (e) => {
    if (e.target.id === 'cell') tdTargeted = true;
  });
  const r = run(d, X.clickLinkByTextJs(X.ENQUIRE_NEEDLES));
  assert(r === 'true', `script reported "${r}", expected "true"`);
  assert(navigated, 'the anchor should have received the click');
  assert(!tdTargeted, 'REGRESSION: the <td> was clicked again — see J2-3');
  return 'querySelector("a") resolves down to the anchor before closest() walks up; the cell is not clicked';
});

check('J2-1b', 'a text match on something with no control in it is NOT a click', () => {
  // The other half of the fix. Reporting "true" for a click that cannot
  // navigate sends the caller off waiting for a page that will never come.
  const d = dom(`<div><span id="label">Agent Enquire &amp; Update Screen</span></div>`);
  const r = run(d, X.clickLinkByTextJs(X.ENQUIRE_NEEDLES));
  assert(r === 'false', `expected "false" for a bare <span>, got "${r}"`);
  return 'a <span> with no anchor or button inside reports false instead of a phantom success';
});

check('J2-2', 'the same DOM WITH name*="Enquire" is handled correctly by _clickSelector', () => {
  const d = dom(`<table><tr>
     <td id="cell"><a id="link" name="HREF_EnquireUpdate" href="/x">Agent Enquire &amp; Update Screen</a></td>
   </tr></table>`);
  let navigated = false;
  d.window.document.getElementById('link').addEventListener('click', () => { navigated = true; });
  const r = run(d, X.clickSelectorJs('a[name*="Enquire"], a[id*="Enquire"]'));
  assert(r === 'true', 'selector path should click');
  assert(navigated, 'anchor should have been clicked on the fast path');
  return 'the fast path was always fine; J2-1 covers the fallback that was not';
});

check('J2-3', 'document order is why the fix has to look DOWN, not just up', () => {
  const d = dom(`<table><tr><td id="cell"><a id="link">Agent Enquire &amp; Update Screen</a></td></tr></table>`);
  const els = [...d.window.document.querySelectorAll('a, input[type=button], input[type=submit], button, span, td')];
  const ids = els.map(e => e.id);
  assert(ids.indexOf('cell') < ids.indexOf('link'), 'expected td before a');
  const td = d.window.document.getElementById('cell');
  assert(td.closest('a') === null, 'closest() should not find a descendant anchor');
  return `querySelectorAll order = [${ids}] — the cell is always seen first, and td.closest('a') === null, so upward resolution alone can never reach the link`;
});

// ── D3 ─ captcha fill: which events fire, and does it focus? ─────────────────
check('J1-1', 'captcha fill dispatches no keydown/keypress and never focuses the field', () => {
  const d = dom(`<input name="AuthenticationFG.VERIFICATION_CODE" id="cap">`);
  const w = d.window, seen = [];
  let focused = false;
  const f = w.document.getElementById('cap');
  for (const t of ['input','change','keyup','blur','keydown','keypress','focus'])
    f.addEventListener(t, () => seen.push(t));
  f.focus = () => { focused = true; };
  const r = run(d, X.fillCaptchaJs('A1B2C'));
  assert(r === 'true', 'fill should report true');
  assert(f.value === 'A1B2C', 'value should be set');
  assert(!seen.includes('keydown') && !seen.includes('keypress'),
         'BUG NOT REPRODUCED: a key event was dispatched');
  assert(!focused, 'BUG NOT REPRODUCED: the field was focused');
  return `dispatched [${seen}] — a portal handler bound to keypress/keydown, or one that requires focus, never runs`;
});

check('J1-2', 'a portal that enables Login on keypress stays disabled after our fill', () => {
  const d = dom(`<input name="AuthenticationFG.VERIFICATION_CODE" id="cap">
                 <input type="submit" name="AuthenticationFG.VALIDATE_CREDENTIALS" value="Log in" disabled>`);
  const w = d.window;
  // Realistic Finacle-style gate: button enables only on a key event.
  w.document.getElementById('cap').addEventListener('keypress', function () {
    w.document.querySelector('[name*="VALIDATE_CREDENTIALS"]').disabled = false;
  });
  run(d, X.fillCaptchaJs('A1B2C'));
  const clicked = run(d, X.loginJs());
  assert(clicked === 'false', `BUG NOT REPRODUCED: login click returned "${clicked}"`);
  return 'login button still disabled → _loginJs returns "false" for all 10 polls → falls through to "tap Login"';
});

// ── D6 ─ captcha scorer fires on pages that have no captcha ─────────────────
check('J3-1', 'a 120x22 spacer/banner gif on a NON-login page scores high enough to be OCR\'d', () => {
  const d = dom(`<img id="spacer" src="/img/hdr_bar.gif" width="120" height="22">`);
  const w = d.window;
  const img = w.document.getElementById('spacer');
  Object.defineProperty(img, 'complete', { value: true });
  Object.defineProperty(img, 'naturalWidth', { value: 120 });
  Object.defineProperty(img, 'naturalHeight', { value: 22 });
  // Stub canvas (jsdom has no 2D context without the `canvas` package).
  const realCreate = w.document.createElement.bind(w.document);
  w.document.createElement = (tag) => {
    if (tag !== 'canvas') return realCreate(tag);
    const px = { data: new Uint8ClampedArray(4 * 64) };
    return { width: 0, height: 0,
      getContext: () => ({ drawImage(){}, getImageData: () => px, putImageData(){},
                           imageSmoothingEnabled: true, imageSmoothingQuality: '' }),
      toDataURL: () => 'data:image/png;base64,STUB' };
  };
  const out = JSON.parse(run(d, X.captchaExtractJs()));
  assert(out.variants.length === 3, `expected 3 OCR variants, got ${out.variants.length}`);
  return `dbg="${out.dbg}" → scores 4 (size 3 + wide 1) ≥ 3, so 3 canvases are rendered and 3 ML Kit OCR passes run on a decorative gif`;
});

check('J3-2', 'and the resulting junk read is written into any input matching [id*=captcha]', () => {
  const d = dom(`<input id="recaptcha_note" name="whatever">`);
  const r = run(d, X.fillCaptchaJs('X9Z2'));
  assert(r === 'true', 'expected the loose selector to match');
  assert(d.window.document.getElementById('recaptcha_note').value === 'X9Z2', 'value not written');
  return 'selector [id*="captcha" i] matched a non-captcha input and overwrote it';
});

// ── D1 ─ the creds gate that permanently abandons auto-submit ───────────────
check('C3-1', 'credsFilled returns "false" while the Keystore read is still in flight', () => {
  const d = dom(`<input name="AuthenticationFG.USER_PRINCIPAL">
                 <input name="AuthenticationFG.ACCESS_CODE" type="password">`);
  const r = run(d, X.credsFilledJs());
  assert(r === 'false', `expected "false", got "${r}"`);
  return 'empty fields → gate says false → _autofillCaptcha returns with NO retry scheduled';
});

console.log(`\n${pass} passed, ${fail} failed`);
require('fs').writeFileSync(__dirname + '/dom_results.json', JSON.stringify(results, null, 2));
process.exit(fail ? 1 : 0);
