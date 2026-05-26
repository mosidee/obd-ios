# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Validate

Use the Xcode MCP tools:
- **Build**: `mcp__xcode-tools__BuildProject`
- **Quick diagnostics** (no full build): `mcp__xcode-tools__XcodeRefreshCodeIssuesInFile` — use this after editing Swift files to catch type errors fast
- **Render preview**: `mcp__xcode-tools__RenderPreview` on `ContentView.swift`

There are no automated tests in this project.

## Architecture

Three files carry all the logic:

**`OBDBluetoothManager.swift`** — Pure BLE transport. Scans for ELM327 adapters (service UUIDs FFF0/18F0/FFE0), manages CoreBluetooth lifecycle, and exposes a single `AsyncStream<String>` of complete ELM327 lines split on `\r`. Contains zero OBD logic. `CBCentralManager` is only created when `startScanning()` is called (not at init), which keeps preview-safe.

**`OBDViewModel.swift`** — All OBD logic. A `@MainActor` state machine that drives an active polling cycle every 4–6 seconds. Lines from `OBDBluetoothManager.lines` are routed to the current parser based on `QueryState`. Publishes `stft`, `ltft`, `coolantTemp`, `engineOilTemp`, `atfTemp`, `coolantTempECT`, `coolantTempV2`.

**`ContentView.swift`** — Observes `OBDViewModel` via `@StateObject`. Renders temperature cards, fuel trim cells, and a live TX/RX log. Uses `#if DEBUG` extension init + `OBDViewModel.preview` static factory for SwiftUI previews.

## OBD Polling Chain

Each cycle executes in sequence; each parser calls the next `begin*Query()` on success, NRC (`7F`), or error:

```
passive (4–6 s wait)
  → queryingToyota2101  ATSH7E0 + 2101  coolant:    payload[18] − 40 → °C
  → queryingToyota2103  ATSH7E0 + 2103  STFT/LTFT:  payload[4/5], (raw×200/256)−100 → %
  → queryingEngineOil   ATSH7E0 + 2151  engine oil: payload[11] − 40 → °C
  → queryingATF         ATSH7E0 + 2182  ATF:        first byte after [61 82] − 40 → °C
  → queryingCoolantV2   ATSH7C0 + 2123  coolant V2: payload[2] × 0.5 → °C
  → restoringHeader     ATCEA + ATSH7DF
  → passive
```

Before sending each command, every `begin*Query()` sends `ATCEA` (disable CAN extended addressing) then the target header, with 150 ms delays between. A 5-second watchdog (`armActiveTimeout`) auto-advances if no response arrives.

## Two Parsing Strategies

**`completePayloadTokens(from:)`** — Stateful, multi-frame aware. Accumulates ISO-TP first frames (`0x10–0x1F`) and consecutive frames (`0x20–0x2F`) into `multiFramePayload`, returns the complete payload only once `multiFramePayload.count >= expectedLength`, or `nil` while still accumulating. Used for 2101, 2103, 2151, 2123.

**`responsePayloadTokens(from:)`** — Stateless single-frame stripper. Drops the optional CAN ID, extended address byte, and length/first-frame bytes, then returns remaining tokens. Used for 2182 (ATF) which is a known single-frame response.

Both functions strip the CAN response ID (e.g. `7E8`) if present, and the extended address byte `18` if it follows.

## Adding a New PID

1. Add constants for the header command and OBD command string.
2. Add a `queryingFoo` case to `QueryState`.
3. Add a `beginFooQuery()` that cancels the timeout, resets the multi-frame buffer, sets state, and sends `ATCEA → header → command` with 150 ms delays.
4. Add a `parseFooLine(_ line: String)` using `completePayloadTokens` (multi-frame) or `responsePayloadTokens` (single-frame). Check `payload.first == "7F"` for NRC. On success, update the published property and call the next `begin*Query()`.
5. Add a `handleNonFrameFooLine` that calls the next step on terminal errors.
6. Wire the new case into `route()` and `armActiveTimeout()`.
7. Chain it into the polling cycle by changing the preceding step's success/NRC/error calls to `beginFooQuery()`.

## Polling Rate

`scheduleNextActiveQuery()` in `OBDViewModel.swift`:
```swift
let delay = Double.random(in: 4...6)  // seconds between cycles
```

## Preview

`OBDViewModel.preview` (inside `#if DEBUG`) constructs a pre-populated instance with sample values. The `init()` body returns early when `XCODE_RUNNING_FOR_PREVIEWS == "1"` to skip Bluetooth setup. `ContentView` gains a debug `init(viewModel:)` via a `#if DEBUG` extension so the synthesised no-arg `init()` still works in production.
