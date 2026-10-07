import AppKit
import Carbon.HIToolbox

/// The thing the user holds down to talk, recorded by pressing it in
/// Settings. It can be any key (a modifier such as right ⌥ on its own, or an
/// ordinary key such as F13) or any mouse button other than left and right.
struct TalkTrigger: Codable, Equatable {
    enum Kind: String, Codable { case modifier, key, mouse }

    var kind: Kind
    /// Virtual key code for `.modifier` and `.key`; button number for `.mouse`.
    var code: Int
    /// What to show, e.g. "Right ⌥", "F13", "Mouse Back".
    var name: String

    static let rightOption = TalkTrigger(kind: .modifier, code: kVK_RightOption, name: "Right ⌥")

    var shortLabel: String { name }

    /// The modifier flag a modifier key toggles, for reading `flagsChanged`.
    var modifierFlag: NSEvent.ModifierFlags? {
        guard kind == .modifier else { return nil }
        return Self.modifierFlags[code]
    }

    /// Ordinary keys and mouse buttons are swallowed while the app runs, so
    /// they stop doing their usual job. Modifiers are left alone.
    var swallowsInput: Bool { kind != .modifier }

    // MARK: Building from a pressed key or button

    static func modifier(keyCode: Int) -> TalkTrigger? {
        guard let name = modifierNames[keyCode] else { return nil }
        return TalkTrigger(kind: .modifier, code: keyCode, name: name)
    }

    static func key(keyCode: Int, characters: String?) -> TalkTrigger {
        TalkTrigger(kind: .key, code: keyCode, name: keyName(keyCode, characters))
    }

    /// nil for the left (0) and right (1) buttons, which are never used.
    static func mouse(button: Int) -> TalkTrigger? {
        guard button >= 2 else { return nil }
        let name = switch button {
        case 2: "Middle mouse button"
        case 3: "Mouse Back button"
        case 4: "Mouse Forward button"
        default: "Mouse button \(button + 1)"
        }
        return TalkTrigger(kind: .mouse, code: button, name: name)
    }

    /// Reads the setting stored by the old drop-down menu.
    static func migrating(_ old: String?) -> TalkTrigger {
        switch old {
        case "rightCommand": modifier(keyCode: kVK_RightCommand)!
        case "rightControl": modifier(keyCode: kVK_RightControl)!
        case "function": modifier(keyCode: kVK_Function)!
        case "middleMouse": mouse(button: 2)!
        case "mouseBack": mouse(button: 3)!
        case "mouseForward": mouse(button: 4)!
        default: .rightOption
        }
    }

    private static let modifierFlags: [Int: NSEvent.ModifierFlags] = [
        kVK_Command: .command, kVK_RightCommand: .command,
        kVK_Shift: .shift, kVK_RightShift: .shift,
        kVK_Option: .option, kVK_RightOption: .option,
        kVK_Control: .control, kVK_RightControl: .control,
        kVK_Function: .function,
    ]

    private static let modifierNames: [Int: String] = [
        kVK_Command: "Left ⌘", kVK_RightCommand: "Right ⌘",
        kVK_Shift: "Left ⇧", kVK_RightShift: "Right ⇧",
        kVK_Option: "Left ⌥", kVK_RightOption: "Right ⌥",
        kVK_Control: "Left ⌃", kVK_RightControl: "Right ⌃",
        kVK_Function: "fn",
    ]

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "Return", kVK_Tab: "Tab", kVK_Delete: "Delete",
        kVK_ForwardDelete: "⌦", kVK_Escape: "Esc", kVK_Home: "Home", kVK_End: "End",
        kVK_PageUp: "Page Up", kVK_PageDown: "Page Down", kVK_Help: "Help",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20", kVK_ANSI_KeypadEnter: "Keypad Enter",
    ]

    private static func keyName(_ code: Int, _ characters: String?) -> String {
        if let name = specialKeys[code] { return name }
        let chars = (characters ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return chars.isEmpty ? "Key \(code)" : chars
    }
}
