import Foundation

/// Shared data between the watch app and widget via App Groups.
/// Both targets must have the same App Group entitlement.
enum SharedConsoleData {
    static let appGroup = "group.com.jeffbachand.jeffjs"
    static let lastResultKey = "widget.lastResult"
    static let lastCommandKey = "widget.lastCommand"
    static let lastUpdateKey = "widget.lastUpdate"
    static let widgetScriptKey = "widget.script"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroup)
    }

    static var lastResult: String {
        get { defaults?.string(forKey: lastResultKey) ?? "" }
        set { defaults?.set(newValue, forKey: lastResultKey) }
    }

    static var lastCommand: String {
        get { defaults?.string(forKey: lastCommandKey) ?? "" }
        set { defaults?.set(newValue, forKey: lastCommandKey) }
    }

    static var lastUpdate: Date {
        get { defaults?.object(forKey: lastUpdateKey) as? Date ?? .distantPast }
        set { defaults?.set(newValue, forKey: lastUpdateKey) }
    }

    /// JS snippet the widget runs on timeline refresh. Defaults to the threes.day fetch.
    static var widgetScript: String {
        get {
            defaults?.string(forKey: widgetScriptKey) ?? """
            fetch('https://api.threes.day/live?ts='+Date.now()).then(r=>r.json()).then(d=>JSON.stringify(d)).catch(e=>''+e)
            """
        }
        set { defaults?.set(newValue, forKey: widgetScriptKey) }
    }
}
