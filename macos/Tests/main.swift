// Self-check for the parts of VoiceBar that run without a GUI.
// Run: ./check.sh   (pass --network to also send 1 s of silence to the transcription API)
import Foundation

// Config parsing on a sample with every construct the reader supports.
let sample = """
    # comment
    [transcription]
    backend = "groq"   # trailing comment
    api_key = "k#ey"
    prompt = 'raw \\n string'

    [hotkey]
    key = "j"
    modifiers = ["cmd", "shift"]
    """
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("voicebar-check.toml")
try sample.write(to: tmp, atomically: true, encoding: .utf8)
let cfg = Config.load(from: tmp)
assert(cfg.string("transcription", "backend") == "groq")
assert(cfg.string("transcription", "api_key") == "k#ey", "# inside a string is not a comment")
assert(cfg.string("transcription", "prompt") == "raw \\n string", "literal strings keep backslashes")
assert(cfg.strings("hotkey", "modifiers") == ["cmd", "shift"])

// Hotkeys built from the config map to the right key code and label.
let hk = Hotkey(key: "j", modifiers: ["cmd", "shift"])!
assert(hk.keyCode == 38 && hk.label == "⇧⌘J")
assert(Hotkey(key: "space", modifiers: ["ctrl", "cmd", "shift"])!.label == "⌃⇧⌘Space")
assert(Hotkey(key: "nonsense", modifiers: ["cmd"]) == nil)

// WAV header for 1 s of 16 kHz mono 16-bit audio.
let pcm = Data(count: 2 * Recorder.sampleRate)
let wav = wavData(pcm)
assert(wav.count == 44 + pcm.count)
assert(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
assert(wav[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } == 16000)
assert(peakLevel(pcm) == 0)
var loud = pcm
loud.replaceSubrange(100..<102, with: withUnsafeBytes(of: Int16(-1200).littleEndian) { Data($0) })
assert(peakLevel(loud) == 1200)
print("offline checks passed")

if CommandLine.arguments.contains("--network") {
    let real = Config.load()
    guard let key = real.string("transcription", "api_key") else { fatalError("no api_key in config.toml") }
    let groq = real.string("transcription", "backend") != "openai"
    let t = Transcriber(
        baseURL: URL(string: groq ? "https://api.groq.com/openai/v1" : "https://api.openai.com/v1")!,
        apiKey: key, model: groq ? "whisper-large-v3-turbo" : "whisper-1", language: "en", prompt: "")
    let done = DispatchSemaphore(value: 0)
    Task {
        do {
            let text = try await t.transcribe(wav: wav)
            print("network check passed (silence transcribed as \"\(text)\")")
        } catch {
            print("network check FAILED: \(error.localizedDescription)")
            exit(1)
        }
        done.signal()
    }
    done.wait()
}
