import Foundation

struct AccessUnit {
    let data: Data
    let presentationTimeUs: UInt64
    let isConfiguration: Bool
    let isKeyFrame: Bool
}

final class PacketAssembler {
    private struct PartialFrame {
        let createdAt: ContinuousClock.Instant
        let fragmentCount: Int
        let presentationTimeUs: UInt64
        let flags: UInt8
        var fragments: [Int: Data]
    }

    private let clock = ContinuousClock()
    private let onAccessUnit: (AccessUnit) -> Void
    private let onDrop: (Int) -> Void
    private var frames: [UInt32: PartialFrame] = [:]

    init(onAccessUnit: @escaping (AccessUnit) -> Void, onDrop: @escaping (Int) -> Void) {
        self.onAccessUnit = onAccessUnit
        self.onDrop = onDrop
    }

    func ingest(_ datagram: Data) {
        guard let packet = Packet(datagram) else { return }
        expireOldFrames()

        var frame = frames[packet.frameID] ?? PartialFrame(
            createdAt: clock.now,
            fragmentCount: packet.fragmentCount,
            presentationTimeUs: packet.presentationTimeUs,
            flags: packet.flags,
            fragments: [:]
        )
        guard frame.fragmentCount == packet.fragmentCount else {
            frames.removeValue(forKey: packet.frameID)
            onDrop(1)
            return
        }
        frame.fragments[packet.fragmentIndex] = packet.payload

        if frame.fragments.count == frame.fragmentCount {
            var accessUnit = Data()
            for index in 0..<frame.fragmentCount {
                guard let fragment = frame.fragments[index] else { return }
                accessUnit.append(fragment)
            }
            frames.removeValue(forKey: packet.frameID)
            onAccessUnit(AccessUnit(
                data: accessUnit,
                presentationTimeUs: frame.presentationTimeUs,
                isConfiguration: frame.flags & 0x01 != 0,
                isKeyFrame: frame.flags & 0x02 != 0
            ))
        } else {
            frames[packet.frameID] = frame
            trimFrameWindow()
        }
    }

    private func expireOldFrames() {
        let deadline = clock.now - .milliseconds(80)
        let expired = frames.filter { $0.value.createdAt < deadline }.map(\.key)
        expired.forEach { frames.removeValue(forKey: $0) }
        if !expired.isEmpty { onDrop(expired.count) }
    }

    private func trimFrameWindow() {
        guard frames.count > 4 else { return }
        let excess = frames.count - 4
        let oldest = frames.sorted { $0.value.createdAt < $1.value.createdAt }.prefix(excess)
        oldest.forEach { frames.removeValue(forKey: $0.key) }
        onDrop(excess)
    }
}

private struct Packet {
    let flags: UInt8
    let frameID: UInt32
    let fragmentIndex: Int
    let fragmentCount: Int
    let presentationTimeUs: UInt64
    let payload: Data

    init?(_ data: Data) {
        guard data.count >= 24,
              data.prefix(4) == Data([0x51, 0x43, 0x54, 0x56]),
              data[4] == 1 else { return nil }
        let headerLength = Int(data.uint16(at: 6))
        guard headerLength == 24, data.count >= headerLength else { return nil }
        let fragmentIndex = Int(data.uint16(at: 12))
        let fragmentCount = Int(data.uint16(at: 14))
        guard fragmentCount > 0, fragmentIndex < fragmentCount else { return nil }

        self.flags = data[5]
        self.frameID = data.uint32(at: 8)
        self.fragmentIndex = fragmentIndex
        self.fragmentCount = fragmentCount
        self.presentationTimeUs = data.uint64(at: 16)
        self.payload = data.subdata(in: headerLength..<data.count)
    }
}

private extension Data {
    func uint16(at offset: Int) -> UInt16 {
        (UInt16(self[offset]) << 8) | UInt16(self[offset + 1])
    }

    func uint32(at offset: Int) -> UInt32 {
        (UInt32(self[offset]) << 24) |
        (UInt32(self[offset + 1]) << 16) |
        (UInt32(self[offset + 2]) << 8) |
        UInt32(self[offset + 3])
    }

    func uint64(at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 { value = (value << 8) | UInt64(self[offset + index]) }
        return value
    }
}

