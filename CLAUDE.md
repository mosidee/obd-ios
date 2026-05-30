# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

This is an iPhone (SwiftUI) app that reads live engine parameters off a **Toyota Sienta** which runs a **EuropeGas Avance48 LPG (gas) ECU**.

The constraint that shapes the whole design: the Avance48 stays permanently wired to the vehicle's OBD-II port for its own **auto-tuning** — it reads the petrol ECU's data over OBD (fuel trims, RPM, coolant, etc.) to calibrate gas delivery. A typical third-party ELM327 OBD app actively requests PIDs on that same bus, and that extra request traffic collides with the gas ECU's own OBD reads and disrupts its tuning.

That is why **Listen-Only mode** exists (see below): instead of flooding the bus with requests, the app can passively sniff the standard PIDs the Avance48 (or another tester) is already polling, and only briefly transmit for the two values nobody else requests (engine-oil and ATF temp, which have no standard PID). The goal is to observe the car without interfering with the gas ECU's tuning. Active Polling mode is the conventional alternative for when nothing else is on the bus.

**Adapter:** Vgate iCar Pro 2S (ELM327 v2.3, BLE). **Vehicle bus:** ISO 15765-4 CAN, 11-bit IDs, 500 kbps.

## Build & Validate

Use the Xcode MCP tools:
- **Build**: `mcp__xcode-tools__BuildProject`
- **Quick diagnostics** (no full build): `mcp__xcode-tools__XcodeRefreshCodeIssuesInFile` — use this after editing Swift files to catch type errors fast
- **Render preview**: `mcp__xcode-tools__RenderPreview` on `ContentView.swift`

**Tests**: Run via Xcode's Test action (⌘U) on the `OBD ELM327 ConnectorTests` target. Tests use the Swift Testing framework (`import Testing`, `@Suite`/`@Test`/`#expect`) and cover `OBDParser` (frame assembly, token stripping, `mode01Values` PID walking, `rawByte`) plus the value-conversion formulas. `xcodebuild` is unavailable from the CLI here (only CommandLineTools is installed), so tests can't be run from the shell.

There is also a portable, client-agnostic protocol spec at **`docs/PROTOCOL.md`** describing both modes in command-by-command detail — keep it in sync when the polling chain or listen flow changes.

## Architecture

Five source files; four carry the logic, one is the app entry point.

**`OBDELM327ConnectorApp.swift`** — `@main` entry. Sets `UIApplication.shared.isIdleTimerDisabled` from the `keepScreenAwake` setting (default true) and shows `ContentView`.

**`OBDBluetoothManager.swift`** — Pure BLE transport for the Vgate adapter. Scans for ELM327 adapters (service UUIDs FFF0/18F0/FFE0; write FFF1/18F1/FFE1; notify FFF2/18F2/FFE1), manages the `CBCentralManager` lifecycle, buffers incoming chunks and splits on `\r` into an `AsyncStream<String>` of complete ELM327 lines. The `>` command prompt is emitted as its own sentinel line (used by the header-restore step). Contains zero OBD logic. `CBCentralManager` is created only when `startScanning()` is called (not at `init()`), which keeps SwiftUI previews safe. A 12 s watchdog (`armConnectionTimeout`) fails a stuck `.connecting` state.

**`OBDViewModel.swift`** — All OBD logic. A `@MainActor` `ObservableObject` state machine. Lines from `OBDBluetoothManager.lines` are consumed by one long-lived `streamTask` (never cancelled — the `AsyncStream` is not restartable) and routed by `route()` based on `QueryState`, decoded via an owned `OBDParser` (`private var parser = OBDParser()`). Publishes `stft`, `ltft`, `coolantTemp`, `engineOilTemp`, `atfTemp`, `engineSpeed`, `throttlePosition`, `accelPedal`, plus `connectionStatus` / `isConnected` / `lastUpdate` and the `communicationLog`.

**`OBDParser.swift`** — Frame decoding, extracted from `OBDViewModel` so it's unit-testable without `@MainActor`/Bluetooth. A `struct` holding the multi-frame accumulation state; exposes `completePayloadTokens(from:)` (mutating, multi-frame), `responsePayloadTokens(from:)` (stateless, single-frame), `reset()`, and the statics `mode01Values(from:lengths:)` and `rawByte(after:in:)`. Contains zero CoreBluetooth or UI code.

**`ContentView.swift`** — Observes `OBDViewModel` via `@StateObject`. Renders four cards: Fuel Trims (STFT + LTFT cells; the header shows the STFT+LTFT total), Fluid Temperatures (Coolant / Trans Fluid / Engine Oil, each with a Normal/Warm/Hot colour badge), Engine (RPM / Throttle / Pedal), and an optional live TX/RX log card shown only when the `loggingEnabled` setting is on. Includes a `SettingsView` sheet — Listen-Only toggle, polling interval slider (0.5–10 s), keep-screen-awake (`UIApplication.shared.isIdleTimerDisabled`), and the TX/RX logging toggle — all `@AppStorage`-backed. Uses a `#if DEBUG` extension `init(viewModel:)` + the `OBDViewModel.preview` static factory for SwiftUI previews.

## OBD Polling Chain (Active Polling mode)

Each cycle executes in sequence; each parser calls the next `begin*Query()` on success, NRC (`7F`), or terminal error:

```
passive (pollingDelay wait, default 1.0 s)
  → queryingStandard    ATSH7E0 + 01 05 0C 11 06 07 49   (SAE J1979 Mode-01 multi-PID)
                                          coolant  05 → A−40 → °C
                                          RPM      0C → (256A+B)/4
                                          throttle 11 → A×100/255 %
                                          STFT/LTFT 06/07 → A×100/128−100 %
                                          accel    49 → A×100/255 %
  → queryingEngineOil   ATSH7E0 + 2151  engine oil: payload[11] − 40 → °C  (Toyota enhanced)
  → queryingATF         ATSH7E0 + 2182  ATF:        first byte after [61 82] − 40 → °C  (Toyota enhanced)
  → restoringHeader     ATCEA + ATSH7DF
  → passive
```

Coolant, RPM, throttle, and fuel trims always come from standard Mode-01 PIDs. Engine oil and ATF have no standard equivalent on this ECU, so they stay Toyota-enhanced (`2151`/`2182`).

Before sending each command, every `begin*Query()` sends `ATCEA` (disable CAN extended addressing) then the target header (`ATSH7E0`), with 150 ms delays between, then the OBD command. A 5-second watchdog (`armActiveTimeout`) auto-advances to the next step if no response arrives. The entry point is `triggerActiveQuery()` → `beginStandardQuery()`, fired by `scheduleNextActiveQuery()`.

## Listen Mode (alternating poll + passive standard-PID monitor)

This is the mode that lets the app coexist with the Avance48 gas ECU on the shared bus. Gated by the `listenOnlyMode` setting (read in `runELM327Init()` into `listenModeActive`, so it applies on connect). Because the six standard values (coolant/RPM/throttle/STFT/LTFT/pedal) have generic Mode-01 PIDs another tester is already polling, but engine oil and ATF do **not**, and the ELM327 can't monitor (`ATMA`) and request at the same time, the mode **alternates**:

```
beginListenOnly()  ATCM7FF + ATCF7E8   (mask 0x7FF / filter 0x7E8 = exactly 7E8, the engine ECU's response ID)
  → beginEngineOilQuery   2151  engine oil  (active request, CAF on)
  → beginATFQuery         2182  ATF         (active request)
  → beginListenWindow     ATCAF0 + ATMA, monitor for one pollingDelay interval
        parseListeningLine: standard 41 responses → mode01Values → 6 standard values
  → exitMonitorThenPoll   " ATCAF1" (leading space stops ATMA, then restores auto-formatting)
  → beginEngineOilQuery … (repeat)
```

`afterATFCycle()` is the branch point: `listenModeActive ? beginListenWindow() : returnToPassive()`. All four ATF-cycle exits (success, NRC, terminal error, watchdog) call it, so the mode never falls through to active standard requests. The six standard values are sniffed passively — they update only while another tester (e.g. the Avance48) is polling them on the bus, **and** only outside each brief oil/ATF poll window. The 7E8 filter is also correctness for the monitor phase: `OBDParser` holds one shared multi-frame accumulator that any other CAN ID would reset mid-sequence.

Stopping `ATMA` with a leading-space-prefixed command (never a bare `CR`, which the ELM327 treats as "repeat last command" = restart `ATMA`) is the one part unverified on the Vgate clone; if it doesn't discard the leading byte, CAF stays off, the `2151`/`2182` requests go out malformed and unanswered, and the symptom is oil/ATF staying blank with ~5 s stutters (the watchdog firing). See the `exitMonitorThenPoll` doc-comment.

"Listen-Only" is a slight misnomer — the poll phase does transmit `2151`/`2182`. But those two PIDs are not what the Avance48 polls, so this is the minimum transmission needed and still avoids competing for the standard PIDs.

## ELM327 Initialisation (run once per connect)

`runELM327Init()` sends, with per-command delays: `ATZ` (2 s, soft reset), `ATE0` (echo off), `ATL0` (linefeeds off), `ATH1` (headers on — CAN ID shown per frame, required for parsing), `ATS1` (spaces on, easy tokenisation), `ATSP6` (protocol 6 = ISO 15765-4 CAN 11-bit 500 kbps), `ATCEA`, `ATSH7DF` (default functional header). CAN auto-formatting (`CAF`) is left **on** and only disabled (`ATCAF0`) inside a listen-mode monitor window. Then it branches: `beginListenOnly()` if `listenOnlyMode`, else `scheduleNextActiveQuery()`.

## Two Parsing Strategies

Both live on the `OBDParser` struct; the ViewModel calls them through its `parser` instance.

**`completePayloadTokens(from:)`** — Stateful (`mutating`), multi-frame aware. Strips the CAN response ID (e.g. `7E8`) and an extended address byte `18` if present, then accumulates ISO-TP first frames (`0x10–0x1F`) and consecutive frames (`0x20–0x2F`) into `multiFramePayload`, returning the complete payload only once `count >= expectedLength`, or `nil` while still accumulating. Single-frame responses (length nibble `≤ 0x0F`) return their stripped payload immediately. Used for the enhanced engine-oil `2151` and the standard Mode-01 multi-PID response (both in active polling and the `41` frames listen mode sniffs).

**`responsePayloadTokens(from:)`** — Stateless single-frame stripper. Drops the optional CAN ID, extended address byte `18`, and length / first-frame header bytes (recognising `41`/`61`/`62`/`7F` service bytes), then returns remaining tokens. Used for `2182` (ATF), a known single-frame response.

**`mode01Values(from:lengths:)`** (static) — walks a `41`-prefixed Mode-01 payload into a `pid → [data byte]` map, using `lengths` for each PID's byte count. Stops at the first unknown PID or truncation so a trailing unsupported PID can't corrupt earlier values.

**`rawByte(after:in:)`** (static) — returns the byte immediately following a token sequence (e.g. the ATF byte after `[61, 82]`).

## Adding a New PID

1. Add constants for the header command and OBD command string.
2. Add a `queryingFoo` case to `QueryState`.
3. Add a `beginFooQuery()` that cancels the timeout, resets the multi-frame buffer (`parser.reset()`), sets state, and sends `ATCEA → header → command` with 150 ms delays.
4. Add a `parseFooLine(_:)` using `parser.completePayloadTokens` (multi-frame) or `parser.responsePayloadTokens` (single-frame). Check `payload.first == "7F"` for NRC. On success, update the published property, set `lastUpdate`, and call the next `begin*Query()`.
5. Add a `handleNonFrameFooLine` that calls the next step on terminal errors (`NO DATA` / `ERROR` / `UNABLE TO CONNECT`).
6. Wire the new case into `route()` and `armActiveTimeout()`.
7. Chain it into the polling cycle by changing the preceding step's success/NRC/error calls to `beginFooQuery()`.

## Polling Rate

`scheduleNextActiveQuery()` (and the listen-mode monitor window) reads the user-configurable `pollingDelay` setting from `SettingsView`, defaulting to 1.0 s:
```swift
let stored = UserDefaults.standard.double(forKey: "pollingDelay")
let delay = stored > 0 ? stored : 1.0   // seconds between cycles
```

## Logging (TX/RX + Tuning CSV)

Two independent logs, each gated by its own `@AppStorage` toggle, both written to the Documents directory as **one timestamped file per connection** (created lazily on the first write of a session, so a session with the toggle off leaves no file). A single `sessionTimestamp` captured in `connect()` names both files for that connection:

- **TX/RX diagnostic log** (`loggingEnabled`): every sent command and received line is appended to the in-memory `communicationLog` (capped at `maxLogEntries = 120`) and to `obd_txrx_<yyyy-MM-dd_HH-mm-ss>.txt`. The log card in `ContentView` shows the live tail with copy/clear; "clear" now only empties the on-screen `communicationLog` (file deletion lives in the manager). When the toggle is off, `appendLog` returns early.
- **Tuning CSV** (`dataLoggingEnabled`): one row per decoded standard Mode-01 frame — `timestamp,STFT,LTFT,RPM,Throttle,Pedal,Coolant` (all sampled from the same frame) — written via `logTuningSample()` in both `parseStandardLine` and `parseListeningLine` to `obd_tune_<yyyy-MM-dd_HH-mm-ss>.csv`. The Tuning Data Log card shows the row count and a `ShareLink` (AirDrop) to the current session file.

`currentTxRxFileURL` / `currentDataLogFileURL` are published optionals pointing at the active-session files (nil until the first write). `OBDViewModel.savedLogFiles()` lists all `obd_txrx_*`/`obd_tune_*` files (newest first) and `deleteLogFiles(_:)` removes them. `LogManagerView` (a sheet opened from the folder toolbar button, always reachable regardless of toggles) presents the saved files with a selection mode — Select All / Deselect All, then Share (AirDrop the selected set) or Delete.

## On-car Verification Status

The standard Mode-01 path for the five live values (coolant/RPM/throttle/STFT/LTFT — and the accel-pedal PID `49`) is **not yet confirmed on this specific car**; the captured transcripts only ever confirmed the older Toyota-enhanced `2101` coolant/RPM path on the Sienta. The enhanced `2101`/`2103` path has since been removed — both modes now use standard Mode-01 frames for these values. The leading-space `ATMA` stop in listen mode is likewise unverified on the Vgate clone (see Listen Mode above). Treat both as open until validated on the vehicle.

## Preview

`OBDViewModel.preview` (inside `#if DEBUG`) constructs a pre-populated instance with sample values. The `init()` body returns early when `XCODE_RUNNING_FOR_PREVIEWS == "1"` to skip Bluetooth setup. `ContentView` gains a debug `init(viewModel:)` via a `#if DEBUG` extension so the synthesised no-arg `init()` still works in production.
