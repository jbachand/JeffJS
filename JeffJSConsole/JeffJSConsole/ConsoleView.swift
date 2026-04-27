import SwiftUI
import Combine
import JeffJS

// MARK: - Console Line Model

struct ConsoleLine: Identifiable {
    let id = UUID()
    let level: String
    let text: String

    var color: Color {
        switch level {
        case "error": return .red
        case "warn": return .yellow
        case "info": return .cyan
        case "input": return .gray
        case "result": return .green
        default: return .white
        }
    }

    var prefix: String {
        switch level {
        case "input": return "> "
        case "result": return "< "
        case "error": return "[error] "
        case "warn": return "[warn] "
        case "info": return "[info] "
        default: return ""
        }
    }
}

// MARK: - Console View Model

@MainActor
final class ConsoleViewModel: ObservableObject {
    @Published var lines: [ConsoleLine] = []
    @Published var inputText: String = ""
    @Published var isReady = false
    @Published var suggestions: [String] = []
    @Published var suggestionIndex: Int = -1
    @Published var showResetConfirm = false

    private var env: JeffJSEnvironment?
    private var commandHistory: [String] = []
    private var historyIndex: Int = -1
    private var suggestionTask: Task<Void, Never>?

    /// Up-arrow recall list. Kept under the legacy key so existing installs
    /// don't lose their history on upgrade. (User-globals state lives in the
    /// snapshot file below — these are just strings for the recall buffer.)
    private static let commandHistoryKey = "jeffjs.persistedCommands"
    private static let maxCommandHistory = 50

    /// User-globals snapshot blob lives in the caches dir, not UserDefaults,
    /// because user state can grow large. Survives relaunches but is wiped
    /// when the OS evicts caches or the user explicitly resets.
    private static let snapshotURL: URL? = {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("JeffJSUserGlobals.json")
    }()

    private static let startupScripts = [
        """
        var t = () => {
            fetch('https://api.threes.day/live?ts='+Date.now())
            .then(results => results.json())
            .then(data => {
                console.log(JSON.stringify(data));
            })
            .catch(error => {
                console.error('Error fetching live data:', error);
            });
        };
        """,
    ]

    func setup() {
        guard env == nil else { return }
        // Defer heavy init so the UI + keyboard render first
        Task { @MainActor in
            // Yield to let the run loop process pending layout/animation
            try? await Task.sleep(nanoseconds: 100_000_000)
            createEnvironment()
            restoreUserGlobalsFromDisk()
            commandHistory = Self.loadCommandHistory()
        }
    }

    private func createEnvironment() {
        let config = JeffJSEnvironment.Configuration(
            startupScripts: Self.startupScripts
        )
        let environment = JeffJSEnvironment(configuration: config)
        environment.onConsoleMessage = { [weak self] level, message in
            self?.appendLine(level: level, text: message)
        }
        self.env = environment
        self.isReady = true
    }

    private static let banner = [
        "░░░░░░░░░░░▒░██▒▒░░                     ░▓▓█▓░░  ░",
        "░░░░░░░░░░▓█▓█░░▒░                      ░▒▓▓█▒▒▒▒░",
        "░░░░░░░░ ░░▓▒░░░   ░░░▒▒▒▒▒▒░░░░░       ░░░▒▓▓▓▓▒░",
        "░░░░░░░░░░▒▒ ░░  ░▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒░░    ░░░░▒▓▓▒▒",
        "░░░░░░░░ ▒▒░  ░ ░▒▓▓▓▓▓▓▓▓▓▒▒▒▒▒▒▒▒▒▒▒▓▒   ░▒▒▒▒▒",
        "░░░░░░░░░▓░░  ░░░▓▓▓▓▓▓▓▓▓▒▒▒▒▒▒▒▒▒▒▒▒▓██▓   ░▒▒▒▒",
        "░░░ ░░ ░░░░░░ ░▒▓▓▓▓▓▓▓▓▓▒▒▒▒▒▒▒▒▒▒▒▒▒▓███▓  ▒▓▓░░",
        "       ░▒░░░░░▒▓▓▓▓▓▓▓▓▓▒▓▒▒▒▒▒▒▒▒▒▒▒▒▓▓███░ ░▓░░░",
        "░░░░░░░▒░▒░░░▒▓▓▓▓▓▒▒▒░▒▒▒▒▒▒▒▒▒▒▒▒▒▒▓▓▓███▒░▒▓▓░",
        "░░▒▒░░░▓▒▒░░▒▓▓▓▓▓▓▓▒▒▒▒▒░░░░░▒▒▒▒▒▒▒▓▓▓███▒▒█▓░░░",
        "▒▒▒▒▒▒▒█▒▒▒░▓▓▓▓▓▓▓▓▒▒▒▒▒░▒▒▒▒▒▒▒░░░░░░░███▓▒█▓░░░",
        "▒▒▒▓▒▒▓▒░░░▓▓▓▓▓▓▓▒▒▒▒▒░░ ░░▓▓▒▒▒░░░░░░░░██▓▓▓░░░░",
        "▒▒▓▒▒▓▓▓▓▒▒▓▓▓▓▓▓▓▓▓▓▓▒▒▒░▒▒▓▒▒▒▓   ░░▒▒░▒█▓█▒░░░░",
        "▒▒▓░▒▒▒▒▓▓▓▓▓▓▓▓▓▓▓▓▒▒▒▒▒▒▓▓▓▒▒▒▓░    ░▒▒▓██▓░░░░░",
        "  ▓▒▒░▒▓▓▓▓▓▓▓▓▓▓▓▓▓▓▒▒▒▒▒▓▒▒▓▒▒██░░░▒███████▓░",
        "▒░▒▓▓▒▓▒▓▓▓▓▓▓▓▓▓▓▓▓▓▒▒▒▒▓▓░░▒▒▒▒█▒▒▒▒▓█████████▒",
        "░░ ░▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▒▒▒▒▒▒▒▒▒░ ░▒▒▒▒▒▓▓████░▒█▓▒",
        "▒▒░  ░▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▒▒▒▒▒▒▒▒▒▒▒▒░▒▒▓▓▓██▒░░░▒▓░",
        " ░░░░  ████▓▓▓▓▓▓▓▓▓▓▓▒▓▓▒▒▒▒▒▒▒▓█▓▒▒▓▓▓██▒▓░ ░░▓█",
        "░ ░░   ████▓▓▓▓▓▓▓▓▓▓▒░░░░░░░░░░▓▓██▓▓███▒▒░░░░░░░",
        "▓▒  ░▒▒████▓▓▓▓▓▓▓▓▓▓▒▓▓▒▒▒░▒▒▒▓░░▒███████▒░░░░░░░",
        "▓▓▓░▒▓███▓▓▓▓▓▓▓▓▓▓▓▓▒▒▒▒▒░░░░░░▒▒░▓█████▒░░░░░░░░",
        "▒▓█▓▓▓██▓▓▓▒▒▒▓▓▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒░▒▒▒▓▓█▓░░░░░░░░░░",
        "░▒██▒▓█▓▓▓▓▓▓▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▓▓▒▒▒▒▓▓░░░░░░░░░░░",
        "░▒▓▓▓██▓▓▓▓▓▓▓▒▒▒▒▒▒▒▒▒▒▒▒░░░░░▒▓▒▒▒▒▓░░░░░░░░░░░░",
        "▒▒▓▒ █▓▓▓▓▓▓▓▓▓▓▒▒▒▒░░░░░░░░░ ░░░▒▒▒▓█░░ ░░░░░░░░░",
        "░▒   █▓▓▓▓▓▓▓▓▓▓▓▒▒▒▒░░░░░     ░▒▒▒▒▓█░░░░ ░░░░░░░",
        "░    ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▒▒▒░░░   ░░░░░▒▒▒▓█░░░░░░░░░░░░",
        "░   ░▓▓▓▓▓▓▓▓▓▓▓▓▓▒▓▒▒▒░░░░░░░░░░░▒▒▓ ▒░░░░░░░░░░░",
        "    ░▓▓▓▓▓▓▓▓▓▓▓▓▓▒▒▒▒░░░░░░░░░░░░▒▒    ▒░░░░░░░░░",
        "    ░▓▓▓▓▓▓▓▓▓▓▓▓▒▒▒▒░░░░░░░░░░░░▒░     ▒  ░░░░░░░",
        "     ░▓▓▓▓▓▓▓▓▓▓▓▒▒▒▒░░░░░░░░░░░░░    ░ ░     ░▒░░",
        "      ░▓▓▓▓▓▓▓▓▒▒▒▒▒▒▒░░░░░░░░░░",
        "       ░▒▓▓▓▓▓▓▒▒▒▒▒░░░░░░▒░░░░",
        "         ░▒▒▓▓▒▒▒▒░▒░▒▒▒▒▒░░░░",
        "            ░▒▒▒▒░░░▒▒▒▒▒▒░░░",
        "",
        "            my name is jeff.",
    ].joined(separator: "\n")

    private func restoreUserGlobalsFromDisk() {
        appendLine(level: "info", text: Self.banner)
        guard let env,
              let url = Self.snapshotURL,
              let data = try? Data(contentsOf: url),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        let result = env.restoreUserGlobals(from: json)
        if result.restored > 0 {
            appendLine(level: "info", text: "Restored \(result.restored) global(s).")
        }
    }

    /// Snapshot every user-added global and write it to disk. Called after
    /// each successful eval. No commands are replayed on launch — the values
    /// are written directly back onto globalThis.
    private func persistUserGlobals() {
        guard let env, let url = Self.snapshotURL else { return }
        let snap = env.snapshotUserGlobals()
        if let data = snap.json.data(using: .utf8) {
            try? data.write(to: url, options: .atomic)
        }
        if !snap.skipped.isEmpty {
            // Surface the first skipped name (most recent eval is the likely cause)
            // so the user knows their function/native binding wasn't persisted.
            for entry in snap.skipped where entry.key.firstIndex(of: ".") == nil
                                           && entry.key.firstIndex(of: "[") == nil
                                           && entry.key.firstIndex(of: "<") == nil {
                appendLine(level: "warn",
                           text: "‘\(entry.key)’ won’t persist (\(entry.why))")
                break
            }
        }
    }

    func evaluate() {
        let raw = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }

        let input = Self.straightenQuotes(raw)
        commandHistory.append(input)
        historyIndex = -1
        inputText = ""
        suggestions = []
        suggestionIndex = -1

        Self.saveCommandHistory(commandHistory)
        appendLine(level: "input", text: input)

        guard let env else { return }
        let result = env.eval(input)
        switch result {
        case .success(let str):
            if let str, str != "undefined" {
                appendLine(level: "result", text: str)
            }
            // Refresh the on-disk snapshot so the new binding survives relaunch.
            persistUserGlobals()
        case .exception(let msg):
            appendLine(level: "error", text: msg)
        }
    }

    func resetContext() {
        env?.teardown()
        env = nil
        lines.removeAll()
        commandHistory.removeAll()
        historyIndex = -1
        suggestions = []
        suggestionIndex = -1
        Self.saveCommandHistory([])
        if let url = Self.snapshotURL {
            try? FileManager.default.removeItem(at: url)
        }
        createEnvironment()
        appendLine(level: "info", text: "Context reset. JeffJS ready.")
    }

    // MARK: - Persistence

    private static func loadCommandHistory() -> [String] {
        UserDefaults.standard.stringArray(forKey: commandHistoryKey) ?? []
    }

    private static func saveCommandHistory(_ commands: [String]) {
        let trimmed = Array(commands.suffix(maxCommandHistory))
        UserDefaults.standard.set(trimmed, forKey: commandHistoryKey)
    }

    // MARK: - History

    func historyUp() {
        if !suggestions.isEmpty {
            suggestionIndex = max(0, suggestionIndex - 1)
            return
        }
        guard !commandHistory.isEmpty else { return }
        if historyIndex < 0 {
            historyIndex = commandHistory.count - 1
        } else if historyIndex > 0 {
            historyIndex -= 1
        }
        inputText = commandHistory[historyIndex]
    }

    func historyDown() {
        if !suggestions.isEmpty {
            if suggestionIndex < min(suggestions.count, 50) - 1 {
                suggestionIndex += 1
            } else {
                suggestions = []
                suggestionIndex = -1
            }
            return
        }
        guard historyIndex >= 0 else { return }
        if historyIndex < commandHistory.count - 1 {
            historyIndex += 1
            inputText = commandHistory[historyIndex]
        } else {
            historyIndex = -1
            inputText = ""
        }
    }

    // MARK: - Autocomplete

    func updateSuggestions() {
        suggestionTask?.cancel()
        let input = inputText
        guard input.contains(".") else {
            suggestions = []
            suggestionIndex = -1
            return
        }
        suggestionTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000) // 150ms debounce
            guard !Task.isCancelled, let env else { return }
            guard let dotIndex = input.lastIndex(of: ".") else {
                suggestions = []
                suggestionIndex = -1
                return
            }
            let objectExpr = String(input[input.startIndex..<dotIndex])
            let afterDot = String(input[input.index(after: dotIndex)...])
            guard !objectExpr.isEmpty, Double(objectExpr) == nil else {
                suggestions = []
                suggestionIndex = -1
                return
            }
            suggestions = env.consoleCompletions(objectExpr: objectExpr, partial: afterDot)
            suggestionIndex = -1
        }
    }

    func applySuggestion(_ suggestion: String) {
        guard let dotIndex = inputText.lastIndex(of: ".") else { return }
        inputText = String(inputText[inputText.startIndex...dotIndex]) + suggestion
        suggestions = []
        suggestionIndex = -1
    }

    func tabComplete() {
        guard !suggestions.isEmpty else { return }
        let idx = suggestionIndex >= 0 ? suggestionIndex : 0
        if idx < suggestions.count {
            applySuggestion(suggestions[idx])
        }
    }

    func dismissSuggestions() {
        suggestions = []
        suggestionIndex = -1
    }

    /// Peek-ahead text shown inline after cursor.
    var inlineSuggestion: String? {
        guard !suggestions.isEmpty else { return nil }
        let idx = suggestionIndex >= 0 ? suggestionIndex : 0
        guard idx < suggestions.count,
              let dotIndex = inputText.lastIndex(of: ".") else { return nil }
        let afterDot = String(inputText[inputText.index(after: dotIndex)...])
        let full = suggestions[idx]
        guard full.hasPrefix(afterDot), full.count > afterDot.count else { return nil }
        return String(full.dropFirst(afterDot.count))
    }

    func teardown() {
        env?.teardown()
        env = nil
    }

    private func appendLine(level: String, text: String) {
        lines.append(ConsoleLine(level: level, text: text))
    }

    private static func straightenQuotes(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{2018}", with: "'")
         .replacingOccurrences(of: "\u{2019}", with: "'")
         .replacingOccurrences(of: "\u{201C}", with: "\"")
         .replacingOccurrences(of: "\u{201D}", with: "\"")
    }
}

// MARK: - Console View

struct ConsoleView: View {
    @StateObject private var vm = ConsoleViewModel()

    var body: some View {
        VStack(spacing: 0) {
            // Output area
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(vm.lines) { line in
                            Text(line.prefix + line.text)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(line.color)
                                .textSelection(.enabled)
                                .id(line.id)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .onChange(of: vm.lines.count) {
                    scrollToBottom(proxy: proxy)
                }
                #if os(iOS)
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        scrollToBottom(proxy: proxy)
                    }
                }
                #endif
            }

            // Suggestions dropdown
            if !vm.suggestions.isEmpty {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(vm.suggestions.prefix(50).enumerated()), id: \.offset) { idx, suggestion in
                            Button {
                                vm.applySuggestion(suggestion)
                            } label: {
                                Text(suggestion)
                                    .font(.system(.caption2, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 3)
                                    .background(idx == vm.suggestionIndex ? Color.accentColor.opacity(0.2) : Color.clear)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 120)
                .background(Color(white: 0.08))
            }

            Divider()

            // Syntax toolbar
            JSKeyboardToolbar(text: $vm.inputText)

            Divider()

            // Input area with peek-ahead
            HStack(spacing: 4) {
                Button {
                    vm.showResetConfirm = true
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                }
                .buttonStyle(.plain)

                Text(">")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.green)

                ZStack(alignment: .leading) {
                    if let ghost = vm.inlineSuggestion {
                        HStack(spacing: 0) {
                            Text(vm.inputText)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(.clear)
                            Text(ghost)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(.gray.opacity(0.4))
                        }
                    }

                    #if os(iOS)
                    ConsoleTextField(
                        text: $vm.inputText,
                        onSubmit: { vm.evaluate() },
                        onUpArrow: { vm.historyUp() },
                        onDownArrow: { vm.historyDown() },
                        onTab: { vm.tabComplete() },
                        onEscape: { vm.dismissSuggestions() }
                    )
                    .frame(height: 28)
                    #else
                    TextField("JavaScript", text: $vm.inputText)
                        .font(.system(size: 13, design: .monospaced))
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .onSubmit { vm.evaluate() }
                        .onKeyPress(.upArrow) { vm.historyUp(); return .handled }
                        .onKeyPress(.downArrow) { vm.historyDown(); return .handled }
                        .onKeyPress(.tab) { vm.tabComplete(); return .handled }
                        .onKeyPress(.escape) { vm.dismissSuggestions(); return .handled }
                    #endif
                }
                .disabled(!vm.isReady)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .confirmationDialog("Reset JS Context?", isPresented: $vm.showResetConfirm, titleVisibility: .visible) {
            Button("Reset Context", role: .destructive) {
                vm.resetContext()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will clear all variables, functions, and command history.")
        }
        .onChange(of: vm.inputText) {
            vm.updateSuggestions()
        }
        .task {
            vm.setup()
        }
        .onDisappear {
            vm.teardown()
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        if let last = vm.lines.last {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}

// MARK: - JS Keyboard Toolbar

struct JSKeyboardToolbar: View {
    @Binding var text: String
    @State private var row: Int = 3

    // Rows 0-2: insert/append mode
    private static let insertRows: [[(label: String, insert: String)]] = [
        [("(", "("), (")", ")"), ("{", "{"), ("}", "}"),
         ("[", "["), ("]", "]"), (";", ";"), (":", ":"),
         (".", "."), (",", ","), ("=", "="), ("+", "+"),
         ("-", "-"), ("*", "*"), ("/", "/"), ("!", "!"),
         ("&", "&"), ("|", "|"), ("?", "?"), ("'", "'"), ("\"", "\"")],
        [("var", "var "), ("let", "let "), ("const", "const "),
         ("function", "function "), ("=>", "=> "), ("return", "return "),
         ("if", "if ("), ("else", "else "), ("for", "for ("),
         ("while", "while ("), ("new", "new "), ("this", "this"),
         ("typeof", "typeof "), ("null", "null"), ("undefined", "undefined")],
        [("console.log(", "console.log("), ("true", "true"), ("false", "false"),
         ("===", "=== "), ("!==", "!== "), ("&&", "&& "), ("||", "|| "),
         ("() => {}", "() => {}"), (".map(", ".map("), (".filter(", ".filter("),
         (".forEach(", ".forEach("), ("JSON.stringify(", "JSON.stringify("),
         ("JSON.parse(", "JSON.parse("), ("document.", "document."),
         ("window.", "window.")],
    ]

    // Row 3: examples (replace mode)
    private static let examples: [(label: String, code: String)] = [
        ("fetch", "fetch('https://).then(r=>r.json()).then(d=>console.log(JSON.stringify(d))).catch(e=>console.error(e))"),
        ("Shor's", "window.jeffjs.quantum.simulator.shorFactor(143).then((t)=>{console.log(JSON.stringify(t));})"),
        ("DOM create", "var d = document.createElement('div'); d.innerHTML = '<h1>Hello JeffJS</h1>'; document.body.appendChild(d); d.outerHTML"),
        ("querySelector", "document.querySelector('body').children.length"),
        ("Promise", "new Promise((resolve) => { setTimeout(() => resolve('done!'), 500) }).then(r => console.log(r))"),
        ("Math", "Array.from({length:10}, (_,i) => Math.round(Math.sin(i) * 100) / 100)"),
        ("Fibonacci", "[...Array(15)].reduce((a,_,i) => (a.push(i<2?i:a[i-1]+a[i-2]),a),[]).join(', ')"),
        ("Object keys", "Object.keys(window).sort().slice(0,20).join(', ')"),
        ("Date", "new Date().toISOString()"),
        ("Load React", "var React = await import('https://unpkg.com/react@18/umd/react.production.min.js');"),
    ]

    private static let rowLabels = ["{ }", "kw", "fn", "ex"]
    private static let rowCount = 4

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if row < Self.insertRows.count {
                        // Insert mode rows
                        ForEach(Self.insertRows[row], id: \.label) { item in
                            Button {
                                text += item.insert
                            } label: {
                                Text(item.label)
                                    .font(.system(size: 14, design: .monospaced))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(Color(white: 0.2))
                                    .foregroundColor(.white)
                                    .cornerRadius(5)
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        // Examples row - replaces text
                        ForEach(Self.examples, id: \.label) { item in
                            Button {
                                text = item.code
                            } label: {
                                Text(item.label)
                                    .font(.system(size: 13))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.blue.opacity(0.25))
                                    .foregroundColor(.cyan)
                                    .cornerRadius(5)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            .frame(height: 36)

            HStack(spacing: 12) {
                ForEach(0..<Self.rowCount, id: \.self) { i in
                    Button {
                        row = i
                    } label: {
                        Text(Self.rowLabels[i])
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(row == i ? .green : .gray)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
        }
        .background(Color(white: 0.1))
    }
}

// MARK: - iOS Console TextField (UIViewRepresentable)

#if os(iOS)
struct ConsoleTextField: UIViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void
    var onUpArrow: () -> Void
    var onDownArrow: () -> Void
    var onTab: (() -> Void)?
    var onEscape: (() -> Void)?

    func makeUIView(context: Context) -> ConsoleUITextField {
        let field = ConsoleUITextField()
        field.delegate = context.coordinator
        field.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.returnKeyType = .go
        field.placeholder = "JavaScript…"
        field.textColor = .white
        field.backgroundColor = .clear
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.onUpArrow = onUpArrow
        field.onDownArrow = onDownArrow
        field.onTab = onTab
        field.onEscape = onEscape
        // Auto-focus after engine init settles
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { field.becomeFirstResponder() }
        return field
    }

    func updateUIView(_ uiView: ConsoleUITextField, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
        uiView.onUpArrow = onUpArrow
        uiView.onDownArrow = onDownArrow
        uiView.onTab = onTab
        uiView.onEscape = onEscape
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        let parent: ConsoleTextField
        init(parent: ConsoleTextField) { self.parent = parent }

        func textFieldDidChangeSelection(_ textField: UITextField) {
            parent.text = textField.text ?? ""
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSubmit()
            return false
        }
    }
}

/// UITextField subclass that intercepts arrow/tab/escape keys.
final class ConsoleUITextField: UITextField {
    var onUpArrow: (() -> Void)?
    var onDownArrow: (() -> Void)?
    var onTab: (() -> Void)?
    var onEscape: (() -> Void)?

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            switch press.key?.keyCode {
            case .keyboardUpArrow:
                onUpArrow?()
                return
            case .keyboardDownArrow:
                onDownArrow?()
                return
            case .keyboardTab:
                onTab?()
                return
            case .keyboardEscape:
                onEscape?()
                return
            default:
                break
            }
        }
        super.pressesBegan(presses, with: event)
    }
}
#endif
