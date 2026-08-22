# tool/

## `mock_portal.py` — the DOP portal, replayed locally

A stand-in for `dopagent.indiapost.gov.in`, served from the captures in
`recon/live/`. It exists because **every sync defect in this project's history
has been navigation timing, not parsing** — a click the portal dropped, a
page-finish that fired before the DOM changed, a screen misread as a failure.
None of that reproduces against a string of HTML in a unit test, because none of
it is about the HTML. It needs a real browser issuing real navigations.

This gives us that without touching a live banking session, and without
spending one of Finacle's ten login attempts.

```bash
python3 tool/mock_portal.py            # http://localhost:8799
flutter test integration_test/portal_sync_mock_test.dart -d <emulator>
```

The Android emulator reaches the host loopback at **10.0.2.2**. Cleartext to it
is permitted by `android/app/src/debug/res/xml/network_security_config.xml`,
which is a **debug-only overlay** — the release policy in `src/main` still
forbids cleartext everywhere and trusts system CAs only.

### What it is faithful about

The DOM. Every page is the captured byte stream with only the link targets
rewritten, so the real two-hop menu, the Finacle element ids, the `type="Submit"`
pagination, the five-minute `sessionTimeout` field and the double-post banner
are all exactly as the portal serves them.

The screen graph it walks is the one the captures proved:

```
login → dashboard(RMDashboard) → accounts_home(AgentAccountHomePage) → list
             #Accounts                  Enquire link appears only here
```

### What it is NOT faithful about

- **Pages 2–48 are synthesised** from the page-1 capture by renumbering. The
  real portal was only ever captured on page 1, so anything this proves about
  page 30 is proof about the *walk*, not about the portal's markup that deep.
- **No real timing.** It answers instantly; the real portal does not. Click
  *counts* are structural and transfer; wall-clock numbers do not.
- **No transaction tokens.** It never actually rejects a replayed `bwayparam`,
  so it cannot prove what does or does not poison a real session — only that we
  no longer send the traffic that we believe poisons it.
- **Login accepts anything.**

### Customer data

Account numbers and names are replaced with synthetic values on the way out.
The captures hold a real Agent ID and real customers; none of that needs to
reach the emulator to test navigation, so none of it does. `recon/live/` is
git-ignored and must stay that way.

### Driving a scenario

| Endpoint | Effect |
|---|---|
| `GET /__reset` | back to the login page, faults cleared |
| `GET /__arm?fault=expire&at=N` | serve "Session is Expired" when leaving list page N |
| `GET /__arm?fault=busy&at=N` | render page N under the double-post banner |
| `GET /__arm?fault=drop&at=N` | silently swallow the click that leaves page N |
| `GET /__state` | JSON: current screen, page, and per-control click counts |

`/__state`'s click counters are the useful part: they let a test assert on what
the portal *received* rather than on what the engine believes it sent. For the
keep-alive fix in particular that distinction is the whole point — the engine
reporting that it declined is not evidence; the portal never seeing the post is.
