import SwiftUI
import Combine
import JeffJS
import WidgetKit

// MARK: - Console Line

struct WatchConsoleLine: Identifiable {
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
        case "error": return "! "
        case "warn": return "⚠ "
        default: return ""
        }
    }
}

// MARK: - View Model

@MainActor
final class WatchConsoleViewModel: ObservableObject {
    @Published var lines: [WatchConsoleLine] = []
    @Published var inputText: String = ""
    @Published var isReady = false
    @Published var showResetConfirm = false

    private var env: JeffJSEnvironment?
    private var commandHistory: [String] = []

    /// Up-arrow recall list. Kept under the legacy key for back-compat —
    /// user-globals state lives in the on-disk snapshot file.
    private static let commandHistoryKey = "jeffjs.persistedCommands"
    private static let maxCommandHistory = 30

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
        createEnvironment()
        restoreUserGlobalsFromDisk()
        commandHistory = Self.loadCommandHistory()
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

    private func restoreUserGlobalsFromDisk() {
        appendLine(level: "info", text: "my name is jeff.")
        guard let env,
              let url = Self.snapshotURL,
              let data = try? Data(contentsOf: url),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        let result = env.restoreUserGlobals(from: json)
        if result.restored > 0 {
            appendLine(level: "info", text: "Restored \(result.restored) global(s)")
        }
    }

    /// Snapshot user globals to disk after a successful eval. No commands are
    /// replayed on launch — values are written directly back onto globalThis.
    private func persistUserGlobals() {
        guard let env, let url = Self.snapshotURL else { return }
        let snap = env.snapshotUserGlobals()
        if let data = snap.json.data(using: .utf8) {
            try? data.write(to: url, options: .atomic)
        }
        if !snap.skipped.isEmpty {
            for entry in snap.skipped where entry.key.firstIndex(of: ".") == nil
                                           && entry.key.firstIndex(of: "[") == nil
                                           && entry.key.firstIndex(of: "<") == nil {
                appendLine(level: "warn", text: "‘\(entry.key)’ won’t persist")
                break
            }
        }
    }

    func evaluate() {
        let raw = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        inputText = ""

        let input = Self.straightenQuotes(raw)
        commandHistory.append(input)
        Self.saveCommandHistory(commandHistory)

        appendLine(level: "input", text: input)

        guard let env else { return }
        let result = env.eval(input)
        switch result {
        case .success(let str):
            if let str, str != "undefined" {
                appendLine(level: "result", text: str)
                SharedConsoleData.lastResult = str
                SharedConsoleData.lastCommand = input
                SharedConsoleData.lastUpdate = .now
                WidgetCenter.shared.reloadAllTimelines()
            }
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
        Self.saveCommandHistory([])
        if let url = Self.snapshotURL {
            try? FileManager.default.removeItem(at: url)
        }
        createEnvironment()
        appendLine(level: "info", text: "Context reset.")
    }

    private static func straightenQuotes(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{2018}", with: "'")
         .replacingOccurrences(of: "\u{2019}", with: "'")
         .replacingOccurrences(of: "\u{201C}", with: "\"")
         .replacingOccurrences(of: "\u{201D}", with: "\"")
    }

    func teardown() {
        env?.teardown()
        env = nil
    }

    private func appendLine(level: String, text: String) {
        lines.append(WatchConsoleLine(level: level, text: text))
        if lines.count > 50 {
            lines.removeFirst(lines.count - 50)
        }
    }

    private static func loadCommandHistory() -> [String] {
        UserDefaults.standard.stringArray(forKey: commandHistoryKey) ?? []
    }

    private static func saveCommandHistory(_ commands: [String]) {
        let trimmed = Array(commands.suffix(maxCommandHistory))
        UserDefaults.standard.set(trimmed, forKey: commandHistoryKey)
    }
}

// MARK: - Console View

struct ContentView: View {
    @StateObject private var vm = WatchConsoleViewModel()

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 25)
            // Output
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(vm.lines) { line in
                            Text(line.prefix + line.text)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(line.color)
                                .id(line.id)
                                //.padding(.leading, line.level == "input" ? 0 : 20) //todo: make this so top 3 lines have indent
                        }
                    }
                    .padding(.top, 6)
                }
                .onChange(of: vm.lines.count) {
                    if let last = vm.lines.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }.padding(.horizontal, 5)
            // Syntax toolbar
            WatchJSToolbar(text: $vm.inputText)
                .padding(.vertical, 1)

            // Input + reset button
            // TODO: make this not as tall
            HStack(spacing: 2) {
                Spacer().frame(width: 5)
                Button {
                    vm.showResetConfirm = true
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 8))
                        .foregroundColor(.gray)
                }
                .buttonStyle(.plain)
                .frame(width: 15)

                TextField("JS", text: $vm.inputText)
                    .font(.system(size: 9, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit { vm.evaluate() }
                    .disabled(!vm.isReady)
                Button {
                    $vm.inputText.wrappedValue = ""
                } label: {
                    Image(systemName: "x.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                        
                }
                .buttonStyle(.plain)
                .padding(.leading, -5)
                .padding(.top, -25)
                
                Button {
                    vm.evaluate()
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.blue)
                        .padding(8)
                }
                .buttonStyle(CompactGlassButtonStyle())
                .padding(.leading, 5)
                
                    
                Spacer().frame(width: 10)
            }
            Spacer().frame(height: 5)
             
        }
        .ignoresSafeArea()
        .confirmationDialog("Reset Context?", isPresented: $vm.showResetConfirm, titleVisibility: .visible) {
            Button("Reset", role: .destructive) {
                vm.resetContext()
            }
            Button("Cancel", role: .cancel) {}
        }
        .task {
            vm.setup()
        }
    }
}

// MARK: - Watch JS Toolbar

struct WatchJSToolbar: View {
    @Binding var text: String
    @State private var row: Int = 2

    private static let insertRows: [[(label: String, insert: String)]] = [
        [("(", "("), (")", ")"), ("{", "{"), ("}", "}"),
         ("[", "["), ("]", "]"), (";", ";"), (".", "."),
         ("=", "="), ("'", "'"), ("\"", "\""), ("+", "+")],
        [("var ", "var "), ("let ", "let "), ("const ", "const "),
         ("log(", "console.log("), ("fn ", "function "),
         ("=>", "=> "), ("if(", "if ("), ("for(", "for ("),
         ("true", "true"), ("false", "false"), ("null", "null")],
    ]

    private static let examples: [(label: String, code: String)] = [
        ("React", "var React = await import('https://unpkg.com/react@18/umd/react.production.min.js');"),
        ("Shor's", "window.jeffjs.quantum.simulator.shorFactor(143).then((t)=>{console.log(JSON.stringify(t));})"),
        ("fetch", "fetch('https://').then(r=>r.json()).then(d=>console.log(JSON.stringify(d))).catch(e=>console.error(e))"),
        ("DOM", "document.createElement('div').tagName"),
        ("Date", "new Date().toISOString()"),
        ("Math", "Math.round(Math.random()*100)"),
    ]

    private static let rowLabels = ["{ }", "kw", "ex"]
    private static let rowCount = 3

    var body: some View {
        VStack(spacing: 1) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    if row < Self.insertRows.count {
                        ForEach(Self.insertRows[row], id: \.label) { item in
                            Button {
                                text += item.insert
                            } label: {
                                Text(item.label)
                                    .font(.system(size: 9, design: .monospaced))
                                    .padding(.horizontal, 3)
                                    .padding(.vertical, 1)
                                    .background(Color(white: 0.25))
                                    .cornerRadius(2)
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        ForEach(Self.examples, id: \.label) { item in
                            Button {
                                text = item.code
                            } label: {
                                Text(item.label)
                                    .font(.system(size: 9))
                                    .padding(.horizontal, 3)
                                    .padding(.vertical, 1)
                                    .background(Color.blue.opacity(0.3))
                                    .foregroundColor(.cyan)
                                    .cornerRadius(2)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            HStack(spacing: 6) {
                ForEach(0..<Self.rowCount, id: \.self) { i in
                    Button {
                        row = i
                    } label: {
                        Text(Self.rowLabels[i])
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundColor(row == i ? .green : .gray)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
        }
    }
}

// MARK: - Compact Glass Styles

/// A compact button style that preserves the Liquid Glass appearance
/// but uses minimal padding so the input row stays short on watchOS.
struct CompactGlassButtonStyle: ButtonStyle {
    var horizontalPadding: CGFloat = 6
    var verticalPadding: CGFloat = 2

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .glassEffect(in: Capsule())
            .opacity(configuration.isPressed ? 0.6 : 1.0)
    }
}

