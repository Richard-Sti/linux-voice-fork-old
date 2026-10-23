import AVFoundation

/// Records the default input device as 16 kHz mono 16-bit PCM (Whisper's native rate).
final class Recorder {
    static let sampleRate = 16000
    /// Audio kept from just before `start()` while the microphone is kept ready.
    private static let prerollBytes = 2 * sampleRate * 4 / 10  // 0.4 s

    private let outFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: Double(Recorder.sampleRate),
        channels: 1, interleaved: true)!
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var configObserver: NSObjectProtocol?

    private let lock = NSLock()
    private var warm = false
    private var capturing = false
    private var pcm = Data()
    private var preroll = Data()

    struct NoInput: LocalizedError {
        var errorDescription: String? { "No microphone input (check Microphone permission)" }
    }

    /// Starts capturing. With the microphone kept ready, the last 0.4 s before
    /// the call is included, so a word spoken with the tap is not clipped.
    func start() throws {
        if engine == nil { try startEngine() }
        lock.withLock {
            pcm = preroll
            preroll.removeAll()
            capturing = true
        }
    }

    /// Stops capturing and returns everything captured since `start()`.
    func stop() -> Data {
        let data = lock.withLock { () -> Data in
            capturing = false
            defer { pcm.removeAll() }
            return pcm
        }
        if !lock.withLock({ warm }) { stopEngine() }
        return data
    }

    /// Keeps the microphone running between recordings (macOS then shows its
    /// microphone indicator), or releases it when not recording.
    func setWarm(_ keepReady: Bool) {
        let isCapturing = lock.withLock { () -> Bool in
            warm = keepReady
            if !keepReady { preroll.removeAll() }
            return capturing
        }
        if keepReady, engine == nil { try? startEngine() }
        if !keepReady, !isCapturing { stopEngine() }
    }

    // MARK: - Engine

    /// A fresh engine per use: one built for a previous microphone can fail or
    /// crash when the input device has changed since.
    private func startEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { throw NoInput() }
        converter = AVAudioConverter(from: inFormat, to: outFormat)
        // Take the first channel of a multichannel input; without an explicit
        // map the conversion to mono can come out silent.
        converter?.channelMap = [0]
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine

        // A new input device (AirPods, a headset) stops the engine; rebuild it
        // and carry on, keeping what was already captured.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.stopEngine()
            if self.lock.withLock({ self.warm || self.capturing }) { try? self.startEngine() }
        }
    }

    private func stopEngine() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let samples = out.int16ChannelData, out.frameLength > 0 else { return }
        let bytes = Data(bytes: samples[0], count: Int(out.frameLength) * 2)
        lock.withLock {
            if capturing {
                pcm.append(bytes)
            } else if warm {
                preroll.append(bytes)
                if preroll.count > Self.prerollBytes { preroll.removeFirst(preroll.count - Self.prerollBytes) }
            }
        }
    }
}

/// Largest absolute sample value. Whisper turns silence into phrases such as
/// "Thank you.", so near-silent recordings are not sent at all.
func peakLevel(_ pcm: Data) -> Int {
    pcm.withUnsafeBytes { raw in
        raw.bindMemory(to: Int16.self).reduce(0) { max($0, abs(Int($1))) }
    }
}

/// Wraps 16 kHz mono 16-bit PCM in a WAV header.
func wavData(_ pcm: Data, sampleRate: Int = Recorder.sampleRate) -> Data {
    var d = Data()
    func ascii(_ s: String) { d.append(s.data(using: .ascii)!) }
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    ascii("RIFF"); u32(UInt32(36 + pcm.count)); ascii("WAVE")
    ascii("fmt "); u32(16); u16(1); u16(1)
    u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
    ascii("data"); u32(UInt32(pcm.count))
    d.append(pcm)
    return d
}
