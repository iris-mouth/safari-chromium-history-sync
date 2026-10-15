import AppKit
import SafariSyncCore

/// Safari's standard Apple events perform a normal navigation, never an account upload.
enum SafariSyncAssistDriver {
    static func source(for url: URL) -> String? {
        guard let alternateURL = SafariSyncAssist.alternateControlURL(for: url) else { return nil }
        // URL validation admits a generated UUID only; never interpolate history URLs.
        return """
        with timeout of 5 seconds
            if application id "com.apple.Safari" is not running then return "notRunning"
            tell application id "com.apple.Safari"
                set controlURL to "\(url.absoluteString)"
                set refreshURL to "\(alternateURL.absoluteString)"
                repeat with helperWindow in windows
                    repeat with helperTab in tabs of helperWindow
                        if (URL of helperTab) is controlURL then
                            set URL of helperTab to refreshURL
                            return "tabReused"
                        else if (URL of helperTab) is refreshURL then
                            set URL of helperTab to controlURL
                            return "tabReused"
                        end if
                    end repeat
                end repeat
                make new document with properties {URL:controlURL}
                set visible of window 1 to false
                return "tabCreated"
            end tell
        end timeout
        """
    }

    static func validate() -> Bool {
        guard let source = source(for: SafariSyncAssist().controlURL), let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        return script.compileAndReturnError(&error)
    }

    static func perform(_ url: URL) -> String {
        guard let source = source(for: url) else { return "invalidControlURL" }
        // NSAppleScript is used serially on the main thread. The timer holds no service lock.
        return DispatchQueue.main.sync {
            guard let script = NSAppleScript(source: source) else { return "scriptUnavailable" }
            var error: NSDictionary?
            let result = script.executeAndReturnError(&error)
            if let error {
                let code = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
                if code == -1743 { return "permissionDenied" }
                if code == -1712 { return "navigationTimedOut" }
                return "navigationFailed:\(code)"
            }
            return ["tabCreated", "tabReused", "notRunning"].contains(result.stringValue ?? "")
                ? result.stringValue! : "navigationFailed"
        }
    }
}
