# Listen to Gqrx — Remote-Control Feasibility Study

**Question:** the "Listen to Gqrx" web page today is a one‑way audio relay
(`PCMUDPReceiver :7355 → sox → PCMUDPSender :6020 → LiveAudioServer`). Can it
also *control* the running `Gqrx.app` — frequency, RF gain, filter width, filter
shape, demodulation mode, squelch, audio gain, mute — by speaking Gqrx's
documented remote‑control protocol over TCP?

**Date:** 2026-09-09
**Scope reviewed:**
- Gqrx remote‑control protocol — `gqrx-sdr/gqrx` `resources/remote-control.txt`
  and `src/applications/gqrx/remote_control.cpp` (command parser, default port,
  mode list, level list, `RPRT` codes).
- AntennaHead: `SDRController.startGqrxListening(channels:)` (`SDRController.swift:866`),
  `gqrxReceivePort` (`:83`), `sendUDPMessage(_:toPort:)` (`:218`),
  `AntennaHeadHTTPServer` Gqrx routes (`:538`, `:554`) and `gqrxFormHTML()`
  (`:1384`), `nowplayingstatus.html` polling (`antennahead.js:1215`,
  `updateStatusDisplay` `:1252`), spatial‑slider live‑control precedent
  (`sendSpatialDistanceUpdate` `:205`, debounced `oninput` in `antennahead.js`).
- `AntennaHead.entitlements`, `antennahead-workspace/NETWORK_PORTS.md`.
- Gqrx PR #1446 (device control, submitted); Gqrx `remote_control.{h,cpp}`
  (`cmd_set_mode`/`newPassband` plumbing), `mainwindow.cpp` (`selectDemod`,
  `d_filter_shape`, `on_plotter_newFilterFreq`), `receiver.h`
  (`filter_shape` enum, `set_filter`), `dockrxopt.cpp` (`currentFilterShape`),
  and `src/qtgui/bookmarks.{h,cpp}` (`BookmarkInfo`, `bookmarks.csv`,
  `getBookmarksInRange`) — background for the §8b/§8c PRs.

---

## 1. Verdict

**Feasible. Moderate effort (~2.5–3 days). No architectural obstacles, no new
entitlements, no PipelineHelpers changes.**

Gqrx's remote control is a line‑oriented TCP protocol modelled on Hamlib
`rigctld`, on **`127.0.0.1:7356`** by default. AntennaHead already keeps a live
control channel to running helpers (the spatial‑audio UDP sliders), already
polls a status JSON four times a second for the Now Playing panel, and already
owns a web form for this exact page. The work is: a small persistent TCP client,
some `SDRController` state, a handful of POST endpoints, and a control panel
grafted onto `devicegqrx.html`.

**The gaps against *released* Gqrx are all closable upstream.** Released Gqrx
exposes filter *width* (the passband arg of `M`) but not filter *shape*
(soft/normal/sharp), no device selection, and no bookmark access. All three are
small, well‑seamed additions to Gqrx's own remote‑control code — §8 specs a PR
for each (device control is **already submitted** as #1446), and §9 covers how
one AntennaHead build detects each at runtime and degrades cleanly when it's
absent. Until a PR lands, that control is simply hidden; none of them change the
core verdict or effort. Filter shape in particular (§8c) is ~0.5 day of C++
because `receiver::set_filter()` already takes the shape parameter.

**Recommended path:** build `GqrxRemoteControlClient` as a standalone, unit‑
tested unit; ship the **Option B** subset first (frequency, mode + width, RF
gain, AF gain, squelch, live signal readout); fast‑follow with mute / record /
RDS text.

---

## 2. The protocol, and the useful subset

Enable it in Gqrx via **Tools ▸ Remote control** (or the toolbar toggle). The
server `listen()`s on all interfaces but rejects any peer not in its
allowed‑hosts list, which defaults to loopback only — so a connection from
`127.0.0.1` works with zero Gqrx configuration, and nothing is LAN‑reachable on
Gqrx's side. One command per line, `\n`‑terminated; the server answers
synchronously, one line per request (a few commands answer with two). Writes
reply `RPRT 0` on success, `RPRT 1` on error. There is **no** unsolicited
event/notification stream — everything is request/response.

### Controls to expose

| AntennaHead control | Gqrx command(s) | Notes / units |
|---|---|---|
| **Frequency** | `F <Hz>` set · `f` get | Center frequency in Hz. |
| **Demod mode** | `M <mode> <passband>` set · `m` get (2 lines: mode, passband) · `M ?` list | Tokens: `OFF RAW AM AMS LSB USB CWL CWU CW FM WFM WFM_ST WFM_ST_OIRT`. Curate a friendly subset (WFM (stereo) / WFM (mono) / FM / AM / AM‑sync / LSB / USB / CW). |
| **Filter width** | passband arg of `M` (Hz, single integer) · read from `m` | One width value; Gqrx derives the low/high edges itself (asymmetric for SSB/CW). Always send a real width — some builds treat `passband == 0` as "unchanged". |
| **Filter shape** | *(none in released Gqrx)* | Proposed as `l/L FILTER_SHAPE` — see §8c. Until that lands, hide the control; don't fake it. |
| **RF gain** | `L <name>_GAIN <value>` set · `l <name>_GAIN` get · `l ?` / `L ?` list | Gain‑stage names are **driver‑dependent** — RTL‑SDR usually exposes a single `RF`; other front‑ends expose `LNA`/`MIX`/`VGA`/`IF`. Build the slider(s) from the discovered `*_GAIN` names, never hard‑code. If Gqrx has hardware AGC on, gain writes are ignored and there is no remote AGC toggle — document it. |
| **Audio gain (AF)** | `L AF <dB>` set · `l AF` get | dB, Gqrx clamps to `[-80, 50]`. |
| **Squelch** | `L SQL <dBFS>` set · `l SQL` get | dBFS, Gqrx clamps to `[-150, 0]`. |
| **Signal strength** (read‑only) | `l STRENGTH` | dBFS. Poll for the meter. |
| **Mute** | `U MUTE <0\|1>` · `u MUTE` | |
| **Record** (Gqrx‑side WAV) | `U RECORD <0\|1>` · `u RECORD` | Independent of AntennaHead's own recorder. |
| **RDS text** (WFM only) | `p RDS_PS_NAME` · `p RDS_RADIOTEXT` · `p RDS_PI` | Nice for the Now Playing panel; empty when not WFM / no data. |
| **DSP on/off** | `U DSP <0\|1>` · `u DSP` | Starts/stops Gqrx's receiver. Optional — risky to expose casually (kills the audio). |
| **Probe / version** | `_` | Connection health check; also a cheap "is this really Gqrx?" test. |

### Explicitly *not* reachable over stock, released Gqrx (keep off the page)

Hardware/software AGC toggle · noise blanker / NR / notch · FFT & waterfall
settings · sample rate / decimation · LNB except `LNB_LO` · DC‑offset &
IQ‑balance · demod‑specific params (de‑emphasis, CTCSS, AM‑sync params). The
Gqrx‑specific `AOS`/`LOS` are recorder triggers, not general controls.

**Filter shape**, **input/output device selection**, and **bookmarks** are also
absent from the released protocol, but each is the subject of a small Gqrx PR —
#1446 (device control) is already submitted by Douglas Ward; filter shape (§8c)
and bookmarks (§8b) are proposed. Treat all three as optional, runtime‑detected
capabilities, not as reasons to hold the core feature.

---

## 3. What already exists (reusable as‑is)

| Piece | Where | Relevant capability |
|---|---|---|
| "Listen to Gqrx" page + form | `Web/devicegqrx.html`, `gqrxFormHTML()` `AntennaHeadHTTPServer.swift:1384` | Already renders on its own sub‑page with `%%GQRX_FORM%%`; already shows the receive port and a channel picker. The control panel is an addition to this fragment, not a new page. |
| Gqrx audio relay | `SDRController.startGqrxListening(channels:)` `:866` | `PCMUDPReceiver(::1, 7355) → sox(→48k/2ch) → PCMUDPSender(6020)`. **Independent of the control channel** — audio keeps working with RC disabled, and vice‑versa. This method is the natural place to also spin up / tear down the TCP client. |
| Live‑control precedent | `sendSpatialDistanceUpdate` `:205`, `sendUDPMessage` `:218`; debounced `oninput` sliders in `antennahead.js` (`spatialAudioControlsHTML`) | Exact pattern for "slider drag → throttled control message to a running process → observable state updates → status poll reflects it." Swap fire‑and‑forget UDP for a queued TCP request/response. |
| Status poll loop | `antennahead.js:1215` `periodicUpdate()` → POST `/nowplayingstatus.html` 4×/s → `updateStatusDisplay()` `:1252`; Swift handler `AntennaHeadHTTPServer.swift:727` | Already the transport for live readouts (signal level, tuner gain, station name). Add a `gqrx` sub‑object to the JSON when `statusFunction == "Gqrx"`; the existing loop delivers it. |
| POST‑endpoint plumbing | `AntennaHeadHTTPServer.swift:554` `/gqrxlistenbuttonclicked.html`, `formFields(fromBody:)`, `okResponse()` | Copy‑paste shape for `/gqrxset*.html` endpoints. |
| Observable status props | `SDRController` `statusFunction`/`stationName`/`frequencyDisplay`/`modulation`/`tunerGain`/`squelchLevel` (`:456`–`462`) | Add siblings (`gqrxMode`, `gqrxPassband`, `gqrxRFGain`, …); `@Observable` drives both the SwiftUI Status tab and the JSON. |
| TCP via Network.framework | `AntennaHeadHTTPServer` uses `NWConnection`/`NWListener` throughout; `TranscriptionCaptionListener` / `RTLSDRStatusListener` are line‑buffered `NWConnection` readers | We have in‑repo examples of exactly the socket style the client needs — just outbound and request/response. |
| Entitlements | `AntennaHead.entitlements` | `com.apple.security.network.client` **already present** (LiveAudioServerClient's HTTP fetches need it). Outbound TCP to `127.0.0.1:7356` needs nothing new. |

**Nothing in PipelineHelpers changes.** This is host‑app + web‑UI only.

---

## 4. Proposed architecture

```
 Browser (devicegqrx.html control panel)
   │  POST /gqrxsetfrequency.html, /gqrxsetmode.html, /gqrxsetgain.html, …      (user action / debounced slider)
   │  POST /nowplayingstatus.html  ── 4×/s ──▶  { …, "gqrx": { mode, passband, rf_gain, af_gain, sql, strength, rds_ps, rds_rt } }
   ▼
 AntennaHeadHTTPServer  ──▶  SDRController (@MainActor, @Observable)
                               │  gqrxRemote: GqrxRemoteControlClient?
                               ▼
                        GqrxRemoteControlClient
                          • NWConnection(host: 127.0.0.1, port: 7356, using: .tcp), persistent
                          • serial actor queue: one outstanding command, FIFO reply match
                          • func send(_ line: String) async throws -> String     ("F 89100000" → "RPRT 0")
                          • func query(_ line: String) async throws -> [String]   ("m" → ["WFM_ST", "160000"])
                          • connect probe via "_"; on connect: "M ?", "L ?" → cache mode & gain-name lists
                          • auto-reconnect w/ backoff; surfaces reachable/unreachable to SDRController
                               ▼  TCP 127.0.0.1:7356
                           Gqrx.app  (Tools ▸ Remote control ON)
```

- **Lifecycle:** `startGqrxListening()` creates `gqrxRemote`, connects, runs the
  `M ?` / `L ?` discovery, and starts a 1 Hz sync poll (`f`, `m`, `l STRENGTH`,
  and `p RDS_*` when mode is WFM). Any transition to another source, or
  `stopAllTasks()`, tears it down. The audio relay path is untouched.
- **Command discipline:** the client serialises everything through an `actor`
  (or a `DispatchQueue` + continuation queue). rigctld is strictly one‑in‑one‑
  out; never pipeline. Treat `m` as a two‑line reply, `M ?` / `l ?` as one
  space‑separated line, everything else as one line. Reads terminate on `\n`.
- **Throttling:** slider `oninput` → POST at ≤10 Hz (reuse the spatial‑slider
  debounce); `onchange` / buttons fire immediately. Server‑side, coalesce: if a
  newer value for the same control arrives while one is in flight, send only the
  latest.
- **State echo:** each successful write updates the matching `SDRController`
  observable immediately (optimistic), and the 1 Hz sync poll corrects it if the
  user also touched Gqrx's own GUI.
- **Failure UX:** connect failure → panel shows "Gqrx remote control not
  reachable — turn on Tools ▸ Remote control in Gqrx" and disables the inputs;
  `RPRT 1` on a write → brief inline "Gqrx rejected that" without tearing the
  connection down.

### New HTTP endpoints (all POST, form‑encoded, `okResponse()` / 4xx + text)

`/gqrxsetfrequency.html` · `/gqrxsetmode.html` (`mode`,`passband`) ·
`/gqrxsetgain.html` (`name`,`value`) · `/gqrxsetaf.html` · `/gqrxsetsquelch.html` ·
`/gqrxmute.html` (`on`) · `/gqrxrecord.html` (`on`). No new ports — 7356 is
Gqrx's, outbound.

---

## 5. Implementation options

### Option A — full control panel

Everything in §2's first table, including mute, Gqrx‑side record, RDS readout,
and (behind a confirm) DSP on/off.

- **Pro:** the page becomes a genuine thin client for Gqrx.
- **Con:** most surface area to test against real Gqrx across modes; DSP‑off is
  a foot‑gun (silences the stream) and needs guarding.

### Option B — core subset first *(recommended)*

Frequency · mode + width · RF gain (discovered names) · AF gain · squelch ·
read‑only signal‑strength meter. Ship it, then add mute / record / RDS as a
follow‑up once the client has proven stable.

- **Pro:** covers everything the user named except shape (which isn't possible);
  smallest first cut that's clearly useful; the client and the status‑JSON
  extension are the same work either way.
- **Con:** two PRs instead of one.

### Option C — reuse the Now Playing details panel

Don't build a bespoke panel; render the Gqrx values into the existing Now
Playing details block and add just a frequency box + mode `<select>` inline.

- **Pro:** least new UI.
- **Con:** that block is a formatted text dump, not a control surface; sliders
  and live feedback want their own layout. Fine as an interim, not the target.

---

## 6. Effort

| Task | Est. |
|---|---|
| `GqrxRemoteControlClient` — connect, serial queue, line framing, `send`/`query`, reconnect/backoff, `M ?`/`l ?` discovery | 0.75 d |
| Unit tests — protocol framing, multi‑line replies, `RPRT` handling, queue ordering, reconnect (against a stub TCP server) | 0.5 d |
| `SDRController` wiring — client lifecycle in `startGqrxListening`/teardown, new `@Observable` props, 1 Hz sync poll | 0.5 d |
| HTTP endpoints + `nowplayingstatus.html` `gqrx` sub‑object | 0.5 d |
| Web UI — control panel in `gqrxFormHTML()`, JS handlers (mode/gain/width/AF/SQL, debounced), meter + "shape lives in Gqrx" note, CSS | 0.75 d |
| Manual integration test vs. real Gqrx — WFM/FM/AM/SSB, RTL‑SDR + one other front‑end for gain‑name variety, AGC‑on behaviour, Gqrx‑GUI‑changes‑underneath sync | 0.5 d |

**Total ≈ 2.5–3 days** for Option B; **+0.5–1 day** for the Option A extras.

---

## 7. Risks / unknowns

- **Gain‑stage names vary by device.** `l ?` on an RTL‑SDR session typically
  yields one `RF_GAIN`; SDRplay/Airspy/HackRF expose several. The UI must be
  generated from discovered names. Mitigation: render one slider per `*_GAIN`
  token, labelled by the token; fall back to a single "RF gain" if none are
  found (older Gqrx).
- **Hardware AGC.** No remote toggle. When it's on in Gqrx, `L RF_GAIN` writes
  silently no‑op. Mitigation: a one‑line hint on the panel; consider polling and
  greying the slider if a write doesn't "take" after the next sync.
- **Version drift.** Older Gqrx lacks `U MUTE`, `p RDS_*`, and used a linear
  `0..1` `AF` instead of dB. Mitigation: probe with `_` / `\dump_state` on
  connect, feature‑gate, degrade gracefully.
- **`passband == 0` semantics.** Some builds read it as "leave unchanged."
  Always send a real, per‑mode‑sane width; clamp client‑side to a sensible range
  per mode.
- **Multi‑line replies.** `m`, `M ?`, `l ?`, `\dump_state` return more than one
  line. Keep a per‑command expected‑shape table in the client; never rely on
  timing.
- **No push from Gqrx.** Changes made in Gqrx's own window are only picked up on
  the 1 Hz poll — brief visual lag if the user drives both. Acceptable; matches
  how the RTL‑SDR Now Playing panel already behaves.
- **Unauthenticated protocol, now behind our LAN‑reachable web UI.** The Gqrx
  side stays loopback‑only, but exposing these controls through AntennaHead's
  web server makes them reachable to anyone who can reach that server — exactly
  the same exposure as the existing RTL‑SDR tuner, and covered by the same
  optional HTTP auth. No new posture, worth a sentence in the PR.
- **Connection thrash.** If Gqrx isn't running / RC is off, the client must
  back off (e.g. 1 s → 2 s → 5 s cap) rather than hammer `connect()`; the panel
  reflects "unreachable" without spamming the log.

---

## 8. Pending upstream Gqrx protocol additions

Three enhancements to Gqrx's own remote‑control protocol are in play — device
control (#1446, submitted), filter shape (§8c), and bookmarks (§8b). **None is in
a tagged Gqrx release**, so all three are opt‑in extras layered on top of the
§2–§5 core — not prerequisites for it. Each is a small, independently
submittable change to `remote_control.cpp` (+ its doc + a test).

### 8a. Device control — Gqrx PR #1446 (submitted by Douglas Ward, awaiting review)

<https://github.com/gqrx-sdr/gqrx/pull/1446> adds six commands:

| Command | Args | Returns |
|---|---|---|
| `\get_input_device_list` | — | newline‑separated device strings |
| `\get_input_device` | — | current input device string |
| `\set_input_device <string>` | gr‑osmosdr device string, e.g. `rtl=0,direct_samp=2` | `RPRT 0` / `RPRT 1` |
| `\get_output_device_list` | — | newline list |
| `\get_output_device` | — | current |
| `\set_output_device <string>` | — | `RPRT 0` / `RPRT 1` |

This closes the *device* half of §2's "input device not remote‑controllable"
gap — AntennaHead could show a Gqrx input/output picker. As of 2026‑09‑09: open,
no maintainer review, author‑targeted at the next release. Not guaranteed to
land.

### 8b. Bookmarks — submitted as [gqrx-sdr/gqrx#1464](https://github.com/gqrx-sdr/gqrx/pull/1464)

**Goal:** AntennaHead downloads the Gqrx bookmark list once, displays it, and can
ask Gqrx to jump to any entry with one tap.

Gqrx already has the internals. `Bookmarks` is a singleton (`src/qtgui/bookmarks.h`);
each `BookmarkInfo` holds **`frequency` (qint64) · `name` · `modulation` ·
`bandwidth` (qint64) · `tags[]`**, persisted as `<config_dir>/bookmarks.csv`
(`;`‑separated, unquoted, a tag section then a bookmark section). Applying a
bookmark = set frequency + mode + bandwidth on the receiver — exactly what a
double‑click in the Bookmarks dock does now. There is a
`Bookmarks::getBookmarksInRange(lo, hi)` helper already.

Proposed commands, in rigctl `\`‑style, borrowing `\dump_state`'s
count‑then‑lines framing so multi‑line replies are unambiguous:

| Command | Args | Returns |
|---|---|---|
| `\get_bookmarks` | — | line 1: integer count `N`; then `N` lines, each `<freq_Hz>\|<name>\|<modulation>\|<bandwidth_Hz>\|<tag,tag,…>` |
| `\get_bookmarks_in_range <lo> <hi>` | Hz | same framing, filtered — maps straight onto `getBookmarksInRange()` |
| `\get_bookmark_tags` | — | count, then one tag name per line |
| `\set_bookmark <n>` | 0‑based index into the most recent `\get_bookmarks` order | `RPRT 0` (applies freq+mode+bandwidth) / `RPRT 1` if out of range |
| `\set_bookmark_freq <Hz>` | exact frequency of a bookmark | `RPRT 0` / `RPRT 1` — index‑independent, survives list edits |
| `\reload_bookmarks` | — | re‑reads `bookmarks.csv` from disk, `RPRT 0` |

PR design notes:

- **Delimiter.** Bookmark names/tags can hold nearly anything and Gqrx's CSV
  doesn't quote. Pick `|` (or `\t`) for the wire format and strip it from
  names, or length‑prefix each field — don't inherit the CSV's ambiguity.
- **Addressing.** Ship both `\set_bookmark <index>` (simple, but stale if the
  list changes between calls) and `\set_bookmark_freq <Hz>` (stable).
- **Scope.** Read + apply only. `\add_bookmark` / `\remove_bookmark` are easy
  follow‑ons but not needed for this feature.
- **Deliverable size.** The Gqrx C++ change is parser plumbing in
  `remote_control.cpp` + `remote-control.txt` + one test — roughly **0.5–1 day**,
  since the model and the "apply" path already exist.

### 8c. Filter shape — submitted as [gqrx-sdr/gqrx#1463](https://github.com/gqrx-sdr/gqrx/pull/1463)

**Yes — a filter‑shape command is feasible and small.** The DSP support is
already there: `receiver::set_filter(low, high, filter_shape)` takes the shape,
and `MainWindow` keeps the current value in a single member `d_filter_shape`
(`receiver::filter_shape` enum: `SOFT = 0`, `NORMAL = 1`, `SHARP = 2`). Every
GUI shape change already routes through `MainWindow::selectDemod()`, which
re‑reads `uiDockRxOpt->currentFilterShape()` and re‑applies the filter — so the
remote path just needs to feed that same variable and re‑apply. It's the exact
mirror of the existing passband plumbing (`RemoteControl::setPassband` ⇄
`newPassband` ⇄ `MainWindow::setPassband`).

Proposed surface — expose it as a **level**, not as an extra line on `m`:

| Command | Args | Returns |
|---|---|---|
| `l FILTER_SHAPE` | — | `0` \| `1` \| `2` (or `SOFT`/`NORMAL`/`SHARP`) |
| `L FILTER_SHAPE <v>` | `0..2`, or `SOFT`/`NORMAL`/`SHARP` (case‑insensitive) | `RPRT 0` / `RPRT 1` |
| `l ?` / `L ?` | — | list gains **plus `FILTER_SHAPE`** — the discovery hook |

Optionally also accept a 3rd token on `M <mode> <passband> <shape>` for
convenience. **Do not** add a third line to `m`'s reply: hamlib/`rigctld`
clients (gpredict, WSJT‑X) parse exactly mode + passband, and `cmd_get_mode()`
returning three lines would break them. A new level name is invisible to those
clients and is exactly how AntennaHead already detects optional capabilities.

C++ touch points (all analogous to passband):

- `remote_control.h/.cpp` — `int rc_filter_shape` (init `1`); `setFilterShape(int)`
  slot (GUI→RC sync); `newFilterShape(int)` signal (RC→GUI); handle
  `FILTER_SHAPE` in `cmd_get_level` / `cmd_set_level` and add it to the `l|L ?`
  list.
- `mainwindow.cpp` — `connect(remote, SIGNAL(newFilterShape(int)), …)` to a slot
  that clamps `0..2`, calls `uiDockRxOpt->setCurrentFilterShape(idx)`, sets
  `d_filter_shape`, and re‑applies `rx->set_filter(flo, fhi, d_filter_shape)`
  with the current cutoffs; and one line in `selectDemod()` next to the existing
  `remote->setMode/​setPassband` calls: `remote->setFilterShape(uiDockRxOpt->currentFilterShape())`.
- `resources/remote-control.txt` + one RC test.

**Deliverable size ≈ 0.5 day** of C++. Design caveats for the PR: shape is a
single app‑wide setting in Gqrx (not per‑mode) and persists across demod
switches — document that; map `0/1/2` explicitly; keep `m` at two lines.

---

## 9. AntennaHead handling of not‑yet‑released Gqrx

One AntennaHead build should work across three tiers of Gqrx by **discovering
capabilities at runtime**, never by sniffing a version string:

| Gqrx in front of it | What the page shows |
|---|---|
| Any current release | Core panel: frequency, mode + width, gains, squelch, signal meter, mute, RDS. |
| + filter‑shape PR (§8c) | + a Soft / Normal / Sharp selector next to the width slider. |
| + PR #1446 (§8a) | + Gqrx input/output device picker. |
| + bookmarks PR (§8b) | + Gqrx bookmark list with one‑tap Tune. |

The three PRs are independent — any subset can land, in any order, and the
matching panel just appears.

**Mechanism.** On connect, after the existing `M ?` / `l ?` discovery, the client
records optional capabilities in the same set it already needs for
release‑version gaps (§7 "Version drift"):

- `FILTER_SHAPE` present in the `l ?` / `L ?` list ⇒ show the shape selector
  (this one falls out of the discovery the client already does — no extra probe).
- `\get_input_device_list` → anything but `RPRT 1` ⇒ enable device picker.
- `\get_bookmarks` → parses as `count` + rows ⇒ enable bookmarks panel; fetch
  once, cache in `SDRController`, offer a Refresh button (and re‑fetch after any
  `\set_bookmark`).

A failed probe (or an absent list entry) is silent and just leaves that control
unrendered. No separate code path.

**Web UI.** A "Gqrx Bookmarks" block in `devicegqrx.html`, emitted by
`gqrxFormHTML()` only when the capability is present: a table (name · frequency ·
mode · tags) with a **Tune** button per row →
`POST /gqrxbookmark.html` (`freq=` preferred, `index=` fallback) →
`gqrxRemote.send("\\set_bookmark_freq \(hz)")`. Tag names become client‑side
filter chips. This is the §4 endpoint/JS pattern verbatim.

**Effort delta** (AntennaHead side, assuming each Gqrx PR is written separately):
filter‑shape selector ≈ 0.25 day (it's one `<select>` + one endpoint, and the
capability check is already in the `l ?` discovery); device picker ≈ 0.5 day;
bookmarks panel ≈ 0.75 day (client parse + cache + table + endpoint).

**Risk.** All three depend on PRs a third‑party maintainer may revise or
decline. Contain the dependency: each feature's wire syntax is referenced by
only its own parser + one endpoint, so a changed merge form has a small blast
radius. Do **not** let any of them gate shipping the core control panel against
stock Gqrx.

---

## 10. The three Gqrx PRs as separate deliverables

Each is an independent contribution to `gqrx-sdr/gqrx`, submittable and
reviewable on its own, touching only the remote‑control layer (`remote_control.{h,cpp}`,
`resources/remote-control.txt`) plus — for shape and bookmarks — a few lines of
Qt signal wiring in `mainwindow.cpp`. None touches the DSP/GNU Radio flowgraph.
Order below is by ascending size / review risk.

> **Status (2026‑09‑09):** all three are open upstream —
> **PR 1 = [gqrx#1463](https://github.com/gqrx-sdr/gqrx/pull/1463)**,
> **PR 2 = [gqrx#1464](https://github.com/gqrx-sdr/gqrx/pull/1464)** (both just
> filed, `MERGEABLE`, no review yet; one commit each off `upstream/master`
> `08f84f5`, Qt5 build green), **PR 3 = the older [gqrx#1446](https://github.com/gqrx-sdr/gqrx/pull/1446)**.
> Branch names and commit hashes are in §11.

### PR 1 — `L/l FILTER_SHAPE` remote level  *(new, ~0.5 day)*

| | |
|---|---|
| **Adds** | `l FILTER_SHAPE` → `0\|1\|2`; `L FILTER_SHAPE <0..2 \| SOFT\|NORMAL\|SHARP>` → `RPRT 0/1`; `FILTER_SHAPE` appended to the `l ?` / `L ?` lists. |
| **Does not change** | `m` / `M` replies stay two‑line — no hamlib/gpredict/WSJT‑X regression. |
| **Gqrx‑side wiring** *(as built)* | `remote_control`: `int rc_filter_shape` (init `1`), `setFilterShape(int)` slot, `newFilterShape(int)` signal, `FILTER_SHAPE` cases in `cmd_get_level`/`cmd_set_level` + both `?` lists. `mainwindow`: `connect(remote, newFilterShape, this, setFilterShape)`; the slot clamps to `FILTER_SHAPE_SOFT..SHARP`, calls `uiDockRxOpt->setCurrentFilterShape(index)`, then re‑runs `selectDemod(uiDockRxOpt->currentDemod())` (the exact GUI combo path); one line in `selectDemod()` — `remote->setFilterShape(uiDockRxOpt->currentFilterShape())` — for GUI→RC sync. |
| **Reuses** | `receiver::set_filter(low, high, filter_shape)` already takes the shape; `receiver::filter_shape` enum already defined; `DockRxOpt::setCurrentFilterShape` / `currentFilterShape`. |
| **Tests / docs** | Gqrx has no RC unit‑test harness (no `test/`, no `add_test`) — manual `nc` steps in the PR body, same as #1446. One block added to `remote-control.txt`. |
| **Review‑risk notes** | Shape is a single app‑wide setting in Gqrx (not per‑mode) and persists across demod switches — stated in the doc block. Accepts ints and `SOFT`/`NORMAL`/`SHARP`. |
| **Status** | **Open — [gqrx#1463](https://github.com/gqrx-sdr/gqrx/pull/1463)** (`MERGEABLE`, no review yet). Branch `gqrx-rc-filter-shape` = commit `4c4be36` (5 files, +70/−2), off `upstream/master` `08f84f5`. **Smoke‑tested 2026‑09‑09** against a headless build (Qt5 offscreen, no SDR): `l ?`/`L ?` list `FILTER_SHAPE`; `l FILTER_SHAPE`=`1` default; `L FILTER_SHAPE 2`/`soft`/`normal` → `RPRT 0` with correct readback; `L FILTER_SHAPE 5` → `RPRT 1`; `m` still two lines. Full transcript posted as a [PR comment](https://github.com/gqrx-sdr/gqrx/pull/1463#issuecomment-5611595188). |

### PR 2 — bookmark download & recall  *(new, ~0.5–1 day)*

| | |
|---|---|
| **Adds** | `\get_bookmarks` and `\get_bookmarks_in_range <lo> <hi>` (count line, then `freq\|name\|modulation\|bandwidth\|tags` rows); `\get_bookmark_tags`; `\set_bookmark <index>` and `\set_bookmark_freq <Hz>`; `\reload_bookmarks`. |
| **Framing** *(as built)* | Count line, then one line per bookmark: `<freq>\|<name>\|<modulation>\|<bandwidth>\|<tag,tag,…>`. `|`, CR and LF are replaced with a space in `name`, `modulation` and tag names — a chosen, sanitised wire separator, not `bookmarks.csv`'s unquoted `;`. |
| **Gqrx‑side wiring** *(as built)* | `remote_control`: 6 new `\`‑command cases + handlers reading `Bookmarks::Get()` (`size()`, `getBookmark(i)`, `getTagList()`, `load()`); range/freq filters are a direct `frequency` loop (not `getBookmarksInRange`, which also filters by active tag). `\set_bookmark*` emit a new `newBookmarkActivated(qint64,QString,int)` signal wired to the existing `MainWindow::onBookmarkActivated` slot — the same slot the dock uses. No `MainWindow` include added to `remote_control.cpp`. |
| **Reuses** | `Bookmarks` singleton, `BookmarkInfo` (`frequency·name·modulation·bandwidth·tags[]`), `MainWindow::onBookmarkActivated`. |
| **Tests / docs** | No RC unit‑test harness in Gqrx — manual `nc` steps in the PR body. New `remote-control.txt` block incl. the delimiter/sanitisation contract. |
| **Review‑risk notes** | Index staleness if the list changes between calls — that's why `\set_bookmark_freq` ships alongside. Read + apply only; `\add_bookmark`/`\remove_bookmark` explicitly out of scope. `bandwidth` is narrowed `qint64`→`int` to match the existing dock signal. |
| **Status** | **Open — [gqrx#1464](https://github.com/gqrx-sdr/gqrx/pull/1464)** (`MERGEABLE`, no review yet). Branch `gqrx-rc-bookmarks` = commit `889e801` (4 files, +182), off `upstream/master` `08f84f5`. **Smoke‑tested 2026‑09‑09** against a headless build with a seeded `bookmarks.csv`: `\get_bookmarks` returns the count + `\|`‑rows (a `\|` in a name came back space‑sanitised); `\get_bookmark_tags` and `\get_bookmarks_in_range` correct; `\get_bookmarks_in_range 100 50` → `RPRT 1`; `\set_bookmark 0` / `\set_bookmark_freq <Hz>` retuned (`f` confirmed) and switched mode; out‑of‑range / no‑match → `RPRT 1`; `\reload_bookmarks` → `RPRT 0`. Full transcript posted as a [PR comment](https://github.com/gqrx-sdr/gqrx/pull/1464#issuecomment-5611596577). |

### PR 3 — input/output device control — **#1446**  *(open, by Douglas Ward)*

| | |
|---|---|
| **Adds** | `\get_input_device_list` · `\get_input_device` · `\set_input_device <gr‑osmosdr string>` and the three `_output_` equivalents; `RPRT 0/1` on set. |
| **Enables (AntennaHead)** | a Gqrx input/output device picker on the page. |
| **Tests / docs** | Present in the PR; also fixes an unrelated `plotter.h` negative‑value crash and updates an I/O‑config tooltip. |
| **Status** | <https://github.com/gqrx-sdr/gqrx/pull/1446> — open, no maintainer review as of 2026‑09‑09. Local branch `gqrx-remote-control-device-managment` (commit `57f5ae4`) is off the older `d657e66` and wants a rebase onto current `upstream/master` (`08f84f5`, +6). Action: rebase, split out the `plotter.h` fix if a reviewer asks, respond to review. |

### Shared submission notes

- **One PR per feature.** They're orthogonal; bundling invites a single blocking
  review comment to stall all three.
- **Every addition is capability‑detectable** without a version string — a new
  `l ?` entry (PR 1) or a `\`‑verb that returns non‑`RPRT 1` (PR 2, PR 3) — which
  is what lets one AntennaHead build target released and patched Gqrx alike (§9).
- **Compatibility invariant:** no PR changes the reply shape of an existing
  command. New names and new verbs only. (Verified for PR 1 and PR 2 as built —
  `m`/`M` and every other existing command are byte‑for‑byte unchanged.)
- **Per PR:** branch from `upstream/master`, code + `resources/remote-control.txt`
  + manual `nc` test steps in the PR body (Gqrx ships no RC test harness), PR
  description linking this study's §8, and a note that the author's AntennaHead /
  LocalRadio project is the consumer (as #1446 already does).
- **PR 1 vs PR 2 overlap:** both branch off the same `upstream/master` and both
  add lines to `signals:` / the `cmd_*` list in `remote_control.h` and near the
  `l|L` block in `remote-control.txt`. Add‑only, non‑adjacent — GitHub should
  auto‑merge; at worst a trivial textual conflict resolved in seconds.

---

## 11. Local Gqrx build & test environment

A working Gqrx source tree is already checked out at
`…/Claude working directory/gqrx` — it's the base for all three PRs and for the
temporary build AntennaHead is developed against.

### State of the checkout (as surveyed 2026‑09‑09)

| | |
|---|---|
| Remotes | `origin` → `github.com/dsward2/gqrx`, `upstream` → `github.com/gqrx-sdr/gqrx` — correct topology for PRs. |
| Branches | `gqrx-remote-control-device-managment` = **#1446** (`57f5ae4`, off `d657e66`) · **`gqrx-rc-filter-shape`** = **#1463** (`4c4be36`, +70/−2) · **`gqrx-rc-bookmarks`** = **#1464** (`889e801`, +182) — the last two each one commit off `upstream/master` `08f84f5`, pushed to `origin` and open upstream. `master` still tracks the stale Feb `upstream/master`. |
| Currency | `git fetch upstream` done — `upstream/master` now at `08f84f5` (`v2.6.1`+…; the local `master` ref is still the Feb `v2.17.7-17-g57f5ae4` and is behind, but the two new branches are off the fresh `upstream/master`, so it doesn't matter). Re‑`fetch` again before pushing, in case upstream moved. |
| Toolchain | MacPorts at `/opt/local`: `cmake` 3.31, **Qt 5.15.18**, GNU Radio **3.8.5**, boost 1.76. Older SDR stack, fine for RC‑protocol work. |
| Build dir | The original `gqrx/build/` was configured for the pre‑move path and is gone (trashed). Current working build dir is **`gqrx/build-fs/`** (`cmake -DCMAKE_BUILD_TYPE=Debug -DCMAKE_PREFIX_PATH=/opt/local -DCMAKE_C_COMPILER=/usr/bin/clang -DCMAKE_CXX_COMPILER=/usr/bin/clang++ ..`); `build-fs/src/gqrx` compiles and **runs** (arm64, linker ad‑hoc signed). Not branch‑specific — `make` there rebuilds whatever is checked out. |
| Toolchain caveat | `Xcode-beta.app` was removed mid‑session (an `Xcode_27_RC.xip` is sitting in `/Applications`), so `xcode-select` now points at `/Library/Developer/CommandLineTools` (Apple clang 21). A `build-fs/` configured against the old Xcode‑beta path fails with `c++: No such file or directory` — reconfigure with the explicit `CMAKE_*_COMPILER=/usr/bin/clang…` above. Builds are green under CLT clang 21. |
| Headless run | For a no‑device smoke test: `XDG_CONFIG_HOME=<scratch>/config QT_QPA_PLATFORM=offscreen build-fs/src/gqrx -c smoke.conf`, with `smoke.conf` = `[General] configversion=4, crashed=false` + `[remote_control] enabled=true` and **no `input/device`** (empty device ⇒ `loadConfig` still returns true, no modal I/O dialog). Seed `<scratch>/config/gqrx/bookmarks.csv` for the bookmark commands. RC server binds `127.0.0.1:7356`; drive it with a short Python `socket` client (macOS `nc` didn't print replies here). |
| Uncommitted | one line in `macos_bundle.sh` (`CONDA_PREFIX="/opt/local"`) — a local hack; kept out of all three PR commits. |

### Iterating on a PR

Don't use the `.app` bundle for development — build and run the raw product
(`build-fs/` rebuilds whatever branch is checked out):

```bash
cd "…/Claude working directory/gqrx"
git switch gqrx-rc-filter-shape          # or gqrx-rc-bookmarks
cd build-fs && make -j"$(sysctl -n hw.ncpu)" && ./src/gqrx
```

New PRs branch from **fresh `upstream/master`**, never from another PR branch
(they must stay independent — §10): `git fetch upstream && git switch -c <name> upstream/master`.

Smoke‑test the RC channel without AntennaHead in the loop:

```bash
# Gqrx: Tools ▸ Remote control ON, then —
# PR 1 (branch gqrx-rc-filter-shape):
printf 'l ?\nL FILTER_SHAPE 2\nl FILTER_SHAPE\nL FILTER_SHAPE normal\nL FILTER_SHAPE 5\n' | nc 127.0.0.1 7356
#   -> list contains FILTER_SHAPE ; RPRT 0 ; 2 ; RPRT 0 ; RPRT 1

# PR 2 (branch gqrx-rc-bookmarks), with a couple of bookmarks saved:
printf '\\get_bookmarks\n\\get_bookmark_tags\n\\set_bookmark 0\n\\set_bookmark_freq 95500000\n\\set_bookmark 99\n' | nc 127.0.0.1 7356
#   -> count+rows ; count+tags ; RPRT 0 ; RPRT 0 ; RPRT 1  (receiver retunes on each RPRT 0)
```

### Why `Gqrx.app` won't launch (and why it doesn't matter here)

`Gqrx.app/Contents/MacOS/gqrx` is **completely unsigned** (`codesign -dv` →
"code object is not signed at all") and arm64 on Apple Silicon, so the kernel
kills it at exec. Root cause is `macos_bundle.sh`, which is written for a
conda/Qt6 environment: (1) its non‑notarization path runs
`codesign --remove-signature` on the final binary — stripping the linker's
ad‑hoc signature, fatal on Apple Silicon; (2) `MACDEPLOYQT6=${CONDA_PREFIX}/bin/macdeployqt6`
doesn't exist — this is a Qt5 build (`macdeployqt` lives in
`/opt/local/libexec/qt5/bin/`), so the Frameworks are never relocated and
`otool -L` still shows absolute `/opt/local/...` links. This is **not**
Gatekeeper (disabled here per `spctl`) and **not** quarantine (no
`com.apple.quarantine` xattr).

It doesn't block any of this work — `build-fs/src/gqrx` is the thing to run. If a
launchable bundle is ever wanted:

```bash
codesign --force --deep --sign - "…/Claude working directory/gqrx/Gqrx.app"
```

…which runs as long as MacPorts stays at `/opt/local` with these library
versions. A portable bundle needs `macos_bundle.sh` pointed at the Qt5
`macdeployqt` with the `--remove-signature` line changed to `--sign -` — a
separate task from the protocol PRs.

---

## 12. Recommendation

Proceed, in phases:

1. **Core control panel against stock Gqrx.** Build `GqrxRemoteControlClient`
   first, in isolation, with a stub‑server test suite — it's the only genuinely
   new mechanism; everything else is a known pattern here. Ship **Option B**
   (frequency, mode + width, RF/AF gain, squelch, signal meter). Fast‑follow
   with mute / Gqrx‑record / RDS text.
2. **Shepherd the three Gqrx PRs** (§10). Filter shape ([#1463](https://github.com/gqrx-sdr/gqrx/pull/1463))
   and bookmarks ([#1464](https://github.com/gqrx-sdr/gqrx/pull/1464)) are
   **filed, `MERGEABLE`, and smoke‑tested** — transcripts posted as PR comments
   ([#1463](https://github.com/gqrx-sdr/gqrx/pull/1463#issuecomment-5611595188),
   [#1464](https://github.com/gqrx-sdr/gqrx/pull/1464#issuecomment-5611596577)) —
   so remaining work is responding to review. Rebase
   [#1446](https://github.com/gqrx-sdr/gqrx/pull/1446) onto current
   `upstream/master` and shepherd it too.
3. **Wire the matching AntennaHead panels**, each gated on its runtime probe
   (§9): the shape selector on `FILTER_SHAPE` appearing in `l ?`; the device
   picker on `\get_input_device_list`; the bookmarks panel on `\get_bookmarks`.
   Develop against your temporary Gqrx build so each is ready the moment its
   protocol change ships in an official release.

If all three PRs make the next Gqrx release, phase 3 is "flip the panels on for
everyone"; if none do, AntennaHead still has a complete, useful Gqrx control
page from phase 1.
