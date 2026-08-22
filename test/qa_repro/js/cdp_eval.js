// Evaluate an expression in the live Android WebView via the DevTools protocol.
//   adb forward tcp:9222 localabstract:webview_devtools_remote_<pid>
//   node cdp_eval.js "<js expression>"
const WebSocket = require('ws');

(async () => {
  const targets = await (await fetch('http://localhost:9222/json')).json();
  const page = targets.find(t => t.type === 'page');
  if (!page) { console.error('no page target'); process.exit(1); }
  const ws = new WebSocket(page.webSocketDebuggerUrl, {
    perMessageDeflate: false, maxPayload: 64 * 1024 * 1024,
  });
  const expr = process.argv[2];
  ws.on('open', () => ws.send(JSON.stringify({
    id: 1, method: 'Runtime.evaluate',
    params: { expression: expr, returnByValue: true, awaitPromise: true },
  })));
  ws.on('message', (buf) => {
    const msg = JSON.parse(buf.toString());
    if (msg.id !== 1) return;
    const r = msg.result && msg.result.result;
    if (msg.result && msg.result.exceptionDetails) {
      console.error('JS threw:', JSON.stringify(msg.result.exceptionDetails.text));
    }
    console.log(typeof r?.value === 'string' ? r.value : JSON.stringify(r?.value, null, 2));
    ws.close(); process.exit(0);
  });
  ws.on('error', (e) => { console.error('ws error', e.message); process.exit(1); });
})();
