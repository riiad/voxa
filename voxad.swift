import Cocoa
import Carbon
import Darwin

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
                    log(" warning: config line \(lineNum + 1) ignored (no '=' found): \(trimmed)")
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
                    log(" warning: unknown config key '\(k)' on line \(lineNum + 1)")
                }
            }
        } catch {
            log(" warning: could not read config at \(configPath): \(error.localizedDescription)")
            log(" using defaults")
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
                log(" error: unknown modifier '\(name)'")
                exit(1)
            }
        }
        keyMode = .keyCombo(keyCode: code, modifiers: flags)
    } else {
        log(" error: unknown key '\(key)'")
        log(" valid keys: \(keyCodeMap.keys.sorted().joined(separator: ", "))")
        log(" valid modifier keys: \(modifierOnlyMap.keys.sorted().joined(separator: ", "))")
        exit(1)
    }

    let modelPath = NSString(string: "~/.voxa/models/\(model)").expandingTildeInPath
    return VoxaConfig(keyMode: keyMode, holdDelay: delay, language: language, modelPath: modelPath)
}

// MARK: - Audio Recorder (via ffmpeg)

class AudioRecorder {
    private var ffmpegProcess: Process?
    private let recordingURL: URL
    private let tmpDir: String

    init(tmpDir: String) {
        self.tmpDir = tmpDir
        recordingURL = URL(fileURLWithPath: tmpDir).appendingPathComponent("recording.wav")
    }

    func start() -> Bool {
        let ffmpegPaths = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        guard let ffmpegPath = ffmpegPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            log("error: ffmpeg not found")
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = ["-y", "-f", "avfoundation", "-i", ":0", "-ar", "16000", "-ac", "1", "-sample_fmt", "s16", recordingURL.path]

        let logPath = (tmpDir as NSString).appendingPathComponent("ffmpeg.log")
        FileManager.default.createFile(atPath: logPath, contents: nil)
        process.standardError = FileHandle(forWritingAtPath: logPath)
        process.standardOutput = FileHandle.nullDevice

        do {
            try process.run()
            ffmpegProcess = process

            // Verify ffmpeg started
            Thread.sleep(forTimeInterval: 0.3)
            guard process.isRunning else {
                log("error: ffmpeg exited immediately")
                ffmpegProcess = nil
                return false
            }
            return true
        } catch {
            log("error: could not start ffmpeg: \(error.localizedDescription)")
            return false
        }
    }

    func stop() -> URL? {
        guard let process = ffmpegProcess else { return nil }
        ffmpegProcess = nil

        process.interrupt() // SIGINT for graceful WAV finalization
        for _ in 0..<20 {
            if !process.isRunning { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.5)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            log("warning: ffmpeg required SIGKILL")
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: recordingURL.path),
              let attrs = try? fm.attributesOfItem(atPath: recordingURL.path),
              let size = attrs[.size] as? UInt64,
              size > 1000 else {
            return nil
        }

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

        // Find whisper-cli
        let whisperPaths = ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
        guard let whisperPath = whisperPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            log(" error: whisper-cli not found")
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperPath)
        process.arguments = ["-m", modelPath, "-l", language, "-f", audioURL.path, "-np", "-otxt", "-of", outputBase]

        let logURL = URL(fileURLWithPath: tmpDir).appendingPathComponent("whisper.log")
        let logHandle = try? FileHandle(forWritingTo: logURL)
        if logHandle == nil {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            log(" error: could not run whisper-cli: \(error.localizedDescription)")
            return nil
        }

        // Save stderr to log
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        try? errData.write(to: logURL)

        guard process.terminationStatus == 0 else {
            log(" error: whisper-cli exited with status \(process.terminationStatus)")
            return nil
        }

        guard let text = try? String(contentsOfFile: outputTxt, encoding: .utf8) else {
            return nil
        }

        // Cleanup output file
        try? FileManager.default.removeItem(atPath: outputTxt)

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || isHallucination(trimmed) {
            return nil
        }
        return trimmed
    }

    private func isHallucination(_ text: String) -> Bool {
        let lower = text.lowercased()

        // Known whisper hallucination phrases
        let hallucinations = [
            "sous-titres réalisés par",
            "sous-titres par",
            "sous-titrage",
            "amara.org",
            "merci d'avoir regardé",
            "merci de votre attention",
            "thanks for watching",
            "thank you for watching",
            "please subscribe",
            "like and subscribe",
            "copyright",
            "www.",
            "http",
        ]

        for pattern in hallucinations {
            if lower.contains(pattern) {
                log("hallucination filtered: \(text)")
                return true
            }
        }

        // Bracketed annotations like [Musique], [Bruit], [silence], ...
        let bracketPattern = try? NSRegularExpression(pattern: "^\\[.*\\]$")
        let range = NSRange(lower.startIndex..., in: lower)
        if bracketPattern?.firstMatch(in: lower, range: range) != nil {
            log("hallucination filtered: \(text)")
            return true
        }

        // Repeated short fragments (e.g. "..." or "♪ ♪ ♪")
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
            DispatchQueue.main.async {
                guard let self = self, let start = self.startTime else { return }

                // Update timer
                let elapsed = Int(Date().timeIntervalSince(start))
                let mins = elapsed / 60
                let secs = elapsed % 60
                self.timerLabel?.stringValue = String(format: "%02d:%02d", mins, secs)

                // Pulse dot
                self.dotView?.layer?.backgroundColor = bright
                    ? NSColor.systemRed.withAlphaComponent(0.3).cgColor
                    : NSColor.systemRed.cgColor
                bright = !bright
            }
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

// MARK: - Sounds

func playSound(_ name: String) {
    if let sound = NSSound(named: name) {
        sound.play()
    }
}

func notifyError(_ message: String) {
    let script = "display notification \"\(message)\" with title \"Voxa Error\""
    if let appleScript = NSAppleScript(source: script) {
        appleScript.executeAndReturnError(nil)
    }
}

// MARK: - Clipboard & Paste

func copyAndPaste(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)

    // Simulate Cmd+V
    let source = CGEventSource(stateID: .combinedSessionState)
    let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true) // 9 = V
    let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
    keyDown?.flags = .maskCommand
    keyUp?.flags = .maskCommand
    keyDown?.post(tap: .cghidEventTap)
    keyUp?.post(tap: .cghidEventTap)
}

// MARK: - App Delegate

class VoxaDelegate: NSObject, NSApplicationDelegate {
    let config: VoxaConfig
    let overlay = RecordingOverlay()
    let recorder: AudioRecorder
    let transcriber: Transcriber
    var isRecording = false
    var globalTap: CFMachPort?
    var holdTimer: DispatchWorkItem?
    var recordingTimeout: DispatchWorkItem?
    let maxRecordingDuration: Int = 120 // seconds

    init(config: VoxaConfig) {
        self.config = config
        self.recorder = AudioRecorder(tmpDir: config.tmpDir)
        self.transcriber = Transcriber(modelPath: config.modelPath, language: config.language, tmpDir: config.tmpDir)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure tmp directory exists
        try? FileManager.default.createDirectory(atPath: config.tmpDir, withIntermediateDirectories: true)
        setupEventTap()
        setupSignalHandlers()
    }

    // MARK: - Signal handling

    func setupSignalHandlers() {
        let handler: @convention(c) (Int32) -> Void = { _ in
            let delegate = NSApplication.shared.delegate as? VoxaDelegate
            delegate?.cleanup()
            exit(0)
        }
        signal(SIGINT, handler)
        signal(SIGTERM, handler)
    }

    func cleanup() {
        if isRecording {
            print("\nvoxa: cleaning up...")
            _ = recorder.stop()
            recorder.cleanup()
            DispatchQueue.main.async { self.overlay.hide() }
        }
    }

    // MARK: - Recording lifecycle

    func handleStart() {
        playSound("Tink")
        log("recording starting...")

        DispatchQueue.global().async {
            guard self.recorder.start() else {
                log("recording failed to start")
                DispatchQueue.main.async {
                    notifyError("Microphone recording failed. Check permissions.")
                }
                return
            }

            DispatchQueue.main.async {
                self.isRecording = true
                self.overlay.show()
                log("recording started")

                // Safety timeout
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

            log(text)

            DispatchQueue.main.async {
                copyAndPaste(text)
            }

            self.recorder.cleanup()
        }
    }

    // MARK: - Event tap

    func setupEventTap() {
        let eventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let delegate = Unmanaged<VoxaDelegate>.fromOpaque(refcon).takeUnretainedValue()
                return delegate.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: refcon
        ) else {
            log(" failed to create event tap. Grant Accessibility permission in System Settings.")
            exit(1)
        }

        globalTap = eventTap

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            log("warning: event tap was disabled, re-enabling")
            if let tap = globalTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let rawFlags = event.flags.rawValue

        switch config.keyMode {
        case .modifierOnly(let deviceFlag, _):
            guard type == .flagsChanged else {
                return Unmanaged.passUnretained(event)
            }

            let isPressed = (rawFlags & deviceFlag) != 0

            if isPressed && !isRecording && holdTimer == nil {
                let timer = DispatchWorkItem { [weak self] in
                    self?.holdTimer = nil
                    self?.handleStart()
                }
                holdTimer = timer
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(config.holdDelay), execute: timer)
            } else if !isPressed {
                if let timer = holdTimer {
                    timer.cancel()
                    holdTimer = nil
                } else if isRecording {
                    DispatchQueue.main.async { self.handleStop() }
                }
            }

            return Unmanaged.passUnretained(event)

        case .keyCombo(let keyCode, let requiredMods):
            let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            guard eventKeyCode == keyCode else {
                return Unmanaged.passUnretained(event)
            }

            let relevantFlags = event.flags.intersection([.maskControl, .maskShift, .maskAlternate, .maskCommand])
            guard relevantFlags.contains(requiredMods) else {
                return Unmanaged.passUnretained(event)
            }

            if type == .keyDown && !isRecording {
                DispatchQueue.main.async { self.handleStart() }
            } else if type == .keyUp && isRecording {
                DispatchQueue.main.async { self.handleStop() }
            }

            return Unmanaged.passUnretained(event)
        }
    }
}

// MARK: - Logging

func log(_ message: String) {
    let msg = "voxa: \(message)\n"
    fputs(msg, stderr)
    // Also write to log file
    let logPath = NSString(string: "~/.voxa/tmp/voxad.log").expandingTildeInPath
    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile()
        handle.write(msg.data(using: .utf8)!)
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: msg.data(using: .utf8))
    }
}

// MARK: - Main

let config = loadConfig()

switch config.keyMode {
case .modifierOnly(_, let name):
    log(" push-to-talk with \(name)")
case .keyCombo(let keyCode, let modifiers):
    log(" push-to-talk with key \(keyCode) + modifiers \(modifiers.rawValue)")
}
log(" hold delay \(config.holdDelay)ms, language \(config.language)")
log(" press Ctrl+C to quit")

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = VoxaDelegate(config: config)
app.delegate = delegate
app.run()
