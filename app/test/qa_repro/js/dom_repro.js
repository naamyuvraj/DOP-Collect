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
// Both J1 tests are INVERTED: they used to assert the defect (no key events, no
// focus). The fill now focuses the field and fires keydown/keypress/keyup, so
// these assert the fixed behaviour instead.
check('J1-1', 'captcha fill focuses the field and fires real key events', () => {
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
  assert(seen.includes('keydown') && seen.includes('keypress') && seen.includes('keyup'),
         `REGRESSION: key events missing — dispatched [${seen}]`);
  assert(focused, 'REGRESSION: the field was not focused');
  // Order matters to a handler that reads .value on keyup.
  assert(seen.indexOf('keydown') < seen.indexOf('input'),
         `REGRESSION: keydown must precede input — got [${seen}]`);
  assert(seen.indexOf('input') < seen.indexOf('keyup'),
         `REGRESSION: input must precede keyup — got [${seen}]`);
  return `focused, dispatched [${seen}] — a portal handler bound to keypress/keydown, or one that requires focus, now runs`;
});

check('J1-2', 'a portal that enables Login on keypress is enabled by our fill', () => {
  const d = dom(`<input name="AuthenticationFG.VERIFICATION_CODE" id="cap">
                 <input type="submit" name="AuthenticationFG.VALIDATE_CREDENTIALS" value="Log in" disabled>`);
  const w = d.window;
  // Realistic Finacle-style gate: button enables only on a key event.
  w.document.getElementById('cap').addEventListener('keypress', function () {
    w.document.querySelector('[name*="VALIDATE_CREDENTIALS"]').disabled = false;
  });
  run(d, X.fillCaptchaJs('A1B2C'));
  const clicked = run(d, X.loginJs());
  assert(clicked === 'true', `REGRESSION: login click returned "${clicked}" — the keypress gate never opened`);
  return 'the keypress handler ran, the button enabled, and _loginJs clicked it on the first poll';
});

// ── D6 (FIXED) ─ what the captcha scorer will and will not send to OCR ──────
// Both J3 tests are INVERTED. The acceptance threshold went from 3 to 5, so
// size alone (3 captcha-sized + 1 wide = 4) is no longer enough: an image needs
// a name that says captcha, or a position beside the verification box.

// jsdom has no 2D context without the `canvas` package.
function stubCanvas(w) {
  const realCreate = w.document.createElement.bind(w.document);
  w.document.createElement = (tag) => {
    if (tag !== 'canvas') return realCreate(tag);
    const px = { data: new Uint8ClampedArray(4 * 64) };
    return { width: 0, height: 0,
      getContext: () => ({ drawImage(){}, getImageData: () => px, putImageData(){},
                           imageSmoothingEnabled: true, imageSmoothingQuality: '' }),
      toDataURL: () => 'data:image/png;base64,STUB' };
  };
}
function sized(w, id, width, height) {
  const img = w.document.getElementById(id);
  Object.defineProperty(img, 'complete', { value: true });
  Object.defineProperty(img, 'naturalWidth', { value: width });
  Object.defineProperty(img, 'naturalHeight', { value: height });
  return img;
}

check('J3-1', 'a 120x22 spacer/banner gif is NOT sent to OCR on its shape alone', () => {
  const d = dom(`<img id="spacer" src="/img/hdr_bar.gif" width="120" height="22">`);
  stubCanvas(d.window);
  sized(d.window, 'spacer', 120, 22);
  const out = JSON.parse(run(d, X.captchaExtractJs()));
  assert(out.variants.length === 0,
         `REGRESSION: ${out.variants.length} OCR variants for a spacer gif — dbg="${out.dbg}"`);
  return `dbg="${out.dbg}" → scores 4 (size 3 + wide 1) < 5, so no canvas is rendered and no ML Kit pass runs`;
});

check('J3-1b', 'the REAL portal captcha is still picked, by name and by position', () => {
  // The live DOM: IMAGECAPTCHA next to the verification box, with the portal's
  // own reset.jpg refresh icon beside it at almost the same size.
  const d = dom(`<table><tr>
      <td><img id="IMAGECAPTCHA" src="AuthenticationController;jsessionid=x"
               alt="Please Click On The Icon Next For Audio"></td>
      <td><img id="TEXTIMAGE" src="L001/bankuser/images/reset.jpg"
               alt="Click here to Change Image"></td>
      <td><input name="AuthenticationFG.VERIFICATION_CODE" id="vc"></td>
    </tr></table>`);
  stubCanvas(d.window);
  sized(d.window, 'IMAGECAPTCHA', 120, 22);
  sized(d.window, 'TEXTIMAGE', 100, 20);
  const out = JSON.parse(run(d, X.captchaExtractJs()));
  assert(out.variants.length === 3,
         `REGRESSION: the real captcha was not read — dbg="${out.dbg}"`);
  assert(/used 120x22/.test(out.dbg),
         `REGRESSION: picked the wrong image — dbg="${out.dbg}"`);
  return `dbg="${out.dbg}" → the refresh icon is beside the box too, but "reset" scores -6 and loses to IMAGECAPTCHA`;
});

check('J3-1c', 'an unnamed captcha beside the verification box still qualifies', () => {
  // Proximity alone must carry it, or a deployment that renames the image
  // silently drops the agent back to typing it himself.
  const d = dom(`<table><tr>
      <td><img id="x7" src="/servlet/img?tok=99"></td>
      <td><input name="AuthenticationFG.VERIFICATION_CODE" id="vc"></td>
    </tr></table>`);
  stubCanvas(d.window);
  sized(d.window, 'x7', 120, 22);
  const out = JSON.parse(run(d, X.captchaExtractJs()));
  assert(out.variants.length === 3,
         `REGRESSION: a nameless captcha next to the box was skipped — dbg="${out.dbg}"`);
  return `dbg="${out.dbg}" → 4 (near the field) + 3 (sized) + 1 (wide) = 8 ≥ 5`;
});

check('J3-2', 'an OCR read is never written into the reCAPTCHA token field', () => {
  // The real hazard, and a new one: `[id*="captcha" i]` matches
  // `#g-recaptcha-response`. Harmless while this portal had no reCAPTCHA.
  const d = dom(`<textarea id="g-recaptcha-response" name="g-recaptcha-response"></textarea>`);
  const r = run(d, X.fillCaptchaJs('X9Z2'));
  assert(r === 'false', `REGRESSION: fill reported "${r}" against the token field`);
  assert(d.window.document.getElementById('g-recaptcha-response').value === '',
         'REGRESSION: an OCR read was written into the reCAPTCHA token');
  return 'the token field is skipped by name, and it is not a text input either';
});

check('J3-2b', 'a genuine captcha input is still filled by the loose fallback', () => {
  const d = dom(`<input id="captchaCode" name="CAPTCHA_TEXT" type="text">`);
  const r = run(d, X.fillCaptchaJs('X9Z2'));
  assert(r === 'true', `expected the fallback to still match, got "${r}"`);
  assert(d.window.document.getElementById('captchaCode').value === 'X9Z2', 'value not written');
  return 'tightening the fallback did not break a deployment that renames the field';
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
