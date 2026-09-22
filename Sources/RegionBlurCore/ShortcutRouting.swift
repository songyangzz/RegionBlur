public enum AppShortcut: String, Codable, CaseIterable, Hashable, Sendable {
    case createRegion
    case showAll
    case hideAll
    case increaseClarity
    case decreaseClarity

    public var hotKeyIdentifier: UInt32 {
        switch self {
        case .createRegion: 1
        case .showAll: 2
        case .hideAll: 3
        case .increaseClarity: 4
        case .decreaseClarity: 5
        }
    }

    public init?(hotKeyIdentifier: UInt32) {
        guard let command = Self.allCases.first(where: { $0.hotKeyIdentifier == hotKeyIdentifier }) else { return nil }
        self = command
    }
}

public struct ShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let command = ShortcutModifiers(rawValue: 1 << 0)
    public static let option = ShortcutModifiers(rawValue: 1 << 1)
    public static let control = ShortcutModifiers(rawValue: 1 << 2)
    public static let shift = ShortcutModifiers(rawValue: 1 << 3)
}

public struct ShortcutBinding: Codable, Equatable, Hashable, Sendable {
    public var keyCode: UInt16
    public var modifiers: ShortcutModifiers
    public var keyLabel: String

    public init(keyCode: UInt16, modifiers: ShortcutModifiers, keyLabel: String? = nil) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel ?? Self.defaultLabel(for: keyCode)
    }

    public var displayString: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        return result + keyLabel.uppercased()
    }

    public static func == (lhs: ShortcutBinding, rhs: ShortcutBinding) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(modifiers)
    }

    private static func defaultLabel(for keyCode: UInt16) -> String {
        switch keyCode {
        case 18: "1"
        case 19: "2"
        case 125: "↓"
        case 126: "↑"
        case 11: "B"
        case 0: "A"
        default: "键\(keyCode)"
        }
    }
}

public struct ShortcutConfiguration: Codable, Equatable, Sendable {
    public var showAll: ShortcutBinding
    public var hideAll: ShortcutBinding
    public var increaseClarity: ShortcutBinding
    public var decreaseClarity: ShortcutBinding

    public static let `default` = ShortcutConfiguration(
        showAll: ShortcutBinding(keyCode: 18, modifiers: [.command, .option]),
        hideAll: ShortcutBinding(keyCode: 19, modifiers: [.command, .option]),
        increaseClarity: ShortcutBinding(keyCode: 126, modifiers: [.command, .option]),
        decreaseClarity: ShortcutBinding(keyCode: 125, modifiers: [.command, .option])
    )

    public func binding(for command: AppShortcut) -> ShortcutBinding? {
        switch command {
        case .createRegion: ShortcutBinding(keyCode: 11, modifiers: [.command, .option])
        case .showAll: showAll
        case .hideAll: hideAll
        case .increaseClarity: increaseClarity
        case .decreaseClarity: decreaseClarity
        }
    }

    @discardableResult
    public mutating func set(_ binding: ShortcutBinding, for command: AppShortcut) -> Bool {
        guard command != .createRegion else { return false }
        guard !AppShortcut.allCases.contains(where: { $0 != command && self.binding(for: $0) == binding }) else { return false }
        switch command {
        case .createRegion: return false
        case .showAll: showAll = binding
        case .hideAll: hideAll = binding
        case .increaseClarity: increaseClarity = binding
        case .decreaseClarity: decreaseClarity = binding
        }
        return true
    }
}

public enum ShortcutRouting {
    public static func command(keyCode: UInt16, modifiers: ShortcutModifiers, configuration: ShortcutConfiguration) -> AppShortcut? {
        AppShortcut.allCases.first {
            configuration.binding(for: $0) == ShortcutBinding(keyCode: keyCode, modifiers: modifiers)
        }
    }
}

public enum ClarityDirection: Sendable {
    case increase
    case decrease
}

public enum ClarityAdjustment {
    public static func adjust(_ current: Double, direction: ClarityDirection) -> Double {
        let delta = direction == .increase ? -0.08 : 0.08
        let clamped = min(1.0, max(0.15, current + delta))
        return (clamped * 100).rounded() / 100
    }
}
