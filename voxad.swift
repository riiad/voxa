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

func loadConfig() -> KeyMode {
    let configPath = NSString(string: "~/.voxa/config").expandingTildeInPath
    var key = "right_cmd"
    var mods: [String] = []

    if FileManager.default.fileExists(atPath: configPath) {
        do {
            let contents = try String(contentsOfFile: configPath, encoding: .utf8)
            for (lineNum, line) in contents.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                let parts = trimmed.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else {
                    print("voxa: warning: config line \(lineNum + 1) ignored (no '=' found): \(trimmed)")
                    continue
                }
                let k = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
                let v = parts[1].trimmingCharacters(in: .whitespaces).lowercased()
                switch k {
                case "key": key = v
                case "modifiers":
                    mods = v.components(separatedBy: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                case "language", "model": break // handled by voxa.sh
                default:
                    print("voxa: warning: unknown config key '\(k)' on line \(lineNum + 1)")
                }
            }
        } catch {
            print("voxa: warning: could not read config at \(configPath): \(error.localizedDescription)")
            print("voxa: using default key (right_cmd)")
        }
    }

    if let (flag, name) = modifierOnlyMap[key] {
        return .modifierOnly(deviceFlag: flag, name: name)
    }

    guard let code = keyCodeMap[key] else {
        print("voxa: error: unknown key '\(key)'")
        print("voxa: valid keys: \(keyCodeMap.keys.sorted().joined(separator: ", "))")
        print("voxa: valid modifier keys: \(modifierOnlyMap.keys.sorted().joined(separator: ", "))")
        exit(1)
    }

    var flags = CGEventFlags()
    for name in mods {
        switch name {
        case "ctrl", "control": flags.insert(.maskControl)
        case "shift": flags.insert(.maskShift)
        case "alt", "option", "opt": flags.insert(.maskAlternate)
        case "cmd", "command": flags.insert(.maskCommand)
        default:
            print("voxa: error: unknown modifier '\(name)'")
            print("voxa: valid modifiers: ctrl, shift, alt/option, cmd/command")
            exit(1)
        }
    }

    return .keyCombo(keyCode: code, modifiers: flags)
}

// MARK: - Recording Overlay

class RecordingOverlay {
    private var window: NSWindow?
    private var pulseTimer: Timer?
    private var dotView: NSView?

    func show() {
        guard let screen = NSScreen.main else { return }

        let width: CGFloat = 120
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

        // Red dot
        let dotSize: CGFloat = 10
        let dot = NSView(frame: NSRect(x: 12, y: (height - dotSize) / 2, width: dotSize, height: dotSize))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = dotSize / 2
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        pill.addSubview(dot)

        // Label
        let label = NSTextField(labelWithString: "Recording")
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.frame = NSRect(x: 28, y: (height - 16) / 2, width: 80, height: 16)
        pill.addSubview(label)

        win.contentView = pill
        self.dotView = dot

        win.orderFrontRegardless()
        self.window = win

        // Pulse animation on the red dot
        var bright = true
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.dotView?.layer?.backgroundColor = bright
                    ? NSColor.systemRed.withAlphaComponent(0.3).cgColor
                    : NSColor.systemRed.cgColor
                bright = !bright
            }
        }
    }

    func hide() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        window?.orderOut(nil)
        window = nil
        dotView = nil
    }
}

// MARK: - App Delegate

class VoxaDelegate: NSObject, NSApplicationDelegate {
    let mode: KeyMode
    let voxaScript: String
    let overlay = RecordingOverlay()
    var isRecording = false
    let processLock = NSLock()
    var globalTap: CFMachPort?

    init(mode: KeyMode, voxaScript: String) {
        self.mode = mode
        self.voxaScript = voxaScript
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
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
            DispatchQueue.main.async { self.overlay.hide() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [voxaScript, "stop"]
            try? process.run()
            process.waitUntilExit()
        }
    }

    // MARK: - Process management

    func runVoxa(_ action: String) {
        processLock.lock()
        defer { processLock.unlock() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [voxaScript, action]
        do {
            try process.run()
        } catch {
            print("voxa: error launching \(action): \(error.localizedDescription)")
            isRecording = false
            DispatchQueue.main.async { self.overlay.hide() }
        }
    }

    func handleStart() {
        isRecording = true
        DispatchQueue.main.async { self.overlay.show() }
        DispatchQueue.global().async { self.runVoxa("start") }
    }

    func handleStop() {
        isRecording = false
        DispatchQueue.main.async { self.overlay.hide() }
        DispatchQueue.global().async { self.runVoxa("stop") }
    }

    // MARK: - Event tap

    func setupEventTap() {
        let eventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        // Store self in a pointer for the C callback
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
            print("voxa: failed to create event tap. Grant Accessibility permission in System Settings.")
            exit(1)
        }

        globalTap = eventTap

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = globalTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let rawFlags = event.flags.rawValue

        switch mode {
        case .modifierOnly(let deviceFlag, _):
            guard type == .flagsChanged else {
                return Unmanaged.passUnretained(event)
            }

            let isPressed = (rawFlags & deviceFlag) != 0

            if isPressed && !isRecording {
                handleStart()
            } else if !isPressed && isRecording {
                handleStop()
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
                handleStart()
            } else if type == .keyUp && isRecording {
                handleStop()
            }

            return nil
        }
    }
}

// MARK: - Main

let voxaDir = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent().path
let voxaScript = "\(voxaDir)/voxa.sh"

guard FileManager.default.isExecutableFile(atPath: voxaScript) else {
    print("voxa: error: voxa.sh not found at \(voxaScript)")
    exit(1)
}

let mode = loadConfig()

switch mode {
case .modifierOnly(_, let name):
    print("voxa: push-to-talk with \(name)")
case .keyCombo(let keyCode, let modifiers):
    print("voxa: push-to-talk with key \(keyCode) + modifiers \(modifiers.rawValue)")
}
print("voxa: press Ctrl+C to quit")

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // No dock icon
let delegate = VoxaDelegate(mode: mode, voxaScript: voxaScript)
app.delegate = delegate
app.run()
