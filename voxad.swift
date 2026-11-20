import Cocoa
import AVFoundation
import Accelerate

// MARK: - Config

let voxaDir = NSString(string: "~/.voxa").expandingTildeInPath
let tmpDir = voxaDir + "/tmp"

/// A modifier used alone as push-to-talk. `deviceFlag` (NX_DEVICE*KEYMASK) tells left from right;
/// `keyCode` is what its flagsChanged events carry, so other modifiers' events can be ignored.
struct ModifierKey {
    let deviceFlag: UInt64
    let keyCode: UInt16
    let name: String
}

let modifierOnlyMap: [String: ModifierKey] = [
    "right_cmd":    ModifierKey(deviceFlag: 0x0010, keyCode: 54, name: "Right Command"),
    "left_cmd":     ModifierKey(deviceFlag: 0x0008, keyCode: 55, name: "Left Command"),
    "right_shift":  ModifierKey(deviceFlag: 0x0004, keyCode: 60, name: "Right Shift"),
    "left_shift":   ModifierKey(deviceFlag: 0x0002, keyCode: 56, name: "Left Shift"),
    "right_ctrl":   ModifierKey(deviceFlag: 0x2000, keyCode: 62, name: "Right Control"),
    "left_ctrl":    ModifierKey(deviceFlag: 0x0001, keyCode: 59, name: "Left Control"),
    "right_alt":    ModifierKey(deviceFlag: 0x0040, keyCode: 61, name: "Right Option"),
    "right_option": ModifierKey(deviceFlag: 0x0040, keyCode: 61, name: "Right Option"),
    "left_alt":     ModifierKey(deviceFlag: 0x0020, keyCode: 58, name: "Left Option"),
    "left_option":  ModifierKey(deviceFlag: 0x0020, keyCode: 58, name: "Left Option"),
]

let keyCodeMap: [String: UInt16] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
    "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
    "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
    "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32,
    "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
    "space": 49, "return": 36, "tab": 48, "escape": 53, "delete": 51,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
    "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    "f13": 105, "f14": 107, "f15": 113, "f16": 106, "f17": 64,
    "f18": 79, "f19": 80, "f20": 90,
]

enum KeyMode {
    case modifierOnly(ModifierKey)
    case keyCombo(keyCode: UInt16, modifiers: NSEvent.ModifierFlags)
}

struct VoxaConfig {
    var keyMode = KeyMode.modifierOnly(modifierOnlyMap["right_cmd"]!)
    var holdDelay = 300
    var language = "fr"
    var modelPath = voxaDir + "/models/ggml-large-v3-turbo-q5_0.bin"
    /// Vocabulary hint for whisper (names, jargon, preferred spellings).
    var prompt = ""
    /// Takes whose loudest moment stays below this level (dBFS) are not transcribed:
    /// whisper hallucinates on silence ("Sous-titres réalisés par…").
    var silenceDb: Float = -50
    var restoreClipboard = true
    var serverIdleMinutes = 10
}

/// Parses the config file. Never fails: invalid lines keep the default and are reported in `errors`.
func parseConfig(_ contents: String) -> (config: VoxaConfig, errors: [String]) {
    var config = VoxaConfig()
    var errors: [String] = []
    var key = "right_cmd"
    var mods: [String] = []

    for (index, line) in contents.components(separatedBy: .newlines).enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
        let parts = trimmed.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else {
            errors.append("line \(index + 1) ignored: \(trimmed)")
            continue
        }
        let (k, v) = (parts[0].lowercased(), parts[1])
        let invalid = "invalid value '\(v)' for \(k), using default"

        switch k {
        case "key": key = v.lowercased()
        case "modifiers":
            mods = v.lowercased().components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        case "delay":
            if let ms = Int(v), ms >= 0 { config.holdDelay = ms } else { errors.append(invalid) }
        case "language": config.language = v.lowercased()
        case "model": config.modelPath = voxaDir + "/models/" + v
        case "prompt": config.prompt = v
        case "silence_db":
            if let db = Float(v) { config.silenceDb = db } else { errors.append(invalid) }
        case "restore_clipboard":
            switch v.lowercased() {
            case "true", "yes", "1": config.restoreClipboard = true
            case "false", "no", "0": config.restoreClipboard = false
            default: errors.append(invalid)
            }
        case "server_idle_minutes":
            if let m = Int(v), m > 0 { config.serverIdleMinutes = m } else { errors.append(invalid) }
        default:
            errors.append("unknown key '\(k)' on line \(index + 1)")
        }
    }

    if let modifier = modifierOnlyMap[key] {
        config.keyMode = .modifierOnly(modifier)
    } else if let code = keyCodeMap[key] {
        var flags: NSEvent.ModifierFlags = []
        for name in mods {
            switch name {
            case "ctrl", "control": flags.insert(.control)
            case "shift": flags.insert(.shift)
            case "alt", "option", "opt": flags.insert(.option)
            case "cmd", "command": flags.insert(.command)
            default: errors.append("unknown modifier '\(name)', ignored")
            }
        }
        config.keyMode = .keyCombo(keyCode: code, modifiers: flags)
    } else {
        errors.append("unknown key '\(key)', using right_cmd")
    }

    return (config, errors)
}

func loadConfig() -> (config: VoxaConfig, errors: [String]) {
    let path = voxaDir + "/config"
    guard FileManager.default.fileExists(atPath: path) else { return (VoxaConfig(), []) }
    do {
        return parseConfig(try String(contentsOfFile: path, encoding: .utf8))
    } catch {
        return (VoxaConfig(), ["could not read config: \(error.localizedDescription)"])
    }
}

// MARK: - Audio Recorder (AVFoundation)

struct Take {
    let url: URL
    /// Loudest buffer RMS of the take, in dBFS.
    let peakDb: Float
}

class AudioRecorder {
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var converter: AVAudioConverter?
    private var recordingURL: URL?
    private var peakRms: Float = 0
    private let lock = NSLock()

    func start() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        // Unique file per take: a transcription still running on the previous take must not see its file replaced or deleted.
        let url = URL(fileURLWithPath: tmpDir).appendingPathComponent("\(UUID().uuidString).wav")

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0 && inputFormat.channelCount > 0 else {
            log("error: no audio input available")
            return false
        }

        // Target: 16kHz mono 16-bit (what whisper expects)
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true) else {
            log("error: could not create target format")
            return false
        }

        guard let conv = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            log("error: could not create audio converter from \(inputFormat) to \(targetFormat)")
            return false
        }
        converter = conv
        peakRms = 0

        let wavSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        do {
            audioFile = try AVAudioFile(forWriting: url, settings: wavSettings, commonFormat: .pcmFormatInt16, interleaved: true)
        } catch {
            log("error: could not create audio file: \(error.localizedDescription)")
            return false
        }

        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard let file = self.audioFile, let conv = self.converter else { return }

            if let samples = buffer.floatChannelData?[0] {
                var rms: Float = 0
                vDSP_rmsqv(samples, 1, &rms, vDSP_Length(buffer.frameLength))
                self.peakRms = max(self.peakRms, rms)
            }

            let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount) else { return }

            // Feed the buffer exactly once: the converter may call this block several times per convert().
            var fed = false
            var error: NSError?
            conv.convert(to: outputBuffer, error: &error) { _, outStatus in
                if fed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                fed = true
                outStatus.pointee = .haveData
                return buffer
            }

            if error == nil && outputBuffer.frameLength > 0 {
                try? file.write(from: outputBuffer)
            }
        }

        do {
            try engine.start()
            audioEngine = engine
            recordingURL = url
            log("audio engine started (input: \(inputFormat.sampleRate)Hz → 16000Hz)")
            return true
        } catch {
            log("error: could not start audio engine: \(error.localizedDescription)")
            inputNode.removeTap(onBus: 0)
            audioFile = nil
            converter = nil
            try? FileManager.default.removeItem(at: url)
            return false
        }
    }

    /// Stops the take and returns it. The caller owns the file and must delete it.
    func stop() -> Take? {
        lock.lock()
        let engine = audioEngine
        let url = recordingURL
        let rms = peakRms
        audioEngine = nil
        audioFile = nil
        converter = nil
        recordingURL = nil
        lock.unlock()

        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)

        guard let url = url else { return nil }
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64,
              size > 1000 else {
            log("warning: recording file missing or too small")
            try? FileManager.default.removeItem(at: url)
            return nil
        }

        let peakDb = 20 * log10(max(rms, 1e-9))
        log("recording saved (\(size / 1024) KB, peak \(Int(peakDb)) dBFS)")
        return Take(url: url, peakDb: peakDb)
    }
}

// MARK: - Transcription (whisper-server)

/// Keeps a whisper-server process alive while dictations happen, so the model is loaded once
/// instead of on every take (about twice as fast). The server is started when a
/// take starts — model loading overlaps speech — and stopped after `idleMinutes` without use,
/// since it holds the model in memory (~700 MB).
final class WhisperServer {
    static let pidFile = tmpDir + "/whisper-server.pid"
    static let logPath = tmpDir + "/whisper.log"

    private let modelPath: String
    private let language: String
    private let prompt: String
    private let idleMinutes: Int
    private let queue = DispatchQueue(label: "voxa.server")  // guards process, port, idleStop
    private var process: Process?
    private var port = 0
    private var idleStop: DispatchWorkItem?

    init(config: VoxaConfig) {
        modelPath = config.modelPath
        language = config.language
        prompt = config.prompt
        idleMinutes = config.serverIdleMinutes
    }

    /// Starts the server in the background if it isn't running.
    func warmUp() {
        queue.async { self.launchIfNeeded() }
    }

    func stop() {
        queue.sync {
            idleStop?.cancel()
            process?.terminate()
            process = nil
            try? FileManager.default.removeItem(atPath: WhisperServer.pidFile)
        }
    }

    /// Kills a server left behind by a crashed daemon (it would otherwise hold its memory forever).
    static func killStale() {
        guard let pidString = try? String(contentsOfFile: pidFile, encoding: .utf8),
              let pid = Int32(pidString.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        var name = [CChar](repeating: 0, count: 256)
        if proc_name(pid, &name, UInt32(name.count)) > 0, String(cString: name) == "whisper-server" {
            kill(pid, SIGTERM)
            log("killed stale whisper-server (pid \(pid))")
        }
        try? FileManager.default.removeItem(atPath: pidFile)
    }

    /// Returns whisper's raw text, or nil on failure (details in whisper.log / voxad.log). Blocking.
    func transcribe(_ audioURL: URL) -> String? {
        let port: Int? = queue.sync {
            idleStop?.cancel()  // never stop the server while a request is in flight
            launchIfNeeded()
            return process?.isRunning == true ? self.port : nil
        }
        defer { scheduleIdleStop() }
        guard let port = port, let wav = try? Data(contentsOf: audioURL) else { return nil }

        // The server only listens once the model is loaded: retry while it's still starting.
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            switch post(wav, port: port) {
            case .text(let text):
                return text
            case .failed(let reason):
                log("error: whisper-server request failed: \(reason)")
                return nil
            case .notReady:
                guard queue.sync(execute: { process?.isRunning == true }) else {
                    log("error: whisper-server exited during startup")
                    return nil
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        log("error: whisper-server not ready after 30s")
        return nil
    }

    // Must run on `queue`.
    private func launchIfNeeded() {
        if process?.isRunning == true { return }

        let candidates = ["/opt/homebrew/bin/whisper-server", "/usr/local/bin/whisper-server"]
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            log("error: whisper-server not found (brew install whisper-cpp)")
            return
        }

        // ponytail: random port, a collision makes the server exit and the take fail; next take retries another port.
        let port = Int.random(in: 49152...65000)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["-m", modelPath, "-l", language, "--host", "127.0.0.1", "--port", "\(port)",
                       "--suppress-nst"] + (prompt.isEmpty ? [] : ["--prompt", prompt])
        FileManager.default.createFile(atPath: WhisperServer.logPath, contents: nil)
        p.standardError = FileHandle(forWritingAtPath: WhisperServer.logPath) ?? FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice

        do {
            try p.run()
        } catch {
            log("error: could not start whisper-server: \(error.localizedDescription)")
            return
        }
        try? "\(p.processIdentifier)".write(toFile: WhisperServer.pidFile, atomically: true, encoding: .utf8)
        process = p
        self.port = port
        log("whisper-server started (pid \(p.processIdentifier), port \(port))")
        scheduleIdleStop()
    }

    private func scheduleIdleStop() {
        queue.async {
            self.idleStop?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self = self, let p = self.process else { return }
                log("whisper-server idle for \(self.idleMinutes) min, stopping")
                p.terminate()
                self.process = nil
                try? FileManager.default.removeItem(atPath: WhisperServer.pidFile)
            }
            self.idleStop = work
            self.queue.asyncAfter(deadline: .now() + .seconds(self.idleMinutes * 60), execute: work)
        }
    }

    private enum PostResult {
        case text(String)
        case notReady
        case failed(String)
    }

    private func post(_ wav: Data, port: Int) -> PostResult {
        let boundary = "voxa-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"take.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"response_format\"\r\n\r\njson\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/inference")!, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var result = PostResult.failed("no response")
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.uploadTask(with: request, from: body) { data, _, error in
            defer { done.signal() }
            if let error = error as? URLError, error.code == .cannotConnectToHost || error.code == .networkConnectionLost {
                result = .notReady
            } else if let error = error {
                result = .failed(error.localizedDescription)
            } else if let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let text = json["text"] as? String {
                    result = .text(text)
                } else {
                    result = .failed(json["error"] as? String ?? "response without text")
                }
            } else {
                result = .failed("invalid response")
            }
        }.resume()
        done.wait()
        return result
    }
}

/// Joins whisper's lines and drops known hallucinations. Returns nil when nothing usable is left.
func cleanTranscript(_ raw: String) -> String? {
    // whisper wraps lines anywhere, even mid-word ("trimest\nriel"); a line starting a new word
    // already carries its leading space, so newlines are removed, not turned into spaces.
    let text = raw.replacingOccurrences(of: "\n", with: "")
        .components(separatedBy: " ").filter { !$0.isEmpty }.joined(separator: " ")
    let lower = text.lowercased()

    // Whisper artifacts take up the whole output, so match on the start of the text only:
    // a dictation that merely mentions "sous-titrage" or a URL must not be discarded.
    let hallucinationPrefixes = [
        "sous-titres réalisés par", "sous-titres par", "sous-titrage",
        "merci d'avoir regardé", "thanks for watching", "thank you for watching",
        "please subscribe", "like and subscribe",
    ]
    if lower.contains("amara.org") || hallucinationPrefixes.contains(where: { lower.hasPrefix($0) }) {
        return nil
    }

    // "[Musique]", "(applaudissements)"…
    if (lower.hasPrefix("[") && lower.hasSuffix("]")) || (lower.hasPrefix("(") && lower.hasSuffix(")")) {
        return nil
    }

    // Only punctuation / music notes.
    if lower.unicodeScalars.allSatisfy({ !CharacterSet.alphanumerics.contains($0) }) {
        return nil
    }

    return text
}

// MARK: - Recording Overlay

class RecordingOverlay {
    private var window: NSWindow?
    private var timer: Timer?
    private var dotView: NSView?
    private var timerLabel: NSTextField?
    private var startTime: Date?

    func show() {
        guard let screen = NSScreen.main else { return }

        let width: CGFloat = 90
        let height: CGFloat = 32
        let frame = NSRect(
            x: screen.frame.midX - width / 2,
            y: screen.frame.maxY - height - 60,
            width: width,
            height: height
        )

        let win = NSWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        win.level = .statusBar
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = true
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .stationary]

        let pill = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        pill.wantsLayer = true
        pill.layer?.cornerRadius = height / 2
        pill.layer?.backgroundColor = NSColor.black.cgColor

        let dotSize: CGFloat = 10
        let dot = NSView(frame: NSRect(x: 12, y: (height - dotSize) / 2, width: dotSize, height: dotSize))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = dotSize / 2
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        pill.addSubview(dot)

        let label = NSTextField(labelWithString: "00:00")
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 26, y: (height - 16) / 2, width: 52, height: 16)
        pill.addSubview(label)

        win.contentView = pill
        self.dotView = dot
        self.timerLabel = label
        self.startTime = Date()

        win.orderFrontRegardless()
        self.window = win

        var bright = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self, let start = self.startTime else { return }
            let elapsed = Int(Date().timeIntervalSince(start))
            self.timerLabel?.stringValue = String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
            self.dotView?.layer?.backgroundColor = bright
                ? NSColor.systemRed.withAlphaComponent(0.3).cgColor
                : NSColor.systemRed.cgColor
            bright = !bright
        }
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        window?.orderOut(nil)
        window = nil
        dotView = nil
        timerLabel = nil
        startTime = nil
    }
}

// MARK: - Sounds & Notifications

func playSound(_ name: String) {
    if let sound = NSSound(named: name) {
        sound.play()
    }
}

/// Must be called on the main thread (NSAppleScript is not thread-safe).
func notifyError(_ message: String) {
    let escaped = message.replacingOccurrences(of: "\\", with: "\\\\")
                         .replacingOccurrences(of: "\"", with: "\\\"")
    let script = "display notification \"\(escaped)\" with title \"Voxa Error\""
    if let appleScript = NSAppleScript(source: script) {
        appleScript.executeAndReturnError(nil)
    }
}

// MARK: - Clipboard & Paste

/// keyDowns Voxa posted itself (the paste), excluded from shortcut detection.
var syntheticKeyDowns: UInt32 = 0

/// System-wide keyDown count minus our own. The window server counts every key, including those
/// the system consumes (Cmd+Tab, Cmd+Space) which never reach NSEvent monitors.
func userKeyDownCount() -> UInt32 {
    CGEventSource.counterForEventType(.combinedSessionState, eventType: .keyDown) &- syntheticKeyDowns
}

/// Pastes `text` into the frontmost app through the clipboard. With `restore`, the previous
/// clipboard comes back once the paste is done, unless something else changed it meanwhile.
func paste(_ text: String, restore: Bool) {
    let pasteboard = NSPasteboard.general
    let saved: [NSPasteboardItem] = (pasteboard.pasteboardItems ?? []).map { item in
        let copy = NSPasteboardItem()
        for type in item.types {
            if let data = item.data(forType: type) { copy.setData(data, forType: type) }
        }
        return copy
    }

    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    let ourChange = pasteboard.changeCount
    log("copied to clipboard (\(text.count) chars)")

    guard AXIsProcessTrusted() else {
        // No auto-paste: leave the text on the clipboard so the user can paste it by hand.
        log("warning: Accessibility not granted, skipping paste. Text is on clipboard.")
        return
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150)) {
        let src = CGEventSource(stateID: .hidSystemState)
        guard let vDown = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false) else {
            log("warning: could not create paste event. Text is on clipboard.")
            return
        }
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        syntheticKeyDowns &+= 1
        vDown.post(tap: .cghidEventTap)
        vUp.post(tap: .cghidEventTap)
        log("paste sent")

        guard restore else { return }
        // ponytail: fixed 1s for the target app to read the clipboard; slow apps may need more.
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(1)) {
            guard pasteboard.changeCount == ourChange else { return }
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
    }
}

// MARK: - App Delegate

class VoxaDelegate: NSObject, NSApplicationDelegate {
    let config: VoxaConfig
    let configErrors: [String]
    let overlay = RecordingOverlay()
    let recorder = AudioRecorder()
    let server: WhisperServer
    enum TakeState: Equatable { case idle, starting(discard: Bool), recording }
    var state = TakeState.idle { didSet { refreshStatusItem() } }
    var paused = false { didSet { refreshStatusItem() } }
    var pendingTranscriptions = 0 { didSet { refreshStatusItem() } }
    var statusItem: NSStatusItem?
    var accessibilityTimer: Timer?
    // Serializes recorder start/stop so a stop can never land on the next take's engine.
    let audioQueue = DispatchQueue(label: "voxa.audio")
    // One transcription at a time: pastes stay in dictation order.
    let transcribeQueue = DispatchQueue(label: "voxa.transcribe")
    var holdTimer: DispatchWorkItem?
    var recordingTimeout: DispatchWorkItem?
    let maxRecordingDuration: Int = 60
    var globalMonitor: Any?
    var localMonitor: Any?

    init(config: VoxaConfig, configErrors: [String]) {
        self.config = config
        self.configErrors = configErrors
        self.server = WhisperServer(config: config)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        let fm = FileManager.default
        // Purge takes left over by a crash (files are uniquely named, nothing overwrites them).
        for name in (try? fm.contentsOfDirectory(atPath: tmpDir)) ?? [] where name.hasSuffix(".wav") {
            try? fm.removeItem(atPath: tmpDir + "/" + name)
        }
        WhisperServer.killStale()

        // Shows the system prompt (adds Voxa to the Accessibility list) when the grant is missing,
        // which happens after every rebuild because the ad-hoc signature changes.
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        if !AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary) {
            log("warning: Accessibility not granted, system prompt shown.")
        }

        if !configErrors.isEmpty {
            notifyError("Config: " + configErrors.joined(separator: "; "))
        }
        if !fm.fileExists(atPath: config.modelPath) {
            log("error: model not found at \(config.modelPath)")
            notifyError("Whisper model not found: \(config.modelPath). Run setup.sh.")
        }

        setupEventMonitor()
        setupSignalHandlers()
    }

    // MARK: - Signal handling

    var signalSources: [DispatchSourceSignal] = []

    func setupSignalHandlers() {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                self?.cleanup()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func cleanup() {
        server.stop()
        guard state != .idle else { return }
        log("cleaning up...")
        // sync: waits for an in-flight start so its engine is the one we stop.
        if let take = audioQueue.sync(execute: { recorder.stop() }) {
            try? FileManager.default.removeItem(at: take.url)
        }
        overlay.hide()
    }

    // MARK: - Event monitoring (NSEvent — cannot block keyboard)

    func setupEventMonitor() {
        var eventTypes: NSEvent.EventTypeMask = [.flagsChanged]
        if case .keyCombo = config.keyMode {
            eventTypes.formUnion([.keyDown, .keyUp])
        }

        // Global monitor: events in OTHER apps
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: eventTypes) { [weak self] event in
            self?.handleNSEvent(event)
        }

        // Local monitor: ONLY catches key releases to stop recording during popups/dialogs.
        // Does NOT start recordings — that's the global monitor's job.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            guard let self = self, self.state != .idle else { return event }
            if case .modifierOnly(let key) = self.config.keyMode,
               event.keyCode == key.keyCode,
               UInt64(event.modifierFlags.rawValue) & key.deviceFlag == 0 {
                self.handleStop()
            }
            return event
        }

        if globalMonitor == nil {
            log("error: could not create event monitor. Grant Accessibility permission in System Settings.")
            notifyError("Grant Accessibility permission to Voxa in System Settings.")
        }
    }

    func handleNSEvent(_ event: NSEvent) {
        switch config.keyMode {
        case .modifierOnly(let key):
            // Only our key's own events: pressing Shift while holding Right Cmd must not stop the take.
            guard event.type == .flagsChanged, event.keyCode == key.keyCode else { return }

            let isPressed = UInt64(event.modifierFlags.rawValue) & key.deviceFlag != 0

            if isPressed && state == .idle {
                if holdTimer == nil {
                    keyDownsAtPress = userKeyDownCount()
                    let timer = DispatchWorkItem { [weak self] in
                        guard let self = self else { return }
                        self.holdTimer = nil
                        if self.shortcutUsed() {
                            log("shortcut detected, not recording")
                        } else {
                            self.handleStart()
                        }
                    }
                    holdTimer = timer
                    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(config.holdDelay), execute: timer)
                }
            } else {
                // Release, or pressed again while recording (recovery from a missed release).
                // Another key pressed meanwhile means it was a shortcut, not a dictation.
                handleStop(discard: shortcutUsed())
            }

        case .keyCombo(let expectedKeyCode, let requiredMods):
            guard event.keyCode == expectedKeyCode else { return }

            let relevantFlags = event.modifierFlags.intersection([.control, .shift, .option, .command])
            guard relevantFlags.contains(requiredMods) else { return }

            if event.type == .keyDown {
                handleStart()
            } else if event.type == .keyUp {
                handleStop()
            }
        }
    }

    /// keyDown count when the modifier went down, see `shortcutUsed()`.
    var keyDownsAtPress: UInt32 = 0

    /// True if any other key was pressed since the modifier went down (Cmd+Tab, Cmd+C…).
    func shortcutUsed() -> Bool {
        userKeyDownCount() != keyDownsAtPress
    }

    // MARK: - Recording lifecycle

    func handleStart() {
        guard state == .idle, !paused else { return }
        state = .starting(discard: false)
        playSound("Tink")
        log("recording starting...")
        server.warmUp()

        audioQueue.async {
            let started = self.recorder.start()

            DispatchQueue.main.async {
                // Key released (or shortcut typed) while the engine was starting.
                let discard = self.state == .starting(discard: true)
                guard started else {
                    self.state = .idle
                    log("recording failed to start")
                    notifyError("Microphone recording failed. Check permissions.")
                    return
                }
                self.state = .recording
                if discard {
                    self.handleStop(discard: true)
                    return
                }
                self.overlay.show()
                log("recording started")

                let timeout = DispatchWorkItem { [weak self] in
                    guard let self = self, self.state == .recording else { return }
                    log("recording timeout after \(self.maxRecordingDuration)s")
                    self.handleStop()
                }
                self.recordingTimeout = timeout
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + .seconds(self.maxRecordingDuration),
                    execute: timeout
                )
            }
        }
    }

    func handleStop(discard: Bool = false) {
        holdTimer?.cancel()
        holdTimer = nil
        switch state {
        case .idle:
            return
        case .starting:
            // handleStart's completion will stop and discard the take.
            state = .starting(discard: true)
            return
        case .recording:
            break
        }
        state = .idle
        recordingTimeout?.cancel()
        recordingTimeout = nil
        overlay.hide()
        log(discard ? "recording discarded" : "recording stopped")

        audioQueue.async {
            guard let take = self.recorder.stop() else {
                log("no audio recorded")
                return
            }
            if discard || take.peakDb < self.config.silenceDb {
                if !discard { log("silent take (below \(Int(self.config.silenceDb)) dBFS), not transcribed") }
                try? FileManager.default.removeItem(at: take.url)
                return
            }
            DispatchQueue.main.async { self.pendingTranscriptions += 1 }
            self.transcribeQueue.async { self.transcribeAndPaste(take.url) }
        }
    }

    func transcribeAndPaste(_ audioURL: URL) {
        defer {
            try? FileManager.default.removeItem(at: audioURL)
            DispatchQueue.main.async { self.pendingTranscriptions -= 1 }
        }
        log("transcribing...")
        playSound("Pop")

        guard let raw = server.transcribe(audioURL) else {
            log("transcription failed")
            DispatchQueue.main.async {
                notifyError("Transcription failed. Check ~/.voxa/tmp/whisper.log")
            }
            return
        }
        guard let text = cleanTranscript(raw) else {
            log("empty or hallucinated transcription discarded")
            return
        }
        // Not logging the text itself: the log would keep every dictation in clear.
        DispatchQueue.main.async { paste(text, restore: self.config.restoreClipboard) }
    }
}

// MARK: - Menu bar

extension VoxaDelegate: NSMenuDelegate {
    func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self  // rebuilt in menuNeedsUpdate, so it always reflects the current state
        item.menu = menu
        statusItem = item
        refreshStatusItem()
    }

    func refreshStatusItem() {
        guard let button = statusItem?.button else { return }
        let trusted = AXIsProcessTrusted()

        let symbol: String
        var tint: NSColor? = nil
        if !trusted {
            symbol = "exclamationmark.triangle"
        } else if state != .idle {
            symbol = "mic.fill"
            tint = .systemRed
        } else if pendingTranscriptions > 0 {
            symbol = "waveform"
        } else if paused {
            symbol = "mic.slash"
        } else {
            symbol = "mic"
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Voxa")
        button.image?.isTemplate = true
        button.contentTintColor = tint

        // The grant can arrive any time from System Settings: poll only while it's missing.
        if trusted {
            accessibilityTimer?.invalidate()
            accessibilityTimer = nil
        } else if accessibilityTimer == nil {
            accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                self?.refreshStatusItem()
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let keyName: String
        if case .modifierOnly(let key) = config.keyMode { keyName = key.name } else { keyName = "your shortcut" }
        let status: String
        if state != .idle {
            status = "Recording…"
        } else if pendingTranscriptions > 0 {
            status = "Transcribing…"
        } else if paused {
            status = "Paused"
        } else {
            status = "Ready — hold \(keyName) to dictate"
        }
        menu.addItem(NSMenuItem(title: status, action: nil, keyEquivalent: ""))

        if !AXIsProcessTrusted() {
            menu.addItem(menuItem("⚠︎ Grant Accessibility (needed to paste)…", #selector(openAccessibilitySettings)))
        }

        menu.addItem(.separator())
        menu.addItem(menuItem(paused ? "Resume Dictation" : "Pause Dictation", #selector(togglePause)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Edit Config…", #selector(openConfig)))
        menu.addItem(menuItem("Show Log", #selector(openLog)))
        menu.addItem(menuItem("Restart Voxa (reload config)", #selector(restart)))
        menu.addItem(menuItem("Quit Voxa (until next login)", #selector(quit)))
    }

    private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc func togglePause() {
        paused.toggle()
        log(paused ? "dictation paused" : "dictation resumed")
    }

    @objc func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc func openConfig() {
        let path = voxaDir + "/config"
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: Data("# Voxa configuration, see README\n".utf8))
        }
        // The config has no extension, so no app is registered for it: open it in TextEdit explicitly.
        NSWorkspace.shared.open([URL(fileURLWithPath: path)],
                                withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
    }

    /// Exits and lets launchd's KeepAlive start a fresh instance, which rereads the config.
    // ponytail: relies on the LaunchAgent; when launched by hand this only quits.
    @objc func restart() {
        log("restarting")
        cleanup()
        exit(0)
    }

    /// Unloads the LaunchAgent first, otherwise KeepAlive would relaunch Voxa right away.
    /// It loads again at next login (RunAtLoad).
    @objc func quit() {
        log("quitting until next login")
        let launchctl = Process()
        launchctl.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        launchctl.arguments = ["bootout", "gui/\(getuid())/com.voxa.daemon"]
        try? launchctl.run()
        launchctl.waitUntilExit()
        cleanup()
        exit(0)
    }
}

// MARK: - Logging (thread-safe)

private let logQueue = DispatchQueue(label: "voxa.log")
let logPath = tmpDir + "/voxad.log"

func log(_ message: String) {
    let msg = "voxa: \(message)\n"
    fputs(msg, stderr)

    logQueue.async {
        guard let data = msg.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: logPath, contents: data)
        }
    }
}

/// Keeps the log bounded: past 1 MB it moves to voxad.log.1 (replacing the previous one).
func rotateLog() {
    let fm = FileManager.default
    guard let size = (try? fm.attributesOfItem(atPath: logPath))?[.size] as? UInt64, size > 1_000_000 else { return }
    try? fm.removeItem(atPath: logPath + ".1")
    try? fm.moveItem(atPath: logPath, toPath: logPath + ".1")
}

// MARK: - Self-test (`voxad --self-test`, run by build.sh)

func runSelfTest() -> Never {
    var failures = 0
    func check(_ ok: Bool, _ what: String) {
        if !ok { failures += 1; print("FAIL: \(what)") }
    }

    let (defaults, noErrors) = parseConfig("# comment only\n\n")
    check(noErrors.isEmpty, "empty config has no errors: \(noErrors)")
    if case .modifierOnly(let key) = defaults.keyMode { check(key.keyCode == 54, "default key is right_cmd") } else { check(false, "default key mode") }
    check(defaults.holdDelay == 300 && defaults.language == "fr" && defaults.restoreClipboard, "defaults")

    let (combo, comboErrors) = parseConfig("key = space\nmodifiers = ctrl, Shift\ndelay = 150\nlanguage = EN\nrestore_clipboard = false\nsilence_db = -40\nserver_idle_minutes = 3\nprompt = Jean-Baptiste, KPI")
    check(comboErrors.isEmpty, "valid config has no errors: \(comboErrors)")
    if case .keyCombo(let code, let mods) = combo.keyMode { check(code == 49 && mods == [.control, .shift], "space + ctrl,shift") } else { check(false, "combo key mode") }
    check(combo.holdDelay == 150 && combo.language == "en" && !combo.restoreClipboard
          && combo.silenceDb == -40 && combo.serverIdleMinutes == 3 && combo.prompt == "Jean-Baptiste, KPI", "combo values")

    let (bad, badErrors) = parseConfig("key = nope\ndelay = abc\nfoo = 1\ngarbage")
    check(badErrors.count == 4, "4 errors reported, got \(badErrors)")
    if case .modifierOnly = bad.keyMode {} else { check(false, "unknown key falls back to right_cmd") }
    check(bad.holdDelay == 300, "invalid delay keeps default")

    check(cleanTranscript(" Bonjour, ceci est un test pour la\n transcription.\n") == "Bonjour, ceci est un test pour la transcription.", "lines joined")
    check(cleanTranscript(" le rapport trimest\nriel\n sur les KPI\n, et je\nudi.\n") == "le rapport trimestriel sur les KPI, et jeudi.", "mid-word wraps rejoined")
    check(cleanTranscript("Sous-titres réalisés par la communauté d'Amara.org") == nil, "amara filtered")
    check(cleanTranscript("Merci d'avoir regardé !") == nil, "merci d'avoir regardé filtered")
    check(cleanTranscript("[Musique]") == nil, "[Musique] filtered")
    check(cleanTranscript(" ... ♪ ") == nil, "punctuation only filtered")
    check(cleanTranscript("") == nil, "empty filtered")
    check(cleanTranscript("Envoie le lien http://exemple.fr à Paul") != nil, "URL kept")
    check(cleanTranscript("Le copyright de l'image est à vérifier") != nil, "copyright kept")
    check(cleanTranscript("Il faut revoir le sous-titrage") != nil, "sous-titrage mid-sentence kept")

    print(failures == 0 ? "self-test: OK" : "self-test: \(failures) failure(s)")
    exit(failures == 0 ? 0 : 1)
}

// MARK: - Main

let arguments = CommandLine.arguments
if arguments.contains("--self-test") { runSelfTest() }

try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
rotateLog()
let (config, configErrors) = loadConfig()
configErrors.forEach { log("config: \($0)") }

// `voxad --transcribe file.wav`: runs one file through the same pipeline (debugging, no permissions needed).
if let index = arguments.firstIndex(of: "--transcribe"), index + 1 < arguments.count {
    let server = WhisperServer(config: config)
    let raw = server.transcribe(URL(fileURLWithPath: arguments[index + 1]))
    server.stop()
    guard let raw = raw else { print("transcription failed, see \(WhisperServer.logPath)"); exit(1) }
    print(cleanTranscript(raw) ?? "(filtered: \(raw.trimmingCharacters(in: .whitespacesAndNewlines)))")
    exit(0)
}

switch config.keyMode {
case .modifierOnly(let key):
    log("push-to-talk with \(key.name)")
case .keyCombo(let keyCode, let modifiers):
    log("push-to-talk with key \(keyCode) + modifiers \(modifiers.rawValue)")
}
log("hold delay \(config.holdDelay)ms, language \(config.language)")

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = VoxaDelegate(config: config, configErrors: configErrors)
app.delegate = delegate
app.run()
