import AVFoundation
import Foundation

final class QuestAudioPlayer {
    private static let sampleRate = 48_000.0
    private static let channels: AVAudioChannelCount = 2
    private static let bytesPerFrame = 4

    private let queue = DispatchQueue(label: "com.apctv.questcast.audio", qos: .userInteractive)
    private let engine = AVAudioEngine()
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: sampleRate,
        channels: channels,
        interleaved: true
    )!
    private let ring = PCMByteRingBuffer(
        capacityFrames: 9_600,
        startFrames: 2_400,
        highWaterFrames: 4_800,
        bytesPerFrame: bytesPerFrame
    )
    private let onBufferChanged: (Int) -> Void
    private let onUnderrun: () -> Void
    private var isConfigured = false
    private var lastBufferPublication = DispatchTime.now() - .seconds(1)

    private lazy var sourceNode = AVAudioSourceNode(format: format) { [weak self] isSilence, _, frameCount, audioBufferList in
        guard let self else {
            isSilence.pointee = true
            return noErr
        }
        let result = self.ring.render(into: audioBufferList, frameCount: Int(frameCount))
        isSilence.pointee = ObjCBool(result.isSilent)
        if result.didUnderrun {
            DispatchQueue.main.async { [onUnderrun] in onUnderrun() }
        }
        return noErr
    }

    init(onBufferChanged: @escaping (Int) -> Void, onUnderrun: @escaping () -> Void) {
        self.onBufferChanged = onBufferChanged
        self.onUnderrun = onUnderrun
    }

    func enqueue(_ chunk: AudioChunk) {
        queue.async { [weak self] in
            guard let self else { return }
            self.ensureEngineStarted()
            let bufferedFrames = self.ring.write(chunk.pcm)
            self.publishBufferDepth(bufferedFrames: bufferedFrames)
        }
    }

    func insertSilence(chunkCount: Int) {
        guard chunkCount > 0 else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.ensureEngineStarted()
            let bufferedFrames = self.ring.writeSilence(frames: min(chunkCount, 10) * 480)
            self.publishBufferDepth(bufferedFrames: bufferedFrames)
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.ring.reset()
            self.engine.pause()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            DispatchQueue.main.async { [onBufferChanged = self.onBufferChanged] in onBufferChanged(0) }
        }
    }

    private func ensureEngineStarted() {
        if !isConfigured {
            engine.attach(sourceNode)
            engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
            isConfigured = true
        }
        guard !engine.isRunning else { return }

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
        engine.prepare()
        try? engine.start()
    }

    private func publishBufferDepth(bufferedFrames: Int) {
        let now = DispatchTime.now()
        guard now.uptimeNanoseconds - lastBufferPublication.uptimeNanoseconds >= 250_000_000 else { return }
        lastBufferPublication = now
        let milliseconds = Int((Double(bufferedFrames) / Self.sampleRate) * 1_000)
        DispatchQueue.main.async { [onBufferChanged] in onBufferChanged(milliseconds) }
    }
}

private final class PCMByteRingBuffer {
    struct RenderResult {
        let isSilent: Bool
        let didUnderrun: Bool
    }

    private let lock = NSLock()
    private let bytesPerFrame: Int
    private let startBytes: Int
    private let highWaterBytes: Int
    private var storage: [UInt8]
    private var readIndex = 0
    private var writeIndex = 0
    private var byteCount = 0
    private var isPrimed = false

    init(capacityFrames: Int, startFrames: Int, highWaterFrames: Int, bytesPerFrame: Int) {
        self.bytesPerFrame = bytesPerFrame
        startBytes = startFrames * bytesPerFrame
        highWaterBytes = highWaterFrames * bytesPerFrame
        storage = Array(repeating: 0, count: capacityFrames * bytesPerFrame)
    }

    @discardableResult
    func write(_ data: Data) -> Int {
        lock.lock()
        defer { lock.unlock() }

        let alignedByteCount = data.count - (data.count % bytesPerFrame)
        guard alignedByteCount > 0 else { return byteCount / bytesPerFrame }

        if byteCount + alignedByteCount > highWaterBytes {
            discardOldest(min(alignedByteCount, byteCount))
        }
        if byteCount + alignedByteCount > storage.count {
            discardOldest(byteCount + alignedByteCount - storage.count)
        }

        let capacity = storage.count
        let initialWriteIndex = writeIndex
        let sourceOffset = max(0, alignedByteCount - capacity)
        let bytesToWrite = min(alignedByteCount, capacity)

        data.withUnsafeBytes { source in
            guard let sourceBase = source.baseAddress else { return }
            storage.withUnsafeMutableBytes { destination in
                guard let destinationBase = destination.baseAddress else { return }
                let firstCopy = min(bytesToWrite, capacity - initialWriteIndex)
                memcpy(destinationBase.advanced(by: initialWriteIndex), sourceBase.advanced(by: sourceOffset), firstCopy)
                let secondCopy = bytesToWrite - firstCopy
                if secondCopy > 0 {
                    memcpy(destinationBase, sourceBase.advanced(by: sourceOffset + firstCopy), secondCopy)
                }
            }
        }
        writeIndex = (initialWriteIndex + bytesToWrite) % capacity
        byteCount = min(capacity, byteCount + bytesToWrite)
        return byteCount / bytesPerFrame
    }

    @discardableResult
    func writeSilence(frames: Int) -> Int {
        write(Data(count: max(0, frames) * bytesPerFrame))
    }

    func render(into audioBufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) -> RenderResult {
        let outputBytes = frameCount * bytesPerFrame
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        for buffer in buffers {
            if let destination = buffer.mData {
                memset(destination, 0, Int(buffer.mDataByteSize))
            }
        }
        guard let destination = buffers.first?.mData else {
            return RenderResult(isSilent: true, didUnderrun: false)
        }

        lock.lock()
        defer { lock.unlock() }

        if !isPrimed {
            guard byteCount >= startBytes else {
                return RenderResult(isSilent: true, didUnderrun: false)
            }
            isPrimed = true
        }

        guard byteCount >= outputBytes else {
            isPrimed = false
            return RenderResult(isSilent: true, didUnderrun: true)
        }

        let capacity = storage.count
        let initialReadIndex = readIndex
        storage.withUnsafeBytes { source in
            guard let sourceBase = source.baseAddress else { return }
            let firstCopy = min(outputBytes, capacity - initialReadIndex)
            memcpy(destination, sourceBase.advanced(by: initialReadIndex), firstCopy)
            let secondCopy = outputBytes - firstCopy
            if secondCopy > 0 {
                memcpy(destination.advanced(by: firstCopy), sourceBase, secondCopy)
            }
        }
        readIndex = (initialReadIndex + outputBytes) % capacity
        byteCount -= outputBytes
        return RenderResult(isSilent: false, didUnderrun: false)
    }

    func reset() {
        lock.lock()
        readIndex = 0
        writeIndex = 0
        byteCount = 0
        isPrimed = false
        lock.unlock()
    }

    private func discardOldest(_ requestedBytes: Int) {
        let alignedBytes = min(byteCount, requestedBytes - (requestedBytes % bytesPerFrame))
        guard alignedBytes > 0 else { return }
        readIndex = (readIndex + alignedBytes) % storage.count
        byteCount -= alignedBytes
    }
}
