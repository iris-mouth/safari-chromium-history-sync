import Foundation
import ServiceManagement

enum LoginItemRegistration {
    enum Result: Equatable { case ready, requiresApproval }

    struct Unavailable: LocalizedError {
        var errorDescription: String? { "Open at Login could not be registered." }
        var recoverySuggestion: String? { "Add Safari Chromium History Sync in System Settings → General → Login Items & Extensions." }
    }

    /// `notFound` is also returned for an app that has never been registered.
    /// A successful registration must still become enabled or await approval.
    static func ensure(status: () -> SMAppService.Status,
                       register: () throws -> Void) throws -> Result {
        switch status() {
        case .enabled: return .ready
        case .requiresApproval: return .requiresApproval
        case .notRegistered, .notFound:
            do { try register() }
            catch {
                // Registration can race with a system-settings change.
                switch status() {
                case .enabled: return .ready
                case .requiresApproval: return .requiresApproval
                default: throw error
                }
            }
        @unknown default: throw Unavailable()
        }
        switch status() {
        case .enabled: return .ready
        case .requiresApproval: return .requiresApproval
        default: throw Unavailable()
        }
    }
}
