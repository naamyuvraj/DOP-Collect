// Walks tool/mock_portal.py using the sync engine's REAL injected scripts,
// pulled straight out of the Dart sources by extract.js. If a selector in
// portal_dom.dart ever stops matching the portal's markup, this breaks here.
//
//   python3 tool/mock_portal.py &
//   node test/qa_repro/js/walk_mock.js
const { JSDOM } = require('jsdom');
const fs = require('fs');
const path = require('path');

const BASE = process.env.MOCK_PORTAL || 'http://127.0.0.1:8799';
const ROOT = path.resolve(__dirname, '../../..');
const DART = fs.readFileSync(
  path.join(ROOT, 'lib/data/portal/portal_dom.dart'), 'utf8');

/** Pull a `static const x = '...'` selector out of portal_dom.dart. */
function sel(name) {
  const re = new RegExp(
    `static const ${name}\\s*=\\s*((?:r?'[^']*'\\s*)+);`, 'm');
  const m = DART.match(re);
  if (!m) throw new Error('selector not found in portal_dom.dart: ' + name);
  return [...m[1].matchAll(/r?'([^']*)'/g)].map(x => x[1]).join('');
}

const SEL = {
  accountsMenu: sel('accountsMenu'),
  enquireLink: sel('enquireLink'),
  nextButton: sel('nextButton'),
  loginButton: sel('loginButton'),
  rowAnchors: sel('rowAnchors'),
  pageLabel: sel('pageLabel'),
};

let cookie = '';
async function get(url) {
  const r = await fetch(url, { headers: cookie ? { cookie } : {} });
  return r.text();
}
async function post(url, body) {
  const r = await fetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body,
  });
  return r.text();
}

const dom = (html) => new JSDOM(html, { url: BASE + '/' });

/** Find the href the engine's selector would click, the way the DOM does. */
function hrefFor(html, selector) {
  const d = dom(html);
  const els = d.window.document.querySelectorAll(selector);
  for (const el of els) {
    if (el.disabled) continue;
    const a = el.closest('a') || el;
    if (a.getAttribute && a.getAttribute('href')) return a.getAttribute('href');
  }
  return null;
}

function classify(html) {
  if (/Session is Expired|Session Expired/.test(html)) return 'sessionExpired';
  if (html.includes('AuthenticationFG.ACCESS_CODE')) return 'login';
  if (/Page\s+\d+\s+of\s+\d+/i.test(html) && /account no/i.test(html)) return 'list';
  if (html.includes('AgentAccountHomePage')) return 'accountsHome';
  if (html.includes('RMDashboard') || html.includes('HREF_Accounts')) return 'dashboard';
  return 'unknown';
}

const pageOf = (h) => (h.match(/Page\s+(\d+)\s+of\s+(\d+)/i) || []).slice(1);

let failures = 0;
function step(label, ok, detail) {
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${label}${detail ? '\n        → ' + detail : ''}`);
  if (!ok) failures++;
}

(async () => {
  await get(`${BASE}/__reset`);

  let html = await get(`${BASE}/`);
  step('login page is recognised', classify(html) === 'login', classify(html));

  html = await post(`${BASE}/post`,
    'Action.VALIDATE_RM_PLUS_CREDENTIALS_CATCHA_DISABLED=Log+in');
  step('login lands on the dashboard', classify(html) === 'dashboard', classify(html));

  // The dashboard must NOT carry the Enquire link — that is the fact the old
  // engine got wrong, and the reason it burned clicks reaching for it.
  step('dashboard has no Enquire link (two-hop path)',
    hrefFor(html, SEL.enquireLink) === null,
    'portal_dom.enquireLink matched nothing on RMDashboard, as the capture says');

  let href = hrefFor(html, SEL.accountsMenu);
  step('portal_dom.accountsMenu finds the Accounts menu', !!href, href);
  html = await get(new URL(href, BASE + '/').href);
  step('Accounts opens the empty middle screen',
    classify(html) === 'accountsHome', classify(html));

  href = hrefFor(html, SEL.enquireLink);
  step('portal_dom.enquireLink finds Enquire once the menu is open', !!href, href);
  html = await get(new URL(href, BASE + '/').href);
  step('Enquire opens the account list', classify(html) === 'list',
    `${classify(html)} — ${pageOf(html).join(' of ')}`);

  const d0 = dom(html);
  const rows = d0.window.document.querySelectorAll(SEL.rowAnchors).length;
  step('portal_dom.rowAnchors finds the account rows', rows === 10, `${rows} rows`);
  const label = d0.window.document.querySelector(SEL.pageLabel);
  step('portal_dom.pageLabel finds "Page X of N"', !!label,
    label && label.textContent.trim());

  // Walk to the end using the engine's own Next selector, one click per page.
  let clicks = 0, page = 1;
  const total = Number(pageOf(html)[1]);
  while (page < total) {
    const d = dom(html);
    const els = [...d.window.document.querySelectorAll(SEL.nextButton)]
      .filter(e => !e.disabled);
    if (!els.length) break;
    clicks++;
    html = await post(`${BASE}/post`,
      encodeURIComponent(els[0].getAttribute('name')) + '=%3E');
    page = Number(pageOf(html)[0]);
  }
  step(`walked to page ${page} of ${total} in ${clicks} clicks`,
    page === total && clicks === total - 1,
    'one Next per transition, no re-clicks');

  // Last page must retract Next, so the walk ends rather than stalling.
  const last = [...dom(html).window.document.querySelectorAll(SEL.nextButton)]
    .filter(e => !e.disabled);
  step('Next is gone on the last page', last.length === 0,
    'the walk learns it finished instead of reporting a stall');

  const state = JSON.parse(await get(`${BASE}/__state`));
  step('portal received exactly one Accounts and one Enquire click',
    state.clicks.accounts === 1 && state.clicks.enquire === 1,
    JSON.stringify(state.clicks));

  console.log(`\n${failures ? failures + ' FAILED' : 'all steps passed'}`);
  process.exit(failures ? 1 : 0);
})();
