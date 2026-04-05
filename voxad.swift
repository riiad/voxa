import Cocoa
import Carbon

// MARK: - Config

// Device-dependent modifier flags (from IOLLEvent.h)
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

func loadConfig() -> KeyMode {
    let configPath = NSString(string: "~/.voxa/config").expandingTildeInPath
    var key = "right_cmd"
    var mods: [String] = []

    if let contents = try? String(contentsOfFile: configPath, encoding: .utf8) {
        for line in contents.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let parts = trimmed.components(separatedBy: "=")
            guard parts.count == 2 else { continue }
            let k = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let v = parts[1].trimmingCharacters(in: .whitespaces).lowercased()
            switch k {
            case "key": key = v
            case "modifiers":
                mods = v.components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            default: break
            }
        }
    }

    // Check for modifier-only keys
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

    if let (flag, name) = modifierOnlyMap[key] {
        return .modifierOnly(deviceFlag: flag, name: name)
    }

    return .keyCombo(keyCode: keyCodeFor(key), modifiers: modifierFlags(mods))
}

func keyCodeFor(_ name: String) -> UInt16 {
    let map: [String: UInt16] = [
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
    guard let code = map[name] else {
        print("voxa: unknown key '\(name)', defaulting to space")
        return 49
    }
    return code
}

func modifierFlags(_ names: [String]) -> CGEventFlags {
    var flags = CGEventFlags()
    for name in names {
        switch name {
        case "ctrl", "control": flags.insert(.maskControl)
        case "shift": flags.insert(.maskShift)
        case "alt", "option", "opt": flags.insert(.maskAlternate)
        case "cmd", "command": flags.insert(.maskCommand)
        default: break
        }
    }
    return flags
}

// MARK: - Daemon

let voxaDir: String = {
    let execURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    return execURL.path
}()

let mode = loadConfig()
var isRecording = false

switch mode {
case .modifierOnly(_, let name):
    print("voxa: push-to-talk with \(name)")
case .keyCombo(let keyCode, let modifiers):
    print("voxa: push-to-talk with key \(keyCode) + modifiers \(modifiers.rawValue)")
}
print("voxa: press Ctrl+C to quit")

func runVoxa(_ action: String) {
    let script = "\(voxaDir)/voxa.sh"
    let process = Process()
    process.launchPath = "/bin/bash"
    process.arguments = [script, action]
    process.launch()
}

func eventCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let refcon = refcon {
            let tap = Unmanaged<CFMachPort>.fromOpaque(refcon).takeUnretainedValue()
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passRetained(event)
    }

    let rawFlags = event.flags.rawValue

    switch mode {
    case .modifierOnly(let deviceFlag, _):
        guard type == .flagsChanged else {
            return Unmanaged.passRetained(event)
        }

        let isPressed = (rawFlags & deviceFlag) != 0

        if isPressed && !isRecording {
            isRecording = true
            runVoxa("start")
        } else if !isPressed && isRecording {
            isRecording = false
            runVoxa("stop")
        }

        return Unmanaged.passRetained(event)

    case .keyCombo(let keyCode, let requiredMods):
        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard eventKeyCode == keyCode else {
            return Unmanaged.passRetained(event)
        }

        let relevantFlags = event.flags.intersection([.maskControl, .maskShift, .maskAlternate, .maskCommand])
        guard relevantFlags.contains(requiredMods) else {
            return Unmanaged.passRetained(event)
        }

        if type == .keyDown && !isRecording {
            isRecording = true
            runVoxa("start")
        } else if type == .keyUp && isRecording {
            isRecording = false
            runVoxa("stop")
        }

        return nil
    }
}

let eventMask = (1 << CGEventType.keyDown.rawValue)
    | (1 << CGEventType.keyUp.rawValue)
    | (1 << CGEventType.flagsChanged.rawValue)

guard let eventTap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,
    eventsOfInterest: CGEventMask(eventMask),
    callback: eventCallback,
    userInfo: nil
) else {
    print("voxa: failed to create event tap. Grant Accessibility permission in System Settings.")
    exit(1)
}

let tapPtr = Unmanaged.passUnretained(eventTap).toOpaque()

guard let eventTapWithRef = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,
    eventsOfInterest: CGEventMask(eventMask),
    callback: eventCallback,
    userInfo: tapPtr
) else {
    print("voxa: failed to create event tap. Grant Accessibility permission in System Settings.")
    exit(1)
}

let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTapWithRef, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
CGEvent.tapEnable(tap: eventTapWithRef, enable: true)

CFRunLoopRun()
