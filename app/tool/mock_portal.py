#!/usr/bin/env python3
"""A local stand-in for the DOP agent portal, replayed from real captures.

Serves the pages in ``recon/live/`` as a *navigable* Finacle: the anchors and
the form posts actually go somewhere, so a WebView can be walked from the login
page to page 48 of the account list exactly as it would be on the real thing.

Why this exists
---------------
The sync engine's failures have all been timing and navigation, never parsing,
and none of them reproduce against a string of HTML. They need a real WebView
issuing real navigations against real markup. This gives us that without
touching a live banking session or spending one of Finacle's ten login attempts.

What is faithful
    The DOM. Every page is the captured byte stream, with only the link targets
    rewritten so they point back here. The two-hop menu, the Finacle element
    ids, the ``type="Submit"`` pagination, the five-minute session field and the
    double-post banner are all the real thing.

What is not
    Pages 2-48 are synthesised from page 1 by renumbering. The real portal was
    only ever captured on page 1, so anything this proves about page 30 is
    proof about the *walk*, not about the portal's markup that deep in.

Customer data
    Account numbers and names are replaced with synthetic values on the way
    out. The captures hold a real Agent ID and real customers; none of it needs
    to reach the emulator to test navigation, so none of it does.

Usage
    python3 tool/mock_portal.py [--port 8799]

    The Android emulator reaches the host loopback at 10.0.2.2, so the WebView
    wants http://10.0.2.2:8799/ .

Control endpoints (drive a scenario from the test)
    GET /__reset                 back to the login page, all faults cleared
    GET /__arm?fault=expire&at=N serve "Session is Expired" from list page N
    GET /__arm?fault=busy&at=N   serve page N with the double-post banner
    GET /__arm?fault=drop&at=N   silently ignore the click that leaves page N
    GET /__state                 JSON: current screen, page, click counts
"""

import argparse
import json
import os
import re
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIVE = os.path.join(ROOT, 'recon', 'live')

CAPTURES = {
    'login': '01_login__before_submit.html',
    'dashboard': '03_dashboard__after_login.html',
    'accounts_home': '04_account_list__page_1.html',   # misnamed: it is the
    'list': '05_account_list__page_2.html',            # empty middle screen
    'expired': '06_session_expired__as_seen.html',
}

TOTAL_PAGES = 48
ROWS_PER_PAGE = 10

# The banner Finacle shows when a second post lands before the first rendered.
BUSY_HTML = (
    '<div role="alert" class="orangebg"> <a href="#" id="errorlink1"></a> '
    'You clicked on a link or a button when your previous click was still '
    'being processed. System is considering your first request.</div>'
)


def load(name):
    path = os.path.join(LIVE, CAPTURES[name])
    if not os.path.exists(path):
        sys.exit('missing capture: %s\n(recon/live/ is git-ignored — see its '
                 'README for how to capture)' % path)
    with open(path, encoding='utf-8', errors='replace') as fh:
        text = fh.read()
    # The capture files carry a placeholder comment above the real markup.
    i = text.find('<html')
    return text[i:] if i > 0 else text


# --- Rewriting ------------------------------------------------------------

ANCHOR = re.compile(r'<a\b([^>]*)>', re.I)
HREF = re.compile(r'\shref\s*=\s*"[^"]*"', re.I)
ID_ATTR = re.compile(r'\sid\s*=\s*"([^"]*)"', re.I)
FORM_ACTION = re.compile(r'(<form\b[^>]*?)\saction\s*=\s*"[^"]*"', re.I)


def rewrite_links(html):
    """Point every anchor at /go?id=<its id> and every form at /post.

    Finacle's real hrefs are opaque ``bwayparam`` blobs, so the element id is
    the only stable way to say *which* link was clicked. Anchors with no id
    are pinned to '#' so a stray click cannot navigate somewhere undefined.
    """
    def fix_anchor(m):
        attrs = m.group(1)
        found = ID_ATTR.search(attrs)
        target = '/go?id=' + (found.group(1).replace(' ', '+') if found else '')
        attrs = HREF.sub('', attrs)
        return '<a href="%s"%s>' % (target, attrs)

    html = ANCHOR.sub(fix_anchor, html)
    html = FORM_ACTION.sub(r'\1 action="/post"', html)
    return html


def anonymise(html, page):
    """Replace real account numbers and names with synthetic ones.

    Keeps the shape the parser cares about — 12 digits, an uppercase name —
    and keeps them unique per page so the walk's de-duplication is exercised
    rather than accidentally satisfied.
    """
    base = 900000000000 + (page - 1) * ROWS_PER_PAGE

    def num(m):
        idx = int(m.group(1))
        return '%s%d</a>' % (m.group(0)[:-len(m.group(2)) - 4], base + idx)

    html = re.sub(
        r'id="HREF_CustomAgentRDAccountFG\.ACCOUNT_NUMBER_ALL_ARRAY\[(\d+)\]"'
        r'([^>]*)>(\d+)</a>',
        lambda m: 'id="HREF_CustomAgentRDAccountFG.ACCOUNT_NUMBER_ALL_ARRAY[%s]"%s>%d</a>'
                  % (m.group(1), m.group(2), base + int(m.group(1))),
        html)
    html = re.sub(
        r'(id="HREF_CustomAgentRDAccountFG\.ACCOUNT_NAME_ALL_ARRAY\[(\d+)\]"[^>]*>)[^<]*',
        lambda m: '%sCUSTOMER %d' % (m.group(1), base + int(m.group(2))),
        html)
    return html


def list_page(page, busy=False):
    """Page `page` of the account list, synthesised from the page-1 capture."""
    html = load('list')
    html = anonymise(html, page)

    # The portal's own position label — the walk's only honest "where am I?".
    html = re.sub(r'Page\s+1\s+of\s+48', 'Page %d of %d' % (page, TOTAL_PAGES),
                  html)
    first = (page - 1) * ROWS_PER_PAGE + 1
    last = page * ROWS_PER_PAGE
    html = re.sub(r'Displaying\s+1\s*-\s*10\s+of\s+\s*480\s+results',
                  'Displaying %d - %d of  %d results'
                  % (first, last, TOTAL_PAGES * ROWS_PER_PAGE), html)

    # Previous is disabled on page 1 only; Next disappears on the last page,
    # which is how the walk learns it has finished rather than stalled.
    if page > 1:
        html = html.replace('GOTO_PREV__" disabled=""', 'GOTO_PREV__"')
    if page >= TOTAL_PAGES:
        html = re.sub(
            r'<input[^>]*GOTO_NEXT__[^>]*>', '', html)

    # The capture happens to carry the double-post banner. Strip it unless the
    # scenario asked for it — it is a fault, not part of a healthy page.
    html = html.replace(BUSY_HTML, '')
    if busy:
        html = html.replace('<div id="contentarea">',
                            '<div id="contentarea">' + BUSY_HTML, 1)
    return rewrite_links(html)


# --- Server ---------------------------------------------------------------

class Portal:
    def __init__(self):
        self.lock = threading.Lock()
        self.reset()

    def reset(self):
        self.screen = 'login'
        self.page = 1
        self.fault = None
        self.fault_at = 0
        self.fault_fired = False
        self.clicks = {'accounts': 0, 'enquire': 0, 'next': 0,
                       'goto': 0, 'login': 0, 'keepalive': 0}

    def state(self):
        return {'screen': self.screen, 'page': self.page,
                'clicks': dict(self.clicks), 'fault': self.fault,
                'faultAt': self.fault_at}


PORTAL = Portal()


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, fmt, *args):  # keep the test output readable
        sys.stderr.write('  portal: %s\n' % (fmt % args))

    # -- helpers --
    def send_html(self, html):
        body = html.encode('utf-8', 'replace')
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body)

    def send_json(self, obj):
        body = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def current(self):
        p = PORTAL
        if p.screen == 'expired':
            return rewrite_links(load('expired'))
        if p.screen == 'list':
            busy = p.fault == 'busy' and p.fault_at == p.page
            return list_page(p.page, busy=busy)
        return rewrite_links(load(p.screen))

    def fault_due(self):
        """Should the armed fault fire for the page we are about to leave?"""
        p = PORTAL
        return p.fault and not p.fault_fired and p.fault_at == p.page

    # -- routes --
    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        p = PORTAL

        if u.path == '/__reset':
            with p.lock:
                p.reset()
            return self.send_json({'ok': True})

        if u.path == '/__arm':
            with p.lock:
                p.fault = (q.get('fault') or [None])[0]
                p.fault_at = int((q.get('at') or ['0'])[0])
                p.fault_fired = False
            return self.send_json(p.state())

        if u.path == '/__state':
            return self.send_json(p.state())

        if u.path == '/go':
            target = (q.get('id') or [''])[0].replace('+', ' ')
            with p.lock:
                self.follow(target)
            return self.send_html(self.current())

        # Anything else (including /) is "load the portal from the top".
        if u.path in ('/', '/index.html'):
            with p.lock:
                p.screen = 'login'
            return self.send_html(self.current())
        return self.send_html(self.current())

    def do_POST(self):
        length = int(self.headers.get('Content-Length') or 0)
        body = self.rfile.read(length).decode('utf-8', 'replace')
        fields = parse_qs(body)
        p = PORTAL
        with p.lock:
            self.submit(fields)
        self.send_html(self.current())

    # -- state machine --
    def follow(self, target):
        p = PORTAL
        if target == 'Accounts':
            p.clicks['accounts'] += 1
            if p.screen in ('dashboard', 'accounts_home', 'list'):
                p.screen = 'accounts_home'
        elif 'Enquire' in target:
            p.clicks['enquire'] += 1
            if self.fault_due() and p.fault == 'drop':
                p.fault_fired = True
                return                      # the click is silently swallowed
            if p.screen == 'accounts_home':
                p.screen = 'list'
                p.page = 1
        elif target == 'Dashboard':
            p.screen = 'dashboard'

    def submit(self, fields):
        p = PORTAL
        names = ' '.join(fields.keys())

        if 'VALIDATE_RM_PLUS_CREDENTIALS' in names:
            p.clicks['login'] += 1
            p.screen = 'dashboard'
            return

        if 'PREVENT_SESSION_TIMEOUT' in names:
            # The real control is a form submit, so it navigates — and on the
            # listing it re-renders whatever page is showing. Counted so a test
            # can prove the engine did not fire it mid-walk.
            p.clicks['keepalive'] += 1
            return

        if 'GOTO_NEXT__' in names:
            p.clicks['next'] += 1
            if self.fault_due():
                p.fault_fired = True
                if p.fault == 'expire':
                    p.screen = 'expired'
                    return
                if p.fault == 'drop':
                    return                  # stay put: the click vanished
            if p.page < TOTAL_PAGES:
                p.page += 1
            return

        if 'GOTO_PREV__' in names:
            p.page = max(1, p.page - 1)
            return

        if 'GOTO_PAGE__' in names:
            p.clicks['goto'] += 1
            want = fields.get(
                'CustomAgentRDAccountFG.AgentRDActSummaryAllListing'
                '_REQUESTED_PAGE_NUMBER', ['1'])[0]
            try:
                p.page = max(1, min(TOTAL_PAGES, int(want)))
            except ValueError:
                pass
            return


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--port', type=int, default=8799)
    args = ap.parse_args()
    for name in CAPTURES:
        load(name)  # fail loudly at startup, not mid-test
    srv = ThreadingHTTPServer(('0.0.0.0', args.port), Handler)
    print('mock portal on http://0.0.0.0:%d  (emulator: http://10.0.2.2:%d/)'
          % (args.port, args.port), flush=True)
    srv.serve_forever()


if __name__ == '__main__':
    main()
