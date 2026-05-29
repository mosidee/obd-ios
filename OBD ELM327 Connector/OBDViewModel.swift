//
//  OBDViewModel.swift
//  OBD ELM327 Connector
//
//  OBD polling loop — every `pollingDelay` seconds (default 1.0 s) an active query cycle runs in sequence:
//
//    Coolant    : ATSH7E0 + 2101, payload[11] − 40 → °C
//    Fuel trims : ATSH7E0 + 2103, payload[4/5] → STFT / LTFT
//    Engine oil : ATSH7E0 + 2151, payload[11] − 40 → °C  (Toyota mode-21, PID 51)
//    ATF        : ATSH7E0 + 2182, raw − 40 → °C          (Toyota mode-21, PID 82)
//    Coolant V2 : ATSH7C0 + 2123, raw × 0.5 → °C         (Toyota mode-21, PID 23, ECU 7C0)
//                   payload[2] → coolantTempV2 (single data byte)
//
//  After all responses are handled, ATSH7DF is restored and the cycle repeats.

import Foundation
import Combine

private enum QueryState {
    case passive         // Waiting between active polling cycles
    case queryingToyota2101 // Toyota enhanced engine packet 2101; includes coolant temp
    case queryingToyota2103 // Toyota enhanced engine packet 2103; includes fuel trims
    case queryingEngineOil // Engine oil command sent; awaiting ECU response
    case queryingATF       // ATF command sent; awaiting ECU response
    case queryingCoolantV2 // 7C0/2123 coolant V2 command sent; awaiting ECU response
    case restoringHeader   // Restoring normal functional request header before next cycle
    case listening         // Listen-Only: passively monitoring the CAN bus (CAF0 + ATMA)
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
    @Published private(set) var coolantTempV2: Double?    // TOYOTA_COOLANT_T from 7C0/2123
    @Published private(set) var connectionStatus: String = "Disconnected"
    @Published private(set) var isConnected: Bool = false
    @Published private(set) var lastUpdate: Date?
    @Published private(set) var communicationLog: [OBDCommunicationLogEntry] = [] // TX commands and RX adapter lines.
    @Published private(set) var logFileError: String?

    let logFileURL: URL

    var logFileName: String {
        logFileURL.lastPathComponent
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
    private var parser = OBDParser()

    private let maxLogEntries = 120
    private let logFileNameOnDisk = "obd_tx_rx_log.txt"
    private let defaultHeaderCommand = "ATSH7DF" // Functional OBD-II request header
    private let disableExtendedAddressCommand = "ATCEA"
    private let engineHeaderCommand = "ATSH7E0" // Toyota engine ECU request header (also carries the ATF oil-pan sensor on 7E0/7E8)
    private let toyotaEngineDataCommand = "2101" // Toyota enhanced engine data packet
    private let toyotaFuelTrimCommand = "2103"  // Toyota enhanced fuel-trim packet
    private let engineOilCommand = "2151"        // Toyota mode 21, PID 51 — TOYOTA_EOT at bix 72 (data byte 9)
    private let atfPrimaryCommand    = "2182"     // Toyota mode 21, PID 82 — ATF oil pan sensor
    private let coolantV2HeaderCommand = "ATSH7C0" // Toyota coolant ECU (V2 definition)
    private let coolantV2Command     = "2123"     // Toyota mode 21, PID 23 — ECU 7C0, response from 7C8

    // MARK: - Init

    init() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        logFileURL = documentsURL.appendingPathComponent(logFileNameOnDisk)

        #if DEBUG
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" { return }
        #endif

        bluetooth.onStateChanged = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handleBLEStateChange(state)
            }
        }
        prepareLogFileIfNeeded()
        startLineConsumer()
    }

    // MARK: - Public

    func connect() {
        communicationLog.removeAll()
        resetLogFile()
        connectionStatus = "Scanning..."
        bluetooth.startScanning()
    }

    func savedLogText() -> String {
        (try? String(contentsOf: logFileURL, encoding: .utf8)) ?? ""
    }

    func clearSavedLog() {
        communicationLog.removeAll()
        resetLogFile()
    }

    func disconnect() {
        pollTimerTask?.cancel()
        activeQueryTimeoutTask?.cancel()
        isInitializing = false
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

        isInitializing = false
        isConnected = true

        if UserDefaults.standard.bool(forKey: "listenOnlyMode") {
            beginListenOnly()           // Passive monitor instead of active polling
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

        case .queryingToyota2101:
            parseToyota2101Line(line)

        case .queryingToyota2103:
            parseToyota2103Line(line)

        case .queryingEngineOil:
            parseEngineOilLine(line)

        case .queryingATF:
            parseATFLine(line)

        case .queryingCoolantV2:
            parseCoolantV2Line(line)

        case .restoringHeader:
            if line == ">" || line.hasSuffix(">") {
                startPassiveMonitoring()
            }

        case .listening:
            parseListeningLine(line)
        }
    }

    // MARK: - Active Parser — Toyota Enhanced Engine Data

    /// Parses Toyota enhanced packet 2101 from engine ECU 7E0 (7E8 responds) — multi-frame.
    /// Coolant temp byte is at payload[11] (OBDb TOYOTA_COOLANT_TEMP; pending on-device confirmation).
    /// Formula: coolant temp (°C) = payload[11] − 40.
    private func parseToyota2101Line(_ line: String) {
        guard let payload = parser.completePayloadTokens(from: line) else { return }

        if payload.first == "7F" {
            beginToyota2103Query()
            return
        }

        if payload.count > 11,
           payload[0] == "61", payload[1] == "01",
           let rawCoolant = UInt8(payload[11], radix: 16) {
            coolantTemp = Double(rawCoolant) - 40.0
            lastUpdate = Date()
            beginToyota2103Query()
            return
        }

        handleNonFrameToyota2101Line(line)
    }

    /// Parses Toyota enhanced packet 2103 from ECU 7E8.
    /// The log shows STFT/LTFT after two status bytes: `61 03 02 00 7F 8D ...`.
    private func parseToyota2103Line(_ line: String) {
        guard let payload = parser.completePayloadTokens(from: line) else { return }

        if payload.first == "7F" {
            beginEngineOilQuery()
            return
        }

        if payload.count > 5,
           payload[0] == "61", payload[1] == "03",
           let rawSTFT = UInt8(payload[4], radix: 16),
           let rawLTFT = UInt8(payload[5], radix: 16) {
            stft = (Double(rawSTFT) * 200.0 / 256.0) - 100.0
            ltft = (Double(rawLTFT) * 200.0 / 256.0) - 100.0
            lastUpdate = Date()
            beginEngineOilQuery()
            return
        }

        handleNonFrameToyota2103Line(line)
    }

    private func handleNonFrameToyota2101Line(_ line: String) {
        let isTerminal = line.contains("NO DATA")
                      || line.contains("ERROR")
                      || line.contains("UNABLE TO CONNECT")
        if isTerminal { beginToyota2103Query() }
    }

    private func handleNonFrameToyota2103Line(_ line: String) {
        let isTerminal = line.contains("NO DATA")
                      || line.contains("ERROR")
                      || line.contains("UNABLE TO CONNECT")
        if isTerminal { beginEngineOilQuery() }
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
            beginCoolantV2Query()
            return
        }

        if payload.first == "7F" {
            beginCoolantV2Query()
            return
        }

        handleNonFrameATFLine(line)
    }

    private func handleNonFrameATFLine(_ line: String) {
        let isTerminal = line.contains("NO DATA")
                      || line.contains("ERROR")
                      || line.contains("UNABLE TO CONNECT")
        if isTerminal { beginCoolantV2Query() }
    }

    // MARK: - Active Parser — Coolant Temp V2 (ECU 7C0, command 2123)

    /// Parses Toyota mode-21 PID 23 from ECU 7C0 (7C8 responds) — single-frame response.
    /// Response: 7C8 03 61 23 XX — both TOYOTA_ECT_7C0 and TOYOTA_COOLANT_T read payload[2].
    /// Formula: °C = raw × 0.5.
    private func parseCoolantV2Line(_ line: String) {
        guard let payload = parser.completePayloadTokens(from: line) else { return }

        if payload.first == "7F" {
            returnToPassive()
            return
        }

        if payload.count > 2,
           payload[0] == "61", payload[1] == "23",
           let raw = UInt8(payload[2], radix: 16) {
            coolantTempV2 = Double(raw) * 0.5
            lastUpdate = Date()
            returnToPassive()
            return
        }

        handleNonFrameCoolantV2Line(line)
    }

    private func handleNonFrameCoolantV2Line(_ line: String) {
        let isTerminal = line.contains("NO DATA")
                      || line.contains("ERROR")
                      || line.contains("UNABLE TO CONNECT")
        if isTerminal { returnToPassive() }
    }

    private func beginCoolantV2Query() {
        activeQueryTimeoutTask?.cancel()
        parser.reset()
        queryState = .queryingCoolantV2
        connectionStatus = "Querying Coolant Temp (V2)..."
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.sendCommand(self.disableExtendedAddressCommand)
            try? await Task.sleep(for: .milliseconds(150))
            self.sendCommand(self.coolantV2HeaderCommand)
            try? await Task.sleep(for: .milliseconds(150))
            guard self.queryState == .queryingCoolantV2 else { return }
            self.sendCommand(self.coolantV2Command)
            self.armActiveTimeout()
        }
    }

    private func beginToyota2101Query() {
        activeQueryTimeoutTask?.cancel()
        parser.reset()
        queryState = .queryingToyota2101
        connectionStatus = "Querying Toyota Engine Data..."
        sendEngineRequest(toyotaEngineDataCommand)
    }

    private func beginToyota2103Query() {
        activeQueryTimeoutTask?.cancel()
        parser.reset()
        queryState = .queryingToyota2103
        connectionStatus = "Querying Toyota Fuel Trims..."
        sendEngineRequest(toyotaFuelTrimCommand)
    }

    private func sendEngineRequest(_ command: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.sendCommand(self.disableExtendedAddressCommand)
            try? await Task.sleep(for: .milliseconds(150))
            self.sendCommand(self.engineHeaderCommand)
            try? await Task.sleep(for: .milliseconds(150))
            guard self.queryState == .queryingToyota2101 || self.queryState == .queryingToyota2103 else { return }
            self.sendCommand(command)
            self.armActiveTimeout()
        }
    }

    private func beginEngineOilQuery() {
        activeQueryTimeoutTask?.cancel()
        parser.reset()
        queryState = .queryingEngineOil
        connectionStatus = "Querying Engine Oil Temp..."
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.sendCommand(self.disableExtendedAddressCommand)
            try? await Task.sleep(for: .milliseconds(150))
            self.sendCommand(self.engineHeaderCommand)
            try? await Task.sleep(for: .milliseconds(150))
            guard self.queryState == .queryingEngineOil else { return }
            self.sendCommand(self.engineOilCommand)
            self.armActiveTimeout()
        }
    }

    private func beginATFQuery() {
        activeQueryTimeoutTask?.cancel()
        queryState = .queryingATF
        connectionStatus = "Querying ATF Temp..."
        sendATFRequest()
    }

    private func sendATFRequest() {
        activeQueryTimeoutTask?.cancel()
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.sendCommand(self.disableExtendedAddressCommand)
            try? await Task.sleep(for: .milliseconds(150))
            self.sendCommand(self.engineHeaderCommand)
            try? await Task.sleep(for: .milliseconds(150))
            guard self.queryState == .queryingATF else { return }
            self.sendCommand(self.atfPrimaryCommand)
            self.armActiveTimeout()
        }
    }

    private func returnToPassive() {
        activeQueryTimeoutTask?.cancel()
        queryState = .restoringHeader
        connectionStatus = "Restoring OBD Header..."
        sendCommand(disableExtendedAddressCommand)
        sendCommand(defaultHeaderCommand)

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, self.queryState == .restoringHeader else { return }
            self.startPassiveMonitoring()
        }
    }

    private func startPassiveMonitoring() {
        queryState = .passive
        connectionStatus = "Active Polling"
        scheduleNextActiveQuery()
    }

    // MARK: - Listen-Only Mode (passive CAN-bus monitor)

    /// Enters passive monitor mode: disables CAN auto-formatting so raw ISO-TP frames
    /// (10/21/22…) reach OBDParser, filters to just the two source ECUs, then starts ATMA.
    /// Sends no OBD requests — values update only while another tester is actively polling
    /// these PIDs on the bus.
    ///
    /// The CM/CF filter is correctness, not bandwidth: OBDParser holds one shared multi-frame
    /// accumulator, and any non-ISO-TP frame resets it. Restricting delivery to 7E8/7C8 keeps
    /// interleaving noise off the bus so the multi-frame coolant (2101) and oil (2151)
    /// sequences can complete. Mask 0x7DF / filter 0x7C8 accepts exactly 7C8 and 7E8.
    private func beginListenOnly() {
        pollTimerTask?.cancel()
        activeQueryTimeoutTask?.cancel()
        parser.reset()
        queryState = .listening
        connectionStatus = "Listen-Only (monitoring)"
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.sendCommand("ATCAF0")   // CAN auto-formatting off — expose raw frames
            try? await Task.sleep(for: .milliseconds(150))
            self.sendCommand("ATCM7DF")  // CAN mask: bit 0x020 = don't-care
            try? await Task.sleep(for: .milliseconds(150))
            self.sendCommand("ATCF7C8")  // CAN filter: accept only 7C8 and 7E8
            try? await Task.sleep(for: .milliseconds(150))
            guard self.queryState == .listening else { return }
            self.sendCommand("ATMA")     // Monitor All (subject to the CM/CF filter)
        }
    }

    /// Routes a monitored frame to the matching value by its response PID byte.
    /// Reuses the same multi-frame assembler and decode formulas as active polling.
    private func parseListeningLine(_ line: String) {
        guard let payload = parser.completePayloadTokens(from: line) else { return }
        guard payload.first == "61", payload.count >= 2 else { return }

        switch payload[1] {
        case "01" where payload.count > 11:
            if let raw = UInt8(payload[11], radix: 16) {
                coolantTemp = Double(raw) - 40.0
                lastUpdate = Date()
            }
        case "03" where payload.count > 5:
            if let rawSTFT = UInt8(payload[4], radix: 16),
               let rawLTFT = UInt8(payload[5], radix: 16) {
                stft = (Double(rawSTFT) * 200.0 / 256.0) - 100.0
                ltft = (Double(rawLTFT) * 200.0 / 256.0) - 100.0
                lastUpdate = Date()
            }
        case "51" where payload.count > 11:
            if let raw = UInt8(payload[11], radix: 16) {
                engineOilTemp = Double(raw) - 40.0
                lastUpdate = Date()
            }
        case "82" where payload.count > 2:
            if let raw = UInt8(payload[2], radix: 16) {
                atfTemp = Double(raw) - 40.0
                lastUpdate = Date()
            }
        case "23" where payload.count > 2:
            if let raw = UInt8(payload[2], radix: 16) {
                coolantTempV2 = Double(raw) * 0.5
                lastUpdate = Date()
            }
        default:
            break
        }
    }

    // MARK: - Active Query Scheduling

    private func scheduleNextActiveQuery() {
        pollTimerTask?.cancel()
        pollTimerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let stored = UserDefaults.standard.double(forKey: "pollingDelay")
            let delay = stored > 0 ? stored : 1.0
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self.triggerActiveQuery()
        }
    }

    private func triggerActiveQuery() {
        guard queryState == .passive, isConnected, !isInitializing else {
            scheduleNextActiveQuery()  // Back off and retry later
            return
        }
        beginToyota2101Query()
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

    private func prepareLogFileIfNeeded() {
        guard !FileManager.default.fileExists(atPath: logFileURL.path) else { return }
        resetLogFile()
    }

    private func resetLogFile() {
        logFileError = nil
        let header = "OBD ELM327 Connector TX/RX Log\nStarted: \(Self.logTimestampFormatter.string(from: Date()))\n\n"
        do {
            try header.write(to: logFileURL, atomically: true, encoding: .utf8)
        } catch {
            logFileError = error.localizedDescription
        }
    }

    private func appendEntryToLogFile(_ entry: OBDCommunicationLogEntry) {
        logFileError = nil
        let line = "\(Self.logTimestampFormatter.string(from: entry.timestamp)) \(entry.direction.rawValue) \(entry.message)\n"
        guard let data = line.data(using: .utf8) else { return }

        do {
            let handle = try FileHandle(forWritingTo: logFileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            logFileError = error.localizedDescription
        }
    }

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
        vm.coolantTempV2 = 88.0
        vm.engineOilTemp = 95.0
        vm.atfTemp       = 72.0
        vm.connectionStatus = "Active Polling"
        vm.isConnected   = true
        vm.lastUpdate    = Date()
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
            case .queryingToyota2101:
                self.beginToyota2103Query()
            case .queryingToyota2103:
                self.beginEngineOilQuery()
            case .queryingEngineOil:
                self.beginATFQuery()
            case .queryingATF:
                self.beginCoolantV2Query()
            case .queryingCoolantV2:
                self.returnToPassive()
            case .passive, .restoringHeader, .listening:
                break
            }
        }
    }
}
