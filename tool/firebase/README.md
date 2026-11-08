# Firebase build & deploy (P12)

How to build Material Lab against a real Firebase project, and how to publish the
Firestore rules and indexes. The current synchronization policy is [SYNC_CURRENT_CONTRACT.md](../../SYNC_CURRENT_CONTRACT.md).

---

## 1) Where the configuration comes from

`lib/core/firebase/firebase_options.dart` resolves the config in this order:

1. `--dart-define` flags — **use these for every release build.**
2. `assets/firebase/firebase.local.json` — a developer machine convenience only.
   This file is git-ignored; never ship it.
3. Nothing — `FirebaseConfig.isConfigured` is `false` and the app shows the
   configuration screen instead of crashing before `runApp`.

### Keys

| Key | Required | Source in the Firebase console |
|---|---|---|
| `FIREBASE_API_KEY` | yes | Project settings → Your apps → Web/Windows → API key |
| `FIREBASE_APP_ID` | yes | same → App ID |
| `FIREBASE_MESSAGING_SENDER_ID` | yes | same → Messaging sender ID |
| `FIREBASE_PROJECT_ID` | yes | same → Project ID |
| `FIREBASE_AUTH_DOMAIN` | yes | same → Authoritative domain |
| `FIREBASE_STORAGE_BUCKET` | no | same → Storage bucket |
| `GOOGLE_DESKTOP_CLIENT_ID` | no¹ | Google Cloud console → Credentials → **Desktop app** client ID |
| `GOOGLE_WEB_CLIENT_ID` | no² | legacy fallback; a Web client cannot complete the loopback flow |

¹ Required for the Google sign-in button to work on Windows. Without it the app
still starts; `FirebaseConfig.hasGoogleClientId` is `false` and the login screen
says so instead of failing at the popup. See §5.

² Read only when `GOOGLE_DESKTOP_CLIENT_ID` is empty. See the client-type table
in §5 before using it.

---

## 2) Local development (staging emulator)

`firebase.json` already pins the emulator hosts, and `.firebaserc` points at
`materiallab-63405`. The security suite must run against the emulator, never
against production:

```powershell
flutter analyze
flutter test
firebase emulators:exec --only firestore,auth --project demo-materiallab "flutter test test/security"
```

`--project demo-materiallab` is the `demo-` prefix that stops the emulators from
ever talking to a real project.

---

## 3) Release builds

Set the keys once per shell session, then build:

```powershell
$env:FIREBASE_API_KEY             = "AIza..."
$env:FIREBASE_APP_ID              = "1:1234567890:windows:abc123"
$env:FIREBASE_MESSAGING_SENDER_ID = "1234567890"
$env:FIREBASE_PROJECT_ID          = "materiallab-63405"
$env:FIREBASE_AUTH_DOMAIN         = "materiallab-63405.firebaseapp.com"
$env:FIREBASE_STORAGE_BUCKET      = "materiallab-63405.firebasestorage.app"
$env:GOOGLE_DESKTOP_CLIENT_ID      = "1234567890-abcdef.apps.googleusercontent.com"

flutter build windows --release `
  --dart-define=FIREBASE_API_KEY=$env:FIREBASE_API_KEY `
  --dart-define=FIREBASE_APP_ID=$env:FIREBASE_APP_ID `
  --dart-define=FIREBASE_MESSAGING_SENDER_ID=$env:FIREBASE_MESSAGING_SENDER_ID `
  --dart-define=FIREBASE_PROJECT_ID=$env:FIREBASE_PROJECT_ID `
  --dart-define=FIREBASE_AUTH_DOMAIN=$env:FIREBASE_AUTH_DOMAIN `
  --dart-define=FIREBASE_STORAGE_BUCKET=$env:FIREBASE_STORAGE_BUCKET `
  --dart-define=GOOGLE_DESKTOP_CLIENT_ID=$env:GOOGLE_DESKTOP_CLIENT_ID
```

Output: `build/windows/x64/runner/Release/material_lab.exe` (plus the DLLs
beside it — ship the whole folder).

`--dart-define` values are compiled into the binary. The API key is not a
secret, but do not reuse a key across projects you do not control.

---

### Android production signing on this machine

Run `powershell -NoProfile -File tool/firebase/create_android_signing.ps1` in an
interactive terminal. Enter the certificate identity, password, and an external
backup folder locally. The script never overwrites an existing `android/key.properties`,
creates an access-restricted PKCS12/RSA-3072 key with a 10,000-day certificate,
verifies a separate keystore backup, and writes SHA-1/SHA-256 to
`output/android-production-signing.json`. Keep the password in your password manager.

Gradle reads ignored `android/key.properties` first, with the former
`F:/material lab/key.properties` location retained as a fallback. Release tasks
fail when signing credentials are missing; they never silently use a debug key.
Keys and credentials must stay out of Git. Do not paste passwords into chat or logs.

Add both certificate fingerprints to the existing Firebase Android app for
`com.materiallab`; retain existing fingerprints for existing installations.
A different signing identity cannot normally update the installed APK in place.
Never uninstall or clear app storage as a workaround: that can destroy local
drafts and unresolved operation evidence. For Play distribution, also register
the Play app-signing certificate, which may differ from the upload certificate.

## 4) Deploying the rules and indexes

**Always deploy to staging first, run the emulator suite against a real project
copy, and only then to production.**

```powershell
# staging: a separate Firebase project used for conflict testing
firebase use <staging-project-id>
firebase deploy --only firestore:rules,firestore:indexes

# production, after staging is verified
firebase use materiallab-63405
firebase deploy --only firestore:rules,firestore:indexes
```

A rules deployment is a **security change**: it takes effect for every client
immediately, including already-installed desktop apps. So:

- [ ] `flutter analyze` → 0 issues
- [ ] `flutter test` → all green
- [ ] `flutter test test/security` against the emulator → all green
- [ ] Read the diff of `firestore.rules` yourself. R4 in §16 of the plan: a
      wrong rules file is the one bug that leaks data between organizations.
- [ ] The file ends with a catch-all `allow: if false`.

To roll back, redeploy the previous `firestore.rules`.

Keep this project on Spark without linking a billing account or deploying
Functions. A billing budget is an alert, not a spending cap; it is not a reason
to activate billing for this application. The current direct reader checks the
server head every 30 seconds in the foreground, reads changed records in pages,
and stops after quota exhaustion until an explicit manual request.

---

## 5) Google sign-in setup

The Windows build uses the **loopback** OAuth flow, and that dictates the client
type. Get this wrong and the browser shows `400: redirect_uri_mismatch`.

1. Firebase console → Authentication → Sign-in method → enable **Google**.
2. Google Cloud console → OAuth consent screen: add the desktop app e-mail as a
   test user while the app is in staging.
3. Google Cloud console → Credentials → **Create credentials → OAuth client ID →
   Application type: `Desktop app`**. Name it (e.g. `Material Lab Windows`).
4. Add the **loopback** redirect URI to *that client's* Authorized redirect URIs:

   ```
   http://127.0.0.1
   ```

   No port, no trailing slash. `http://localhost` is also safe to add. The app
   asks for a random port at runtime — `google_sign_in_dartio` calls
   `HttpServer.bind(loopbackIPv4, 0)` and sends `http://127.0.0.1:<port>` as
   `redirect_uri` (`token_sign_in.dart:29-31,49`).
5. Copy the **Desktop app** client id (it ends in `.apps.googleusercontent.com`)
   into `GOOGLE_DESKTOP_CLIENT_ID`.

### Why the client type must be `Desktop app`

Google ignores the **port** when matching a loopback redirect URI — but only for
`Desktop app` clients. Per
[RFC 8252 §7.3](https://datacker.ietf.org/doc/html/rfc8252#section-7.3), and
[Google's own loopback policy](https://developers.google.com/identity/protocols/oauth2/resources/loopback-migration),
the authorization server "must ignore the port number component when comparing
the specified redirection URI to pre-registered ones" for loopback hosts.

A **Web application** client is excluded: it is matched byte-for-byte, so
`http://127.0.0.1:52476` never equals the registered `http://127.0.0.1`. No choice
of registered URI can fix that, and the error appears in the browser tab, not in
the app — the Dart side simply never receives a callback.

| Client type          | Loopback + random port |
|----------------------|-----------------------|
| `Desktop app`        | works (port ignored)  |
| `Web application`    | `redirect_uri_mismatch` |

`GOOGLE_WEB_CLIENT_ID` is still read as a fallback so older invocations resolve,
but a Web client id cannot complete the loopback flow.

Without step 1 the Google provider exists but rejects the sign-in; the app shows
the error rather than looping. Credential changes take a few minutes to propagate.

---

## 6) Current release policy

Firebase Auth and direct Firestore transactions are the runtime path. Protocol
3 permits multiple registered authorized writers and read-only viewers. Auth,
membership, role, device state, expected versions and atomic receipts remain
independently enforced by Firestore rules. Device IDs do not replace Auth.

Offline work remains an unsent draft until explicitly submitted. A submitted
request recovers its original operation ID after a lost reply. No legacy queue
or seed data is uploaded on session startup.

Unclassified and mixed operations permit **4 business effects**. Proven scoped
families have separate limits: custom-table definitions **10 effects / 9
columns**, analysis definitions up to **6 effects**, laboratory results with
stock consumption up to **10 effects**, and one existing product with its
existing reference updates up to **7 effects**. Simple configuration/record
families use a calculated bound up to **12 effects**. Eleven/twelve-effect
operations include one immutable proof so that the change event and proof each
stay within the per-write read limit. Twelve images + seven shared lookups +
one proof use the whole twenty-call atomic budget. Uniqueness reservations and
external parents lower that bound (for example, six new unique parameters).
An analysis can pack up to **36 chemical definitions** across nine four-entry
proof blocks when the distinct inventory references fit the same budget;
36 arbitrary different inventory parents cannot fit. Distinct parents, lots and
chemical proofs can lower these limits. The Dart admission calculation and
Firestore Rules both enforce the applicable family. Larger operations stay
unsent drafts with submission disabled; they are never split or partly saved.
Every supported operation still needs its own rule and acceptance evidence.

These are atomic-operation limits, separate from the Standard database's Spark
quota: **50,000 reads, 20,000 writes and 20,000 deletes per day**, **1 GiB stored**
and **10 GiB outbound per month**, shared across all applications/devices in the
project. Receipts, events, counters, audit records, reservations and security-rule
document reads also consume quota; a business save is not one billed write.
Daily quota resets around midnight Pacific time. Emulator usage counters are
diagnostic estimates and exclude billed internal rule/index reads; they do not
prove that an arbitrary production workload fits the daily quota. See the
[official limits](https://firebase.google.com/docs/firestore/quotas) and
[billing calculation](https://firebase.google.com/docs/firestore/pricing).

Deleting a local organization cache triggers a permission-scoped archive
download. Pages use one Firestore read time, and cache plus cursor install
atomically. A missing server sequence/protocol or malformed record blocks
readiness explicitly; never repair this by opening rules or uploading local data.
Foreground refresh runs every 30 seconds and on reconnect/resume. Background
business polling and remote push delivery are not required or enabled.

Trials and suspension are enforced by Firestore rules using server time, with
the client gate providing UI feedback. There is no scheduled expiry function.
Administrative activation and data migrations require their own reviewed path.

Production acceptance, migration and rollback requirements are in the
[current contract](../../SYNC_CURRENT_CONTRACT.md). Do not infer a live
deployment or a successful release build from these instructions.

---

## 7) Build environment

### The C++ toolchain must be new enough for the Firebase SDK

`firebase_core 4.15.0` pins **Firebase C++ SDK 13.12.0** (a 2025 build). Its
prebuilt Windows libraries are compiled against a 2025-era MSVC Standard
Library, and they reference internals such as
`__std_find_first_of_trivial_pos_1`, `__std_search_1`, `__std_remove_8` and
`_Avx2WmemEnabled`.

If your Visual Studio is older than that, the link fails with:

```
LNK2019: unresolved external symbol __std_find_first_of_trivial_pos_1
LNK2019: unresolved external symbol __std_find_last_of_trivial_pos_1
LNK2019: unresolved external symbol __std_search_1
LNK2019: unresolved external symbol __std_find_end_1
LNK2019: unresolved external symbol __std_remove_8
LNK2019: unresolved external symbol _Avx2WmemEnabled
fatal error LNK1120: 6 unresolved externals
```

**Verified fix:** update Visual Studio 2022. VS **17.12.1** (MSVC 14.42) failed;
**17.14** (MSVC `14.44.35207`) builds `material_lab.exe` cleanly.

The symbols come from `msvcprt.lib` / `libcpmt.lib` — note that current
toolsets have **no `msvcp140.lib`** at all, so do not go looking for that file
when diagnosing this. Check the toolset version instead:

```powershell
Get-ChildItem "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC" -Directory
```

To update (Administrator required, ~20 min, several GB):

```powershell
$setup = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\setup.exe"
Start-Process -FilePath $setup -Verb RunAs -ArgumentList @(
  'update',
  '--installPath','"C:\Program Files\Microsoft Visual Studio\2022\Community"',
  '--quiet','--norestart'
)
```

Two traps that cost time here:

- `setup.exe` **must be launched elevated from the start** — running
  `--quiet` from a non-elevated shell fails with exit code 5007
  ("should be run elevated from the beginning").
- The `--installPath` value **must keep its quotes**. Without them the
  installer receives `--installPath C:\Program` and dies with
  `Error 0x80131509: No instance found for path C:\Program`.
- There is no `--wait` option; `setup.exe` returns immediately and the real
  work continues in the background. Poll for it instead of assuming failure.

Do **not** work around this by forcing `MSVC_RUNTIME_MODE=MT`: that was tried
and made it worse (12 unresolved externals instead of 6).

### Remaining blockers

- **Cloudflare R2 delivery** of the exe to the landing page needs the account
  credentials; the upload step is not scripted in this repo.
- **Production sign-in** needs a real `Desktop app` `GOOGLE_DESKTOP_CLIENT_ID`
  from §5. The Web client id already in `tool/firebase/dev.json` cannot complete
  the loopback flow.
- **Rules/indexes deployment** needs Firebase CLI credentials for
  `materiallab-63405` (§4).

The app's own Dart tests do **not** need any of this: they run on the Dart VM and
only the Windows *executable* depends on the C++ toolchain.
