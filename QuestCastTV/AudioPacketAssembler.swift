import Foundation

struct AudioChunk {
    let pcm: Data
    let presentationTimeUs: UInt64
}

final class AudioPacketAssembler {
    private struct PartialChunk {
        let createdAt: ContinuousClock.Instant
        let fragmentCount: Int
        let presentationTimeUs: UInt64
        var fragments: [Int: Data]
    }

    private let clock = ContinuousClock()
    private let onChunk: (AudioChunk) -> Void
    private let onDrop: (Int) -> Void
    private var chunks: [UInt32: PartialChunk] = [:]

    init(onChunk: @escaping (AudioChunk) -> Void, onDrop: @escaping (Int) -> Void) {
        self.onChunk = onChunk
        self.onDrop = onDrop
    }

    func ingest(_ datagram: Data) {
        guard let packet = AudioPacket(datagram) else { return }
        expireOldChunks()

        var chunk = chunks[packet.chunkID] ?? PartialChunk(
            createdAt: clock.now,
            fragmentCount: packet.fragmentCount,
            presentationTimeUs: packet.presentationTimeUs,
            fragments: [:]
        )
        guard chunk.fragmentCount == packet.fragmentCount else {
            chunks.removeValue(forKey: packet.chunkID)
            onDrop(1)
            return
        }
        chunk.fragments[packet.fragmentIndex] = packet.payload

        if chunk.fragments.count == chunk.fragmentCount {
            var pcm = Data()
            for index in 0..<chunk.fragmentCount {
                guard let fragment = chunk.fragments[index] else { return }
                pcm.append(fragment)
            }
            chunks.removeValue(forKey: packet.chunkID)
            onChunk(AudioChunk(pcm: pcm, presentationTimeUs: chunk.presentationTimeUs))
        } else {
            chunks[packet.chunkID] = chunk
            trimChunkWindow()
        }
    }

    private func expireOldChunks() {
        let deadline = clock.now - .milliseconds(80)
        let expired = chunks.filter { $0.value.createdAt < deadline }.map(\.key)
        expired.forEach { chunks.removeValue(forKey: $0) }
        if !expired.isEmpty { onDrop(expired.count) }
    }

    private func trimChunkWindow() {
        guard chunks.count > 12 else { return }
        let excess = chunks.count - 12
        let oldest = chunks.sorted { $0.value.createdAt < $1.value.createdAt }.prefix(excess)
        oldest.forEach { chunks.removeValue(forKey: $0.key) }
        onDrop(excess)
    }
}

private struct AudioPacket {
    let chunkID: UInt32
    let fragmentIndex: Int
    let fragmentCount: Int
    let presentationTimeUs: UInt64
    let payload: Data

    init?(_ data: Data) {
        guard data.count >= 24,
              data.prefix(4) == Data([0x51, 0x43, 0x54, 0x41]),
              data[4] == 1 else { return nil }
        let headerLength = Int(data.audioUInt16(at: 6))
        guard headerLength == 24, data.count >= headerLength else { return nil }
        let fragmentIndex = Int(data.audioUInt16(at: 12))
        let fragmentCount = Int(data.audioUInt16(at: 14))
        guard fragmentCount > 0, fragmentIndex < fragmentCount else { return nil }

        chunkID = data.audioUInt32(at: 8)
        self.fragmentIndex = fragmentIndex
        self.fragmentCount = fragmentCount
        presentationTimeUs = data.audioUInt64(at: 16)
        payload = data.subdata(in: headerLength..<data.count)
    }
}

private extension Data {
    func audioUInt16(at offset: Int) -> UInt16 {
        (UInt16(self[offset]) << 8) | UInt16(self[offset + 1])
    }

    func audioUInt32(at offset: Int) -> UInt32 {
        (UInt32(self[offset]) << 24) |
        (UInt32(self[offset + 1]) << 16) |
        (UInt32(self[offset + 2]) << 8) |
        UInt32(self[offset + 3])
    }

    func audioUInt64(at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 { value = (value << 8) | UInt64(self[offset + index]) }
        return value
    }
}
