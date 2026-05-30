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

**`OBDViewModel.swift`** — All OBD logic. A `@MainActor` `ObservableObject` state machine. Lines from `OBDBluetoothManager.lines` are consumed by one long-lived `streamTask` (never cancelled — the `AsyncStream` is not restartable) and routed by `route()` based on `QueryState`, decoded via an owned `OBDParser` (`private var parser = OBDParser()`). Publishes `stft`, `ltft`, `coolantTemp`, `engineOilTemp`, `atfTemp`, `engineSpeed`, `throttlePosition`, `engineLoad`, `injectorPulse`, plus `connectionStatus` / `isConnected` / `lastUpdate` and the `communicationLog`.

**`OBDParser.swift`** — Frame decoding, extracted from `OBDViewModel` so it's unit-testable without `@MainActor`/Bluetooth. A `struct` holding the multi-frame accumulation state; exposes `completePayloadTokens(from:)` (mutating, multi-frame), `responsePayloadTokens(from:)` (stateless, single-frame), `reset()`, and the statics `mode01Values(from:lengths:)` and `rawByte(after:in:)`. Contains zero CoreBluetooth or UI code.

**`ContentView.swift`** — Observes `OBDViewModel` via `@StateObject`. Renders four cards: Fuel Trims (STFT + LTFT cells; the header shows the STFT+LTFT total), Fluid Temperatures (Coolant / Trans Fluid / Engine Oil, each with a Normal/Warm/Hot colour badge), Engine (RPM / Load / Injector — injector pulse width replaces the throttle cell; throttle still rides the standard Mode-01 frame into the tuning CSV), and an optional live TX/RX log card shown only when the `loggingEnabled` setting is on. Includes a `SettingsView` sheet — Listen-Only toggle, polling interval slider (0–10 s, 0.1 s steps), keep-screen-awake (`UIApplication.shared.isIdleTimerDisabled`), and the TX/RX logging toggle — all `@AppStorage`-backed. Uses a `#if DEBUG` extension `init(viewModel:)` + the `OBDViewModel.preview` static factory for SwiftUI previews.

## OBD Polling Chain (Active Polling mode)

Each cycle executes in sequence; each parser calls the next `begin*Query()` on success, NRC (`7F`), or terminal error:

```
(first cycle only)  ATCEA + ATSH7E0                      ← header set once for the session
passive (pollingDelay wait, default 1.0 s)
  → queryingStandard    01 05 0C 11 06 07 04             (SAE J1979 Mode-01 multi-PID)
                                          coolant  05 → A−40 → °C
                                          RPM      0C → (256A+B)/4
                                          throttle 11 → A×100/255 %
                                          STFT/LTFT 06/07 → A×100/128−100 %
                                          load     04 → A×100/255 %
  → queryingInjectorPulse 213C   injector pulse: (256C+D)/1000 → ms (C,D = 3rd/4th byte after 61 3C)  (Toyota enhanced)
  → queryingEngineOil   2151     engine oil:    payload[11] − 40 → °C        (Toyota enhanced)
  → queryingATF         2182     ATF:           first byte after [61 82] − 40 → °C  (Toyota enhanced)
  → passive   (no header restore — 7E0 persists for the next cycle)
```

Coolant, RPM, throttle, and fuel trims always come from standard Mode-01 PIDs. Engine oil, ATF, and injector pulse width have no standard equivalent on this ECU, so they stay Toyota-enhanced (`2151`/`2182`/`213C`). Injector pulse width is mode-21 PID `3C`. The response `61 3C A B C D E` carries two 16-bit fields; the live pulse width is the **second** one — `(256·C + D) / 1000 → ms` (3rd/4th data bytes after `61 3C`). On-car captures show `C·D` wobbles with fuel correction at idle (~4 ms) and rises under load (~7.9 ms), while the first field `A·B` is a slow staircase (an averaged/adapted value); Car Scanner shows the `C·D` value in ms. The earlier `21F3` guess returned a `7F` NRC on this ECU and was replaced by `213C`.

All four reads go through one shared `sendEngineQuery(_:state:status:resetParser:)` helper. It sends `ATCEA` then the engine header (`ATSH7E0`), with 150 ms delays, **only if the header isn't already active** — tracked by the `engineHeaderActive` flag. The header is **established once per session and persists**: the first read sets `7E0` (flag `true`), and the steady-state active loop sends *no AT commands at all* (no per-cycle restore, no re-send), so nothing can change the header — each subsequent cycle is just `pollingDelay` wait + the four OBD commands. The flag is only cleared (forcing a re-establish) at: `runELM327Init` (ends on `ATSH7DF`); a **whole-cycle read failure** in `afterPollCycle` (`if !cycleGotData`, the clone self-heal); and `beginListenWindow` (entering the listen monitor, which toggles CAF/ATMA — there the header *must* be re-set each cycle). There is **no `ATSH7DF` restore between active cycles** — `7DF` is only set once per connect in init, since the standard batch is requested on `7E0`, not the functional header. A 5-second watchdog (`armActiveTimeout`) auto-advances each step.  Entry point: `triggerActiveQuery()` → `beginStandardQuery()`, fired by `scheduleNextActiveQuery()`.

> **Why active mode can persist the header but listen mode can't:** the active steady-state loop emits zero AT commands, so `ATSH7E0` cannot be perturbed — it's safe to set once. Listen mode toggles `ATCAF0`/`ATMA`/`" ATCAF1"` every cycle (the clone-unverified part), which *can* leave the adapter in a state where the next request's header is wrong, so it re-establishes per cycle.
>
> **Not yet verified on the vehicle:** session-persisting the header trusts that `ATSH7E0` survives across cycles (very likely, since nothing rewrites it). The `cycleGotData` self-heal is the safety net: if a whole cycle returns no data the header is re-established next cycle, so a clone that silently dropped its config recovers within one cycle rather than staying blank until reconnect. Symptom of a regression: enhanced reads blank with ~5 s watchdog stutters.

## Listen Mode (alternating poll + passive standard-PID monitor)

This is the mode that lets the app coexist with the Avance48 gas ECU on the shared bus. Gated by the `listenOnlyMode` setting (read in `runELM327Init()` into `listenModeActive`, so it applies on connect). Because the six standard values (coolant/RPM/throttle/STFT/LTFT/load) have generic Mode-01 PIDs another tester is already polling, but engine oil and ATF do **not**, and the ELM327 can't monitor (`ATMA`) and request at the same time, the mode **alternates**:

```
beginListenOnly()  ATCM7FF + ATCF7E8   (mask 0x7FF / filter 0x7E8 = exactly 7E8, the engine ECU's response ID)
  → beginInjectorPulseQuery 213C injector pulse (active request, CAF on)
  → beginEngineOilQuery   2151  engine oil     (active request)
  → beginATFQuery         2182  ATF            (active request)
  → beginListenWindow     ATCAF0 + ATMA, monitor for one pollingDelay interval
        parseListeningLine: standard 41 responses → mode01Values → 6 standard values
  → exitMonitorThenPoll   " ATCAF1" (leading space stops ATMA, then restores auto-formatting)
  → beginInjectorPulseQuery … (repeat)
```

`afterPollCycle()` is the branch point: `listenModeActive ? beginListenWindow() : returnToPassive()`. The poll chain is `Standard → InjectorPulse → EngineOil → ATF → afterPollCycle` (injector pulse is polled first among the enhanced reads, right after the standard frame; in listen mode the chain starts at `InjectorPulse` since the standard frame is sniffed in the monitor window). Each step's four exits (success, NRC, terminal error, watchdog) all call the next `begin*Query()`, and ATF's four all call `afterPollCycle()`, so the mode never falls through to active standard requests. The six standard values are sniffed passively — they update only while another tester (e.g. the Avance48) is polling them on the bus, **and** only outside each brief injector/oil/ATF poll window. The 7E8 filter is also correctness for the monitor phase: `OBDParser` holds one shared multi-frame accumulator that any other CAN ID would reset mid-sequence.

Stopping `ATMA` with a leading-space-prefixed command (never a bare `CR`, which the ELM327 treats as "repeat last command" = restart `ATMA`) is the one part unverified on the Vgate clone; if it doesn't discard the leading byte, CAF stays off, the `2151`/`2182` requests go out malformed and unanswered, and the symptom is oil/ATF staying blank with ~5 s stutters (the watchdog firing). See the `exitMonitorThenPoll` doc-comment.

"Listen-Only" is a slight misnomer — the poll phase does transmit `2151`/`2182`/`213C`. But those enhanced PIDs are not what the Avance48 polls, so this is the minimum transmission needed and still avoids competing for the standard PIDs. (Injector pulse adds a third transmit per cycle, marginally increasing the footprint on the shared bus.)

## ELM327 Initialisation (run once per connect)

`runELM327Init()` sends, with per-command delays: `ATZ` (2 s, soft reset), `ATE0` (echo off), `ATL0` (linefeeds off), `ATH1` (headers on — CAN ID shown per frame, required for parsing), `ATS1` (spaces on, easy tokenisation), `ATSP6` (protocol 6 = ISO 15765-4 CAN 11-bit 500 kbps), `ATCEA`, `ATSH7DF` (default functional header). CAN auto-formatting (`CAF`) is left **on** and only disabled (`ATCAF0`) inside a listen-mode monitor window. Then it branches: `beginListenOnly()` if `listenOnlyMode`, else `scheduleNextActiveQuery()`.

## Two Parsing Strategies

Both live on the `OBDParser` struct; the ViewModel calls them through its `parser` instance.

**`completePayloadTokens(from:)`** — Stateful (`mutating`), multi-frame aware. Strips the CAN response ID (e.g. `7E8`) and an extended address byte `18` if present, then accumulates ISO-TP first frames (`0x10–0x1F`) and consecutive frames (`0x20–0x2F`) into `multiFramePayload`, returning the complete payload only once `count >= expectedLength`, or `nil` while still accumulating. Single-frame responses (length nibble `≤ 0x0F`) return their stripped payload immediately. Used for the enhanced engine-oil `2151` and the standard Mode-01 multi-PID response (both in active polling and the `41` frames listen mode sniffs).

**`responsePayloadTokens(from:)`** — Stateless single-frame stripper. Drops the optional CAN ID, extended address byte `18`, and length / first-frame header bytes (recognising `41`/`61`/`62`/`7F` service bytes), then returns remaining tokens. Used for `2182` (ATF) and `213C` (injector pulse), both known single-frame responses.

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

`scheduleNextActiveQuery()` (and the listen-mode monitor window) read the user-configurable `pollingDelay` setting (slider range 0–10 s, 0.1 s steps) via the `pollingDelaySeconds` computed property:
```swift
private var pollingDelaySeconds: Double {
    guard UserDefaults.standard.object(forKey: "pollingDelay") != nil else { return 1.0 }
    return max(0, UserDefaults.standard.double(forKey: "pollingDelay"))
}
```
`0` is a valid choice (poll as fast as possible / negligible listen-mode monitor window). The `1.0 s` default applies **only when the key was never written** — `double(forKey:)` returns `0` for both an unset key and an explicit `0`, so the `object(forKey:) != nil` existence check is what distinguishes them (the old `stored > 0 ? stored : 1.0` form couldn't, and would have silently forced a user-chosen 0 back to 1.0).

## Logging (TX/RX + Tuning CSV)

Two independent logs, each gated by its own `@AppStorage` toggle, both written to the Documents directory as **one timestamped file per connection** (created lazily on the first write of a session, so a session with the toggle off — or one that logs nothing — leaves no file). A single `sessionTimestamp` captured in `connect()` names both files for that connection:

- **TX/RX diagnostic log** (`loggingEnabled`): every sent command and received line is appended to the in-memory `communicationLog` (capped at `maxLogEntries = 120`) and to `obd_txrx_<yyyy-MM-dd_HH-mm-ss>.txt`. The log card in `ContentView` shows the live tail with copy/clear; "clear" now only empties the on-screen `communicationLog` (file deletion lives in the manager). When the toggle is off, `appendLog` returns early.
- **Tuning CSV** (`dataLoggingEnabled`): one row per decoded standard Mode-01 frame — `timestamp,STFT,LTFT,RPM,Throttle,EngineLoad,Coolant,InjectorPulse` — written via `logTuningSample()` in both `parseStandardLine` and `parseListeningLine` to `obd_tune_<yyyy-MM-dd_HH-mm-ss>.csv`. The first seven columns are sampled from the same standard frame; `InjectorPulse` comes from the separate enhanced `213C` read (polled earlier in the cycle) and so lags the row by about one poll cycle (it logs the most recent injector value at row time). The Tuning Data Log card shows the row count and a `ShareLink` (AirDrop) to the current session file.

`currentTxRxFileURL` / `currentDataLogFileURL` are published optionals pointing at the active-session files (nil until the first write). `OBDViewModel.savedLogFiles()` lists all `obd_txrx_*`/`obd_tune_*` files (newest first) and `deleteLogFiles(_:)` removes them. `LogManagerView` (a sheet opened from the folder toolbar button, always reachable regardless of toggles) presents the saved files with a selection mode — Select All / Deselect All, then Share (AirDrop the selected set) or Delete.

## On-car Verification Status

Confirmed on-car (active-polling TX/RX capture, 2026-05-30):
- **Standard Mode-01 path** (coolant `05` / RPM `0C` / throttle `11` / STFT `06` / LTFT `07` / load `04`) — **confirmed working**. Decodes to sensible live values (e.g. coolant 68→73 °C warming, RPM ~930 idle, throttle ~17 %). This supersedes the old note that only the removed `2101`/`2103` enhanced path was ever confirmed.
- **Engine oil `2151`** (~61 °C) and **ATF `2182`** (~46 °C) — confirmed working (multi-frame reassembly).
- **Injector pulse width** — the earlier `21F3` guess returned `7F 21 12` (not supported). Replaced by **`213C`**, which responds with data. The decode is the **second** 16-bit field, `(256·C + D)/1000 → ms`: on-car captures show `C·D` is the live, fuel-corrected value (wobbles ~4.0 ms at idle, ~7.9 ms under load), whereas the first field `A·B` is a slow staircase (averaged/adapted). The **ms unit is confirmed against Car Scanner**; the `/1000` scale is a best fit to an idle ~4 ms reading — cross-check the exact divisor against a known Car Scanner value (and confirm the field by revving: Car Scanner's injector PW should jump to ~7–8 ms, matching `C·D`).
- **Header persistence optimization** — confirmed: only the first cycle sends `ATCEA + ATSH7E0`; later cycles send OBD commands only, no `7DF` restore. Self-heal never had to fire.

Still open:
- **`STOPPED` / pacing.** The adapter occasionally returned `STOPPED` (command aborted) for the first ~3 cycles, then ran clean at ~0.8 s/cycle. Cause: the app sends the next command on response-receipt without waiting for the `>` prompt, racing the ELM327's inter-response wait window — exposed by removing the per-read header re-send that used to provide ~300 ms of settle time. A lost command then waits for the 5 s watchdog (the ~5 s stutter). Fix not yet applied (options: gate on `>`, or append an expected-response count).
- **Leading-space `ATMA` stop** in listen mode — still unverified (the capture was active mode only).

## Preview

`OBDViewModel.preview` (inside `#if DEBUG`) constructs a pre-populated instance with sample values. The `init()` body returns early when `XCODE_RUNNING_FOR_PREVIEWS == "1"` to skip Bluetooth setup. `ContentView` gains a debug `init(viewModel:)` via a `#if DEBUG` extension so the synthesised no-arg `init()` still works in production.
