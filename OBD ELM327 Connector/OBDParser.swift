//
//  OBDParser.swift
//  OBD ELM327 Connector
//
//  Stateful ISO-TP multi-frame assembler and stateless single-frame token extractor.
//  Extracted from OBDViewModel to enable unit testing without MainActor/Bluetooth setup.

import Foundation

struct OBDParser {

    private var multiFramePayload: [String] = []
    private var multiFrameExpectedLength: Int?
    private let extendedAddressByte = "18"

    /// Resets multi-frame assembly state; call at the start of each new query.
    mutating func reset() {
        multiFramePayload.removeAll()
        multiFrameExpectedLength = nil
    }

    /// Stateful multi-frame aware payload extractor.
    ///
    /// Returns `nil` while accumulating consecutive frames, and the complete
    /// payload token array once all frames have arrived (or immediately for
    /// single-frame responses).
    @discardableResult
    mutating func completePayloadTokens(from line: String) -> [String]? {
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
           tokens[0] == extendedAddressByte,
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
            return completedPayloadIfReady()
        }

        if tokens.count >= 2,
           let frameType = UInt8(tokens[0], radix: 16),
           (0x20...0x2F).contains(frameType) {
            multiFramePayload.append(contentsOf: tokens.dropFirst())
            return completedPayloadIfReady()
        }

        reset()

        if tokens.count >= 2,
           let length = UInt8(tokens[0], radix: 16), length <= 0x0F,
           Int(length) <= tokens.count - 1 {
            return Array(tokens.dropFirst().prefix(Int(length)))
        }

        return tokens
    }

    /// Stateless single-frame payload extractor for known single-frame responses (e.g. ATF 2182).
    /// Strips optional CAN ID, extended address byte, length byte, and first-frame header bytes.
    func responsePayloadTokens(from line: String) -> [String] {
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
           tokens[0] == extendedAddressByte,
           UInt8(tokens[1], radix: 16) != nil {
            tokens.removeFirst()
        }

        if tokens.count >= 2,
           let length = UInt8(tokens[0], radix: 16), length <= 0x0F,
           ["41", "61", "62", "7F"].contains(tokens[1]) {
            tokens.removeFirst()
        }

        if tokens.count >= 3,
           let frameType = UInt8(tokens[0], radix: 16),
           (0x10...0x1F).contains(frameType),
           UInt8(tokens[1], radix: 16) != nil,
           ["41", "61", "62", "7F"].contains(tokens[2]) {
            tokens.removeFirst(2)
        }

        return tokens
    }

    /// Walks a standard Mode-01 response payload (which begins with `41`) into a
    /// pid → data-byte map. `lengths` gives the data-byte count for each expected PID.
    /// Stops at the first PID not in `lengths` or if the payload is truncated, so an
    /// unknown/unsupported trailing PID can't corrupt the values parsed before it.
    static func mode01Values(from payload: [String], lengths: [String: Int]) -> [String: [UInt8]] {
        guard payload.first == "41" else { return [:] }
        var result: [String: [UInt8]] = [:]
        var i = 1
        while i < payload.count {
            let pid = payload[i]
            guard let len = lengths[pid], i + len < payload.count else { break }
            let bytes = (1...len).compactMap { UInt8(payload[i + $0], radix: 16) }
            guard bytes.count == len else { break }
            result[pid] = bytes
            i += 1 + len
        }
        return result
    }

    /// Returns the byte immediately following `sequence` within `payload`, or `nil` if not found.
    static func rawByte(after sequence: [String], in payload: [String]) -> UInt8? {
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

    // MARK: - Private

    private mutating func completedPayloadIfReady() -> [String]? {
        // A consecutive frame with no preceding first frame leaves expectedLength nil;
        // return nil rather than a partial accumulator.
        guard let expected = multiFrameExpectedLength else { return nil }
        guard multiFramePayload.count >= expected else { return nil }
        let payload = Array(multiFramePayload.prefix(expected))
        reset()
        return payload
    }
}
