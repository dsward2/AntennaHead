# Filler Pipeline — Implementation Plan (Option A)

**Status:** Phase 1 implemented on branch `add-filler-pipeline` (2026-09-05). Phases 2–3 pending.
**Scope:** AntennaHead only (sandboxed app). No ControlBooth, no LiveAudioServer changes.
**Date:** 2026-09-05

## Phase 1 — done (branch `add-filler-pipeline`, not merged)

- `Web/Monitor_Beacon.wav` → top-level `Monitor_Beacon.wav`; `Web/Monitor_Beacon.mp3` deleted; `project.pbxproj` ships it at `Contents/Resources/Monitor_Beacon.wav` (4 edits, ids `D1F111E0BEACDA7A0000000{1,2}`).
- `SDRController`: `TaskMode.filler`, `isPlayingRealSource`/`isFillerPlaying`, settings keys + accessors (default-ON via `!= "0"`), `fillerPipelineManager` (+ `onLog` in `init`), `startFillerPipeline()` / `fillerSettingsDidChange()` / `stopFillerForNewSource()` (called from all 6 real-source builder preambles) / `fillerFolderURL` / track-list + custom-folder helpers / `publishFillerStatus()`. `terminateTasks(enterIdle: Bool = true)` re-enters the filler on every stop except when `false`.
- `ContentView`: `teardownServices()` → `terminateTasks(enterIdle: false)`; deferred (1.5 s) filler start after `lasProcess.start(...)`.
- `ConfigurationView`: "Filler Audio" section (enable toggle + custom-source/shuffle/gap + reveal folder), `reloadSettings()`/`saveFillerSettings()`.
- `AntennaHeadHTTPServer`: `/fillerstop.html` route (`terminateTasks(enterIdle: false)`); `filler`/`filler_source` keys in `nowPlayingStatusJSON()`.
- **No fade** (Phase 2). No `PCMDistanceGain`, no port 6026 yet. Selecting a program stops the filler outright (brief ~100 ms dual-sender overlap into LAS is accepted until Phase 2 folds the filler procs into `dying`).
- **Typed `/api/v1/now-playing` reports `taskMode: "stopped"` during filler** (the AntennaHeadAPI `TaskMode` enum has no `.filler`); the HTML `/nowplayingstatus.html` reports `rtlsdr_task_mode: "filler"` + `filler: true`. API/`AntennaHeadTV` filler awareness is deferred.
- Verified: `xcodebuild build` + `test` succeed; live run — launch auto-starts the beacon loop, tuning favorite 1 stops it and starts `rtl_fm_localradio`, `/api/v1/stop` returns to the beacon, `/fillerstop.html` goes truly silent, clean quit leaves no orphaned helpers.

## Goal

When AntennaHead has no audio source running, automatically loop a user‑selectable
**filler** pipeline so the stream is never digitally silent. The built‑in
**Monitor Beacon** WAV is the default filler. Selecting any real program
(Favorite, ad‑hoc tune, category scan, Core Audio device, Gqrx, ControlBooth
listen, Text‑to‑Speech, recording playback) fades the filler out and then starts
the program.

Locked decisions:

- **Feature defaults ON.** An idle AntennaHead loops the Monitor Beacon out of the
  box. Only an explicit "off" in Configuration disables it.
- **The Monitor Beacon WAV moves to a top‑level bundle resource**
  (`Contents/Resources/Monitor_Beacon.wav`), not `Contents/Resources/Web/…`.

Explicitly **out of scope** (this is a separate, larger feature — "Option B"):
ducking filler *under* a tuned station when the station itself goes quiet. Here
"silent" means strictly "no source pipeline running" (`taskMode == .stopped`).

---

## 1. What already exists (no work needed)

| Piece | Where | Notes |
|---|---|---|
| `PCMFilePlayer` helper | `PipelineHelpers/Sources/PCMFilePlayer/main.swift`, embedded in `AntennaHead.app/Contents/Helpers/` (`project.pbxproj` lines ~59, ~74, ~138, ~247) | Real‑time‑paced source stage. Decodes AAC/MP3/WAV/CAF to S16LE at `--rate`/`--channels` via `AVAudioConverter`. Args: `--file` (repeatable), `--playlist <path>`, `--rate`, `--channels`, `--gap <s>`, `--repeat`, `--exit-with-parent`. With one `--file` + `--repeat` + `--gap 0` it loops the track back‑to‑back with no inserted silence. |
| `PCMDistanceGain` helper | `PipelineHelpers/Sources/PCMDistanceGain/main.swift`, embedded in `Contents/Helpers/` | Passthrough gain stage with a UDP `--control-port`. Live command wire format is `dist <value>\n` (see `SDRController.sendSpatialDistanceUpdate`, `SDRController.swift:194`). Higher distance ⇒ lower gain. Already used for the spatial‑audio feature on port 6024; the filler uses a **separate instance** on its own port. |
| `PCMUDPSender` helper | embedded | Terminal stage of every pipeline; `--port <udpInputPort> --exit-with-parent`. |
| `Monitor_Beacon.wav` | `AntennaHead/Web/Monitor_Beacon.wav` (git‑tracked) | **48000 Hz, 2 ch, S16LE interleaved, 49.76 s, 9,554,284 bytes.** Already exactly the LiveAudioServer UDP contract, so `PCMFilePlayer` plays it with **zero resampling**. Currently referenced by nothing in the codebase (dead weight inherited from LocalRadio). |
| `Monitor_Beacon.mp3` | `AntennaHead/Web/Monitor_Beacon.mp3` | 22050 Hz mono, 32 kbps, 49.76 s, 199,053 bytes. Also unreferenced. |
| `TaskPipelineManager` | `PipelineHelpers/Sources/PipelineRunner/TaskPipelineManager.swift` | `add()`, `start()`, `terminate()`, `taskItems`, `onLog`. `terminate()` SIGTERMs every running stage immediately and clears `taskItems`. |
| App‑settings store | `SQLiteController.shared.appSettingsValue(forKey:) -> String?` (throwing, double‑optional) / `.storeAppSettingsValue(_:forKey:)` | Convention: `static let xKey = "AntennaHeadX"`, computed `Bool` var `((try? …) ?? nil) == "1"`. |

**PipelineHelpers requires no changes.** **Xcode project requires only the WAV move.**

---

## 2. The Monitor Beacon: move to a top‑level bundle resource

### 2.1 Move the file

```bash
cd antennahead-umbrella/AntennaHead
git mv Web/Monitor_Beacon.wav Monitor_Beacon.wav
git rm Web/Monitor_Beacon.mp3      # unreferenced, 199 KB; restore from history if a
                                   # small-bundle variant is ever wanted
```

The WAV now sits at the AntennaHead source root, alongside the other vendored
top‑level assets (`sox`, `stereodemux`, `LiveAudioServer`, …).

### 2.2 `AntennaHead.xcodeproj/project.pbxproj` edits

`Web/` is a **folder reference** (`0EA8DC4A2FD666B300D79877`, `lastKnownFileType = folder`)
copied wholesale into `Contents/Resources/Web/`. Add the WAV as its own resource so
filler code does not depend on the Web folder layout:

1. **`PBXFileReference`** (new id, e.g. `D1FILLERBEACON0000000001`), near the other
   file refs (~line 177):
   ```
   D1FILLERBEACON0000000001 /* Monitor_Beacon.wav */ = {isa = PBXFileReference; lastKnownFileType = audio.wav; path = Monitor_Beacon.wav; sourceTree = "<group>"; };
   ```
2. **Main group children** (`0EF469AD2FCE8911001510D3`, ~line 322) — add as a sibling
   of `Web`:
   ```
   D1FILLERBEACON0000000001 /* Monitor_Beacon.wav */,
   ```
3. **`PBXBuildFile`** (new id, e.g. `D1FILLERBEACON0000000002`), near the other build
   files (~line 28):
   ```
   D1FILLERBEACON0000000002 /* Monitor_Beacon.wav in Resources */ = {isa = PBXBuildFile; fileRef = D1FILLERBEACON0000000001 /* Monitor_Beacon.wav */; };
   ```
4. **Resources build phase** `0EF469B42FCE8911001510D3` (`files` currently only holds
   `Web in Resources`, ~line 545) — add:
   ```
   D1FILLERBEACON0000000002 /* Monitor_Beacon.wav in Resources */,
   ```

Result: `AntennaHead.app/Contents/Resources/Monitor_Beacon.wav`.

### 2.3 Resolve it in code

```swift
private var beaconFillerURL: URL? {
    Bundle.main.url(forResource: "Monitor_Beacon", withExtension: "wav")
}
```

### 2.4 Sandbox note — why the bundle path "just works"

A bundle resource is a plain, world‑readable file inside the `.app`. It is
readable by the sandboxed app **and** by the `PCMFilePlayer` child process with
no App Group container, no security‑scoped bookmark, and no copy‑into‑container
step. This is the whole reason the default filler needs none of the sandbox
machinery that Text‑to‑Speech and LAS recording require.

### 2.5 Verify nothing referenced the old path

`grep -rn "Monitor_Beacon"` across `*.swift *.html *.js *.css *.json *.md *.plist`
currently returns **nothing**, so the move breaks no web page or script. Re‑run
after the move.

---

## 3. `SDRController.swift` — the core of the feature

`SDRController` is `@MainActor @Observable`. All new members are `@MainActor`.

### 3.1 New task mode

```swift
enum TaskMode: String {
    case stopped
    case frequency
    case scan
    case device
    case customTask
    case recording
    case filler        // NEW
}
```

Add UI‑intent helpers used by views and the web layer:

```swift
/// A real, user‑selected source is playing (not idle, not the auto filler).
var isPlayingRealSource: Bool { taskMode != .stopped && taskMode != .filler }
var isFillerPlaying: Bool { taskMode == .filler }
```

### 3.2 Settings keys + computed accessors (default‑ON semantics)

```swift
static let fillerEnabledKey        = "AntennaHeadFillerEnabled"
static let fillerFadeEnabledKey    = "AntennaHeadFillerFadeOut"
static let fillerUseCustomKey      = "AntennaHeadFillerUseCustomSource"
static let fillerShuffleKey        = "AntennaHeadFillerShuffle"
static let fillerGapKey            = "AntennaHeadFillerGapSeconds"
static let fillerFadeMsKey         = "AntennaHeadFillerFadeMs"      // default 700

/// Default ON: absent key ⇒ enabled. Only an explicit "0" disables it.
var fillerEnabled: Bool {
    ((try? sqliteController.appSettingsValue(forKey: Self.fillerEnabledKey)) ?? nil) != "0"
}

/// Default ON, same convention.
var fillerFadeEnabled: Bool {
    ((try? sqliteController.appSettingsValue(forKey: Self.fillerFadeEnabledKey)) ?? nil) != "0"
}

var fillerUsesCustomSource: Bool {
    ((try? sqliteController.appSettingsValue(forKey: Self.fillerUseCustomKey)) ?? nil) == "1"
}
var fillerShuffle: Bool {
    ((try? sqliteController.appSettingsValue(forKey: Self.fillerShuffleKey)) ?? nil) == "1"
}
var fillerGapSeconds: Int {
    Int(((try? sqliteController.appSettingsValue(forKey: Self.fillerGapKey)) ?? nil) ?? "") ?? 0
}
var fillerFadeMs: Int {
    let v = Int(((try? sqliteController.appSettingsValue(forKey: Self.fillerFadeMsKey)) ?? nil) ?? "") ?? 700
    return min(max(v, 100), 1800)   // keep < waitForProcessesToExit's 2.5 s timeout
}
```

### 3.3 Fixed internal UDP port

Existing fixed internal ports: transcription 6023, spatial‑gain 6024, binaural 6025.

```swift
/// Control port for the filler's own PCMDistanceGain instance (gain ramps).
/// Fixed, internal, AntennaHead owns both ends — no cross‑app coordination.
let fillerControlPort: UInt16 = 6026
```

### 3.4 Dedicated pipeline manager

Give the filler its **own** `TaskPipelineManager` so its lifecycle is fully
independent of the program pipeline (`radioTaskPipelineManager`). This avoids any
shared‑`taskItems` juggling and lets the fade‑out run without
`TaskPipelineManager.terminate()` killing the filler instantly.

```swift
let fillerPipelineManager = TaskPipelineManager()
private var fillerGeneration = 0   // guards stale fade/kill timers
```

In `init`, wire logging the same way `radioTaskPipelineManager` is wired
(ControlBooth already runs several managers sharing one `onLog` — see the
2026‑08‑01 SharedLogging notes):

```swift
fillerPipelineManager.onLog = { [weak self] source, message in
    _ = self
    LogStore.shared.log(.info, source: source, message)
}
```

### 3.5 Track‑list resolution

```swift
/// Filler tracks, in play order. Custom source (files the user dropped into
/// <Recordings>/Filler/) when enabled and non‑empty; otherwise the built‑in
/// Monitor Beacon. The PCMFilePlayer child can read both the app bundle and
/// SharedRecordingFolder (proven by startTasksForRecording).
private func fillerTrackList() -> [URL] {
    if fillerUsesCustomSource {
        let custom = customFillerTracks()
        if !custom.isEmpty { return fillerShuffle ? custom.shuffled() : custom }
        LogStore.shared.log(.info, source: "SDRController",
                            "filler: custom source empty — falling back to Monitor Beacon")
    }
    return beaconFillerURL.map { [$0] } ?? []
}

/// Decodable audio files in <Recordings>/Filler/ (created lazily). Phase 3.
private func customFillerTracks() -> [URL] {
    guard let root = SharedRecordingFolder.url else { return [] }
    let dir = root.appendingPathComponent("Filler", isDirectory: true)
    let exts: Set<String> = ["wav", "mp3", "m4a", "aac", "aif", "aiff", "caf", "flac"]
    let items = (try? FileManager.default.contentsOfDirectory(at: dir,
                    includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    return items
        .filter { exts.contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
}
```

### 3.6 Start the filler

Modelled on `startTasksForRecording` (`SDRController.swift:502`), but on
`fillerPipelineManager`. No `dying`/port‑race wait is needed: filler uses none of
the exclusive resources (RTL‑SDR USB, Core Audio device, a bound receive port) —
`PCMUDPSender` only *sends*, and LAS owns the receive socket.

```swift
func startFillerPipeline() {
    fillerPipelineManager.terminate()          // clear any prior filler
    guard fillerEnabled else { return }

    let tracks = fillerTrackList()
    guard !tracks.isEmpty else {
        LogStore.shared.log(.error, source: "SDRController",
                            "filler enabled but no playable audio (Monitor_Beacon.wav missing?)")
        return
    }

    fillerGeneration &+= 1
    taskMode = .filler
    publishFillerStatus(trackCount: tracks.count)

    guard let player = makeFillerPlayerTaskItem(tracks: tracks),
          let sender = makeFillerUDPSenderTaskItem() else {
        taskMode = .stopped
        return
    }
    fillerPipelineManager.add(player)

    let gain = fillerFadeEnabled ? makeFillerGainTaskItem() : nil
    if let gain { fillerPipelineManager.add(gain) }

    fillerPipelineManager.add(sender)

    do {
        try fillerPipelineManager.start()
        lastError = nil
        LogStore.shared.log(.info, source: "SDRController",
            "filler started — \(tracks.count) track(s), "
            + (fillerFadeEnabled ? "fade \(fillerFadeMs) ms" : "no fade"))
        if fillerFadeEnabled { rampFillerGain(from: Self.fillerFadeFloor, to: 1.0, ms: fillerFadeMs) }
    } catch {
        lastError = error
        taskMode = .stopped
        LogStore.shared.log(.error, source: "SDRController", "filler start failed: \(error)")
    }
}

private static let fillerFadeFloor = 6.0   // PCMDistanceGain "distance" at full attenuation (~−18 dB)

private func makeFillerPlayerTaskItem(tracks: [URL]) -> TaskItem? {
    let path = helperPath("PCMFilePlayer")
    guard FileManager.default.isExecutableFile(atPath: path) else {
        lastError = SDRError.notImplemented("PCMFilePlayer helper missing at \(path)")
        return nil
    }
    let item = fillerPipelineManager.makeTaskItem(pathToExecutable: path, functionName: "PCMFilePlayer")
    for url in tracks { item.addArgument("--file"); item.addArgument(url.path) }
    item.addArgument("--rate"); item.addArgument(Self.outputSampleRate)
    item.addArgument("--channels"); item.addArgument(Self.outputChannels)
    item.addArgument("--repeat")
    item.addArgument("--gap"); item.addArgument(fillerUsesCustomSource ? fillerGapSeconds : 0)
    item.addArgument("--exit-with-parent")
    return item
}

private func makeFillerGainTaskItem() -> TaskItem? {
    let path = helperPath("PCMDistanceGain")
    guard FileManager.default.isExecutableFile(atPath: path) else {
        LogStore.shared.log(.error, source: "SDRController",
                            "PCMDistanceGain helper missing — filler fade disabled this run")
        return nil
    }
    let item = fillerPipelineManager.makeTaskItem(pathToExecutable: path, functionName: "PCMDistanceGain")
    item.addArgument("--rate"); item.addArgument(Self.outputSampleRate)
    item.addArgument("--channels"); item.addArgument(Self.outputChannels)
    item.addArgument("--distance"); item.addArgument("\(Self.fillerFadeFloor)")   // start attenuated, ramp in
    item.addArgument("--control-port"); item.addArgument(Int(fillerControlPort))
    item.addArgument("--exit-with-parent")
    return item
}

private func makeFillerUDPSenderTaskItem() -> TaskItem? {
    let item = fillerPipelineManager.makeTaskItem(pathToExecutable: helperPath("PCMUDPSender"),
                                                  functionName: "PCMUDPSender")
    item.addArgument("--port"); item.addArgument(Int(udpInputPort))
    item.addArgument("--exit-with-parent")
    return item
}

private func publishFillerStatus(trackCount: Int) {
    statusFunction = "Filler"
    stationName = fillerUsesCustomSource && trackCount > 0 ? "Filler" : "Monitor Beacon"
    modulation = ""; frequencyDisplay = ""
    sampleRate = Self.outputSampleRate
    tunerGain = 0; squelchLevel = 0; options = ""; audioOutputFilter = ""
    tunerAGC = false; directSamplingQBranch = false
    signalLevel = 0
    activeFrequencyID = nil
    activeDeviceSerial = ""; activeDeviceIndex = -1; activeChannelCount = 0
}
```

**Taps deliberately skipped for filler** — no `addTranscriberStageIfEnabled()`,
`addSpatialGainStageIfEnabled()`, or `addBinauralPannerStageIfEnabled()`. Filler
is background audio; captions/spatial on the Monitor Beacon add nothing.

### 3.7 Gain ramp (fade in / fade out)

```swift
/// Sends `dist <v>` steps to the filler's PCMDistanceGain over `ms`.
/// Fire‑and‑forget UDP; harmless if the stage isn't running.
private func rampFillerGain(from start: Double, to end: Double, ms: Int) {
    let gen = fillerGeneration
    let steps = 20
    let stepMs = max(1, ms / steps)
    Task { [weak self] in
        for i in 1...steps {
            guard let self, self.fillerGeneration == gen else { return }
            let v = start + (end - start) * Double(i) / Double(steps)
            self.sendUDPMessage("dist \(v)\n", toPort: self.fillerControlPort)
            try? await Task.sleep(nanoseconds: UInt64(stepMs) * 1_000_000)
        }
    }
}
```

`sendUDPMessage(_:toPort:)` already exists on `SDRController` (`SDRController.swift:207`).

### 3.8 Fade the filler out when a program starts

```swift
/// Called at the top of every real‑source builder. If the filler is playing:
///   • fade enabled  → ramp gain down, schedule SIGTERM after fillerFadeMs,
///                      and RETURN the filler processes so the caller folds
///                      them into launchCurrentPipeline(dying:). The new
///                      pipeline then can't start until the filler is gone,
///                      so the two PCMUDPSenders never both target LAS.
///   • fade disabled → terminate the filler now, return [].
/// No‑op (returns []) when the filler isn't running.
private func fadeOutOrStopFiller() -> [Process] {
    guard taskMode == .filler else { return [] }
    let procs = fillerPipelineManager.taskItems.compactMap { $0.process }.filter { $0.isRunning }

    guard fillerFadeEnabled, !procs.isEmpty else {
        fillerPipelineManager.terminate()
        return []
    }

    fillerGeneration &+= 1
    let gen = fillerGeneration
    rampFillerGain(from: 1.0, to: Self.fillerFadeFloor, ms: fillerFadeMs)
    Task { [weak self] in
        try? await Task.sleep(nanoseconds: UInt64(fillerFadeMs) * 1_000_000)
        guard let self, self.fillerGeneration == gen else { return }
        // Detach from the manager without a second SIGTERM storm, then stop.
        self.fillerPipelineManager.terminate()
    }
    return procs
}
```

> **`waitForProcessesToExit` interaction.** `launchCurrentPipeline`
> (`SDRController.swift:1006`) already does
> `await Self.waitForProcessesToExit(dying)` (default `timeout: 2.5`). Passing the
> faded filler processes in `dying` makes the new program's audio start right
> after the fade completes and the processes exit. Keep `fillerFadeMs` < ~2 s.
> When `fadeOutOrStopFiller()` returns a non‑empty list, **force**
> `waitForDyingProcesses: true` in that builder's `launchCurrentPipeline` call
> (matters only for `startControlBoothListening`, which sometimes passes `false`).

### 3.9 Re‑enter the filler when a program stops

`terminateTasks()` (`SDRController.swift:952`) is the single stop choke point.

```swift
func terminateTasks(enterIdle: Bool = true) {
    pipelineStartTask?.cancel()
    pipelineStartTask = nil
    radioTaskPipelineManager.terminate()
    cleanUpSpeechSynthTextFile()
    cleanUpAnnouncementClip()
    transcriptFileURL = nil
    resetCaptions()
    taskMode = .stopped
    activeFrequencyID = nil
    statusFunction = "No active tuning"
    signalLevel = 0
    activeDeviceSerial = ""
    activeDeviceIndex = -1
    activeChannelCount = 0

    if enterIdle, fillerEnabled {
        startFillerPipeline()      // sets taskMode = .filler
    } else {
        fillerPipelineManager.terminate()
    }
}
```

`startFillerPipeline()` never calls `terminateTasks()` (it uses
`fillerPipelineManager` directly), so there is no recursion.

**Caller updates:**

| Caller | Change |
|---|---|
| `ContentView.teardownServices()` (`ContentView.swift:199`) | `sdrController.terminateTasks(enterIdle: false)` — app is quitting |
| `NowPlayingView.togglePlayback()` (`:104`) | keep default; also see §5 for the `.filler` UI state |
| `StatusView` (`:48`) | keep default |
| `AntennaHeadHTTPServer` `/controlboothstop.html` (`:778`), `apiStopResponse` (`:1013`), `apiControlBoothStopResponse` (`:1107`) | keep default (stop ⇒ return to filler). Add a true‑silence route — see §6. |
| `ControlBoothEventReceiver` (`:113`) | keep default |

### 3.10 React to a Configuration change without a full service restart

```swift
/// Called by ConfigurationView after saveFillerSettings().
func fillerSettingsDidChange() {
    if fillerEnabled {
        if taskMode == .stopped || taskMode == .filler { startFillerPipeline() }  // (re)build with new opts
    } else if taskMode == .filler {
        terminateTasks(enterIdle: false)                                          // go silent now
    }
}
```

### 3.11 Wire the 6 real‑source builders

Each builder gets two lines. `startPipeline(with:)` covers the three
frequency/scan entry points at once.

```swift
// near the top, where `dying` is captured:
let fadingFiller = fadeOutOrStopFiller()
...
// at the end:
launchCurrentPipeline(dying: dying + fadingFiller /*, waitForDyingProcesses: true if fadingFiller non-empty */)
```

Sites:

1. `startPipeline(with:)` — `SDRController.swift:1219`
2. `startTasksForDevice(deviceName:deviceAudioOutputFilter:)` — `:454`
3. `startTasksForRecording(fileName:repeatAudio:)` — `:502`
4. `startControlBoothListening(name:)` — `:592` (async; force `waitForDyingProcesses: true` when `fadingFiller` non‑empty)
5. `startGqrxListening(channels:)` — `:673`
6. `startTextToSpeech(files:randomOrder:repeatForever:)` — `:728`

> Optional tidy‑up: fold the repeated
> `let dying = …filter { $0.isRunning }; sweepOrphanedHelpers(); …` preamble
> plus `fadeOutOrStopFiller()` into one `private func prepareForNewPipeline() -> (dying: [Process], fadingFiller: [Process])`.
> Not required for correctness.

---

## 4. App launch — start the filler once services are up

In `ContentView`'s service‑startup method (the one containing
`lasProcess.start(...)`, ~`ContentView.swift:193`), after LAS is started:

```swift
// Loop the Monitor Beacon while nothing is tuned. Deferred so LAS has bound
// its UDP input first — otherwise the filler's PCMUDPSender's first datagram
// can hit a closed port and SIGPIPE the chain (cf. the ControlBooth
// PCMUDPReceiver readiness race, 2026‑09‑04).
Task { @MainActor in
    await lasReady()                       // reuse the readiness signal WebRadioView
                                           // uses (WebRadioView.swift:252), OR:
    // try? await Task.sleep(nanoseconds: 1_000_000_000)   // ~1 s fallback
    if sdrController.taskMode == .stopped, sdrController.fillerEnabled {
        sdrController.startFillerPipeline()
    }
}
```

If no reusable LAS‑ready signal exists, the 1 s sleep is an acceptable v1.

---

## 5. Views

### 5.1 `NowPlayingView` (`Views/Detail/NowPlayingView.swift`)

- `togglePlayback()` currently branches on `isPlaying`. Change the "playing"
  test to `sdrController.isPlayingRealSource` so the play/stop control reflects
  *program* state, not filler.
- When `sdrController.isFillerPlaying`, show a subtle row: **"Filler · Monitor
  Beacon"** with a **"Stop filler"** button → `sdrController.terminateTasks(enterIdle: false)`.
- Selecting a Favorite while filler plays works unchanged — the builder's
  `fadeOutOrStopFiller()` handles the handoff.

### 5.2 `StatusView` / `StatusWebView`

`statusFunction` / `stationName` already surface ("Filler" / "Monitor Beacon").
Add a "Stop filler" affordance mirroring NowPlayingView, or leave Status
read‑only and rely on NowPlayingView + Configuration.

### 5.3 `ConfigurationView.swift` — new "Filler Audio" section

State (defaults reflect **feature‑on**):

```swift
@State private var fillerEnabled = true
@State private var fillerFadeEnabled = true
@State private var fillerUsesCustomSource = false
@State private var fillerShuffle = false
@State private var fillerGapSeconds = 0
```

Section, modelled on the Speech‑to‑Text block (`ConfigurationView.swift:91`):

```swift
Section {
    Toggle("Play filler audio when nothing is tuned", isOn: $fillerEnabled)
        .onChange(of: fillerEnabled) { _, _ in saveFillerSettings() }
    Toggle("Fade out when a station is selected", isOn: $fillerFadeEnabled)
        .onChange(of: fillerFadeEnabled) { _, _ in saveFillerSettings() }
        .disabled(!fillerEnabled)
    Toggle("Use my own audio instead of the Monitor Beacon", isOn: $fillerUsesCustomSource)
        .onChange(of: fillerUsesCustomSource) { _, _ in saveFillerSettings() }
        .disabled(!fillerEnabled)
    if fillerUsesCustomSource {
        Toggle("Shuffle", isOn: $fillerShuffle)
            .onChange(of: fillerShuffle) { _, _ in saveFillerSettings() }
        Stepper("Gap between tracks: \(fillerGapSeconds) s",
                value: $fillerGapSeconds, in: 0...30)
            .onChange(of: fillerGapSeconds) { _, _ in saveFillerSettings() }
        Button("Show Filler Folder in Finder") { showFillerFolderInFinder() }
    }
} header: {
    Text("Filler Audio")
} footer: {
    Text("When no station, device, or other source is active, AntennaHead loops "
       + "filler audio so the stream is never silent. The built‑in Monitor Beacon "
       + "plays by default. Selecting a program fades the filler out over about "
       + "\(sdrController.fillerFadeMs) ms. For custom audio, put AAC / MP3 / WAV "
       + "files in the \u{201C}Filler\u{201D} folder inside your Recordings folder.")
        .font(.caption).foregroundStyle(.secondary)
}
```

`reloadSettings()` additions (note the default‑on read — absent ⇒ `true`):

```swift
fillerEnabled        = (((try? SQLiteController.shared.appSettingsValue(forKey: SDRController.fillerEnabledKey)) ?? nil) ?? "1") != "0"
fillerFadeEnabled    = (((try? SQLiteController.shared.appSettingsValue(forKey: SDRController.fillerFadeEnabledKey)) ?? nil) ?? "1") != "0"
fillerUsesCustomSource = (((try? SQLiteController.shared.appSettingsValue(forKey: SDRController.fillerUseCustomKey)) ?? nil)) == "1"
fillerShuffle        = (((try? SQLiteController.shared.appSettingsValue(forKey: SDRController.fillerShuffleKey)) ?? nil)) == "1"
fillerGapSeconds     = Int((((try? SQLiteController.shared.appSettingsValue(forKey: SDRController.fillerGapKey)) ?? nil)) ?? "") ?? 0
```

`saveFillerSettings()`:

```swift
private func saveFillerSettings() {
    let s = SQLiteController.shared
    try? s.storeAppSettingsValue(fillerEnabled ? "1" : "0",       forKey: SDRController.fillerEnabledKey)
    try? s.storeAppSettingsValue(fillerFadeEnabled ? "1" : "0",   forKey: SDRController.fillerFadeEnabledKey)
    try? s.storeAppSettingsValue(fillerUsesCustomSource ? "1":"0", forKey: SDRController.fillerUseCustomKey)
    try? s.storeAppSettingsValue(fillerShuffle ? "1" : "0",       forKey: SDRController.fillerShuffleKey)
    try? s.storeAppSettingsValue("\(fillerGapSeconds)",           forKey: SDRController.fillerGapKey)
    sdrController.fillerSettingsDidChange()
}
```

---

## 6. Web layer (`AntennaHeadHTTPServer.swift`)

- **Now Playing fragment / `/nowplayingstatus.html` / `/api/v1` now‑playing:**
  `statusFunction` = "Filler" flows through already. Add a boolean to the JSON so
  the page can pick the button:
  - `/api/v1` now‑playing (`apiNowPlayingResponse()`): add `"filler": sdrController?.isFillerPlaying == true`.
  - HTML now‑playing poll payload: add the same flag.
- **New route `/fillerstop.html`** (mirrors `/controlboothstop.html`, `:778`):
  ```swift
  case "/fillerstop.html":
      sdrController?.terminateTasks(enterIdle: false)
      return htmlFragmentResponse(nowPlayingFragmentHTML())
  ```
  Shown as a "Stop filler" button only when `filler` is true.
- **New route `/api/v1/filler/stop`** — typed sibling for remote clients that need
  true silence rather than "stopped ⇒ back to filler":
  ```swift
  sdrController?.terminateTasks(enterIdle: false)
  return apiNowPlayingResponse()
  ```
- Existing `/api/v1` stop and `/controlboothstop.html` keep default behavior:
  stopping a program returns to filler. Document this in the API README.

---

## 7. Recording interaction

`LiveAudioServerProcessManager.startRecording(at:useToneFiller:)`
(`LiveAudioServerProcessManager.swift:354`) flips LAS to an internal test tone via
`/api/filler-mode` when `useToneFiller == true`. If the filler pipeline is
feeding real PCM, LAS never emits that tone.

Rule: **suppress the filler only for a tone‑filler test recording.**

- In both recording‑start paths — `AntennaHeadHTTPServer.startAACRecording()` and
  the `ControlBoothEventReceiver` `RecS` handler (`:149`) — when `useToneFiller`
  is true and `sdrController.taskMode == .filler`, call
  `sdrController.terminateTasks(enterIdle: false)` before starting the recording.
- On recording stop, if `fillerEnabled && sdrController.taskMode == .stopped`,
  call `sdrController.startFillerPipeline()`.
- A **normal** (silence‑filler) recording may run with the beacon underneath — it
  captures the beacon instead of digital silence, which is arguably preferable.
  No change for that case.

---

## 8. Port docs

Add UDP **6026 — PCMDistanceGain (filler gain control)** to:

- `NETWORK_PORTS.md` (workspace doc)
- `AntennaHead/README.md` port table

Note that 6024 and 6026 are both `PCMDistanceGain` control ports — 6024 is the
spatial‑audio instance in the program pipeline, 6026 is the filler instance.

---

## 9. Build & verify

> **Xcode GUI gotcha (2026‑08‑01):** close the ControlBooth `.xcodeproj` before
> building AntennaHead — both referencing the same local Swift packages causes
> spurious GUI build failures. `xcodebuild` from the CLI is unaffected.

```bash
cd antennahead-umbrella/AntennaHead
xcodebuild -project AntennaHead.xcodeproj -scheme AntennaHead \
           -configuration Debug -destination 'platform=macOS' \
           -allowProvisioningUpdates build      # normal signing — never CODE_SIGNING_ALLOWED=NO
```

Checks:

1. `AntennaHead.app/Contents/Resources/Monitor_Beacon.wav` exists;
   `Contents/Resources/Web/Monitor_Beacon.*` gone.
2. Launch with no station tuned → within ~1 s the Logs window shows
   `PCMFilePlayer` + `PCMDistanceGain` + `PCMUDPSender` (source "filler") and the
   web player plays the beacon loop seamlessly (49.76 s cycle, no silence gap).
3. Now Playing shows **"Filler · Monitor Beacon"** with **Stop filler**.
4. Tune a Favorite → beacon fades over ~700 ms, then the station; no overlap /
   garble during the handoff.
5. Stop the station → beacon fades back in.
6. Repeat 4–5 for: ad‑hoc Tuner, category scan, Core Audio device, Gqrx,
   ControlBooth listen, Text‑to‑Speech, recording playback.
7. Configuration → turn **off** "Play filler audio…" → beacon stops immediately,
   stream goes to LAS silence. Turn it back on → beacon resumes.
8. Tone‑filler **Test Recording** (ControlBooth `ScheduleEditorView` button or
   `/api/aac-recorder/start` with tone) → beacon stops, LAS tone is audible in
   the capture; after stop, beacon resumes.
9. App quit while beacon plays → clean teardown, no orphaned `PCMFilePlayer`
   (parent‑death watchdog + `--exit-with-parent`).
10. New unit test: `fillerEnabled` / `fillerFadeEnabled` return `true` when their
    keys are absent.

---

## 10. Staging

**Phase 1 — core (default‑on beacon, hard cut).** ~1 day.
WAV move + pbxproj; `TaskMode.filler`; settings keys + accessors (default‑on);
`fillerPipelineManager`; `startFillerPipeline()` (beacon only, no
`PCMDistanceGain`, no fade); `terminateTasks(enterIdle:)`; launch‑time start;
Configuration section with just the enable toggle; `/fillerstop.html` + Now
Playing "Filler / Stop filler" state; port docs.

**Phase 2 — fade.** `PCMDistanceGain` in the filler chain; `fadeOutOrStopFiller()`
folded into the 6 builders; `rampFillerGain` (in and out); `waitForDyingProcesses`
forced true when fading; fade toggle + `fillerFadeMs`; tone‑filler recording
suppression.

**Phase 3 — custom source.** `<Recordings>/Filler/` enumeration, shuffle, gap,
"Show Filler Folder in Finder". Later: a "Choose Folder…" picker that copies
selected files into the container (a helper child can't read an arbitrary
security‑scoped folder — same constraint that shapes Text‑to‑Speech).

---

## 11. Risks & open items

| Risk / question | Handling |
|---|---|
| LAS not bound when the launch‑time filler's `PCMUDPSender` sends its first datagram → SIGPIPE | Defer the launch start behind an LAS‑ready signal (preferred) or a ~1 s sleep (acceptable v1). |
| Both `PCMUDPSender`s (filler + new program) briefly target `udpInputPort` → ~0.7 s garble | Prevented: `fadeOutOrStopFiller()` returns the filler procs, they go into `dying`, `launchCurrentPipeline` waits them out before starting the program. Do **not** skip the wait when `fadingFiller` is non‑empty. |
| `fillerFadeMs` ≥ `waitForProcessesToExit` timeout (2.5 s) → filler SIGKILLed mid‑fade | `fillerFadeMs` clamped to ≤ 1800 ms. |
| `PCMDistanceGain` control socket without `SO_REUSEADDR` → bind failure on rapid stop/start/stop of the filler | Verify in `PCMDistanceGain/main.swift`; if missing, add `SO_REUSEADDR` (matches `PCMMixer`) or a short bind retry. |
| `.filler` leaking into UI that assumes `taskMode != .stopped` means "user is listening" (menu commands, `/api`, Now Playing) | Introduce `isPlayingRealSource` / `isFillerPlaying`; audit each `taskMode` / `isPlaying` read. |
| Bundle size +9.3 MB for the WAV | Accepted. To shrink later, switch the default to `Monitor_Beacon.mp3` (+199 KB) — one string in `beaconFillerURL`; `PCMFilePlayer` decodes/upsamples it fine. |
| Custom filler folder — sandbox | v1 = files dropped in `<Recordings>/Filler/` (the `PCMFilePlayer` child can read `SharedRecordingFolder`, proven by `startTasksForRecording`). Arbitrary‑folder picker deferred to Phase 3 with copy‑into‑container. |
| Second `TaskPipelineManager` and its 5 s liveness monitor | Fine — it only watches the 2–3 filler stages; on a filler stage crash it self‑terminates and logs, same as the program manager. `terminateTasks(enterIdle: false)` and `fillerSettingsDidChange()` both stop it. |
