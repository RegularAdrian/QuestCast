import AVFoundation
import Foundation

final class QuestAudioPlayer {
    private let sampleRate = 48_000.0
    private let channels: AVAudioChannelCount = 2
    private let bytesPerFrame = 4
    private let startBufferFrames: AVAudioFrameCount = 1_440
    private let maximumBufferFrames: AVAudioFrameCount = 4_800

    private let queue = DispatchQueue(label: "com.apctv.questcast.audio", qos: .userInteractive)
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let onBufferChanged: (Int) -> Void
    private var format: AVAudioFormat?
    private var pending: [AVAudioPCMBuffer] = []
    private var queuedFrames: AVAudioFrameCount = 0
    private var isPlaying = false

    init(onBufferChanged: @escaping (Int) -> Void) {
        self.onBufferChanged = onBufferChanged
    }

    func enqueue(_ chunk: AudioChunk) {
        queue.async { [weak self] in self?.enqueueOnQueue(chunk) }
    }

    func stop() {
        queue.async { [weak self] in self?.resetOnQueue() }
    }

    private func enqueueOnQueue(_ chunk: AudioChunk) {
        guard chunk.pcm.count >= bytesPerFrame else { return }
        if queuedFrames >= maximumBufferFrames {
            resetOnQueue()
        }
        guard let buffer = makeBuffer(from: chunk.pcm) else { return }
        pending.append(buffer)
        queuedFrames += buffer.frameLength
        publishBufferDepth()

        guard queuedFrames >= startBufferFrames else { return }
        ensureEngineStarted()
        pending.forEach(schedule)
        pending.removeAll(keepingCapacity: true)
        if !isPlaying {
            player.play()
            isPlaying = true
        }
    }

    private func makeBuffer(from pcm: Data) -> AVAudioPCMBuffer? {
        if format == nil {
            format = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: sampleRate,
                channels: channels,
                interleaved: true
            )
        }
        guard let format else { return nil }
        let frameCount = AVAudioFrameCount(pcm.count / bytesPerFrame)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let destination = buffer.mutableAudioBufferList.pointee.mBuffers.mData else { return nil }
        buffer.frameLength = frameCount
        pcm.copyBytes(to: destination.assumingMemoryBound(to: UInt8.self), count: Int(frameCount) * bytesPerFrame)
        return buffer
    }

    private func ensureEngineStarted() {
        guard let format else { return }
        if engine.attachedNodes.contains(player) == false {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
        }
        if !engine.isRunning {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .moviePlayback)
            try? session.setActive(true)
            try? engine.start()
        }
    }

    private func schedule(_ buffer: AVAudioPCMBuffer) {
        let frameLength = buffer.frameLength
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.queue.async {
                guard let self else { return }
                self.queuedFrames = self.queuedFrames > frameLength ? self.queuedFrames - frameLength : 0
                self.publishBufferDepth()
            }
        }
    }

    private func resetOnQueue() {
        player.stop()
        pending.removeAll(keepingCapacity: true)
        queuedFrames = 0
        isPlaying = false
        publishBufferDepth()
    }

    private func publishBufferDepth() {
        let milliseconds = Int((Double(queuedFrames) / sampleRate) * 1_000)
        DispatchQueue.main.async { [onBufferChanged] in onBufferChanged(milliseconds) }
    }
}
