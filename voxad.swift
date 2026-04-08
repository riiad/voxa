import Cocoa
import Carbon
import Darwin
import AVFoundation

// MARK: - Config

let NX_DEVICELCMDKEYMASK:  UInt64 = 0x00000008
let NX_DEVICERCMDKEYMASK:  UInt64 = 0x00000010
let NX_DEVICELSHIFTKEYMASK: UInt64 = 0x00000002
let NX_DEVICERSHIFTKEYMASK: UInt64 = 0x00000004
let NX_DEVICELCTLKEYMASK:  UInt64 = 0x00000001
let NX_DEVICERCTLKEYMASK:  UInt64 = 0x00002000
let NX_DEVICELALTKEYMASK:  UInt64 = 0x00000020
let NX_DEVICERALTKEYMASK:  UInt64 = 0x00000040

enum KeyMode {
    case modifierOnly(deviceFlag: UInt64, name: String)
    case keyCombo(keyCode: UInt16, modifiers: CGEventFlags)
}

struct VoxaConfig {
    let keyMode: KeyMode
    var holdDelay: Int = 300
    var language: String = "fr"
    var modelPath: String = NSString(string: "~/.voxa/models/ggml-small.bin").expandingTildeInPath
    var tmpDir: String = NSString(string: "~/.voxa/tmp").expandingTildeInPath
}

let modifierOnlyMap: [String: (UInt64, String)] = [
    "right_cmd":     (NX_DEVICERCMDKEYMASK, "Right Command"),
    "left_cmd":      (NX_DEVICELCMDKEYMASK, "Left Command"),
    "right_shift":   (NX_DEVICERSHIFTKEYMASK, "Right Shift"),
    "left_shift":    (NX_DEVICELSHIFTKEYMASK, "Left Shift"),
    "right_ctrl":    (NX_DEVICERCTLKEYMASK, "Right Control"),
    "left_ctrl":     (NX_DEVICELCTLKEYMASK, "Left Control"),
    "right_alt":     (NX_DEVICERALTKEYMASK, "Right Option"),
    "right_option":  (NX_DEVICERALTKEYMASK, "Right Option"),
    "left_alt":      (NX_DEVICELALTKEYMASK, "Left Option"),
    "left_option":   (NX_DEVICELALTKEYMASK, "Left Option"),
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

func loadConfig() -> VoxaConfig {
    let configPath = NSString(string: "~/.voxa/config").expandingTildeInPath
    var key = "right_cmd"
    var mods: [String] = []
    var delay = 300
    var language = "fr"
    var model = "ggml-small.bin"

    if FileManager.default.fileExists(atPath: configPath) {
        do {
            let contents = try String(contentsOfFile: configPath, encoding: .utf8)
            for (lineNum, line) in contents.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                let parts = trimmed.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else {
                    log("warning: config line \(lineNum + 1) ignored: \(trimmed)")
                    continue
                }
                let k = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
                let v = parts[1].trimmingCharacters(in: .whitespaces)
                switch k {
                case "key": key = v.lowercased()
                case "modifiers":
                    mods = v.lowercased().components(separatedBy: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                case "delay":
                    if let ms = Int(v) { delay = ms }
                case "language": language = v.lowercased()
                case "model": model = v
                default:
                    log("warning: unknown config key '\(k)' on line \(lineNum + 1)")
                }
            }
        } catch {
            log("warning: could not read config: \(error.localizedDescription)")
        }
    }

    let keyMode: KeyMode
    if let (flag, name) = modifierOnlyMap[key] {
        keyMode = .modifierOnly(deviceFlag: flag, name: name)
    } else if let code = keyCodeMap[key] {
        var flags = CGEventFlags()
        for name in mods {
            switch name {
            case "ctrl", "control": flags.insert(.maskControl)
            case "shift": flags.insert(.maskShift)
            case "alt", "option", "opt": flags.insert(.maskAlternate)
            case "cmd", "command": flags.insert(.maskCommand)
            default:
                log("error: unknown modifier '\(name)'")
                exit(1)
            }
        }
        keyMode = .keyCombo(keyCode: code, modifiers: flags)
    } else {
        log("error: unknown key '\(key)'")
        exit(1)
    }

    let modelPath = NSString(string: "~/.voxa/models/\(model)").expandingTildeInPath
    return VoxaConfig(keyMode: keyMode, holdDelay: delay, language: language, modelPath: modelPath)
}

// MARK: - Audio Recorder (AVFoundation)

class AudioRecorder {
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var converter: AVAudioConverter?
    private let recordingURL: URL
    private let lock = NSLock()

    init(tmpDir: String) {
        recordingURL = URL(fileURLWithPath: tmpDir).appendingPathComponent("recording.wav")
    }

    func start() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        try? FileManager.default.removeItem(at: recordingURL)

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

        let wavSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        do {
            audioFile = try AVAudioFile(forWriting: recordingURL, settings: wavSettings, commonFormat: .pcmFormatInt16, interleaved: true)
        } catch {
            log("error: could not create audio file: \(error.localizedDescription)")
            return false
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard let file = self.audioFile, let conv = self.converter else { return }

            let ratio = targetFormat.sampleRate / inputFormat.sampleRate
            let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount) else { return }

            var error: NSError?
            conv.convert(to: outputBuffer, error: &error) { _, outStatus in
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
            log("audio engine started (input: \(inputFormat.sampleRate)Hz → 16000Hz)")
            return true
        } catch {
            log("error: could not start audio engine: \(error.localizedDescription)")
            inputNode.removeTap(onBus: 0)
            audioFile = nil
            converter = nil
            return false
        }
    }

    func stop() -> URL? {
        lock.lock()
        let engine = audioEngine
        audioEngine = nil
        audioFile = nil
        converter = nil
        lock.unlock()

        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)

        let fm = FileManager.default
        guard fm.fileExists(atPath: recordingURL.path),
              let attrs = try? fm.attributesOfItem(atPath: recordingURL.path),
              let size = attrs[.size] as? UInt64,
              size > 1000 else {
            log("warning: recording file missing or too small")
            return nil
        }

        log("recording saved (\(size / 1024) KB)")
        return recordingURL
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: recordingURL)
    }
}

// MARK: - Transcriber

class Transcriber {
    let modelPath: String
    let language: String
    let tmpDir: String

    init(modelPath: String, language: String, tmpDir: String) {
        self.modelPath = modelPath
        self.language = language
        self.tmpDir = tmpDir
    }

    func transcribe(audioURL: URL) -> String? {
        let outputBase = (tmpDir as NSString).appendingPathComponent("output")
        let outputTxt = outputBase + ".txt"

        let whisperPaths = ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
        guard let whisperPath = whisperPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            log("error: whisper-cli not found")
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperPath)
        process.arguments = ["-m", modelPath, "-l", language, "-f", audioURL.path, "-np", "-otxt", "-of", outputBase]

        let logURL = URL(fileURLWithPath: tmpDir).appendingPathComponent("whisper.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            log("error: could not run whisper-cli: \(error.localizedDescription)")
            return nil
        }

        // Wait with timeout (60s)
        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        if semaphore.wait(timeout: .now() + .seconds(60)) == .timedOut {
            log("error: whisper-cli timed out after 60s, killing")
            process.terminate()
            process.waitUntilExit()
        }

        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        try? errData.write(to: logURL)

        guard process.terminationStatus == 0 else {
            log("error: whisper-cli exited with status \(process.terminationStatus)")
            return nil
        }

        guard let text = try? String(contentsOfFile: outputTxt, encoding: .utf8) else {
            return nil
        }

        try? FileManager.default.removeItem(atPath: outputTxt)

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || isHallucination(trimmed) {
            return nil
        }
        return trimmed
    }

    private func isHallucination(_ text: String) -> Bool {
        let lower = text.lowercased()

        let hallucinations = [
            "sous-titres réalisés par", "sous-titres par", "sous-titrage",
            "amara.org", "merci d'avoir regardé", "merci de votre attention",
            "thanks for watching", "thank you for watching",
            "please subscribe", "like and subscribe",
            "copyright", "www.", "http",
        ]

        for pattern in hallucinations {
            if lower.contains(pattern) {
                log("hallucination filtered: \(text)")
                return true
            }
        }

        if let regex = try? NSRegularExpression(pattern: "^\\[.*\\]$"),
           regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) != nil {
            log("hallucination filtered: \(text)")
            return true
        }

        let stripped = lower.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "♪", with: "")
            .replacingOccurrences(of: "…", with: "")
        if stripped.isEmpty {
            log("hallucination filtered: \(text)")
            return true
        }

        return false
    }
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

func notifyError(_ message: String) {
    let escaped = message.replacingOccurrences(of: "\\", with: "\\\\")
                         .replacingOccurrences(of: "\"", with: "\\\"")
    let script = "display notification \"\(escaped)\" with title \"Voxa Error\""
    if let appleScript = NSAppleScript(source: script) {
        appleScript.executeAndReturnError(nil)
    }
}

// MARK: - Clipboard & Paste

func copyAndPaste(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    log("copied to clipboard (\(text.count) chars)")

    guard AXIsProcessTrusted() else {
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
        vDown.post(tap: .cghidEventTap)
        vUp.post(tap: .cghidEventTap)
        log("paste sent")
    }
}

// MARK: - App Delegate

class VoxaDelegate: NSObject, NSApplicationDelegate {
    let config: VoxaConfig
    let overlay = RecordingOverlay()
    let recorder: AudioRecorder
    let transcriber: Transcriber
    var isRecording = false
    var isStarting = false
    var holdTimer: DispatchWorkItem?
    var recordingTimeout: DispatchWorkItem?
    let maxRecordingDuration: Int = 30
    var globalMonitor: Any?
    var localMonitor: Any?

    init(config: VoxaConfig) {
        self.config = config
        self.recorder = AudioRecorder(tmpDir: config.tmpDir)
        self.transcriber = Transcriber(modelPath: config.modelPath, language: config.language, tmpDir: config.tmpDir)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(atPath: config.tmpDir, withIntermediateDirectories: true)
        setupEventMonitor()
        setupSignalHandlers()
    }

    // MARK: - Signal handling

    var sigintSource: DispatchSourceSignal?
    var sigtermSource: DispatchSourceSignal?

    func setupSignalHandlers() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigintSource?.setEventHandler { [weak self] in
            self?.cleanup()
            exit(0)
        }
        sigintSource?.resume()

        sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigtermSource?.setEventHandler { [weak self] in
            self?.cleanup()
            exit(0)
        }
        sigtermSource?.resume()
    }

    func cleanup() {
        if isRecording {
            log("cleaning up...")
            _ = recorder.stop()
            recorder.cleanup()
            overlay.hide()
        }
    }

    // MARK: - Event monitoring (NSEvent — cannot block keyboard)

    func setupEventMonitor() {
        var eventTypes: NSEvent.EventTypeMask = [.flagsChanged]
        if case .keyCombo = config.keyMode {
            eventTypes.insert(.keyDown)
            eventTypes.insert(.keyUp)
        }

        // Global monitor: events in OTHER apps
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: eventTypes) { [weak self] event in
            self?.handleNSEvent(event)
        }

        // Local monitor: ONLY catches key releases to stop recording during popups/dialogs.
        // Does NOT start recordings — that's the global monitor's job.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            guard let self = self, self.isRecording else { return event }
            if case .modifierOnly(let deviceFlag, _) = self.config.keyMode {
                let isPressed = (UInt64(event.modifierFlags.rawValue) & deviceFlag) != 0
                if !isPressed {
                    self.handleStop()
                }
            }
            return event
        }

        if globalMonitor == nil {
            log("error: could not create event monitor. Grant Accessibility permission in System Settings.")
            notifyError("Grant Accessibility permission to Voxa in System Settings.")
        }
    }

    func handleNSEvent(_ event: NSEvent) {
        let rawFlags = event.modifierFlags.rawValue

        switch config.keyMode {
        case .modifierOnly(let deviceFlag, _):
            guard event.type == .flagsChanged else { return }

            let isPressed = (UInt64(rawFlags) & deviceFlag) != 0

            if isPressed {
                if isRecording || isStarting {
                    // Key pressed again while recording → force stop (recovery from missed release)
                    holdTimer?.cancel()
                    holdTimer = nil
                    isStarting = false
                    if isRecording { handleStop() }
                } else if holdTimer == nil {
                    // Normal press → start hold timer
                    let timer = DispatchWorkItem { [weak self] in
                        self?.holdTimer = nil
                        self?.handleStart()
                    }
                    holdTimer = timer
                    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(config.holdDelay), execute: timer)
                }
            } else if !isPressed {
                if let timer = holdTimer {
                    timer.cancel()
                    holdTimer = nil
                }
                if isRecording {
                    handleStop()
                }
                isStarting = false
            }

        case .keyCombo(let expectedKeyCode, let requiredMods):
            guard event.keyCode == expectedKeyCode else { return }

            let relevantFlags = event.modifierFlags.intersection([.control, .shift, .option, .command])
            let required = NSEvent.ModifierFlags(rawValue: UInt(requiredMods.rawValue))
            guard relevantFlags.contains(required) else { return }

            if event.type == .keyDown && !isRecording {
                handleStart()
            } else if event.type == .keyUp && isRecording {
                handleStop()
            }
        }
    }

    // MARK: - Recording lifecycle

    func handleStart() {
        guard !isStarting && !isRecording else { return }
        isStarting = true
        log("handleStart called")
        playSound("Tink")
        log("recording starting...")

        DispatchQueue.global().async {
            guard self.recorder.start() else {
                log("recording failed to start")
                DispatchQueue.main.async {
                    self.isStarting = false
                    notifyError("Microphone recording failed. Check permissions.")
                }
                return
            }

            DispatchQueue.main.async {
                self.isStarting = false
                self.isRecording = true
                self.overlay.show()
                log("recording started")

                let timeout = DispatchWorkItem { [weak self] in
                    guard let self = self, self.isRecording else { return }
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

    func handleStop() {
        guard isRecording else { return }
        isRecording = false
        recordingTimeout?.cancel()
        recordingTimeout = nil
        overlay.hide()
        log("recording stopped")

        DispatchQueue.global().async {
            guard let audioURL = self.recorder.stop() else {
                log("no audio recorded")
                self.recorder.cleanup()
                return
            }

            log("transcribing...")
            playSound("Pop")

            guard let text = self.transcriber.transcribe(audioURL: audioURL) else {
                log("transcription failed")
                notifyError("Transcription failed. Check ~/.voxa/tmp/whisper.log")
                self.recorder.cleanup()
                return
            }

            copyAndPaste(text)
            log(text)
            self.recorder.cleanup()
        }
    }
}

// MARK: - Logging (thread-safe)

private let logQueue = DispatchQueue(label: "voxa.log")

func log(_ message: String) {
    let msg = "voxa: \(message)\n"
    fputs(msg, stderr)

    logQueue.async {
        let logPath = NSString(string: "~/.voxa/tmp/voxad.log").expandingTildeInPath
        if let data = msg.data(using: .utf8) {
            if let handle = FileHandle(forWritingAtPath: logPath) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } else {
                FileManager.default.createFile(atPath: logPath, contents: data)
            }
        }
    }
}

// MARK: - Main

let config = loadConfig()

switch config.keyMode {
case .modifierOnly(_, let name):
    log("push-to-talk with \(name)")
case .keyCombo(let keyCode, let modifiers):
    log("push-to-talk with key \(keyCode) + modifiers \(modifiers.rawValue)")
}
log("hold delay \(config.holdDelay)ms, language \(config.language)")
log("press Ctrl+C to quit")

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = VoxaDelegate(config: config)
app.delegate = delegate
app.run()
