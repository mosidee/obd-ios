# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Validate

Use the Xcode MCP tools:
- **Build**: `mcp__xcode-tools__BuildProject`
- **Quick diagnostics** (no full build): `mcp__xcode-tools__XcodeRefreshCodeIssuesInFile` — use this after editing Swift files to catch type errors fast
- **Render preview**: `mcp__xcode-tools__RenderPreview` on `ContentView.swift`

**Tests**: Run via Xcode's Test action (⌘U) on the `OBD ELM327 ConnectorTests` target. Tests use the Swift Testing framework (`import Testing`, `@Suite`/`@Test`/`#expect`) and cover `OBDParser` (frame assembly, token stripping) plus the value-conversion formulas. `xcodebuild` is unavailable from the CLI here (only CommandLineTools is installed), so tests can't be run from the shell.

## Architecture

Four files carry all the logic:

**`OBDBluetoothManager.swift`** — Pure BLE transport. Scans for ELM327 adapters (service UUIDs FFF0/18F0/FFE0), manages CoreBluetooth lifecycle, and exposes a single `AsyncStream<String>` of complete ELM327 lines split on `\r`. Contains zero OBD logic. `CBCentralManager` is only created when `startScanning()` is called (not at init), which keeps preview-safe.

**`OBDViewModel.swift`** — All OBD logic. A `@MainActor` state machine that drives an active polling cycle (interval from the `pollingDelay` setting, default 1.0 s). Lines from `OBDBluetoothManager.lines` are routed based on `QueryState` and decoded via an owned `OBDParser` (`private var parser = OBDParser()`). Publishes `stft`, `ltft`, `coolantTemp`, `engineOilTemp`, `atfTemp`, `coolantTempV2`.

**`OBDParser.swift`** — Frame decoding, extracted from `OBDViewModel` so it's unit-testable without `@MainActor`/Bluetooth. A `struct` holding the multi-frame accumulation state; exposes `completePayloadTokens(from:)` (mutating, multi-frame), `responsePayloadTokens(from:)` (stateless, single-frame), `reset()`, and the static `rawByte(after:in:)`. Contains zero CoreBluetooth or UI code.

**`ContentView.swift`** — Observes `OBDViewModel` via `@StateObject`. Renders temperature cards and fuel trim cells (the Fuel Trims header shows the STFT+LTFT total), plus an optional live TX/RX log card shown only when the `loggingEnabled` setting is on. Includes a `SettingsView` sheet (polling interval, keep-screen-awake via `UIApplication.shared.isIdleTimerDisabled`, and the `loggingEnabled` toggle — all `@AppStorage`-backed). Uses `#if DEBUG` extension init + `OBDViewModel.preview` static factory for SwiftUI previews.

## OBD Polling Chain

Each cycle executes in sequence; each parser calls the next `begin*Query()` on success, NRC (`7F`), or error:

```
passive (pollingDelay wait, default 1.0 s)
  → queryingToyota2101  ATSH7E0 + 2101  coolant:    payload[18] − 40 → °C
  → queryingToyota2103  ATSH7E0 + 2103  STFT/LTFT:  payload[4/5], (raw×200/256)−100 → %
  → queryingEngineOil   ATSH7E0 + 2151  engine oil: payload[11] − 40 → °C
  → queryingATF         ATSH7E0 + 2182  ATF:        first byte after [61 82] − 40 → °C
  → queryingCoolantV2   ATSH7C0 + 2123  coolant V2: payload[2] × 0.5 → °C
  → restoringHeader     ATCEA + ATSH7DF
  → passive
```

Before sending each command, every `begin*Query()` sends `ATCEA` (disable CAN extended addressing) then the target header, with 150 ms delays between. A 5-second watchdog (`armActiveTimeout`) auto-advances if no response arrives.

## Listen-Only Mode

Gated by the `listenOnlyMode` setting (read in `runELM327Init()`, so it applies on connect). When on, `beginListenOnly()` sends `ATCAF0` (CAN auto-formatting off, so raw `10/21/22` ISO-TP frames reach `OBDParser`), `ATCM7DF` + `ATCF7C8` (CAN mask/filter accepting only 7C8 and 7E8 — required because the single shared multi-frame accumulator is reset by any non-ISO-TP frame, so interleaving noise would break 2101/2151 assembly), then `ATMA` (Monitor All) and sends no OBD requests. The `.listening` state routes every monitored line through `parseListeningLine()`, which reuses `parser.completePayloadTokens` and dispatches by the response PID byte (`payload[1]`: `01`→coolant, `03`→fuel trims, `51`→engine oil, `82`→ATF, `23`→coolant V2) using the same formulas as active polling. It's a passive co-monitor: because these are request/response PIDs, values update only while another active tester is polling them on the bus.

## Two Parsing Strategies

Both live on the `OBDParser` struct in `OBDParser.swift`; the ViewModel calls them through its `parser` instance.

**`completePayloadTokens(from:)`** — Stateful (`mutating`), multi-frame aware. Accumulates ISO-TP first frames (`0x10–0x1F`) and consecutive frames (`0x20–0x2F`) into `multiFramePayload`, returns the complete payload only once `multiFramePayload.count >= expectedLength`, or `nil` while still accumulating. Used for 2101, 2103, 2151, 2123.

**`responsePayloadTokens(from:)`** — Stateless single-frame stripper. Drops the optional CAN ID, extended address byte, and length/first-frame bytes, then returns remaining tokens. Used for 2182 (ATF) which is a known single-frame response.

Both functions strip the CAN response ID (e.g. `7E8`) if present, and the extended address byte `18` if it follows.

## Adding a New PID

1. Add constants for the header command and OBD command string.
2. Add a `queryingFoo` case to `QueryState`.
3. Add a `beginFooQuery()` that cancels the timeout, resets the multi-frame buffer, sets state, and sends `ATCEA → header → command` with 150 ms delays.
4. Add a `parseFooLine(_ line: String)` using `parser.completePayloadTokens` (multi-frame) or `parser.responsePayloadTokens` (single-frame). Check `payload.first == "7F"` for NRC. On success, update the published property and call the next `begin*Query()`. (`beginFooQuery()` should call `parser.reset()` when it resets the multi-frame buffer.)
5. Add a `handleNonFrameFooLine` that calls the next step on terminal errors.
6. Wire the new case into `route()` and `armActiveTimeout()`.
7. Chain it into the polling cycle by changing the preceding step's success/NRC/error calls to `beginFooQuery()`.

## Polling Rate

`scheduleNextActiveQuery()` in `OBDViewModel.swift` reads the user-configurable `pollingDelay` setting (set in `SettingsView`), defaulting to 1.0 s:
```swift
let stored = UserDefaults.standard.double(forKey: "pollingDelay")
let delay = stored > 0 ? stored : 1.0   // seconds between cycles
```

## Preview

`OBDViewModel.preview` (inside `#if DEBUG`) constructs a pre-populated instance with sample values. The `init()` body returns early when `XCODE_RUNNING_FOR_PREVIEWS == "1"` to skip Bluetooth setup. `ContentView` gains a debug `init(viewModel:)` via a `#if DEBUG` extension so the synthesised no-arg `init()` still works in production.
