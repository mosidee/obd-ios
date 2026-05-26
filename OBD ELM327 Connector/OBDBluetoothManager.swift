//
//  OBDBluetoothManager.swift
//  OBD ELM327 Connector
//
//  Pure BLE transport layer for the Vgate iCar Pro 2S (ELM327 v2.3, Bluetooth 5.3).
//  Scans for any adapter advertising known ELM327 BLE service UUIDs, connects,
//  enables notifications, and exposes an AsyncStream<String> of complete ELM327 lines.

import Foundation
import Combine
import CoreBluetooth

// Known BLE service/characteristic UUID profiles for ELM327 adapters.
// The Vgate iCar Pro 2S typically uses the FFF0 profile; 18F0 and FFE0 are common fallbacks.
private enum BLEProfile {
    static let serviceUUIDs: [CBUUID] = [
        CBUUID(string: "FFF0"),
        CBUUID(string: "18F0"),
        CBUUID(string: "FFE0")
    ]
    static let writeUUIDs = Set([
        CBUUID(string: "FFF1"),
        CBUUID(string: "18F1"),
        CBUUID(string: "FFE1")
    ])
    static let notifyUUIDs = Set([
        CBUUID(string: "FFF2"),
        CBUUID(string: "18F2"),
        CBUUID(string: "FFE1")  // Some adapters share one UUID for both directions
    ])
}

enum BLEConnectionState: String, Equatable {
    case unknown      = "Unknown"
    case scanning     = "Scanning..."
    case connecting   = "Connecting..."
    case connected    = "Connected"
    case disconnected = "Disconnected"
    case bluetoothOff = "Bluetooth Off"
    case unauthorized = "Bluetooth Unauthorized"
    case error        = "Connection Error"
}

/// Manages the CoreBluetooth stack. All delegate callbacks arrive on the main thread
/// (CBCentralManager is initialised with queue: .main). Exposes complete ELM327 response
/// lines via an AsyncStream and notifies connection-state changes via a closure.
final class OBDBluetoothManager: NSObject, ObservableObject {

    @Published private(set) var connectionState: BLEConnectionState = .unknown {
        didSet { onStateChanged?(connectionState) }
    }
    @Published private(set) var peripheralName: String = "OBD Adapter"

    /// Consume with a single `for await line in lines { … }` loop. Yields trimmed,
    /// non-empty lines split on \r; also yields ">" as a sentinel for the command prompt.
    let lines: AsyncStream<String>

    /// Called on the main thread whenever connectionState changes.
    var onStateChanged: ((BLEConnectionState) -> Void)?

    private var continuation: AsyncStream<String>.Continuation!
    private var central: CBCentralManager?
    private var scanRequested = false
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?
    private var connectionTimeoutTask: Task<Void, Never>?
    private var receiveBuffer = ""

    override init() {
        var cont: AsyncStream<String>.Continuation!
        lines = AsyncStream<String>(bufferingPolicy: .unbounded) { c in cont = c }
        super.init()
        continuation = cont
    }

    func startScanning() {
        scanRequested = true

        guard let central else {
            connectionState = .unknown
            self.central = CBCentralManager(delegate: self, queue: .main)
            return
        }

        guard central.state == .poweredOn else {
            connectionState = central.state == .poweredOff ? .bluetoothOff : .unknown
            return
        }

        beginScanning()
    }

    func disconnect() {
        scanRequested = false
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        clearConnection()
    }

    /// Sends an AT command string, appending the required \r terminator.
    func sendCommand(_ command: String) {
        transmit(command + "\r")
    }

    // MARK: - Private

    private func beginScanning() {
        guard scanRequested, let central else { return }
        connectionState = .scanning
        central.scanForPeripherals(withServices: BLEProfile.serviceUUIDs, options: nil)
    }

    private func transmit(_ string: String) {
        guard let char = writeChar,
              let p = peripheral, p.state == .connected,
              let data = string.data(using: .utf8) else { return }
        let type: CBCharacteristicWriteType =
            char.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        p.writeValue(data, for: char, type: type)
    }

    private func clearConnection() {
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        scanRequested = false
        writeChar = nil
        notifyChar = nil
        peripheral = nil
        receiveBuffer = ""
        connectionState = .disconnected
    }

    private func armConnectionTimeout() {
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self, self.connectionState == .connecting else { return }
            if let peripheral = self.peripheral {
                self.central?.cancelPeripheralConnection(peripheral)
            }
            self.connectionState = .error
        }
    }

    /// Appends a raw BLE chunk to the buffer and emits complete lines.
    /// ELM327 uses \r as the line terminator. The ">" command prompt is emitted
    /// as a special sentinel line so the state machine can detect when the adapter
    /// is ready for the next command (used when restoring the OBD header).
    private func processIncoming(_ chunk: String) {
        receiveBuffer += chunk
        while true {
            if let crRange = receiveBuffer.range(of: "\r") {
                emit(String(receiveBuffer[..<crRange.lowerBound]))
                receiveBuffer = String(receiveBuffer[crRange.upperBound...])
            } else if let promptRange = receiveBuffer.range(of: ">") {
                emit(String(receiveBuffer[..<promptRange.lowerBound]))
                receiveBuffer = String(receiveBuffer[promptRange.upperBound...])
                emit(">")
            } else {
                break
            }
        }
    }

    private func emit(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        continuation.yield(trimmed)
    }
}

// MARK: - CBCentralManagerDelegate

extension OBDBluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if scanRequested { beginScanning() }
        case .poweredOff:
            connectionState = .bluetoothOff
        case .unauthorized:
            connectionState = .unauthorized
        default:
            connectionState = .unknown
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        peripheralName = peripheral.name ?? "OBD Adapter"
        connectionState = .connecting
        armConnectionTimeout()
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        clearConnection()
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        connectionState = .error
        self.peripheral = nil
    }
}

// MARK: - CBPeripheralDelegate

extension OBDBluetoothManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services else {
            connectionState = .error
            return
        }

        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard error == nil, let chars = service.characteristics else { return }

        for char in chars {
            let canWrite = char.properties.contains(.write) || char.properties.contains(.writeWithoutResponse)
            let canNotify = char.properties.contains(.notify) || char.properties.contains(.indicate)

            if BLEProfile.writeUUIDs.contains(char.uuid) || (writeChar == nil && canWrite) {
                writeChar = char
            }

            if BLEProfile.notifyUUIDs.contains(char.uuid) || (notifyChar == nil && canNotify) {
                notifyChar = char
                peripheral.setNotifyValue(true, for: char)
            }
        }

        if writeChar != nil, connectionState != .connected {
            connectionTimeoutTask?.cancel()
            connectionTimeoutTask = nil
            connectionState = .connected
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard let data = characteristic.value,
              let chunk = String(data: data, encoding: .utf8) else { return }
        processIncoming(chunk)
    }
}
