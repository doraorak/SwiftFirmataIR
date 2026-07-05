import Testing
import Foundation
import SwiftFirmataClient
import SwiftFirmataIR

/// Minimal loopback transport (the client's own MockTransport is test-internal to
/// that package, so the IR package tests provide their own against the public protocol).
final class CaptureTransport: FirmataTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [[UInt8]] = []
    var lastSent: [UInt8]? { lock.withLock { sent.last } }
    private var cont: AsyncThrowingStream<UInt8, Error>.Continuation?
    func send(_ bytes: [UInt8]) async throws { lock.withLock { sent.append(bytes) } }
    func openStream() -> AsyncThrowingStream<UInt8, Error> {
        AsyncThrowingStream { self.cont = $0 }
    }
    func inject(_ bytes: [UInt8]) { for b in bytes { cont?.yield(b) } }
}

@Suite("IR module")
struct IRModuleTests {
    private func makeClient() async -> (FirmataClient, CaptureTransport) {
        let t = CaptureTransport()
        let c = FirmataClient(transport: t)
        await c.connect()
        await Task.yield()
        return (c, t)
    }

    @Test func liveBytes() async throws {
        let (c, t) = await makeClient()
        // Configure just sets the pin; carrier is per send.
        try await c.irConfigureTransmit(pin: 4)
        #expect(t.lastSent == [0xF0, 0x0D, 0x01, 0x00, 4, 0xF7])
        // NEC goes out via the raw op (0x03) at 38 kHz.
        try await c.irSendNEC(0x20DF10EF)
        let necPayload = IRModule.rawPayload(carrierHz: 38_000, IRModule.necTiming(0x20DF10EF))
        #expect(necPayload.first == 0x03 && necPayload[1] == 38)
        #expect(t.lastSent == [0xF0, 0x0D, 0x01] + necPayload + [0xF7])
        // RC6 uses the same raw path at 36 kHz.
        try await c.irSendRC6(0x0C)
        let rc6Payload = IRModule.rawPayload(carrierHz: 36_000, IRModule.rc6Timing(0x0C))
        #expect(rc6Payload[1] == 36)
        #expect(t.lastSent == [0xF0, 0x0D, 0x01] + rc6Payload + [0xF7])
        try await c.irStartReceive(pin: 5, into: 9)
        #expect(t.lastSent == [0xF0, 0x0D, 0x01, 0x02, 5, 9, 0xF7])
    }

    @Test func encoders() {
        // NEC: 9/4.5 ms header, 32 bits, trailing mark = 67 durations.
        let nec = IRModule.necTiming(0x20DF10EF)
        #expect(nec.count == 67)
        #expect(nec[0] == 9000 && nec[1] == 4500 && nec.last == 562)
        #expect(nec[2] == 562 && nec[3] == 562)          // first bit (bit31 = 0)
        // RC6 Mode-0: 6t/2t leader, start mark; toggle changes the waveform.
        #expect(IRModule.toggleRC6(0x0C) == 0x1000C)
        let rc6 = IRModule.rc6Timing(0x0C)
        #expect(rc6[0] == 2664 && rc6[1] == 888 && rc6[2] == 444)
        #expect(rc6 != IRModule.rc6Timing(0x1000C))
        // rawPayload: op, kHz, 14-bit LE duration pairs.
        let p = IRModule.rawPayload(carrierHz: 36_000, [2664, 888])
        #expect(p == [0x03, 36, UInt8(2664 & 0x7F), UInt8((2664 >> 7) & 0x7F),
                      UInt8(888 & 0x7F), UInt8((888 >> 7) & 0x7F)])
    }

    @Test func recorderBytes() {
        let r = FirmataTaskRecorder()
        r.irSendNEC(0x20DF10EF)
        let necPayload = IRModule.rawPayload(carrierHz: 38_000, IRModule.necTiming(0x20DF10EF))
        #expect(r.bytes == [0xF0, 0x7B, 0x7F, 0x33, 0x01] + necPayload + [0xF7])
        let r2 = FirmataTaskRecorder()
        r2.irStartReceive(pin: .pin(5), into: .reg(9))
        #expect(r2.bytes == [0xF0, 0x7B, 0x7F, 0x33, 0x01, 0x02, 5, 9, 0xF7])
    }

    @Test func decodeEvent() {
        let limbs: [UInt8] = (0..<5).map { UInt8((0x20DF10EF >> (7 * $0)) & 0x7F) }
        #expect(IRModule.decodeReceivedEvent([IRModule.receivedEvent] + limbs) == 0x20DF10EF)
        #expect(IRModule.decodeReceivedEvent([0x99] + limbs) == nil)   // wrong subcommand
    }
}
