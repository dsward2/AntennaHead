# Apple Events Channel: AntennaHead ↔ ControlBooth

AntennaHead and ControlBooth communicate over a **bidirectional Apple Events channel**. Both directions are active simultaneously whenever both apps are running on the same Mac.

The channel is implemented in two Swift files:

| File | Role |
|---|---|
| `AntennaHead/Services/ControlBoothClient.swift` | Sends events **to** ControlBooth |
| `AntennaHead/Services/ControlBoothEventReceiver.swift` | Receives events **from** ControlBooth |

---

## Direction 1 — AntennaHead → ControlBooth

**Event class: `'CBth'`** (ControlBooth Suite)

| Event ID | Function | Direct Parameter | Reply |
|---|---|---|---|
| `'Strt'` | Start a named pipeline | pipeline name (string) | — |
| `'Stop'` | Stop a named pipeline | pipeline name (string) | — |
| `'StpA'` | Stop all pipelines | — | — |
| `'List'` | List all available pipelines | — | list of strings |
| `'Runs'` | List currently running pipelines | — | list of strings |

All sends are **synchronous with an 8-second timeout** (`waitForReply`). Before constructing any event, `isControlBoothRunning` checks `NSRunningApplication` to confirm the target is alive; if not, `ClientError.notRunning` is thrown immediately. Errors returned in the reply (`errn`/`errs` keywords) are surfaced as `ClientError.eventError`.

### Sandbox authorization

AntennaHead's entitlements include `com.apple.security.scripting-targets`, targeting ControlBooth's access group `com.dsward.ControlBooth.pipelines`. This allows the sandboxed AntennaHead to send these events **without triggering an Automation consent prompt**.

---

## Direction 2 — ControlBooth → AntennaHead

**Event class: `'AntH'`** (AntennaHead Suite)

| Event ID | Function | Direct Parameter | Reply |
|---|---|---|---|
| `'Strt'` | Start listening on a custom task | task name (string) | error on failure |
| `'Stop'` | Stop listening on a custom task | task name (string) | — |
| `'Runs'` | Query the currently active task | — | list of 0 or 1 strings |
| `'RecS'` | Start recording audio to a file | file path (string) | error on failure |
| `'RecP'` | Stop recording | — | — |

All five handlers are registered at `ControlBoothEventReceiver` init time via `NSAppleEventManager`. Receiving Apple Events requires **no sandbox entitlement** on the receiving side — the sender's authorization covers the exchange.

### Threading

`NSAppleEventManager` delivers events on the main thread. Each handler uses `MainActor.assumeIsolated` to safely access `SDRController` and `LiveAudioServerProcessManager`. The recording handlers (`'RecS'`/`'RecP'`) schedule their actual work on `DispatchQueue.main.async` so the AE reply is dispatched before any blocking call (such as `terminate()`'s `Thread.sleep`) can run.

### `'Strt'` — start listening

Resolves the task name to a database ID via `SQLiteController.allCustomTaskRecords()`, then calls `SDRController.startTasksForCustomTask(id:)`. If no custom task with that name exists, `errAENoSuchObject` (-1728) is returned to the caller.

### `'Stop'` — stop listening

A **targeted no-op**: only terminates the active pipeline if the named task matches what is currently running (`sdrController.taskMode == .customTask && sdrController.stationName == name`).

### `'Runs'` — query active task

Returns a one-item AEDesc list if a custom-task pipeline is running, or an empty list if AntennaHead is idle or running a non-custom-task source.

### Error codes used

| Constant | Value | Meaning |
|---|---|---|
| `errAEWrongNumberArgs` | -1721 | Required direct parameter is missing |
| `errAENoSuchObject` | -1728 | Named custom task not found in database |
| `errAEEventFailed` | -10000 | Pipeline start failed or `SDRController.lastError` set |

---

## Lifecycle

`ControlBoothEventReceiver` is created once in `ContentView.onAppear` and held for the app's lifetime:

```swift
controlBoothEvents = ControlBoothEventReceiver(sdrController: sdrController, lasManager: lasProcess)
```

The "Enable remote control with ControlBooth app" toggle in the Configuration tab controls whether the ControlBooth menu item appears in the web UI, but the AE handlers are registered unconditionally — ControlBooth can always send commands to AntennaHead as long as both apps are running.
