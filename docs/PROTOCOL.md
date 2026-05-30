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
| Injector pulse width | **Custom (Toyota enhanced)** | Mode-21 PID `213C` |
| Injection volume | **Custom (Toyota enhanced)** | Mode-21 PID `2137` |

**Defining rule:** the 6 standard values can be *requested* (active) **or** *passively
sniffed* (listen), because any tester on the bus produces `41` responses for them. The 4
custom values have **no standard PID**, so they can **only** be obtained by actively
requesting `2151`/`2182`/`213C`/`2137` — never sniffable, so even listen mode polls them.

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
| `213C` (injector pulse) | `61 3C A B C D E` | `(256·C + D) / 1000` (the **2nd** 16-bit field = 3rd/4th bytes after `61 3C`, a µs value; single frame) | ms |
| `2137` (injection volume) | `61 37 A B …` | `(256·A + B) × 2.047 / 65535` (first 16-bit field after `61 37`; multi-frame, declared `0x11`=17) | ml |

> `payload` = the assembled ISO-TP payload starting at `61`. So `payload[0]=61`,
> `payload[1]=51`, `payload[11]` = oil temp raw.

> **`213C` is confirmed on-car** (it responds with data; Car Scanner shows the value in ms). The
> response carries **two** 16-bit fields. The live injector pulse width is the **second** one
> (`C·D`): on-car captures show it wobbles with fuel correction (~4 ms idle) and rises under load
> (~7.9 ms), while the first field `A·B` is a slow staircase (an averaged/adapted value that
> barely moves under load). The `/1000` scaling is a best fit to an idle ~4 ms reading — cross-check
> the divisor against a known Car Scanner value, and confirm the field by revving (Car Scanner's
> injector PW should jump to ~7–8 ms, tracking `C·D`). (The earlier `21F3` guess returned `7F 21 12`
> — not supported — and was replaced by `213C`.)

> **`2137` (injection volume) is confirmed on-car**: a Car Scanner capture showed 1.6 ml while the
> first 16-bit field (`C8 A2` = 51362) × 2.047/65535 = 1.604 ml. Note the community lists attribute
> this volume formula to `213C`, but on this car `213C` is the pulse width and `2137` is the volume.

## 4. Active polling mode

**What this mode does:** actively requests everything — the 6 standard values in one Mode-01
batch, then the 3 enhanced values one at a time — then waits. Nothing else needs to be on the
bus. The engine header `7E0` is set **once for the whole session** (before the first cycle) and
reused by every read in every cycle, so the steady-state loop sends **no AT commands at all**.

```
ONCE (before the first cycle):
   send ATCEA          (150 ms)
   send ATSH7E0        (150 ms)   ← engine ECU header — stays active for the whole session

loop, one cycle per pollingDelay (default 1.0 s):
   wait pollingDelay
   STEP 1 — Standard batch:
      send "01 05 0C 11 06 07 04"      ← header already 7E0, command only
      on 41 response: decode coolant/RPM/throttle/STFT/LTFT/load  → STEP 2
   STEP 2 — Injector pulse (enhanced):
      send 213C
      on 61 3C A B C D E response: injector = (256·C + D) / 1000 ms  (2nd 16-bit field)  → STEP 3
   STEP 3 — Injection volume (enhanced):
      send 2137
      on 61 37 A B … response: volume = (256·A + B) × 2.047 / 65535 ml  (multi-frame)  → STEP 4
   STEP 4 — Engine oil (enhanced):
      send 2151
      on 61 51 response: oil = payload[11]−40  → STEP 5
   STEP 5 — ATF (enhanced):
      send 2182
      on 61 82 response: atf = byte after [61 82] − 40  → next cycle
   (no header restore — 7E0 persists; → wait pollingDelay → STEP 1)
```

**Wait for the `>` prompt between steps.** Each step advances only after the ELM327 emits its
`>` ready-prompt — *not* the instant the response bytes arrive. Sending the next command while
the adapter is still in its inter-response wait makes it abort the new command with `STOPPED`
(a lost command → 5 s watchdog stall). So: send → read response → **wait for `>`** → next step.

**Error/NRC handling at every step:** if the response is `7F` (negative response code), or
contains `NO DATA` / `ERROR` / `UNABLE TO CONNECT` / `STOPPED`, **skip to the next step** (still
after the `>`). A **5-second watchdog** per step auto-advances if nothing arrives at all.

**Why the header is set only once:** `ATSH7E0` stays the active request header until something
changes it — and nothing in the loop does (the standard batch is requested on `7E0`, not the
functional `7DF`, so there is no restore step). Re-sending `ATCEA + ATSH7E0` every cycle, or
before each read, is also correct — just slower; this client sends it once per session.

**Self-heal:** if a whole cycle returns no data on any read, the client re-sends `ATCEA +
ATSH7E0` at the start of the next cycle. This recovers an adapter that silently lost its header
config without dropping the BLE link (otherwise a reconnect, which re-runs init, would be needed).
The trigger is *whole-cycle* failure, not a single read — so an unsupported PID (e.g. a wrong
enhanced PID returning `7F`/NO DATA every cycle) does not force a re-send as long as another read succeeds.

## 5. Listen mode (alternating poll + passive sniff)

**What this mode does:** coexists with another tester already on the bus (the Avance48 gas
ECU) without competing for the standard PIDs. It never requests the 6 standard values —
it **sniffs** them from the other tester's `41` responses — and only actively requests the 3
enhanced values nobody else polls. It alternates: a short **poll phase** (request injector →
oil → ATF) and a **monitor phase** (`ATMA`, sniff standard `41` frames for one interval).

The ELM327 **cannot monitor and request at the same time** (any byte sent stops `ATMA`),
and the 3 enhanced values can't be sniffed — so the two phases alternate forever:

```
ON ENTER:
   send ATCM7FF        (150 ms)   ← CAN mask: all 11 bits significant
   send ATCF7E8        (150 ms)   ← CAN filter: accept ONLY 7E8 (engine ECU responses)
   → POLL PHASE

POLL PHASE (CAF on):
   poll 213C (injector)        sends ATCEA + ATSH7E0 first (re-establishes 7E0 after the monitor)
   poll 2137 (injection volume) header already 7E0 → command only (no ATCEA/ATSH re-send)
   poll 2151 (engine oil)      header already 7E0 → command only
   poll 2182 (ATF)             header already 7E0 → command only
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
   the poll phase**, or `213C`/`2137`/`2151`/`2182` requests go out malformed.
3. **Filter to exactly `7E8`** (`ATCM7FF` + `ATCF7E8`). The parser uses a single shared
   multi-frame accumulator; a frame from any other CAN ID arriving mid-sequence resets it.
4. **Passive caveat:** the 6 standard values only update while **another active tester** on
   the bus is polling them — and only *outside* each oil/ATF/injector poll window.

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
corrupt earlier values. Length map: `{05:1, 0C:2, 11:1, 06:1, 07:1, 04:1}`.

## 7. Mode comparison

| | Active polling | Listen mode |
|---|---|---|
| Coolant/RPM/throttle/STFT/LTFT/load | **Requested** (`01 05 0C 11 06 07 04`) | **Sniffed** from another tester's `41` frames |
| Injector / volume / oil / ATF | **Requested** (`213C`/`2137`/`2151`/`2182`) | **Requested** (`213C`/`2137`/`2151`/`2182`) — same as active |
| Bus behaviour | Transmits every cycle | Transmits injector/volume/oil/ATF, then monitors |
| `CAF` state | On throughout | Toggled (on=poll, off=monitor) |
| Header | `7E0` for all requests; set once per session, **no `7DF` restore** | `7E0` for requests; filter `7E8` for monitor |
| Header setups | **Once per session** (re-sent only after a connect or a whole no-data cycle) | Once per cycle (CAF/ATMA toggling forces a re-establish) |
| Steady-state AT commands / cycle | **0** | several (`ATCAF0`/`ATMA`/`" ATCAF1"`) |
| Needs another tester? | No | Yes, for the 6 standard values |

## 8. Notes / open items

- The Toyota enhanced `2101`/`2103` packets are **not** used. Both modes get the 6 standard
  values from generic Mode-01 PIDs; only oil (`2151`), ATF (`2182`), injector pulse (`213C`)
  and injection volume (`2137`) are enhanced.
- **Confirmed on-car (active capture):** the 6 standard PIDs decode to sensible live values,
  and `2151`/`2182`/`213C`/`2137` all respond. This supersedes the earlier "standard path unverified" note.
- **Injector pulse `213C`** = `(256·C + D)/1000 → ms` (the 2nd 16-bit field). C·D is the live
  fuel-corrected value; the first field A·B is a slow staircase (averaged). **Confirmed against
  Car Scanner**: a capture showed 2.8–2.9 ms while C·D decoded to 2.87–2.95 ms (warm idle).
  (`21F3` was the wrong guess: `7F 21 12`, not supported.)
- **Injection volume `2137`** = `(256·A + B) × 2.047 / 65535 → ml` (first 16-bit field; multi-frame).
  **Confirmed against Car Scanner**: capture showed 1.6 ml, `C8 A2` × 2.047/65535 = 1.604 ml.
  Community lists put this formula on `213C`; on this car `213C` is pulse width and `2137` the volume.
- **`STOPPED` / pacing (fix applied, unverified on device):** sending the next command on
  response-receipt (not on `>`) raced the ELM327's inter-response wait and got the command
  aborted (`STOPPED`) → 5 s watchdog stutter (seen for the first few cycles, then settled). Now
  fixed by gating each step on the `>` prompt; a stray `STOPPED` is also treated as a fast skip.
  Needs an on-car run to confirm.
- The `" ATCAF1"` ATMA-stop trick is the one adapter-dependent behaviour still to verify (the
  on-car capture was active mode only).
