import AppKit
import SafariSyncCore

/// The normal entry point is read-only; testing and repair live in diagnostics.
@MainActor
final class SyncStatusWindow: NSWindowController {
    private let request: (MenuCommand) async throws -> Data
    private let status = NSTextField(wrappingLabelWithString: "同期状況を確認中…")
    private let browser = NSTextField(wrappingLabelWithString: "")
    private let pending = NSTextField(wrappingLabelWithString: "")
    private let safari = NSTextField(wrappingLabelWithString: "")
    private let assist = NSTextField(wrappingLabelWithString: "")
    private var busy = false

    init(request: @escaping (MenuCommand) async throws -> Data) {
        self.request = request
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 390),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "履歴の同期状況"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor, constant: -24),
        ])
        status.font = .boldSystemFont(ofSize: 17)
        let explanation = NSTextField(wrappingLabelWithString:
            "iPhone／iPadへの到達は、端末のブラウザで履歴を確認してください。Safari側の進行状況だけでは、個々の履歴の到達を確定できません。")
        explanation.textColor = .secondaryLabelColor
        for field in [status, browser, pending, safari, assist, explanation] {
            stack.addArrangedSubview(field)
            field.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let refresh = NSButton(title: "状態表示を更新", target: self, action: #selector(refresh))
        refresh.toolTip = "表示だけを更新します。テスト履歴の追加や設定変更は行いません。"
        stack.addArrangedSubview(refresh)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc func refresh() {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let data = try await request(MenuCommand(operation: "status"))
                let health = try JSONDecoder().decode(HealthSnapshot.self, from: data)
                var diagnostics: CloudDiagnostics?
                if health.runtimeState == "ready", let profile = health.activeProfileID {
                    let data = try await request(MenuCommand(operation: "cloudStatus", profileID: profile))
                    diagnostics = try JSONDecoder().decode(CloudDiagnostics.self, from: data)
                }
                display(health: health, diagnostics: diagnostics)
            } catch {
                status.stringValue = "同期状況を取得できませんでした"
                browser.stringValue = "メニューの「問題を調べる」から接続状態を確認してください。"
                pending.stringValue = ""
                safari.stringValue = ""
                assist.stringValue = ""
            }
        }
    }

    func display(health: HealthSnapshot, diagnostics: CloudDiagnostics?) {
        let profile = health.connectedProfiles.first { $0.profileID == health.activeProfileID }
        status.stringValue = health.runtimeState == "blocked" || !health.enabled ? "同期が停止しています"
            : health.runtimeState == "initializing" ? "同期サービスを起動中…"
            : health.activeProfileID == nil && !health.connectedProfiles.isEmpty ? "同期するブラウザを選んでください"
            : profile == nil ? "ブラウザ拡張機能の接続待ち" : "履歴の同期を実行中"
        browser.stringValue = "同期するブラウザ：\(profile?.displayName ?? (health.activeProfileID == nil ? "未選択" : "接続待ち"))"
        pending.stringValue = "ブラウザへの配送待ち：\(health.pendingSafariToBrowser)件\n配送失敗後の自動再試行待ち：\(health.recoveryCount)件"
        if let cloud = diagnostics?.summary {
            safari.stringValue = "Safari側の同期待ち：\(cloud.safariPending)件\n端末で到達を確認した記録：\(cloud.remoteSeen)件"
        } else {
            safari.stringValue = health.runtimeState == "blocked" ? "「問題を調べる」から停止原因と復旧方法を確認してください。" : ""
        }
        if let diagnostics, let scheduler = diagnostics.safariAssist {
            assist.stringValue = "専用タブによるSafariの自動同期補助：\(scheduler.enabled ? "有効" : "無効")"
            if scheduler.enabled, let next = scheduler.nextAttemptAt, diagnostics.summary.safariPending > 0 {
                assist.stringValue += "\n次に処理を試す時刻：\(next.formatted(date: .abbreviated, time: .shortened))"
            }
        } else { assist.stringValue = "専用タブによるSafariの自動同期補助：無効" }
    }
}
