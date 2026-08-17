# Handoff — DOP Collect

Written 16-Aug-2026. State of play, what bites, and what is left.

## Where things stand

| | |
|---|---|
| Shorebird release | **1.0.0+31** — all patches attach to this |
| Latest patch | **Patch 6**, stable track |
| `buildVersion` | `1.0.0+39` (patch marker; `pubspec` stays at `1.0.0+31`) |
| Distributable APK | `~/Desktop/DOP-Collect-1.0.0.apk` — 75 MB, upload-signed |
| Tests | 429 passing, `flutter analyze` clean |
| `origin/main` | current except the last dashboard commit (see Outstanding) |

Signing: `android/upload-keystore.jks`, alias `upload`, SHA-256
`e9a34af8…e224`. The file is in Yuvraj's email; the password is in his password
manager. **Neither is recoverable.** Lose them and no future build can install
over an existing one — which wipes the `collections` ledger on every phone.

## The three things that will waste your time

**1. `shorebird` exits 0 on failure.** It did this on four failed downloads and
on a bad-flag run. Never trust `$?` — grep the output for `Published`:

```
cd /Users/yuvrajmandal/Desktop/papa
shorebird patch --platforms=android --release-version=1.0.0+31 -- \
  --dart-define-from-file=env.json --no-tree-shake-icons
```

`--flutter-version` is valid on `release` and **rejected by `patch`** (it prints
usage and exits 0). On `release`, always pass it — unpinned pulls the newest
Flutter and downloads a ~960 MB engine first.

**2. The connection is the bottleneck, not the code.** Measured 0.87–1.86 MB/s.
`shorebird patch` re-downloads the whole release bundle with a **60 s internal
timeout and no cache**, so five patch attempts failed before the bundle was
shrunk. Dropping `x86_64` took it 88.1 → 60.6 MB, which is what made patching
work at all. That exclusion lives in `android/app/build.gradle.kts` under
`packaging { jniLibs { excludes } }` — **not** `ndk.abiFilters` (Flutter injects
its `.so` files outside NDK packaging) and **not** `--target-platform` (Shorebird
injects its own, and a duplicate flag kills the build).

**3. `next build` cannot run locally.** Every `build/` directory inside
`dashboard/node_modules` is missing. `tsc --noEmit` works, and Vercel installs
fresh from the lockfile, so deploys are fine. Repair with
`cd dashboard && rm -rf node_modules && npm install`.

## Outstanding

- **Push the last dashboard commit** (`0cb9903` — logo + Payments KPI label).
  `git push origin HEAD:main && git push`.
- **Khata backup has never been exercised on a phone.** 14 tests cover the
  format; no restore has ever been performed. There is a *non-destructive* drill:
  tap Restore, pick the file, enter the password, read the entry count in the
  confirm dialog, then **Cancel** — nothing is written. That validates the file,
  the password, AES-GCM and the parse. Only a real Replace exercises the
  transaction write, so do that on a spare handset. Riskiest untested link is
  `file_picker` returning a content URI with no path when picking out of WhatsApp.
- **Dashboard UI/UX pass.** Not started. Highest-value targets noticed in
  passing: KPI rows are visually undifferentiated so nothing reads as *the*
  number; tables are uniformly dense with no alignment convention for numerics;
  empty states explain mechanics instead of naming the next action.
- **Batch submit has no auto-retry.** It now reports which lists failed and why,
  and separates "Pay All ran but no reference came back" in red because that one
  may already be paid. Retrying the safe failures needs the per-list work pulled
  into something re-runnable — worth doing, but do not do it carelessly around a
  live payment call.
- **`lots` has no `cycle_ym`.** `collections` stamps the cycle at collection
  time; `lots` does not, so two bugs grew in that gap (Downloads filing by
  `createdAt`, and the don't-list-twice guard doing the same). Both are fixed via
  a derived `Lot.filedAt`, but a stamped cycle would make a third bug of this
  shape impossible.

## Things that look wrong and are not

- **Rebate/default fee are blank on lists submitted before today.** Those figures
  are only readable on the portal's installment-entry screen and were never
  captured. The portal's own report leaves both columns empty, so they cannot be
  recovered — only new submissions carry them.
- **Payments tab shows fewer trials than Plans/Overview.** Payments reads
  `v_subscriptions` (real rows); the others include the trial `pay` derives
  without writing a row while `payments_enabled` is off. Labels now say which.
- **Short Code moves when the book grows.** It is a 1-based position in the
  portal listing and doubles as `serialHint` for page-jumping, so positional is
  correct. Invariants are pinned in `test/short_code_test.dart`.
- **Ghost device rows.** A reinstall no longer creates one (the id derives from
  ANDROID_ID). A change of **signing key** does, because ANDROID_ID is scoped per
  key — so the upload-keystore cutover gave every existing phone one new row.

## Deploy order that matters

`ingest` → dashboard → `admin/schema_one_name.sql`. The old `ingest` writes
`devices.name`; drop that column under it and every device upsert fails 42703,
silently taking `last_seen`, `mobile`, `agent_id` and `model` with it.

`admin/schema_devices_view.sql` must run after `schema.sql`,
`schema_accounts.sql`, `schema_regions.sql`, `schema_otp.sql`. Its column order
is load-bearing: `create or replace view` can only **append**.

RUNBOOK.md is current and covers the rest.
