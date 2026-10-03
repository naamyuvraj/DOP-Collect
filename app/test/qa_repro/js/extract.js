const fs = require('fs');
const ROOT = '/Users/yuvrajmandal/Desktop/papa';

const SYNC   = fs.readFileSync(ROOT + '/lib/screens/portal/sync_screen.dart', 'utf8');
const PORTAL = fs.readFileSync(ROOT + '/lib/data/portal/portal_sync.dart', 'utf8');

/** Pull the body of a Dart triple-quoted string that starts after `anchor`. */
function tripleQuoted(src, anchor) {
  const i = src.indexOf(anchor);
  if (i < 0) throw new Error('anchor not found: ' + anchor);
  const start = src.indexOf("'''", i);
  if (start < 0) throw new Error('no ``` after anchor: ' + anchor);
  const end = src.indexOf("'''", start + 3);
  if (end < 0) throw new Error('unterminated string after: ' + anchor);
  return src.slice(start + 3, end);
}

/** Substitute Dart `${...}` interpolations with supplied JS literals. */
function interp(js, map) {
  return js.replace(/\$\{([^}]*)\}/g, (m, expr) => {
    const key = expr.trim();
    if (!(key in map)) throw new Error('un-stubbed interpolation: ' + key);
    return map[key];
  });
}

module.exports = {
  SYNC, PORTAL, tripleQuoted, interp,
  captchaExtractJs: () => tripleQuoted(SYNC, '_captchaExtractJs'),
  fillCaptchaJs: (code) =>
    interp(tripleQuoted(SYNC, 'String _fillCaptchaJs('), {
      'jsonEncode(code)': JSON.stringify(code),
    }),
  loginJs: () => tripleQuoted(SYNC, 'static const _loginJs'),
  credsFilledJs: () => tripleQuoted(SYNC, 'static const _credsFilledJs'),
  clickLinkByTextJs: (needles) =>
    interp(tripleQuoted(PORTAL, 'Future<bool> _clickLinkByText('), {
      'jsonEncode(needles)': JSON.stringify(needles),
    }),
  clickSelectorJs: (sel) =>
    interp(tripleQuoted(PORTAL, 'Future<bool> _clickSelector('), {
      'jsonEncode(selector)': JSON.stringify(sel),
    }),
  ENQUIRE_NEEDLES: [
    'agent enquire & update',
    'enquire & update',
    'enquire and update',
    'update screen',
  ],
};
