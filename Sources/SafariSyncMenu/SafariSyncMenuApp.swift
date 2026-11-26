import AppKit

@main
@MainActor
struct SafariSyncMenuApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = MenuDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
