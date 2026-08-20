# DOM reproductions for the sync-login defects

These run the **real** JavaScript the app injects into the portal WebView — the
scripts are parsed straight out of `lib/screens/portal/sync_screen.dart` and
`lib/data/portal/portal_sync.dart` by `extract.js`, so the tests track the
shipping code and will break loudly if a script is renamed or restructured.

    npm init -y && npm install jsdom
    node dom_repro.js

Covers J1 (captcha fill fires no key events and never focuses), J2 (the Enquire
fallback clicks the wrapping `<td>`), J3 (the captcha scorer fires on pages with
no captcha) and C3-1 (the creds gate reports false while the Keystore read is
still in flight). All are expected to PASS today — each one *documents* a defect.
When a defect is fixed, its test here should be inverted to assert the new
behaviour.
