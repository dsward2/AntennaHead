# Building **Gqrx for AntennaHead** — an interim signed/notarized Gqrx with the 3 remote‑control PRs

**Purpose.** AntennaHead's "Listen to Gqrx" page uses three additions to Gqrx's
remote‑control protocol that are **not in any released Gqrx** — they're open PRs
against `gqrx-sdr/gqrx` (see
[`LISTEN_TO_GQRX_REMOTE_CONTROL_FEASIBILITY.md`](LISTEN_TO_GQRX_REMOTE_CONTROL_FEASIBILITY.md)
§8/§10):

| PR | Adds | Branch (`dsward2/gqrx`) |
|---|---|---|
| [gqrx#1463](https://github.com/gqrx-sdr/gqrx/pull/1463) | `l/L FILTER_SHAPE` remote level | `gqrx-rc-filter-shape` |
| [gqrx#1464](https://github.com/gqrx-sdr/gqrx/pull/1464) | `\get_bookmarks` / `\set_bookmark*` / `\reload_bookmarks` | `gqrx-rc-bookmarks` |
| [gqrx#1446](https://github.com/gqrx-sdr/gqrx/pull/1446) | `\get/set_input_device` + `_output_` variants | `gqrx-remote-control-device-managment` |

Until they land in a tagged release it may be a long wait, and acceptance isn't
guaranteed. **Gqrx for AntennaHead** is a stop‑gap: official Gqrx source +
those three PRs, built into a **Developer‑ID‑signed, hardened‑runtime,
notarized, stapled** `.dmg` that any AntennaHead user can install and drive.

> **Not sandboxed — deliberately.** Gqrx reaches RTL‑SDR hardware through
> `gr-osmosdr → librtlsdr → libusb`, i.e. raw USB. Under the macOS App Sandbox
> that path is unreliable‑to‑broken for RTL dongles even with
> `com.apple.security.device.usb`, and sandboxing is only *required* for the Mac
> App Store. AntennaHead's own sandbox is unaffected — the two are separate
> processes talking over loopback TCP 7356 / UDP, so a non‑sandboxed Gqrx does
> not weaken AntennaHead. Upstream Gqrx ships non‑sandboxed for the same reason.
> The hardening that *does* apply here — Developer ID + hardened runtime +
> notarization + minimal entitlements — is all in this document.

---

## 1. What already exists (don't reinvent it)

Gqrx's own repo already builds, signs, and notarizes a macOS `.dmg`:

- **`macos_bundle.sh`** (repo root) — makes `Gqrx.app`, runs `macdeployqt6` to
  pull Qt + every dependent dylib into `Contents/Frameworks`, copies SoapySDR
  modules into `Contents/soapy-modules`, then `codesign`s each dylib and the
  binary with `--options runtime --entitlements` (hardened runtime).
- **`.github/workflows/build.yml`** → job `macos` (matrix `x86_64`, `arm64`) —
  installs a conda/micromamba env, `cmake -DCMAKE_BUILD_TYPE=Release`, `make`,
  `./macos_bundle.sh`, then `xcrun notarytool submit --wait` → `xcrun stapler
  staple` for the `.app`, `hdiutil create` the `.dmg`, notarize + staple the
  `.dmg`, rename to `Gqrx-<version>-<arch>.dmg`, upload as an artifact.

**The interim app is that pipeline, run against a branch that merges the three
PRs, with the bundle renamed.** Everything below is the delta.

### What MacPorts contributes (and what it doesn't)

`/Applications/MacPorts/Gqrx.app` is a **stub** — `Contents/MacOS/Gqrx` is a
symlink to `/opt/local/bin/gqrx`, which hard‑links ~40 absolute `/opt/local/…`
dylibs and is only ad‑hoc/linker‑signed. **MacPorts produces nothing
relocatable or distributable.** Its value is the *build recipe* in the Portfile
(`science/gqrx`): plain CMake + Qt5 PortGroup, `-DOSX_AUDIO_BACKEND=Portaudio`,
deps `gr-osmosdr` + `gnuradio` + `portaudio` + `volk`. Note MacPorts'
`gr-osmosdr` **links `librtlsdr`/`libhackrf`/`libairspy`/`libuhd` directly**
rather than loading SoapySDR modules by `dlopen` — different from the conda
layout `macos_bundle.sh` expects (that matters for Path B below).

---

## 2. The build branch

Keep a long‑lived branch on **`dsward2/gqrx`** that is *fresh upstream* + a
**merge** (not rebase/squash) of the three PR branches, so each PR stays
independently updatable and re‑merging after a review revision is trivial.

```bash
cd "/path/to/gqrx"                       # the dsward2/gqrx checkout
git fetch upstream
git switch -C gqrx-for-antennahead upstream/master
git merge --no-ff gqrx-rc-filter-shape gqrx-rc-bookmarks gqrx-remote-control-device-managment
#   (octopus merge; all three are add‑only in remote_control.{h,cpp} +
#    remote-control.txt and have merged cleanly before — see feasibility §10)
git push -f origin gqrx-for-antennahead
```

Refresh it whenever **upstream moves** or **any PR branch is updated**:

```bash
git fetch upstream
git switch -C gqrx-for-antennahead upstream/master
git merge --no-ff gqrx-rc-filter-shape gqrx-rc-bookmarks gqrx-remote-control-device-managment
git push -f origin gqrx-for-antennahead
```

> This is the same content as the throw‑away `gqrx-rc-all` branch used for local
> `build-fs/` testing during AntennaHead development — now given a stable name
> and pushed so CI can build it.

### Branding patch (carry on the build branch, or as a 4th tiny "branch")

Small, mechanical, kept out of the three upstream PRs:

| File | Change | Why |
|---|---|---|
| `macos_bundle.sh` | `CFBundleName` → `Gqrx for AntennaHead`; `CFBundleIdentifier` `dk.gqrx.gqrx` → `com.dsward.gqrx-for-antennahead`; output bundle `Gqrx.app` → `Gqrx-for-AntennaHead.app` (and the later `Gqrx.app`/`Gqrx.dmg`/`Gqrx.zip` references) | distinct Launch Services identity; won't be confused with a real Gqrx install |
| `src/applications/gqrx/gqrx.h` | `GQRX_ORG_NAME` `"gqrx"` → `"gqrx-for-antennahead"`, `GQRX_APP_NAME` likewise *(optional)* | isolates `QSettings` so the interim app doesn't share/settings‑stomp a user's real Gqrx |
| `src/applications/gqrx/main.cpp` + `mainwindow.cpp` | the three hard‑coded `"%1/.config/gqrx"` strings → `.config/gqrx-for-antennahead` *(optional, pairs with the above)* | config dir is hard‑coded, **not** derived from `GQRX_APP_NAME` |
| `resources/icons/gqrx.icns` | swap for a distinct icon *(optional)* | visual disambiguation in the Dock |

If you skip the optional rows, the interim app **shares `~/.config/gqrx/`** with
a real Gqrx — usually fine (users won't run both against AntennaHead at once),
but the RC server port (7356) and window state are then shared too.

---

## 3. Path A — mirror upstream (recommended)

Reproduces exactly what `gqrx-sdr` notarizes; least surprise.

### 3.1 One‑time: credentials

You need a **Developer ID Application** certificate (this is *not* the
"Apple Development: …" cert Xcode uses for AntennaHead — issue it from
<https://developer.apple.com/account/resources/certificates> under the same
team) plus a notarization app‑specific password.

| Secret / value | Used for |
|---|---|
| `BUILD_CERTIFICATE_BASE64` | base64 of the exported `.p12` (Developer ID Application + private key) |
| `P12_PASSWORD` | the `.p12` export password |
| `KEYCHAIN_PASSWORD` | any throw‑away string for the CI keychain |
| `NOTARIZE_USERNAME` | your Apple ID email |
| `NOTARIZE_TEAM_ID` | 10‑char team ID (same team as the Developer ID cert) |
| `NOTARIZE_PASSWORD` | app‑specific password from <https://account.apple.com> → Sign‑In & Security |

For local builds, keep the Developer ID cert in your login keychain and store
the notary credentials once:

```bash
xcrun notarytool store-credentials gqrx-notary \
  --apple-id "you@example.com" --team-id "XXXXXXXXXX" --password "app-specific-pw"
```

### 3.2 Local build (matches the CI job)

```bash
# 1. conda/micromamba env — same package set as build.yml
micromamba create -n gqrx -c conda-forge \
  c-compiler cxx-compiler cmake make pkg-config \
  gnuradio-core gnuradio-osmosdr libboost-devel qt6-main \
  soapysdr soapysdr-module-audio soapysdr-module-lms7 \
  soapysdr-module-plutosdr soapysdr-module-remote \
  soapysdr-module-volk-converters volk
micromamba activate gqrx

# 2. build the merge branch
cd "/path/to/gqrx"
git switch gqrx-for-antennahead
mkdir -p build && cd build
cmake -DCMAKE_BUILD_TYPE=Release ..
make -j"$(sysctl -n hw.ncpu)"
cd ..

# 3. bundle + sign + (optionally) notarize.
#    macos_bundle.sh reads $CONDA_PREFIX and $IDENTITY.
#    Edit IDENTITY= near the top of macos_bundle.sh to your Developer ID
#    Application identity hash (security find-identity -v -p codesigning),
#    or export it and patch the script to read the env var.
export CONDA_PREFIX="$(micromamba info --json | python3 -c 'import json,sys;print(json.load(sys.stdin)["env location"])')"
./macos_bundle.sh true          #  'true'  → hardened-runtime signing for notarization
#                               #  (omit / 'false' → codesign --remove-signature, dev only)

# 4. notarize + staple the app, make + notarize + staple the dmg
ditto -c -k --keepParent "Gqrx-for-AntennaHead.app" "Gqrx-for-AntennaHead.zip"
xcrun notarytool submit "Gqrx-for-AntennaHead.zip" --keychain-profile gqrx-notary --wait
xcrun stapler staple --verbose "Gqrx-for-AntennaHead.app"

VER="$(<build/version.txt)"
hdiutil create "Gqrx-for-AntennaHead-$VER.dmg" \
  -srcfolder "Gqrx-for-AntennaHead.app" -format UDZO -fs HFS+ \
  -volname "Gqrx for AntennaHead $VER"
xcrun notarytool submit "Gqrx-for-AntennaHead-$VER.dmg" --keychain-profile gqrx-notary --wait
xcrun stapler staple --verbose "Gqrx-for-AntennaHead-$VER.dmg"
```

`build/version.txt` is written by CMake (`file(WRITE … version.txt …)`) from
`git describe` — e.g. `2.17.7-22-g08f84f5`. If you want a cleaner marketing
string (`2.17.7-ah1`), set it explicitly in the branding patch or pass
`-DVERSION=…` when it's wired for that.

### 3.3 Entitlements (hardened runtime, no sandbox)

`macos_bundle.sh` writes `/tmp/Entitlements.plist` with just
`com.apple.security.cs.allow-unsigned-executable-memory`. That is enough for the
GNU Radio / VOLK runtime. If notarization or first launch reports a library‑
validation failure on a `dlopen`ed SoapySDR module, add one line:

```xml
<key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
<key>com.apple.security.cs.disable-library-validation</key><true/>
```

**Do not** add `com.apple.security.app-sandbox`. A non‑sandboxed app needs no
USB entitlement — omit `com.apple.security.device.usb` too.

### 3.4 CI (optional but worth it)

Fork `build.yml`'s `macos` job into a workflow on **`dsward2/gqrx`** that:

- triggers on push to `gqrx-for-antennahead` (and `workflow_dispatch`);
- is otherwise **byte‑identical** to upstream's job except the bundle/dmg names
  (`Gqrx-for-AntennaHead-<ver>-<arch>.dmg`);
- on a tag, attaches both arch DMGs to a GitHub Release.

Set the six secrets from §3.1 on `dsward2/gqrx`. The job already conditions
every signing/notarizing step on `secret-check`, so it stays green without them
(unsigned artifact) and notarizes once they're present.

---

## 4. Path B — MacPorts / Qt5 (only if you must avoid conda)

Your existing MacPorts install (`/opt/local`, Qt 5.15, GNU Radio 3.8.5) can
build it, but `macos_bundle.sh` needs rework — it's written for conda + Qt6:

| `macos_bundle.sh` line | Path B change |
|---|---|
| `MACDEPLOYQT6=${CONDA_PREFIX}/bin/macdeployqt6` | `MACDEPLOYQT=/opt/local/libexec/qt5/bin/macdeployqt` |
| `cp "$CONDA_PREFIX"/lib/SoapySDR/modules*/* …/soapy-modules` | **delete** — MacPorts `gr-osmosdr` links `librtlsdr`/`libhackrf`/`libairspy`/`libuhd` directly; there are no Soapy modules to copy. `main.cpp`'s `../soapy-modules` probe simply finds nothing, which is fine. |
| `"${MACDEPLOYQT6}" Gqrx.app … -libpath=…/Frameworks` | same flags, `macdeployqt`. **Then** manually chase the libs `macdeployqt` misses — it does **not** follow `gr-osmosdr`'s transitive `librtlsdr` → `libusb`, `libhackrf`, `libairspy*`, `libuhd`, `libvolk`, `libfftw3f*`, `libgmp*`, `liblog4cpp`, boost. For each: `cp` into `Contents/Frameworks`, then `install_name_tool -change /opt/local/... @executable_path/../Frameworks/<name>` on every referrer, `install_name_tool -id @executable_path/../Frameworks/<name>` on the lib itself. Iterate `otool -L` until nothing points at `/opt/local`. |
| `codesign … --sign "${IDENTITY}"` loop | unchanged, but the loop must cover **all** the manually‑added dylibs too (glob `Contents/Frameworks/*.dylib`). Sign leaf‑first, bundle last. |
| `com.apple.security.cs.allow-unsigned-executable-memory` entitlement | keep; add `disable-library-validation` if a re‑signed dylib trips validation. |

Path B is more fragile (the `install_name_tool` closure is the classic macOS
bundling foot‑gun) and its output is what you notarize, so every one of those
hand‑copied dylibs must be Developer‑ID‑signed with a secure timestamp or
notarization fails. **Prefer Path A** unless conda is a hard no.

---

## 5. Verify before publishing

```bash
APP="Gqrx-for-AntennaHead.app"; DMG="Gqrx-for-AntennaHead-<ver>.dmg"

codesign --verify --deep --strict --verbose=2 "$APP"        # -> valid on disk
codesign -dv --verbose=4 "$APP" 2>&1 | grep -E 'flags|TeamIdentifier|Authority'
#   flags=0x10000(runtime) ; Authority=Developer ID Application: …
xcrun stapler validate -v "$APP"
xcrun stapler validate -v "$DMG"
spctl -a -vvv -t install "$DMG"                             # -> accepted, source=Notarized Developer ID
spctl -a -vvv "$APP"                                        # -> accepted
```

Functional check (no AntennaHead in the loop):

```bash
open "$APP"          # Tools ▸ Remote control ▸ enable
python3 - <<'PY'
import socket
s=socket.create_connection(("127.0.0.1",7356),2); s.settimeout(2)
def cmd(c):
    s.sendall((c+"\n").encode()); return s.recv(4096).decode().strip()
print("l ?           ->", cmd("l ?"))              # must contain FILTER_SHAPE   (PR #1463)
print("L FILTER_SHAPE 2 ->", cmd("L FILTER_SHAPE 2"))
print("l FILTER_SHAPE ->", cmd("l FILTER_SHAPE"))  # -> 2
print("\\get_bookmarks ->", cmd("\\get_bookmarks")[:80])          # count + rows (PR #1464)
print("\\get_input_device_list ->", cmd("\\get_input_device_list")[:80])  # not RPRT 1 (PR #1446)
s.close()
PY
```

Then point AntennaHead at it: **Devices ▸ Listen to Gqrx**. AntennaHead's
`GqrxRemoteControlClient` probes each capability at connect
(`FILTER_SHAPE` in `l ?`; `\get_bookmarks` parses; `\get_input_device_list`
≠ `RPRT 1`) and reveals the filter‑shape selector, bookmark list, and device
pickers automatically — **no AntennaHead change is needed** for this build vs a
future official one.

---

## 6. Cost & caveats

- **Ongoing.** This is a parallel distribution to **re‑cut on every Gqrx
  release** (and whenever a PR is revised in review) until the three PRs merge.
  That recurring effort — not the first build — is the real price.
- **conda env drift.** `conda-forge` moves `gnuradio`/`qt6-main` forward; pin
  versions in the CI `create-args` once a known‑good combo builds, bump
  deliberately.
- **`macdeployqt` gaps.** Even on Path A, spot‑check `otool -L` across
  `Contents/Frameworks` and `Contents/soapy-modules` for stray absolute paths
  before signing.
- **Notarization is all‑or‑nothing.** One un‑hardened or un‑timestamped dylib in
  the bundle fails the whole submission; read `notarytool log <id>` on reject.
- **First launch.** Even notarized, the first open from a DMG shows the
  Gatekeeper prompt; that's expected. Ship a one‑line "right‑click ▸ Open isn't
  needed — just Open" note only if users report otherwise.
- **Licensing.** Gqrx is GPL‑3. Redistributing a modified build is fine; publish
  the exact source (the `gqrx-for-antennahead` branch + branding patch) and keep
  the About box / `news.txt` honest that this is an unofficial build carrying
  PRs #1463/#1464/#1446.
- **Name.** "Gqrx for AntennaHead" (not "Gqrx") in `CFBundleName`, the DMG
  volume, and the download page, so it's unambiguous this isn't an official
  gqrx.dk release.

---

## 7. TL;DR checklist

1. `gqrx-for-antennahead` branch on `dsward2/gqrx` = `upstream/master` + `--no-ff`
   merge of the three PR branches; push (`-f`).
2. Apply the branding patch (`macos_bundle.sh` names + identifier; optional
   settings‑dir isolation).
3. Get a **Developer ID Application** cert + notary app‑specific password.
4. Path A: micromamba env (§3.2 package list) → `cmake -DCMAKE_BUILD_TYPE=Release`
   → `make` → `./macos_bundle.sh true` → `notarytool submit --wait` → `stapler
   staple` → `hdiutil create` dmg → notarize + staple dmg.
5. Verify: `codesign --verify --deep --strict`, `spctl -a -t install`, `stapler
   validate`, the `l ?` / `\get_bookmarks` / `\get_input_device_list` probe,
   then AntennaHead ▸ Listen to Gqrx.
6. Publish the DMG(s) + the source branch; note the carried PRs.
7. Re‑cut on each Gqrx release / PR revision until the PRs land upstream — then
   delete this whole path.
