//
//  OBDViewModel.swift
//  OBD ELM327 Connector
//
//  OBD polling loop — every `pollingDelay` seconds (default 1.0 s) an active query cycle runs in sequence:
//
//    Standard   : ATSH7E0 + 01 05 0C 11 06 07 04 — coolant/RPM/throttle/STFT/LTFT/engine load (SAE J1979 Mode-01)
//    Engine oil : ATSH7E0 + 2151, payload[11] − 40 → °C  (Toyota mode-21, PID 51)
//    ATF        : ATSH7E0 + 2182, raw − 40 → °C          (Toyota mode-21, PID 82)
//
//  After all responses are handled, ATSH7DF is restored and the cycle repeats.
//  (Engine oil and ATF have no standard Mode-01 equivalent on this ECU, so they stay enhanced.)

import Foundation
import Combine

private enum QueryState {
    case passive         // Waiting between active polling cycles
    case queryingEngineOil // Engine oil command sent; awaiting ECU response
    case queryingATF       // ATF command sent; awaiting ECU response
    case queryingInjectorPulse // Injector pulse-width command sent; awaiting ECU response
    case listening         // Listen-Only: passively monitoring the CAN bus (CAF0 + ATMA)
    case queryingStandard    // Multi-PID Mode-01 request (coolant/RPM/throttle/trims/load)
}

enum OBDLogDirection: String {
    case sent = "TX"
    case received = "RX"
}

struct OBDCommunicationLogEntry: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let direction: OBDLogDirection
    let message: String
}

@MainActor
final class OBDViewModel: ObservableObject {

    // MARK: - Published output

    @Published private(set) var stft: Double?
    @Published private(set) var ltft: Double?
    @Published private(set) var coolantTemp: Double?
    @Published private(set) var engineOilTemp: Double?
    @Published private(set) var atfTemp: Double?
    @Published private(set) var engineSpeed: Double?      // RPM, standard PID 0C (256A+B)/4
    @Published private(set) var throttlePosition: Double? // %, standard PID 11 (A×100/255)
    @Published private(set) var engineLoad: Double?       // %, standard PID 04 (calculated engine load A×100/255)
    @Published private(set) var injectorPulse: Double?    // ms, Toyota enhanced 213C ((256C+D)/1000, 2nd field)
    @Published private(set) var connectionStatus: String = "Disconnected"
    @Published private(set) var isConnected: Bool = false
    @Published private(set) var lastUpdate: Date?
    @Published private(set) var communicationLog: [OBDCommunicationLogEntry] = [] // TX commands and RX adapter lines.
    @Published private(set) var logFileError: String?
    @Published private(set) var dataRowCount: Int = 0   // Rows written to the tuning CSV this session.
    @Published private(set) var dataLogFileError: String?

    // Per-connection session files (nil until the first line/sample is written this session).
    @Published private(set) var currentTxRxFileURL: URL?
    @Published private(set) var currentDataLogFileURL: URL?   // CSV of tuning values, shared via AirDrop.

    var logFileName: String? {
        currentTxRxFileURL?.lastPathComponent
    }

    var dataLogFileName: String? {
        currentDataLogFileURL?.lastPathComponent
    }

    // Exposed so ContentView can observe BLE-level details (peripheral name, raw state).
    let bluetooth = OBDBluetoothManager()

    // MARK: - Private state

    // streamTask must never be cancelled — it owns the single AsyncStream iterator.
    private var streamTask: Task<Void, Never>?
    private var pollTimerTask: Task<Void, Never>?
    private var activeQueryTimeoutTask: Task<Void, Never>?

    private var queryState: QueryState = .passive
    private var isInitializing = false
    private var listenModeActive = false   // Set at connect; drives the oil/ATF poll → monitor loop
    private var engineHeaderActive = false // True while ATSH7E0 is the active request header; lets
                                           // every active query skip a redundant ATCEA+ATSH7E0 re-send.
                                           // In active mode it stays true across cycles (the loop sends
                                           // no AT commands); a whole-cycle read failure clears it so the
                                           // next cycle re-establishes the header (clone self-heal).
    private var cycleGotData = false       // Did any read in the current active cycle succeed?
    private var parser = OBDParser()

    private let maxLogEntries = 120
    private let txRxFilePrefix = "obd_txrx_"   // + timestamp + ".txt", one file per connection
    private let dataLogFilePrefix = "obd_tune_" // + timestamp + ".csv", one file per connection
    // InjectorPulse is sampled from a separate 213C frame polled earlier in the cycle than the
    // standard frame that triggers each row, so it lags the standard values by about one poll
    // cycle (each row holds the most recent injector read at row time).
    private let dataLogHeader = "timestamp,STFT,LTFT,RPM,Throttle,EngineLoad,Coolant,InjectorPulse\n"
    private var sessionTimestamp: Date?         // Set at connect; both session filenames derive from it
    private let defaultHeaderCommand = "ATSH7DF" // Functional OBD-II request header
    private let disableExtendedAddressCommand = "ATCEA"
    private let engineHeaderCommand = "ATSH7E0" // Toyota engine ECU request header (also carries the ATF oil-pan sensor on 7E0/7E8)
    private let engineOilCommand = "2151"        // Toyota mode 21, PID 51 — TOYOTA_EOT at bix 72 (data byte 9)
    private let atfPrimaryCommand    = "2182"     // Toyota mode 21, PID 82 — ATF oil pan sensor
    private let injectorPulseCommand = "213C"     // Toyota mode 21, PID 3C — injector pulse width (ms)

    // Standard OBD-II Mode 01 — the active polling request for coolant/RPM/throttle/trims/load
    private let standardBatchCommand = "01 05 0C 11 06 07 04" // coolant, RPM, throttle, STFT, LTFT, engine load
    private let standardBatchLengths: [String: Int] = ["05": 1, "0C": 2, "11": 1, "06": 1, "07": 1, "04": 1]

    // MARK: - Init

    private let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" { return }
        #endif

        bluetooth.onStateChanged = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handleBLEStateChange(state)
            }
        }
        startLineConsumer()
    }

    // MARK: - Public

    func connect() {
        communicationLog.removeAll()
        sessionTimestamp = Date()        // Both session files derive their name from this connect time.
        currentTxRxFileURL = nil         // Files are (re)created lazily on the first write this session.
        currentDataLogFileURL = nil
        dataRowCount = 0
        connectionStatus = "Scanning..."
        bluetooth.startScanning()
    }

    func disconnect() {
        pollTimerTask?.cancel()
        activeQueryTimeoutTask?.cancel()
        isInitializing = false
        listenModeActive = false
        queryState = .passive
        bluetooth.disconnect()
        isConnected = false
        connectionStatus = "Disconnected"
    }

    // MARK: - BLE State Changes

    private func handleBLEStateChange(_ state: BLEConnectionState) {
        switch state {
        case .connected:
            // Characteristics may still be discovering; init sequence handles the delay via ATZ.
            Task { @MainActor [weak self] in await self?.runELM327Init() }
        case .disconnected, .error:
            pollTimerTask?.cancel()
            activeQueryTimeoutTask?.cancel()
            isInitializing = false
            isConnected = false
            connectionStatus = state.rawValue
        case .bluetoothOff, .unauthorized:
            pollTimerTask?.cancel()
            activeQueryTimeoutTask?.cancel()
            isInitializing = false
            isConnected = false
            connectionStatus = state.rawValue
        default:
            connectionStatus = state.rawValue
        }
    }

    // MARK: - ELM327 Initialisation (ISO 15765-4 CAN, 11-bit ID, 500 kbps)

    private func runELM327Init() async {
        isInitializing = true
        queryState = .passive
        connectionStatus = "Initialising ELM327..."

        // Helper: send a command, then wait for the adapter to process it.
        func cmd(_ s: String, delay ms: UInt64 = 300) async {
            sendCommand(s)
            try? await Task.sleep(nanoseconds: ms * 1_000_000)
        }

        await cmd("ATZ",   delay: 2000) // Soft reset  — ELM327 needs up to ~1.5 s to boot
        await cmd("ATE0")               // Echo off
        await cmd("ATL0")               // Linefeeds off
        await cmd("ATH1")               // Headers on  — CAN ID (e.g. 7E8) shown in each frame
        await cmd("ATS1")               // Spaces on   — bytes separated for easy tokenisation
        await cmd("ATSP6", delay: 500)  // Protocol 6: ISO 15765-4, CAN 11-bit, 500 kbps
        await cmd(disableExtendedAddressCommand)
        await cmd(defaultHeaderCommand)  // Default functional OBD-II request header
        engineHeaderActive = false       // header is 7DF after init; first engine query sets 7E0

        isInitializing = false
        isConnected = true

        listenModeActive = UserDefaults.standard.bool(forKey: "listenOnlyMode")
        if listenModeActive {
            beginListenOnly()           // Alternate oil/ATF poll with passive standard-PID monitoring
        } else {
            connectionStatus = "Active Polling"
            scheduleNextActiveQuery()   // Begin the active query cycle
        }
    }

    // MARK: - Single Line Consumer

    /// Started once in init(); runs for the lifetime of the ViewModel.
    /// The AsyncStream is not restartable — never cancel this task.
    private func startLineConsumer() {
        streamTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await line in self.bluetooth.lines {
                guard !Task.isCancelled else { break }
                self.appendLog(direction: .received, message: line)
                self.route(line)
            }
        }
    }

    // MARK: - State-Machine Router

    private func route(_ raw: String) {
        guard !isInitializing else { return }
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !line.isEmpty else { return }

        switch queryState {
        case .passive:
            break   // Nothing is requested between cycles; ignore incoming lines.

        case .queryingEngineOil:
            parseEngineOilLine(line)

        case .queryingATF:
            parseATFLine(line)

        case .queryingInjectorPulse:
            parseInjectorPulseLine(line)

        case .queryingStandard:
            parseStandardLine(line)

        case .listening:
            parseListeningLine(line)
        }
    }

    // MARK: - Active Parser — Engine Oil Temperature

    /// Parses Toyota mode-21 PID 51 from engine ECU 7E0 (7E8 responds) — multi-frame response.
    /// TOYOTA_EOT at bix 72 = data byte 9 after "61 51" = payload[11].
    /// Formula: engine oil temp (°C) = payload[11] − 40.
    private func parseEngineOilLine(_ line: String) {
        guard let payload = parser.completePayloadTokens(from: line) else { return }

        if payload.first == "7F" {
            beginATFQuery()
            return
        }

        if payload.count > 11,
           payload[0] == "61", payload[1] == "51",
           let raw = UInt8(payload[11], radix: 16) {
            engineOilTemp = Double(raw) - 40.0
            lastUpdate = Date()
            cycleGotData = true
            beginATFQuery()
            return
        }

        handleNonFrameEngineOilLine(line)
    }

    private func handleNonFrameEngineOilLine(_ line: String) {
        let isTerminal = line.contains("NO DATA")
                      || line.contains("ERROR")
                      || line.contains("UNABLE TO CONNECT")
        if isTerminal { beginATFQuery() }
    }

    // MARK: - Active Parser — ATF Temperature

    /// Parses Toyota mode-21 PID 82 from engine ECU 7E0 (7E8 responds).
    /// Response: 7E8 03 61 82 XX — ATF temp (°C) = XX − 40.
    private func parseATFLine(_ line: String) {
        let payload = parser.responsePayloadTokens(from: line)

        if let raw = OBDParser.rawByte(after: ["61", "82"], in: payload) {
            atfTemp = Double(raw) - 40.0
            lastUpdate = Date()
            cycleGotData = true
            afterPollCycle()
            return
        }

        if payload.first == "7F" {
            afterPollCycle()
            return
        }

        handleNonFrameATFLine(line)
    }

    private func handleNonFrameATFLine(_ line: String) {
        let isTerminal = line.contains("NO DATA")
                      || line.contains("ERROR")
                      || line.contains("UNABLE TO CONNECT")
        if isTerminal { afterPollCycle() }
    }

    // MARK: - Active Parser — Injector Pulse Width

    /// Parses Toyota mode-21 PID 3C from engine ECU 7E0 (7E8 responds). Polled first among the
    /// enhanced reads — right after the standard frame — then chains to the engine-oil query.
    /// Response: 7E8 07 61 3C A B C D E (single frame). Injector pulse width (ms) = (256·C + D) / 1000
    /// — the *second* 16-bit field (3rd/4th data bytes after `61 3C`, a value in microseconds).
    /// Determined from on-car captures: C·D is the live, fuel-corrected value (wobbles at idle,
    /// rises to ~7.9 ms under load), whereas the first field A·B is a slow staircase (an averaged/
    /// adapted value, ~constant under load). Matches Car Scanner's ms reading (~4 ms at idle).
    private func parseInjectorPulseLine(_ line: String) {
        let payload = parser.responsePayloadTokens(from: line)

        if payload.count >= 6, payload[0] == "61", payload[1] == "3C",
           let c = UInt8(payload[4], radix: 16), let d = UInt8(payload[5], radix: 16) {
            injectorPulse = (Double(c) * 256.0 + Double(d)) / 1000.0
            lastUpdate = Date()
            cycleGotData = true
            beginEngineOilQuery()
            return
        }

        if payload.first == "7F" {
            beginEngineOilQuery()
            return
        }

        handleNonFrameInjectorPulseLine(line)
    }

    private func handleNonFrameInjectorPulseLine(_ line: String) {
        let isTerminal = line.contains("NO DATA")
                      || line.contains("ERROR")
                      || line.contains("UNABLE TO CONNECT")
        if isTerminal { beginEngineOilQuery() }
    }

    private func beginInjectorPulseQuery() {
        sendEngineQuery(injectorPulseCommand, state: .queryingInjectorPulse,
                        status: "Querying Injector Pulse...", resetParser: false)
    }

    /// End of the injector/oil/ATF poll (ATF is the last enhanced read). In listen mode, loop into
    /// the passive monitor window. In active mode, just schedule the next cycle — the `7E0` header
    /// is left in place (no `ATSH7DF` restore) so the next cycle skips re-sending it; it's only
    /// reset at connect (init sends `ATSH7DF`). If the whole cycle returned no data, clear the flag
    /// so the next cycle re-establishes the header (recovers a clone that silently lost its config).
    private func afterPollCycle() {
        if listenModeActive {
            beginListenWindow()
        } else {
            if !cycleGotData { engineHeaderActive = false }
            startPassiveMonitoring()
        }
    }

    private func beginEngineOilQuery() {
        sendEngineQuery(engineOilCommand, state: .queryingEngineOil,
                        status: "Querying Engine Oil Temp...", resetParser: true)
    }

    private func beginATFQuery() {
        sendEngineQuery(atfPrimaryCommand, state: .queryingATF,
                        status: "Querying ATF Temp...", resetParser: false)
    }

    /// Sends a request to the engine ECU (the standard Mode-01 batch or a mode-21 enhanced read),
    /// re-establishing the `7E0` header (`ATCEA + ATSH7E0`, ~300 ms) **only if it isn't already
    /// active**. The header is established once and reused: in active mode it persists across whole
    /// cycles (the steady-state loop sends no AT commands, so nothing can change it) — the first
    /// read of a session sets it, and it's only re-sent after a connect (init resets to `7DF`) or a
    /// whole-cycle read failure (self-heal). In listen mode the first read of each cycle re-sets it
    /// (the flag is cleared on entering the monitor window, which toggles CAF/ATMA). The flag is set
    /// inside the Task right after `ATSH7E0` is sent, so it reflects the adapter's actual state.
    private func sendEngineQuery(_ command: String, state: QueryState,
                                 status: String, resetParser: Bool) {
        activeQueryTimeoutTask?.cancel()
        if resetParser { parser.reset() }
        queryState = state
        connectionStatus = status
        Task { @MainActor [weak self] in
            guard let self else { return }
            if !self.engineHeaderActive {
                self.sendCommand(self.disableExtendedAddressCommand)
                try? await Task.sleep(for: .milliseconds(150))
                self.sendCommand(self.engineHeaderCommand)
                try? await Task.sleep(for: .milliseconds(150))
                self.engineHeaderActive = true   // header now established on the adapter
            }
            guard self.queryState == state else { return }
            self.sendCommand(command)
            self.armActiveTimeout()
        }
    }

    private func startPassiveMonitoring() {
        queryState = .passive
        connectionStatus = "Active Polling"
        scheduleNextActiveQuery()
    }

    // MARK: - Listen Mode (alternating poll + passive standard-PID monitor)

    /// Entry point for listen mode. Engine oil and ATF have no standard Mode-01 PID, so they
    /// can only be obtained by requesting them; the six standard values (coolant/RPM/throttle/
    /// STFT/LTFT/load) are sniffed from another tester's Mode-01 traffic. The ELM327 can't
    /// monitor and request at the same time, so the mode alternates: poll oil → ATF, then enter
    /// ATMA for one polling interval, then repeat.
    ///
    /// Sets the CAN mask/filter once (mask 0x7FF / filter 0x7E8 = exactly 7E8, the engine ECU's
    /// response ID). The filter is correctness for the monitor phase: OBDParser holds one shared
    /// multi-frame accumulator that any other CAN ID would reset mid-sequence; it's also harmless
    /// to the poll phase, whose oil/ATF responses also arrive on 7E8.
    private func beginListenOnly() {
        pollTimerTask?.cancel()
        activeQueryTimeoutTask?.cancel()
        parser.reset()
        connectionStatus = "Listen-Only (monitoring)"
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.sendCommand("ATCM7FF")  // CAN mask: every bit significant
            try? await Task.sleep(for: .milliseconds(150))
            self.sendCommand("ATCF7E8")  // CAN filter: accept only 7E8 (engine ECU responses)
            try? await Task.sleep(for: .milliseconds(150))
            guard self.listenModeActive else { return }
            self.beginInjectorPulseQuery()   // poll injector → oil → ATF → monitor window → repeat
        }
    }

    /// Passively monitors the bus for one polling interval, capturing standard Mode-01
    /// responses, then stops and re-polls injector/oil/ATF. ATMA needs CAN auto-formatting off so
    /// the raw ISO-TP frames reach OBDParser.
    private func beginListenWindow() {
        activeQueryTimeoutTask?.cancel()
        parser.reset()
        queryState = .listening
        connectionStatus = "Listen-Only (monitoring)"
        engineHeaderActive = false   // re-establish 7E0 once per listen cycle (clone safety)
        pollTimerTask?.cancel()
        pollTimerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.sendCommand("ATCAF0")   // CAN auto-formatting off — expose raw frames
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, self.queryState == .listening else { return }
            self.sendCommand("ATMA")     // Monitor All (subject to the 7E8 filter)
            try? await Task.sleep(for: .seconds(self.pollingDelaySeconds))
            guard !Task.isCancelled, self.queryState == .listening else { return }
            self.exitMonitorThenPoll()
        }
    }

    /// Stops ATMA, re-enables CAN auto-formatting, then resumes the injector/oil/ATF poll.
    ///
    /// NOTE (the one part unverified on this adapter): a leading space stops the monitor — the
    /// ELM327 discards the triggering byte — while the rest of the same line (`ATCAF1`) restores
    /// auto-formatting in one shot. A bare carriage return must NOT be used: the ELM327 repeats
    /// the last command (ATMA) on an empty line. If the Vgate clone doesn't discard that byte,
    /// CAF stays off, the 2151/2182 requests go out malformed and go unanswered, and the symptom
    /// is oil/ATF staying blank with ~5 s stutters (the watchdog firing) — which points here.
    private func exitMonitorThenPoll() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.sendCommand(" ATCAF1")  // space stops ATMA; ATCAF1 restores auto-formatting
            try? await Task.sleep(for: .milliseconds(200))
            guard self.listenModeActive else { return }
            self.beginInjectorPulseQuery()   // back to polling injector → oil → ATF
        }
    }

    /// Routes a monitored standard Mode-01 (`41`) response to the six standard values, using the
    /// same multi-frame assembler and formulas as active polling. Oil/ATF aren't sniffed here —
    /// they're actively polled between monitor windows.
    private func parseListeningLine(_ line: String) {
        guard let payload = parser.completePayloadTokens(from: line) else { return }
        guard payload.first == "41" else { return }
        let values = OBDParser.mode01Values(from: payload, lengths: standardBatchLengths)
        guard !values.isEmpty else { return }
        if let v = values["05"] { coolantTemp = Double(v[0]) - 40.0 }
        if let v = values["0C"] { engineSpeed = (Double(v[0]) * 256.0 + Double(v[1])) / 4.0 }
        if let v = values["11"] { throttlePosition = Double(v[0]) * 100.0 / 255.0 }
        if let v = values["06"] { stft = Double(v[0]) * 100.0 / 128.0 - 100.0 }
        if let v = values["07"] { ltft = Double(v[0]) * 100.0 / 128.0 - 100.0 }
        if let v = values["04"] { engineLoad = Double(v[0]) * 100.0 / 255.0 }
        lastUpdate = Date()
        logTuningSample()
    }

    // MARK: - Active Parser — Standard OBD-II Mode 01

    /// Sends a single multi-PID Mode-01 request to the engine ECU for coolant, RPM,
    /// throttle, and fuel trims; the response is decoded by `parseStandardLine`.
    private func beginStandardQuery() {
        sendEngineQuery(standardBatchCommand, state: .queryingStandard,
                        status: "Querying Standard PIDs...", resetParser: true)
    }

    /// Decodes the multi-PID Mode-01 response (`41 05 .. 0C .. .. 11 .. 06 .. 07 ..`).
    /// Chains to the enhanced injector-pulse query (213C), then oil → ATF.
    private func parseStandardLine(_ line: String) {
        guard let payload = parser.completePayloadTokens(from: line) else { return }

        if payload.first == "7F" {
            beginInjectorPulseQuery()
            return
        }

        if payload.first == "41" {
            let values = OBDParser.mode01Values(from: payload, lengths: standardBatchLengths)
            if let v = values["05"] { coolantTemp = Double(v[0]) - 40.0 }
            if let v = values["0C"] { engineSpeed = (Double(v[0]) * 256.0 + Double(v[1])) / 4.0 }
            if let v = values["11"] { throttlePosition = Double(v[0]) * 100.0 / 255.0 }
            if let v = values["06"] { stft = Double(v[0]) * 100.0 / 128.0 - 100.0 }
            if let v = values["07"] { ltft = Double(v[0]) * 100.0 / 128.0 - 100.0 }
            if let v = values["04"] { engineLoad = Double(v[0]) * 100.0 / 255.0 }
            lastUpdate = Date()
            cycleGotData = true
            logTuningSample()
            beginInjectorPulseQuery()
            return
        }

        handleNonFrameStandardLine(line)
    }

    private func handleNonFrameStandardLine(_ line: String) {
        let isTerminal = line.contains("NO DATA")
                      || line.contains("ERROR")
                      || line.contains("UNABLE TO CONNECT")
        if isTerminal { beginInjectorPulseQuery() }
    }

    // MARK: - Active Query Scheduling

    /// Seconds between active cycles (also the listen-mode monitor-window length). `0` is a valid
    /// user choice (poll as fast as possible / negligible monitor window); the `1.0` default
    /// applies only when the setting was never written — `double(forKey:)` returns 0 for both an
    /// unset key and an explicit 0, so the existence check is what tells them apart.
    private var pollingDelaySeconds: Double {
        guard UserDefaults.standard.object(forKey: "pollingDelay") != nil else { return 1.0 }
        return max(0, UserDefaults.standard.double(forKey: "pollingDelay"))
    }

    private func scheduleNextActiveQuery() {
        pollTimerTask?.cancel()
        pollTimerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.pollingDelaySeconds))
            guard !Task.isCancelled else { return }
            self.triggerActiveQuery()
        }
    }

    private func triggerActiveQuery() {
        guard queryState == .passive, isConnected, !isInitializing else {
            scheduleNextActiveQuery()  // Back off and retry later
            return
        }
        cycleGotData = false           // reset the per-cycle read tracker (drives header self-heal)
        beginStandardQuery()           // Standard Mode-01 PIDs → enhanced injector → oil → ATF
    }

    // MARK: - Communication Log

    private func sendCommand(_ command: String) {
        appendLog(direction: .sent, message: command)
        bluetooth.sendCommand(command)
    }

    private func appendLog(direction: OBDLogDirection, message: String) {
        guard UserDefaults.standard.bool(forKey: "loggingEnabled") else { return }
        let entry = OBDCommunicationLogEntry(
            timestamp: Date(),
            direction: direction,
            message: message
        )

        communicationLog.append(entry)
        appendEntryToLogFile(entry)

        if communicationLog.count > maxLogEntries {
            communicationLog.removeFirst(communicationLog.count - maxLogEntries)
        }
    }

    /// Lazily opens this connection's TX/RX file (named from `sessionTimestamp`) and writes
    /// the banner header. Called on the first line written each session.
    private func startTxRxSession() {
        logFileError = nil
        let stamp = sessionTimestamp ?? Date()
        let url = documentsURL.appendingPathComponent(txRxFilePrefix + Self.fileTimestampFormatter.string(from: stamp) + ".txt")
        let header = "OBD ELM327 Connector TX/RX Log\nStarted: \(Self.logTimestampFormatter.string(from: stamp))\n\n"
        do {
            try header.write(to: url, atomically: true, encoding: .utf8)
            currentTxRxFileURL = url
        } catch {
            logFileError = error.localizedDescription
        }
    }

    private func appendEntryToLogFile(_ entry: OBDCommunicationLogEntry) {
        if currentTxRxFileURL == nil { startTxRxSession() }
        guard let url = currentTxRxFileURL else { return }
        logFileError = nil
        let line = "\(Self.logTimestampFormatter.string(from: entry.timestamp)) \(entry.direction.rawValue) \(entry.message)\n"
        guard let data = line.data(using: .utf8) else { return }

        do {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            logFileError = error.localizedDescription
        }
    }

    // MARK: - Tuning Data Log (CSV)

    /// Lazily opens this connection's CSV file (named from `sessionTimestamp`) and writes
    /// the column header. Called on the first sample written each session.
    private func startDataLogSession() {
        dataLogFileError = nil
        dataRowCount = 0
        let stamp = sessionTimestamp ?? Date()
        let url = documentsURL.appendingPathComponent(dataLogFilePrefix + Self.fileTimestampFormatter.string(from: stamp) + ".csv")
        do {
            try dataLogHeader.write(to: url, atomically: true, encoding: .utf8)
            currentDataLogFileURL = url
        } catch {
            dataLogFileError = error.localizedDescription
        }
    }

    /// Appends one CSV sample (all values from a single Mode-01 frame) when data logging
    /// is enabled. Each column is fixed-precision, or empty when the value isn't yet known.
    private func logTuningSample() {
        guard UserDefaults.standard.bool(forKey: "dataLoggingEnabled") else { return }
        if currentDataLogFileURL == nil { startDataLogSession() }
        guard let url = currentDataLogFileURL else { return }
        dataLogFileError = nil

        let row = [
            Self.logTimestampFormatter.string(from: Date()),
            Self.csvField(stft, decimals: 2),
            Self.csvField(ltft, decimals: 2),
            Self.csvField(engineSpeed, decimals: 0),
            Self.csvField(throttlePosition, decimals: 1),
            Self.csvField(engineLoad, decimals: 1),
            Self.csvField(coolantTemp, decimals: 1),
            Self.csvField(injectorPulse, decimals: 2),
        ].joined(separator: ",") + "\n"

        guard let data = row.data(using: .utf8) else { return }
        do {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
            dataRowCount += 1
        } catch {
            dataLogFileError = error.localizedDescription
        }
    }

    private static func csvField(_ value: Double?, decimals: Int) -> String {
        guard let value else { return "" }
        return String(format: "%.\(decimals)f", value)
    }

    // MARK: - Saved Log Files (manager)

    struct LogFileInfo: Identifiable {
        let id: URL
        let name: String
        let date: Date
        let sizeText: String
        let isCSV: Bool
    }

    /// All saved per-connection log files (both TX/RX and tuning CSV), newest first.
    func savedLogFiles() -> [LogFileInfo] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: documentsURL, includingPropertiesForKeys: keys)) ?? []
        return contents
            .filter { url in
                let n = url.lastPathComponent
                return n.hasPrefix(txRxFilePrefix) || n.hasPrefix(dataLogFilePrefix)
            }
            .map { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                let date = values?.contentModificationDate ?? Date(timeIntervalSince1970: 0)
                let bytes = values?.fileSize ?? 0
                return LogFileInfo(
                    id: url,
                    name: url.lastPathComponent,
                    date: date,
                    sizeText: ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file),
                    isCSV: url.pathExtension == "csv"
                )
            }
            .sorted { $0.date > $1.date }
    }

    /// Deletes the given files; nulls the matching current-session reference if affected.
    func deleteLogFiles(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
            if url == currentTxRxFileURL { currentTxRxFileURL = nil }
            if url == currentDataLogFileURL {
                currentDataLogFileURL = nil
                dataRowCount = 0
            }
        }
    }

    private static let fileTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static let logTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    // MARK: - Preview

#if DEBUG
    static var preview: OBDViewModel {
        let vm = OBDViewModel()
        vm.stft          = 2.3
        vm.ltft          = -1.6
        vm.coolantTemp   = 87.0
        vm.engineOilTemp = 95.0
        vm.atfTemp       = 72.0
        vm.engineSpeed       = 736.0
        vm.throttlePosition  = 14.5
        vm.engineLoad        = 28.0
        vm.injectorPulse     = 4.1
        vm.connectionStatus = "Active Polling"
        vm.isConnected   = true
        vm.lastUpdate    = Date()
        vm.dataRowCount  = 128
        vm.currentDataLogFileURL = vm.documentsURL.appendingPathComponent("obd_tune_preview.csv")
        return vm
    }
#endif

    /// Safety net: if an active query gets no response, advance or reset after 5 s.
    private func armActiveTimeout() {
        activeQueryTimeoutTask?.cancel()
        activeQueryTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self else { return }

            switch self.queryState {
            case .queryingStandard:
                self.beginInjectorPulseQuery()
            case .queryingInjectorPulse:
                self.beginEngineOilQuery()
            case .queryingEngineOil:
                self.beginATFQuery()
            case .queryingATF:
                self.afterPollCycle()
            case .passive, .listening:
                break
            }
        }
    }
}
