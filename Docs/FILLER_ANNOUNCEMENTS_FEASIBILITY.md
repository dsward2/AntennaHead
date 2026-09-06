# Filler Announcements — Feasibility Study

**Question:** can AntennaHead layer a periodic spoken announcement over the Filler
audio, using `PCMSpeechSynth` for the voice and `PCMMixer` (with ducking) to blend
it under the Monitor Beacon / custom filler? First target: a once‑per‑minute
"Welcome to AntennaHead software defined radio".

**Date:** 2026-09-06
**Scope reviewed:** `SDRController.swift` filler + announcement code (post‑PR #7),
`PipelineHelpers` `PCMMixer` / `PCMSpeechSynth` / `PCMFilePlayer` / `PCMDistanceGain`,
`NETWORK_PORTS.md`.

---

## 1. Verdict

**Feasible, low‑to‑moderate effort (~1.5–2 days), no architectural obstacles.**
Every process in the chain already exists and is already embedded in
`AntennaHead.app/Contents/Helpers/`. The filler pipeline is already built around a
dedicated `TaskPipelineManager` (`fillerPipelineManager`) whose lifecycle is
independent of the program pipeline, which is exactly the seam this feature needs.

**The one real gap:** `PCMMixer` has **no ducking feature today**. It does
sample‑wise mixing with per‑input gains that are settable live over a UDP control
port (`gain <i> <g>`, `ratio <0..1>`), but there is no sidechain / envelope
follower — nothing that automatically pulls the filler down while the
announcement is talking. Ducking therefore has to come from one of:

- **(A)** the host (SDRController) sending timed `gain` commands around each
  announcement — no helper change, but timing is open‑loop and drifts;
- **(B)** a new sidechain‑ducker mode added to `PCMMixer` — ~40 lines in the mix
  loop, self‑synchronising, robust. **Recommended.**
- **(C)** no ducking — static mix with the filler bed pinned lower. Simplest,
  not what was asked for.

---

## 2. What already exists (reusable as‑is)

| Piece | Where | Relevant capability |
|---|---|---|
| `fillerPipelineManager` | `SDRController.swift:347` | Dedicated `TaskPipelineManager` for the filler; `startFillerPipeline()` builds `PCMFilePlayer → [PCMDistanceGain] → PCMUDPSender` and `detachAllTasks()` hands processes off for fade‑out. Independent of `radioTaskPipelineManager`. |
| `PCMFilePlayer` | `PipelineHelpers/Sources/PCMFilePlayer` | Real‑time‑paced source; the filler already runs it at **48 000 Hz / 2 ch** S16LE with `--repeat --gap`. This is the mixer's clock‑master input. |
| `PCMMixer` | `PipelineHelpers/Sources/PCMMixer` | N‑input mix. **Input 0 is the clock master**; other inputs are buffered on reader threads, silence‑padded on underrun, oldest‑dropped on overflow (`ByteFIFO`, ~5 s cap). Inputs from `stdin` or `udp:<port>`; output to `stdout` or `udp:host:port`. Live control port: `gain <i> <g>`, `ratio <r>`, `gains`. Already embedded in AntennaHead (currently unused there; used by ControlBooth). |
| `PCMSpeechSynth` | `PipelineHelpers/Sources/PCMSpeechSynth` | Offline `AVSpeechSynthesizer` render → **mono** S16LE, **real‑time paced**. `--text "<string>"`, `--rate 8000–48000`, `--voice <id|lang>`, `--speech-rate`, `--repeat`, `--gap <s>` (emits **real zero PCM** during the gap, paced — so a downstream mixer input never underruns), plus a `udp:<port>` text source that re‑renders when a new datagram arrives. Runs fine inside AntennaHead's sandbox — the existing announcement + Text‑to‑Speech features already prove it. |
| `makeResampleTaskItem(inputRate:inputChannels:audioOutputFilter:)` | `SDRController.swift` | sox stage; **mono → 2 ch** duplication + resample to 48 kHz. `startTextToSpeech()` already uses it as `PCMSpeechSynth(22050 mono) → sox → PCMUDPSender`. Reuse verbatim for the announcement feeder. |
| `PCMDistanceGain` as a fader | `SDRController.swift:1310` (`makeFillerGainTaskItem`) | The filler's existing fade stage on **port 6026**. Unaffected — it sits *after* the mixer, on the post‑mix bus. |
| `sendUDPMessage(_:toPort:)` | `SDRController.swift:~1395` | Fire‑and‑forget loopback UDP; already used for the 6026 fade ramps. Reuse for mixer control. |
| Announcement settings pattern | `SDRController.swift:240` (`announcementEnabledKey`, `announcementVoiceKey`) + `ConfigurationView.swift:75` (voice picker, Preview Voice) | The "Announcements" section already has an enable toggle + validated voice picker. A "filler announcement" is a sibling of this, not a from‑scratch UI. |

**Note on the existing announcement feature:** it uses `PCMPrefix`, which plays a
rendered clip *once, before* the live audio and then passes audio through. It is
**not** an overlay and cannot repeat while a source plays. This feature is a
genuinely different mechanism (concurrent mix), so `PCMPrefix` is not reusable
here beyond the settings/voice‑validation code around it.

---

## 3. Proposed architecture

Two cooperating pipelines, each on its own `TaskPipelineManager` (mirroring how
`fillerPipelineManager` is already separate from `radioTaskPipelineManager`):

```
 fillerPipelineManager  (clock master = PCMFilePlayer, unchanged pacing)
 ┌──────────────┐   stdin    ┌──────────────────────────────┐   stdin   ┌───────────────┐   stdin   ┌─────────────┐
 │ PCMFilePlayer│──────────▶│ PCMMixer                      │─────────▶│ PCMDistanceGain│─────────▶│ PCMUDPSender │─▶ :6020 (LAS)
 │ 48k/2ch loop │            │  --input stdin  (0 = master) │           │  fade  :6026   │           │             │
 └──────────────┘            │  --input udp:6027 (1 = duck) │           └───────────────┘           └─────────────┘
                             │  --duck-input 1 …            │
                             │  --control-port 6028         │
                             └──────────────▲───────────────┘
                                            │ udp :6027  (48k/2ch S16LE, zeros between utterances)
 fillerAnnouncementManager                  │
 ┌────────────────────────────┐   stdin  ┌──┴────┐   stdin   ┌─────────────┐
 │ PCMSpeechSynth             │─────────▶│ sox   │──────────▶│ PCMUDPSender │─▶ :6027
 │ --text "Welcome to …"      │          │ 1→2ch │           │ --port 6027 │
 │ --rate 22050 --repeat      │          │ →48k  │           └─────────────┘
 │ --gap 57                   │          └───────┘
 └────────────────────────────┘
```

- The mixer's **input 0** is the filler (paced by `PCMFilePlayer`); **input 1** is
  the announcement, arriving over loopback UDP. This is precisely the mixer's
  documented design — one paced master, the rest buffered and jitter‑absorbed.
- The announcement feeder emits a **continuous** 48 kHz / 2‑ch stream: the spoken
  clip, then paced zero PCM for `--gap` seconds, forever. The mixer input never
  underruns; the ducker simply sees "silence" between utterances.
- Fade‑in/out (6026) and `stopFillerForNewSource()` still work unchanged — they
  act on the mixed bus. Selecting a real source tears down **both** managers.

### New fixed loopback ports (next free after 6026)

| Port | Proto | Purpose |
|---|---|---|
| 6027 | UDP | announcement PCM → filler `PCMMixer` input 1 |
| 6028 | UDP | AntennaHead → filler `PCMMixer` control (duck enable / params, or manual `gain`) |

---

## 4. Implementation options

### Option A — host‑timed ducking (no PipelineHelpers change)

`SDRController` runs a repeating `Task`/`Timer`. Each period: `sendUDPMessage("gain 0 0.25\n", toPort: 6028)`, wait `announcementClipEstimate + guard`, `sendUDPMessage("gain 0 1.0\n", toPort: 6028)`. The announcement feeder just runs `--repeat --gap`.

- **Pro:** zero helper changes; ships in ~1 day; all risk is in Swift you control.
- **Con:** open‑loop. The host does not know when the synth's words actually
  reach the mix (synth pacing + sox `--buffer` + UDP + mixer FIFO ≈ 100–400 ms of
  slack), so the duck window must be padded and will still occasionally clip the
  first/last syllable or duck over silence. Absolute phase drifts over hours
  because the synth's clip length is voice‑dependent and never exactly your timer
  period.

### Option B — sidechain ducker in `PCMMixer` *(recommended)*

Add a `--duck-input <i>` mode. When input *i*'s short‑window level exceeds
`--duck-threshold`, attenuate every other input by `--duck-amount` with
`--duck-attack-ms` / `--duck-release-ms` envelope smoothing.

- **Pro:** self‑synchronising — ducking tracks the *actual* announcement audio, no
  host timing, no drift, correct for any voice or clip length. Reusable for future
  overlay needs (station IDs under a tuned station, emergency messages, etc.).
- **Con:** a `PipelineHelpers` change → the 3‑layer SwiftPM cache dance + rebuild
  of the embedded helpers into `AntennaHead.app` (documented in the umbrella
  memory). ~40 lines + unit tests. Still small.

**Sketch** (in the existing mix loop, which already accumulates per‑input into
`acc: [Int32]`):

```swift
// after popping `sideData` for the duck input, before the accumulate() calls:
let sidePeak = peakAbs(sideData)                 // or windowed RMS
let target   = sidePeak > duckThreshold ? duckFloor : 1.0   // duckFloor e.g. 0.25
let coeff    = target < duckEnv ? attackCoeff : releaseCoeff
duckEnv += (target - duckEnv) * coeff            // one‑pole smoothing
// apply duckEnv to every non‑sidechain input's gain:
accumulate(chunk,           gain: gains[0] * duckEnv)
for (i, fifo) in fifos.enumerated() where i != duckIndex && fifo != nil {
    accumulate(fifo!.pop(chunk.count), gain: gains[i] * duckEnv)
}
accumulate(sidePopped,      gain: gains[duckIndex])     // sidechain itself un‑ducked
```

New args: `--duck-input <i>`, `--duck-threshold <0..1>` (default ~0.02),
`--duck-amount <dB|gain>` (default −12 dB ⇒ floor 0.25), `--duck-attack-ms`
(default 40), `--duck-release-ms` (default 400). Absent `--duck-input` ⇒ today's
behaviour exactly.

### Option C — static mix, no ducking

`PCMMixer --gain 0=0.55 --gain 1=1.0`, no control traffic. The beacon just plays
~5 dB down forever. One line. Only listed for completeness.

**Recommendation: Option B.** The extra half‑day buys a feature that is actually
correct and that you'll want again. If you want to see it working end‑to‑end
*first*, ship Option A behind the same settings and swap the ducking mechanism to
B in a follow‑up — the pipeline topology and all the SDRController wiring are
identical.

---

## 5. SDRController wiring (either option)

New settings keys (same `appSettingsValue` convention as `announcementEnabledKey`):

```swift
static let fillerAnnounceEnabledKey  = "AntennaHeadFillerAnnounceEnabled"   // default OFF
static let fillerAnnounceTextKey     = "AntennaHeadFillerAnnounceText"      // default "Welcome to AntennaHead software defined radio"
static let fillerAnnounceVoiceKey    = "AntennaHeadFillerAnnounceVoiceIdentifier"
static let fillerAnnouncePeriodKey   = "AntennaHeadFillerAnnouncePeriodSeconds"   // default 60, clamp 15…3600
```

New members:

```swift
let fillerMixerControlPort:  UInt16 = 6028
let fillerAnnouncePCMPort:   UInt16 = 6027
let fillerAnnouncementManager = TaskPipelineManager()   // onLog wired like fillerPipelineManager
```

`startFillerPipeline()` changes (only when `fillerAnnounceEnabled`):

1. Build the player as today.
2. Insert `makeFillerMixerTaskItem()` **between** the player and the (optional)
   `PCMDistanceGain` / `PCMUDPSender`:
   `--input stdin --input udp:6027 --rate 48000 --channels 2 --control-port 6028`
   plus, for Option B, `--duck-input 1 --duck-amount -12 --duck-attack-ms 40 --duck-release-ms 400`.
3. After `fillerPipelineManager.start()` succeeds, start the announcement feeder
   ~200 ms later (avoid the first‑datagram‑before‑mixer‑binds race — same reason
   the launch‑time filler start is already deferred behind LAS readiness):
   `PCMSpeechSynth(--text <text> --rate 22050 --voice <validated> --repeat --gap <period − clipEstimate>)`
   `→ makeResampleTaskItem(inputRate: 22050, inputChannels: 1, audioOutputFilter: "vol 1")`
   `→ PCMUDPSender(--port 6027)` on `fillerAnnouncementManager`.

Teardown — add `fillerAnnouncementManager.terminate()` everywhere
`fillerPipelineManager` is torn down:

- `stopFillerForNewSource()` (all 6 real‑source builders already call it)
- `terminateTasks(enterIdle:)` — both branches
- `fillerSettingsDidChange()` — and rebuild if still idle
- app quit path (`ContentView.teardownServices()` → `terminateTasks(enterIdle: false)`)

The announcement feeder does **not** need to be folded into `fadingFillerProcesses`
/ the `dying` wait — it only sends to the mixer on 6027, never to LAS on 6020, so
it can't collide with an incoming program's `PCMUDPSender`. Just SIGTERM it.

Configuration UI — a subsection under the existing **Filler Audio** section (not
the program "Announcements" section): enable toggle, text field (default filled
in), voice picker reusing `installedVoices` + `voiceLabel()` + a Preview button,
and a period stepper. `saveFillerSettings()` already calls
`sdrController.fillerSettingsDidChange()`, which becomes the rebuild trigger.

---

## 6. The specific first target

> "Welcome to AntennaHead software defined radio", once per minute.

- Clip length for that sentence ≈ **2.6–3.3 s** depending on voice and
  `--speech-rate`. So `--gap ≈ 57` gives a ~60 s cycle.
- **The cadence is approximate** (± a second or two, and the absolute phase
  slowly walks) because `--repeat --gap` measures from end‑of‑clip, and clip
  length is voice‑dependent. For casual "welcome" filler this is fine.
- **If you need exact wall‑clock cadence** (e.g. top‑of‑minute), don't use
  `--repeat`. Run `PCMSpeechSynth --input udp:<port>` (speak‑once mode) and have a
  SDRController `Task` send the announcement text as a datagram on a precise
  60 s schedule. Costs one timer; buys exact timing and lets the text change at
  runtime without restarting the pipeline. Recommended as the eventual design;
  `--repeat --gap` is the fine v1.

---

## 7. Risks & open items

| Risk / question | Assessment |
|---|---|
| `PCMMixer` has no ducking | Confirmed. Option B adds it (~40 LOC + tests) or Option A works around it in the host. |
| Input rate/channel match — mixer requires all inputs identical | Handled: announcement feeder ends with the existing mono→2ch/48k sox stage, matching the 48k/2ch filler. |
| First announcement datagram hits port 6027 before the mixer binds → `PCMUDPSender` `send()` fails and it `exit(1)`s | Start the mixer chain first, defer the announcement feeder ~200 ms (same pattern already used for the launch‑time filler behind LAS readiness). Low risk. |
| Synth clip length ≠ timer period ⇒ cadence drift | Accepted for v1 (`--repeat --gap`). Exact cadence path documented in §6 (udp‑text trigger). |
| Ducker treats inter‑utterance zero PCM as "talking" | It won't — `PCMSpeechSynth` emits true zeros during `--gap`; threshold ~0.02 (‑34 dBFS) keeps the filler at unity between utterances. |
| Fade‑out (6026) also fades the announcement when switching to a real source | It does, because the mixer is upstream of the fader. This is arguably correct (the whole idle bed goes away together); note it, don't fix it. |
| Second + third `TaskPipelineManager` on the filler side, each with a 5 s liveness monitor | Fine — same lightweight pattern already shipping for `fillerPipelineManager`; on a stage crash it self‑terminates and logs. |
| `PCMMixer` control socket `SO_REUSEADDR` | Present — `boundUDPSocket()` sets it. Rapid filler stop/start won't hit a bind failure on 6028. (`PCMSpeechSynth`'s UDP text listener also sets it.) |
| Memory (per the PCMTranscriber leak history) | `PCMSpeechSynth` renders the clip to a bounded `Data` once and loops it; `PCMMixer`'s FIFO is capped at ~1 MB with drop‑oldest and its `availableData` loop is `autoreleasepool`‑wrapped. No unbounded growth in this chain. |
| Sandbox | `PCMSpeechSynth` already runs sandboxed in AntennaHead (announcement + TTS ship). `--text` literal avoids even needing a container temp file for a fixed string. |
| Bundle / build | No new binaries — `PCMMixer` and `PCMSpeechSynth` are already in `Contents/Helpers/`. Option B still requires rebuilding the embedded `PCMMixer` from the patched `PipelineHelpers` and the documented 3‑layer SwiftPM cache refresh. |

---

## 8. Effort & staging

| Stage | Work | Est. |
|---|---|---|
| **1 — feeder + static mix (Option C/A topology)** | New settings keys + accessors; `fillerAnnouncementManager`; `makeFillerMixerTaskItem()` + feeder stages; splice mixer into `startFillerPipeline()`; teardown hooks; Configuration subsection with enable + text + voice + period. Ships the announcement audibly layered (static bed level, or Option A host‑timed duck). | ~1 day |
| **2 — real ducking (Option B)** | `--duck-input` / threshold / amount / attack / release in `PCMMixer/main.swift`; `PCMMixerTests` for envelope + "no `--duck-input` ⇒ unchanged"; rebuild embedded helper; swap SDRController to pass the duck args. | ~0.5 day |
| **3 — exact cadence (optional)** | Switch feeder to `--input udp:<port>` speak‑once + a 60 s scheduler `Task` in SDRController; runtime text change without restart. | ~0.25 day |
| Docs | `NETWORK_PORTS.md` + `AntennaHead/README.md` port table: add 6027 / 6028. | trivial |

**Total for a shippable feature: ~1.5–2 days** (Stages 1–2). No blockers, no new
dependencies, no sandbox work.
