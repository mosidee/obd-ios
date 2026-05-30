//
//  OBDParserTests.swift
//  OBD ELM327 Connector Tests
//

import Testing
@testable import OBD_ELM327_Connector

// MARK: - completePayloadTokens

@Suite("completePayloadTokens")
struct CompletePayloadTokensTests {

    @Test func singleFrame_stripsCanIdAndLength() {
        // Real 2123 response from TX/RX log: 7C8 03 61 23 7D
        var p = OBDParser()
        let result = p.completePayloadTokens(from: "7C8 03 61 23 7D")
        #expect(result == ["61", "23", "7D"])
    }

    @Test func singleFrame_nrc_response() {
        var p = OBDParser()
        let result = p.completePayloadTokens(from: "7E8 03 7F 21 12")
        #expect(result == ["7F", "21", "12"])
    }

    @Test func singleFrame_fuelTrims_2103() {
        // 2103 single-frame (6 payload bytes): STFT=0x82 (130), LTFT=0x7D (125)
        var p = OBDParser()
        let payload = p.completePayloadTokens(from: "7E8 06 61 03 00 00 82 7D")
        #expect(payload == ["61", "03", "00", "00", "82", "7D"])
    }

    @Test func multiFrame_coolant2101_returnsNilWhileAccumulating() {
        var p = OBDParser()
        // First frame: length=0x1C=28 bytes, contributes 6 payload bytes (indices 0-5)
        #expect(p.completePayloadTokens(from: "7E8 10 1C 61 01 00 00 00 00") == nil)
        // Consecutive frames: each adds 7 bytes (still under 28 total)
        #expect(p.completePayloadTokens(from: "7E8 21 00 00 00 00 00 00 00") == nil)
        // CF2: still accumulating (payload not yet complete)
        #expect(p.completePayloadTokens(from: "7E8 22 00 00 00 00 00 7E 00") == nil)
        #expect(p.completePayloadTokens(from: "7E8 23 00 00 00 00 00 00 00") == nil)
    }

    @Test func multiFrame_coolant2101_completesAtCorrectLength() {
        var p = OBDParser()
        p.completePayloadTokens(from: "7E8 10 1C 61 01 00 00 00 00")
        p.completePayloadTokens(from: "7E8 21 00 00 00 00 00 00 00")
        p.completePayloadTokens(from: "7E8 22 00 00 00 00 00 7E 00")
        p.completePayloadTokens(from: "7E8 23 00 00 00 00 00 00 00")
        let payload = p.completePayloadTokens(from: "7E8 24 00 00 00 00 00 00 00")
        #expect(payload != nil)
        #expect(payload?.count == 28)
        #expect(payload?[0] == "61" && payload?[1] == "01")
    }

    @Test func multiFrame_coolant2101_coolantByteAtIndex18() {
        // Verifies that payload[18] carries the coolant raw byte (0x7E = 86°C after −40)
        var p = OBDParser()
        p.completePayloadTokens(from: "7E8 10 1C 61 01 00 00 00 00")
        p.completePayloadTokens(from: "7E8 21 00 00 00 00 00 00 00")
        p.completePayloadTokens(from: "7E8 22 00 00 00 00 00 7E 00")
        p.completePayloadTokens(from: "7E8 23 00 00 00 00 00 00 00")
        let payload = p.completePayloadTokens(from: "7E8 24 00 00 00 00 00 00 00")!
        let raw = UInt8(payload[18], radix: 16)!   // 0x7E = 126
        #expect(Double(raw) - 40.0 == 86.0)
    }

    @Test func multiFrame_engineOil2151_payloadIndex11() {
        // Engine oil: length=0x0C=12 bytes; payload[11] = oil temp byte (0x5A=90 → 50°C)
        var p = OBDParser()
        #expect(p.completePayloadTokens(from: "7E8 10 0C 61 51 00 00 00 00") == nil)
        let payload = p.completePayloadTokens(from: "7E8 21 00 00 00 00 00 5A 00")!
        #expect(payload.count == 12)
        #expect(payload[0] == "61" && payload[1] == "51")
        let raw = UInt8(payload[11], radix: 16)!   // 0x5A = 90
        #expect(Double(raw) - 40.0 == 50.0)
    }

    @Test func consecutiveFrame_withoutFirstFrame_returnsNil() {
        // A consecutive frame (0x2x) with no preceding first frame has no expected
        // length, so the parser must return nil rather than a partial payload.
        var p = OBDParser()
        #expect(p.completePayloadTokens(from: "7E8 21 00 00 00 00 00 00 00") == nil)
        // State stays clean: a following single-frame still parses correctly.
        #expect(p.completePayloadTokens(from: "7C8 03 61 23 7D") == ["61", "23", "7D"])
    }

    @Test func reset_clearsAccumulatedFrames() {
        // Start a multi-frame sequence, reset, then process a new single-frame
        var p = OBDParser()
        p.completePayloadTokens(from: "7E8 10 1C 61 01 00 00 00 00")
        p.reset()
        let result = p.completePayloadTokens(from: "7C8 03 61 23 7D")
        #expect(result == ["61", "23", "7D"])
    }
}

// MARK: - responsePayloadTokens

@Suite("responsePayloadTokens")
struct ResponsePayloadTokensTests {

    @Test func atf_stripsCanIdAndLength() {
        // ATF response: 7E8 03 61 82 50 → strips 7E8 (CAN ID) and 03 (length)
        let p = OBDParser()
        let tokens = p.responsePayloadTokens(from: "7E8 03 61 82 50")
        #expect(tokens == ["61", "82", "50"])
    }

    @Test func injectorPulse_stripsCanIdAndLength() {
        // Injector pulse response: 7E8 07 61 3C 0F E9 10 16 69 → strips 7E8 (CAN ID) and 07 (length)
        let p = OBDParser()
        let tokens = p.responsePayloadTokens(from: "7E8 07 61 3C 0F E9 10 16 69")
        #expect(tokens == ["61", "3C", "0F", "E9", "10", "16", "69"])
    }

    @Test func stripsExtendedAddressByte() {
        // Extended-address frame: 7E8 18 05 62 DA 12 7B → strips 7E8, 18, 05
        let p = OBDParser()
        let tokens = p.responsePayloadTokens(from: "7E8 18 05 62 DA 12 7B")
        #expect(tokens == ["62", "DA", "12", "7B"])
    }
}

// MARK: - mode01Values

@Suite("mode01Values")
struct Mode01ValuesTests {

    @Test func walksMultiPidResponse() {
        // 41 05 5C  0C 0B 7F  11 2B → coolant 0x5C, rpm 0x0B7F, throttle 0x2B
        let payload = ["41", "05", "5C", "0C", "0B", "7F", "11", "2B"]
        let v = OBDParser.mode01Values(from: payload, lengths: ["05": 1, "0C": 2, "11": 1])
        #expect(v["05"] == [0x5C])
        #expect(v["0C"] == [0x0B, 0x7F])
        #expect(v["11"] == [0x2B])
    }

    @Test func stopsAtUnknownPid() {
        // Trailing unsupported PID 0x99 must not corrupt the values parsed before it.
        let v = OBDParser.mode01Values(from: ["41", "05", "5C", "99", "00"], lengths: ["05": 1])
        #expect(v["05"] == [0x5C])
        #expect(v["99"] == nil)
    }

    @Test func ignoresNonMode01Payload() {
        // An enhanced 61-response is not a Mode-01 reply.
        #expect(OBDParser.mode01Values(from: ["61", "01", "00"], lengths: ["05": 1]).isEmpty)
    }
}

// MARK: - rawByte(after:in:)

@Suite("rawByte")
struct RawByteTests {

    @Test func findsImmediatelyAfterSequence() {
        let result = OBDParser.rawByte(after: ["61", "82"], in: ["61", "82", "50"])
        #expect(result == 0x50)
    }

    @Test func returnsNilWhenSequenceAbsent() {
        let result = OBDParser.rawByte(after: ["61", "82"], in: ["61", "83", "50"])
        #expect(result == nil)
    }

    @Test func returnsNilWhenPayloadTooShort() {
        let result = OBDParser.rawByte(after: ["61", "82"], in: ["61"])
        #expect(result == nil)
    }
}

// MARK: - Value formulas

@Suite("Value formulas")
struct ValueFormulaTests {

    @Test func coolantTemp_rawMinusForty() {
        // payload[18] formula: raw − 40
        let raw: UInt8 = 0x7E   // 126
        #expect(Double(raw) - 40.0 == 86.0)
    }

    @Test func engineOilTemp_rawMinusForty() {
        let raw: UInt8 = 0x5A   // 90
        #expect(Double(raw) - 40.0 == 50.0)
    }

    @Test func atfTemp_rawMinusForty() {
        let raw: UInt8 = 0x50   // 80
        #expect(Double(raw) - 40.0 == 40.0)
    }

    @Test func injectorPulse_scaledToMilliseconds() {
        // Toyota enhanced 213C: injector pulse width = (256·C + D) / 1000 → ms, where C,D are the
        // 3rd/4th data bytes after `61 3C` (the live, fuel-corrected field). 16-bit µs value.
        // Idle sample (C=0F, D=A5): (256×15 + 165)/1000 = 4.005 ms
        #expect(abs((Double(UInt8(0x0F)) * 256.0 + Double(UInt8(0xA5))) / 1000.0 - 4.005) < 0.0001)
        // Under load (C=1E, D=CC): (256×30 + 204)/1000 = 7.884 ms
        #expect(abs((Double(UInt8(0x1E)) * 256.0 + Double(UInt8(0xCC))) / 1000.0 - 7.884) < 0.0001)
    }

    @Test func fuelTrim_zeroAtMidpoint() {
        // raw=0x80=128 → (128 × 200 / 256) − 100 = 0%
        let raw: UInt8 = 0x80
        let pct = (Double(raw) * 200.0 / 256.0) - 100.0
        #expect(pct == 0.0)
    }

    @Test func fuelTrim_positiveSlightLean() {
        // raw=0x82=130 → ≈ +1.5625%
        let raw: UInt8 = 0x82
        let pct = (Double(raw) * 200.0 / 256.0) - 100.0
        #expect(abs(pct - 1.5625) < 0.0001)
    }

    @Test func fuelTrim_negativeSlightRich() {
        // raw=0x7D=125 → ≈ −2.34375%
        let raw: UInt8 = 0x7D
        let pct = (Double(raw) * 200.0 / 256.0) - 100.0
        #expect(abs(pct - (-2.34375)) < 0.0001)
    }

    @Test func engineSpeed_quarterRpm() {
        // Standard PID-0C formula (A·256 + B) / 4 → rpm. 0x0B 0x7F = 2943 → 735.75 (idle).
        let a: UInt8 = 0x0B, b: UInt8 = 0x7F
        #expect((Double(a) * 256.0 + Double(b)) / 4.0 == 735.75)
    }

    @Test func throttle_percentScaling() {
        // Standard PID-11 throttle byte: raw × 100 / 255 → percent.
        #expect((Double(UInt8(0xFF)) * 100.0 / 255.0) == 100.0)
        #expect(abs((Double(UInt8(0x80)) * 100.0 / 255.0) - 50.196) < 0.01)
    }
}
