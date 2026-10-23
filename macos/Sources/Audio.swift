import AVFoundation

/// Records the default input device as 16 kHz mono 16-bit PCM (Whisper's native rate).
final class Recorder {
    static let sampleRate = 16000

    private let engine = AVAudioEngine()
    private let outFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: Double(Recorder.sampleRate),
        channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private var pcm = Data()
    private let lock = NSLock()

    struct NoInput: LocalizedError {
        var errorDescription: String? { "No microphone input (check Microphone permission)" }
    }

    func start() throws {
        lock.withLock { pcm.removeAll() }
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { throw NoInput() }
        converter = AVAudioConverter(from: inFormat, to: outFormat)
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
    }

    /// Stops recording and returns everything captured since `start()`.
    func stop() -> Data {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        return lock.withLock { pcm }
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
        lock.withLock { pcm.append(bytes) }
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
