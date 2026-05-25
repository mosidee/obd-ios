//
//  OBDViewModel.swift
//  OBD ELM327 Connector
//
//  OBD polling loop — every 4–6 s an active query cycle runs in sequence:
//
//    Coolant    : ATSH7E0 + 2101, payload[18] − 40 → °C
//    Fuel trims : ATSH7E0 + 2103, payload[4/5] → STFT / LTFT
//    Engine oil : ATSH7E0 + 2151, payload[11] − 40 → °C  (Toyota mode-21, PID 51)
//    ATF        : ATSH7E0 + 2182, raw − 40 → °C          (Toyota mode-21, PID 82)
//    Coolant V2 : ATSH7C0 + 2123, raw × 0.5 → °C         (Toyota mode-21, PID 23, ECU 7C0)
//                   payload[2] → TOYOTA_ECT_7C0 (Engine Coolant Temp)
//                   payload[3] → TOYOTA_COOLANT_T (Coolant Temp)
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
    @Published private(set) var coolantTempECT: Double?   // TOYOTA_ECT_7C0 from 7C0/2123
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
    private var atfTimerTask: Task<Void, Never>?
    private var atfTimeoutTask: Task<Void, Never>?

    private var queryState: QueryState = .passive
    private var isInitializing = false
    private var multiFramePayload: [String] = []
    private var multiFrameExpectedLength: Int?

    private let maxLogEntries = 120
    private let logFileNameOnDisk = "obd_tx_rx_log.txt"
    private let defaultHeaderCommand = "ATSH7DF" // Functional OBD-II request header
    private let transmissionDA12HeaderCommand = "ATSH7E0" // Engine ECU header — ATF oil pan sensor also on 7E0/7E8
    private let transmissionExtendedAddress = "18"
    private let disableExtendedAddressCommand = "ATCEA"
    private let engineHeaderCommand = "ATSH7E0" // Toyota engine ECU request header
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
        atfTimerTask?.cancel()
        atfTimeoutTask?.cancel()
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
            atfTimerTask?.cancel()
            atfTimeoutTask?.cancel()
            isInitializing = false
            isConnected = false
            connectionStatus = state.rawValue
        case .bluetoothOff, .unauthorized:
            atfTimerTask?.cancel()
            atfTimeoutTask?.cancel()
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
        connectionStatus = "Active Polling"

        scheduleNextActiveQuery()       // Begin the active query cycle
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
            if line.contains("BUFFER FULL") || line == ">" || line == "?" {
                return
            }
            parsePassiveLine(line)

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
        }
    }

    // MARK: - Passive Parser — STFT (PID 06) & LTFT (PID 07)

    /// Parses unsolicited mode-01 CAN frames from ECU 7E0.
    ///
    /// Expected token layout with ATH1 + ATS1:
    ///   7E0  04  41  PID  DATA  …
    ///   [0] [1] [2] [3]  [4]
    ///
    /// 0x41 = mode-01 positive response (0x01 + 0x40)
    /// Formula: fuelTrim% = (rawByte × 0.78125) − 100
    private func parsePassiveLine(_ line: String) {
        let tokens = line.components(separatedBy: " ").filter { !$0.isEmpty }
        guard tokens.count >= 5,
              tokens[0] == "7E0",
              tokens[2] == "41",
              let rawByte = UInt8(tokens[4], radix: 16)
        else { return }

        let trimPct = (Double(rawByte) * 0.78125) - 100.0

        switch tokens[3] {
        case "06":
            stft = trimPct
            lastUpdate = Date()
        case "07":
            ltft = trimPct
            lastUpdate = Date()
        default:
            break
        }
    }

    // MARK: - Active Parser — Toyota Enhanced Engine Data

    /// Parses Toyota enhanced packet 2101 from engine ECU 7E0 (7E8 responds) — multi-frame.
    /// Coolant temp byte is at payload[18] (empirically verified on this ECU).
    /// Formula: coolant temp (°C) = payload[18] − 40.
    private func parseToyota2101Line(_ line: String) {
        guard let payload = completePayloadTokens(from: line) else { return }

        if payload.first == "7F" {
            beginToyota2103Query()
            return
        }

        if payload.count > 18,
           payload[0] == "61", payload[1] == "01",
           let rawCoolant = UInt8(payload[18], radix: 16) {
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
        guard let payload = completePayloadTokens(from: line) else { return }

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

    private func completePayloadTokens(from line: String) -> [String]? {
        var tokens = line.components(separatedBy: " ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty else { return [] }

        if let first = tokens.first,
           first.count >= 3,
           UInt32(first, radix: 16) != nil {
            tokens.removeFirst()
        }

        if tokens.count >= 2,
           tokens[0] == transmissionExtendedAddress,
           UInt8(tokens[1], radix: 16) != nil {
            tokens.removeFirst()
        }

        guard !tokens.isEmpty else { return [] }

        if tokens.count >= 2,
           let frameType = UInt8(tokens[0], radix: 16),
           (0x10...0x1F).contains(frameType),
           let expectedLength = UInt8(tokens[1], radix: 16) {
            multiFrameExpectedLength = Int(expectedLength)
            multiFramePayload = Array(tokens.dropFirst(2))
            return completedMultiFramePayloadIfReady()
        }

        if tokens.count >= 2,
           let frameType = UInt8(tokens[0], radix: 16),
           (0x20...0x2F).contains(frameType) {
            multiFramePayload.append(contentsOf: tokens.dropFirst())
            return completedMultiFramePayloadIfReady()
        }

        resetMultiFrameBuffer()

        if tokens.count >= 2,
           let length = UInt8(tokens[0], radix: 16), length <= 0x0F,
           Int(length) <= tokens.count - 1 {
            return Array(tokens.dropFirst().prefix(Int(length)))
        }

        return tokens
    }

    private func completedMultiFramePayloadIfReady() -> [String]? {
        guard let expectedLength = multiFrameExpectedLength else { return multiFramePayload }
        guard multiFramePayload.count >= expectedLength else { return nil }
        let payload = Array(multiFramePayload.prefix(expectedLength))
        resetMultiFrameBuffer()
        return payload
    }

    private func resetMultiFrameBuffer() {
        multiFramePayload.removeAll()
        multiFrameExpectedLength = nil
    }

    private func responsePayloadTokens(from line: String) -> [String] {
        var tokens = line.components(separatedBy: " ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty else { return [] }

        // Drop an optional CAN response ID such as 7E8, 7E9, or 18DAF110.
        if let first = tokens.first,
           first.count >= 3,
           UInt32(first, radix: 16) != nil {
            tokens.removeFirst()
        }

        // Drop an optional CAN extended address byte, e.g. 18 05 62 DA 12 7B.
        if tokens.count >= 2,
           tokens[0] == transmissionExtendedAddress,
           UInt8(tokens[1], radix: 16) != nil {
            tokens.removeFirst()
        }

        // Drop an optional ISO-TP single-frame length byte, e.g. 03 41 05 7B.
        if tokens.count >= 2,
           let length = UInt8(tokens[0], radix: 16), length <= 0x0F,
           ["41", "61", "62", "7F"].contains(tokens[1]) {
            tokens.removeFirst()
        }

        // Drop optional ISO-TP first-frame bytes, e.g. 10 08 62 DA 12 7B ...
        if tokens.count >= 3,
           let frameType = UInt8(tokens[0], radix: 16),
           (0x10...0x1F).contains(frameType),
           UInt8(tokens[1], radix: 16) != nil,
           ["41", "61", "62", "7F"].contains(tokens[2]) {
            tokens.removeFirst(2)
        }

        return tokens
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
        guard let payload = completePayloadTokens(from: line) else { return }

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

    private func rawByte(after sequence: [String], in payload: [String]) -> UInt8? {
        guard payload.count > sequence.count else { return nil }

        for startIndex in payload.indices {
            let endIndex = startIndex + sequence.count
            guard endIndex < payload.count else { continue }
            if Array(payload[startIndex..<endIndex]) == sequence {
                return UInt8(payload[endIndex], radix: 16)
            }
        }

        return nil
    }

    // MARK: - Active Parser — ATF Temperature

    /// Parses Toyota mode-21 PID 82 from engine ECU 7E0 (7E8 responds).
    /// Response: 7E8 03 61 82 XX — ATF temp (°C) = XX − 40.
    private func parseATFLine(_ line: String) {
        let payload = responsePayloadTokens(from: line)

        if let raw = rawByte(after: ["61", "82"], in: payload) {
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
    /// payload[2] → TOYOTA_ECT_7C0 (Engine Coolant Temp), payload[3] → TOYOTA_COOLANT_T.
    /// Formula: °C = raw × 0.5 for both signals.
    private func parseCoolantV2Line(_ line: String) {
        guard let payload = completePayloadTokens(from: line) else { return }

        if payload.first == "7F" {
            returnToPassive()
            return
        }

        if payload.count > 3,
           payload[0] == "61", payload[1] == "23",
           let rawECT     = UInt8(payload[2], radix: 16),
           let rawCoolant = UInt8(payload[3], radix: 16) {
            coolantTempECT = Double(rawECT)     * 0.5
            coolantTempV2  = Double(rawCoolant) * 0.5
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
        atfTimeoutTask?.cancel()
        resetMultiFrameBuffer()
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
        atfTimeoutTask?.cancel()
        resetMultiFrameBuffer()
        queryState = .queryingToyota2101
        connectionStatus = "Querying Toyota Engine Data..."
        sendEngineRequest(toyotaEngineDataCommand)
    }

    private func beginToyota2103Query() {
        atfTimeoutTask?.cancel()
        resetMultiFrameBuffer()
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
        atfTimeoutTask?.cancel()
        resetMultiFrameBuffer()
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
        atfTimeoutTask?.cancel()
        queryState = .queryingATF
        connectionStatus = "Querying ATF Temp..."
        sendATFRequest()
    }

    private func sendATFRequest() {
        atfTimeoutTask?.cancel()
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.sendCommand(self.disableExtendedAddressCommand)
            try? await Task.sleep(for: .milliseconds(150))
            self.sendCommand(self.transmissionDA12HeaderCommand)
            try? await Task.sleep(for: .milliseconds(150))
            guard self.queryState == .queryingATF else { return }
            self.sendCommand(self.atfPrimaryCommand)
            self.armActiveTimeout()
        }
    }

    private func returnToPassive() {
        atfTimeoutTask?.cancel()
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

    // MARK: - Active Query Scheduling

    private func scheduleNextActiveQuery() {
        atfTimerTask?.cancel()
        atfTimerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let delay = Double.random(in: 4...6)
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
        vm.coolantTempECT = 89.5
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
        atfTimeoutTask?.cancel()
        atfTimeoutTask = Task { @MainActor [weak self] in
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
            case .passive, .restoringHeader:
                break
            }
        }
    }
}
