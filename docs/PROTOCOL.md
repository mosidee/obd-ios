# OBD Protocol Spec — Listen Mode vs Active Polling

Implementation-oriented spec of both modes, pulled from the iOS app. Portable to any
ELM327 client (Android, etc.). Adapter target: ELM327 v2.3 over BLE (Vgate iCar Pro 2S),
vehicle: Toyota Sienta (ISO 15765-4 CAN, 11-bit, 500 kbps).

## 1. ELM327 initialisation (run once on every connect)

Send in order, waiting for each (`>` prompt or a fixed delay):

| Command | Delay after | Meaning |
|---|---|---|
| `ATZ` | ~2000 ms | Soft reset (adapter needs ~1.5 s to boot) |
| `ATE0` | 300 ms | Echo off |
| `ATL0` | 300 ms | Linefeeds off |
| `ATH1` | 300 ms | **Headers on** — every frame shows its CAN ID (e.g. `7E8`). Required for parsing. |
| `ATS1` | 300 ms | Spaces on — bytes space-separated, easy to tokenise |
| `ATSP6` | 500 ms | Protocol 6 = ISO 15765-4, CAN 11-bit, 500 kbps |
| `ATCEA` | 300 ms | Disable CAN extended addressing |
| `ATSH7DF` | 300 ms | Default functional OBD-II request header |

After init, branch: **listen mode** if the setting is on, else **active polling**.

> CAN auto-formatting (`CAF`) is **on** by default after `ATZ` and is never disabled in
> init. It stays on for all active requests, and is only turned off (`ATCAF0`) during a
> listen-mode monitor window.

## 2. The two value groups (core distinction)

| Value | Type | Source |
|---|---|---|
| Coolant temp | **Standard** | Mode-01 PID `05` |
| Engine RPM | **Standard** | Mode-01 PID `0C` |
| Throttle position | **Standard** | Mode-01 PID `11` |
| Short fuel trim (STFT) | **Standard** | Mode-01 PID `06` |
| Long fuel trim (LTFT) | **Standard** | Mode-01 PID `07` |
| Engine load | **Standard** | Mode-01 PID `04` |
| Engine oil temp | **Custom (Toyota enhanced)** | Mode-21 PID `2151` |
| Trans fluid / ATF temp | **Custom (Toyota enhanced)** | Mode-21 PID `2182` |

**Defining rule:** the 6 standard values can be *requested* (active) **or** *passively
sniffed* (listen), because any tester on the bus produces `41` responses for them. The 2
custom values have **no standard PID**, so they can **only** be obtained by actively
requesting `2151`/`2182` — never sniffable, so even listen mode polls them.

## 3. PID decode formulas

### Standard SAE J1979 Mode 01
Request `01 <pid> [<pid>…]` (up to 6 PIDs per request). Response begins with `41`, then
each PID byte followed by its data bytes.

| PID | Bytes | Formula | Unit |
|---|---|---|---|
| `05` | 1 (A) | `A − 40` | °C |
| `0C` | 2 (A,B) | `(256·A + B) / 4` | RPM |
| `11` | 1 (A) | `A × 100 / 255` | % |
| `06` | 1 (A) | `A × 100 / 128 − 100` | % |
| `07` | 1 (A) | `A × 100 / 128 − 100` | % |
| `04` | 1 (A) | `A × 100 / 255` | % |

**Multi-PID request used by both modes:** `01 05 0C 11 06 07 04`
**Response example:** `41 05 5C 0C 0B 7F 11 2B 06 80 07 7E 04 1A` (14 data bytes → arrives
as a multi-frame ISO-TP response, see §6).

> Fuel trim has two scalings. **Standard PID `06`/`07` uses `×100/128 − 100`.** (The old
> Toyota-enhanced `2103` path used `×200/256 − 100`; that path was removed — don't mix them.)

### Custom Toyota enhanced (Mode 21) — header must be `ATSH7E0`
Request `21 <pid>`. Response begins with `61`, then the PID byte, then data.

| Command | Response | Decode | Unit |
|---|---|---|---|
| `2151` (engine oil) | `61 51 …` | `payload[11] − 40` (multi-frame, declared length `0x0C`=12; oil byte is the 10th data byte after `61 51`) | °C |
| `2182` (ATF) | `61 82 XX` | `XX − 40` (byte immediately after the `61 82` sequence; single frame) | °C |

> `payload` = the assembled ISO-TP payload starting at `61`. So `payload[0]=61`,
> `payload[1]=51`, `payload[11]` = oil temp raw.

## 4. Active polling mode

Loop forever, one cycle per `pollingDelay` (default 1.0 s):

```
wait pollingDelay
STEP 1 — Standard batch:
   send ATCEA          (150 ms)
   send ATSH7E0        (150 ms)   ← engine ECU header
   send "01 05 0C 11 06 07 49"
   on 41 response: decode coolant/RPM/throttle/STFT/LTFT/load  → STEP 2
STEP 2 — Engine oil (enhanced):
   send ATCEA          (150 ms)
   send ATSH7E0        (150 ms)
   send 2151
   on 61 51 response: oil = payload[11]−40  → STEP 3
STEP 3 — ATF (enhanced):
   send ATCEA          (150 ms)
   send ATSH7E0        (150 ms)
   send 2182
   on 61 82 response: atf = byte after [61 82] − 40  → STEP 4
STEP 4 — Restore:
   send ATCEA
   send ATSH7DF        ← back to functional header
   wait for ">" prompt → wait pollingDelay → STEP 1
```

**Error/NRC handling at every step:** if the response is `7F` (negative response code), or
contains `NO DATA` / `ERROR` / `UNABLE TO CONNECT`, **skip to the next step anyway**. A
**5-second watchdog** per step auto-advances if nothing arrives.

## 5. Listen mode (alternating poll + passive sniff)

The ELM327 **cannot monitor and request at the same time** (any byte sent stops `ATMA`),
and oil/ATF can't be sniffed — so listen mode alternates:

```
ON ENTER:
   send ATCM7FF        (150 ms)   ← CAN mask: all 11 bits significant
   send ATCF7E8        (150 ms)   ← CAN filter: accept ONLY 7E8 (engine ECU responses)
   → POLL PHASE

POLL PHASE (CAF on):
   poll 2151 (engine oil)   exactly like active STEP 2
   poll 2182 (ATF)          exactly like active STEP 3
   → MONITOR PHASE

MONITOR PHASE:
   send ATCAF0          (150 ms)   ← auto-formatting OFF → raw ISO-TP frames come through
   send ATMA                       ← Monitor All (subject to the 7E8 filter)
   listen for pollingDelay seconds:
        every line → if it's a standard 41 response, decode the 6 standard values
   → EXIT MONITOR

EXIT MONITOR:
   send " ATCAF1"       (200 ms)   ← leading SPACE stops ATMA (stop byte is discarded),
                                      ATCAF1 turns auto-formatting back on, in one line
   → POLL PHASE   (repeat forever)
```

### Listen-mode gotchas
1. **Stopping `ATMA`:** send a line whose **first character is a throwaway** (a space) —
   the ELM327 discards the byte that stops the monitor. **Never send a bare carriage
   return** to stop it — a blank line makes the ELM327 *repeat the last command* (`ATMA`),
   restarting the monitor. `" ATCAF1"` both stops `ATMA` and restores formatting in one
   line. *(This one behaviour needs on-hardware confirmation per adapter.)*
2. **`CAF0` is required for the monitor phase** so multi-frame standard responses arrive as
   raw `10/21` frames the parser can assemble. It **must be turned back on (`CAF1`) before
   the poll phase**, or `2151`/`2182` requests go out malformed.
3. **Filter to exactly `7E8`** (`ATCM7FF` + `ATCF7E8`). The parser uses a single shared
   multi-frame accumulator; a frame from any other CAN ID arriving mid-sequence resets it.
4. **Passive caveat:** the 6 standard values only update while **another active tester** on
   the bus is polling them — and only *outside* each oil/ATF poll window.

## 6. ISO-TP frame parsing (shared by both modes)

Every response line looks like `7E8 <bytes…>`. Steps:

1. **Tokenise** on spaces, uppercase.
2. **Strip CAN ID**: drop the first token if it's ≥3 hex chars (e.g. `7E8`, `7C8`).
3. **Strip extended-address byte**: if the next token is `18`, drop it.
4. **Classify by the first remaining byte (PCI byte):**

| First byte | Frame type | Action |
|---|---|---|
| `0x00–0x0F` | **Single frame** | low nibble = payload length; take that many following bytes |
| `0x10–0x1F` | **First frame** | `(low nibble << 8) + next byte` = total length; start accumulator with the rest |
| `0x20–0x2F` | **Consecutive frame** | append the rest to the accumulator |

5. Accumulate first + consecutive frames until `accumulated.count >= declaredLength`; then
   emit the payload (truncated to declared length). Incomplete → return nothing.
6. A consecutive frame with **no preceding first frame** → ignore.

**Single-frame example (ATF):** `7E8 03 61 82 50` → strip `7E8`, PCI `03`=3 bytes →
payload `[61, 82, 50]` → ATF = `0x50 − 40 = 40 °C`.

**Multi-frame example (oil):** `7E8 10 0C 61 51 …` (declared 12) + `7E8 21 …` → assemble
12-byte payload `[61, 51, …]` → oil = `payload[11] − 40`.

### Standard multi-PID response walker
Given an assembled payload starting with `41`: `index=1`; read PID at `payload[index]`,
look up its byte-length, read that many data bytes, advance `index += 1 + length`. **Stop
at the first PID not in the length map or if truncated** — so an unknown trailing PID can't
corrupt earlier values. Length map: `{05:1, 0C:2, 11:1, 06:1, 07:1, 49:1}`.

## 7. Mode comparison

| | Active polling | Listen mode |
|---|---|---|
| Coolant/RPM/throttle/STFT/LTFT/load | **Requested** (`01 05 0C 11 06 07 04`) | **Sniffed** from another tester's `41` frames |
| Engine oil / ATF | **Requested** (`2151`/`2182`) | **Requested** (`2151`/`2182`) — same as active |
| Bus behaviour | Transmits every cycle | Transmits oil/ATF, then monitors |
| `CAF` state | On throughout | Toggled (on=poll, off=monitor) |
| Header | `7E0` for requests, `7DF` to restore | `7E0` for requests; filter `7E8` for monitor |
| Needs another tester? | No | Yes, for the 6 standard values |

## 8. Notes / open items

- The Toyota enhanced `2101`/`2103` packets are **not** used. Both modes get the 6 standard
  values from generic Mode-01 PIDs; only oil (`2151`) and ATF (`2182`) are enhanced.
- On-car verification of the 6 standard PIDs on the Sienta is still open (only the older
  enhanced 2101 path was confirmed on the car).
- The `" ATCAF1"` ATMA-stop trick is the one adapter-dependent behaviour to verify.
