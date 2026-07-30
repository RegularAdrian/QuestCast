import Foundation
import Network

final class ReceiverController: ObservableObject {
    @Published private(set) var status = "Waiting for Quest on the local network…"
    @Published private(set) var isStreaming = false
    @Published private(set) var framesDecoded = 0
    @Published private(set) var framesDropped = 0
    @Published private(set) var isAudioActive = false
    @Published private(set) var audioChunksDropped = 0
    @Published private(set) var audioBufferMilliseconds = 0

    let frameStore = FrameStore()

    private let networkQueue = DispatchQueue(label: "com.apctv.questcast.receiver.network", qos: .userInteractive)
    private let decoder: VideoDecoder
    private lazy var audioPlayer = QuestAudioPlayer { [weak self] milliseconds in
        self?.audioBufferMilliseconds = milliseconds
    }
    private var listener: NWListener?
    private var connections: [NWEndpoint: NWConnection] = [:]
    private var streamWatchdog: DispatchSourceTimer?
    private var lastVideoFrameTime = DispatchTime.now()
    private var lastAudioChunkTime = DispatchTime.now()
    private var streamingOnNetworkQueue = false
    private lazy var assembler = PacketAssembler(
        onAccessUnit: { [weak self] unit in self?.handle(unit) },
        onDrop: { [weak self] count in self?.publishDrops(count) }
    )
    private lazy var audioAssembler = AudioPacketAssembler(
        onChunk: { [weak self] chunk in self?.handleAudio(chunk) },
        onDrop: { [weak self] count in self?.publishAudioDrops(count) }
    )

    init() {
        decoder = VideoDecoder(frameStore: frameStore)
    }

    func start() {
        guard listener == nil else { return }
        do {
            let listener = try NWListener(using: .udp, on: 49152)
            listener.service = NWListener.Service(name: "QuestCast TV", type: "_questcast._udp")
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.publishStatus("Ready — select QuestCast TV in the headset")
                case .failed(let error):
                    self?.publishStatus("Receiver failed: \(error.localizedDescription)")
                case .waiting(let error):
                    self?.publishStatus("Waiting for network: \(error.localizedDescription)")
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: networkQueue)
            self.listener = listener
            startStreamWatchdog()
        } catch {
            publishStatus("Could not open UDP receiver: \(error.localizedDescription)")
        }
    }

    private func accept(_ connection: NWConnection) {
        connections[connection.endpoint] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            if case .failed = state, let endpoint = connection?.endpoint {
                self?.connections.removeValue(forKey: endpoint)
            }
        }
        connection.start(queue: networkQueue)
        receiveNext(on: connection)
    }

    private func receiveNext(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] content, _, _, error in
            guard let self, let connection else { return }
            if let content {
                if content.prefix(4) == Data([0x51, 0x43, 0x54, 0x41]) {
                    self.audioAssembler.ingest(content)
                } else {
                    self.assembler.ingest(content)
                }
            }
            if error == nil {
                self.receiveNext(on: connection)
            } else {
                self.connections.removeValue(forKey: connection.endpoint)
            }
        }
    }

    private func handleAudio(_ chunk: AudioChunk) {
        lastAudioChunkTime = .now()
        audioPlayer.enqueue(chunk)
        DispatchQueue.main.async { [weak self] in self?.isAudioActive = true }
    }

    private func handle(_ unit: AccessUnit) {
        if unit.isConfiguration {
            decoder.configure(with: unit.data)
            publishStatus("Quest connected — waiting for video")
            return
        }
        lastVideoFrameTime = .now()
        streamingOnNetworkQueue = true
        decoder.decode(unit.data, isKeyFrame: unit.isKeyFrame, presentationTimeUs: unit.presentationTimeUs)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isStreaming = true
            self.status = "Live • 1080p60 target • zero-buffer mode"
            self.framesDecoded += 1
        }
    }

    private func startStreamWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: networkQueue)
        timer.schedule(deadline: .now() + 1, repeating: .milliseconds(500), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self, self.streamingOnNetworkQueue else { return }
            let audioElapsed = DispatchTime.now().uptimeNanoseconds - self.lastAudioChunkTime.uptimeNanoseconds
            if audioElapsed > 1_000_000_000 {
                self.audioPlayer.stop()
                DispatchQueue.main.async { [weak self] in
                    self?.isAudioActive = false
                    self?.audioBufferMilliseconds = 0
                }
            }
            let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - self.lastVideoFrameTime.uptimeNanoseconds
            guard elapsedNanoseconds > 2_500_000_000 else { return }

            self.streamingOnNetworkQueue = false
            self.audioPlayer.stop()
            DispatchQueue.main.async { [weak self] in
                self?.isStreaming = false
                self?.isAudioActive = false
                self?.audioBufferMilliseconds = 0
                self?.status = "Ready — select QuestCast TV in the headset"
            }
        }
        timer.resume()
        streamWatchdog = timer
    }

    private func publishStatus(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.status = message }
    }

    private func publishDrops(_ count: Int) {
        DispatchQueue.main.async { [weak self] in self?.framesDropped += count }
    }

    private func publishAudioDrops(_ count: Int) {
        DispatchQueue.main.async { [weak self] in self?.audioChunksDropped += count }
    }
}
