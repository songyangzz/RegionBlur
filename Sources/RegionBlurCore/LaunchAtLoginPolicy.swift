public enum LaunchAtLoginStatus {
    case disabled
    case enabled
    case requiresApproval
}

public enum LaunchAtLoginAction: Equatable {
    case register
    case unregister
    case openSettings
}

public enum LaunchAtLoginPolicy {
    public static func action(for status: LaunchAtLoginStatus) -> LaunchAtLoginAction {
        switch status {
        case .disabled: .register
        case .enabled: .unregister
        case .requiresApproval: .openSettings
        }
    }
}
