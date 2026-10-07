// Unminify.swift — jeffjs-cli's JS unminifier commands (JeffJSUnminifier).
//
//   jeffjs-cli --unminify <file.js> [--out <path>] [--map] [--rename]
//              [--at <line>:<col> [--context N]] [--indent N] [--width N]
//              [--pos-comments N] [--check]
//   jeffjs-cli --unminify-stack <file.js> --stack "<Error.stack text>" [--stack-url <url>]
//
// --unminify     prints the formatted file (or writes it to --out).
// --map          also writes the position map (one line per run of tokens:
//                `origLine:origCol<TAB>formattedLine:formattedCol`) to
//                `<out>.map.tsv`, or to stderr without --out.
// --at L:C       prints only the formatted excerpt around the ORIGINAL
//                position L:C (±--context lines, default 6), the target line
//                marked with `>`, then the enclosing function's first line.
// --check        formats, re-tokenizes the output and compares the token
//                sequence with the source's; prints sizes, timing, result.
// --unminify-stack rewrites every `url:line:col` frame whose URL names this
//                file (same last path component, query ignored; or exactly
//                --stack-url) to `... -> unminified L:C` + the formatted line.
// --rename       is accepted but not implemented (scope-correct renaming of
//                minified locals needs a scope analysis the token printer does
//                not have); the output is the same as without it.

import Foundation
import JeffJS

private func cliArg(_ args: [String], _ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

private func stderrLine(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

/// Runs the unminify commands when present; returns the exit status, or nil
/// when the arguments are not an unminify command.
func cliUnminifyMain(_ args: [String]) -> Int32? {
    let isStack = args.contains("--unminify-stack")
    guard isStack || args.contains("--unminify") else { return nil }
    guard let path = cliArg(args, isStack ? "--unminify-stack" : "--unminify") else {
        stderrLine("usage: jeffjs-cli --unminify <file.js> [--out <path>] [--map] [--at <line>:<col> [--context N]] [--check]\n"
                   + "       jeffjs-cli --unminify-stack <file.js> --stack \"<Error.stack text>\" [--stack-url <url>]")
        return 2
    }
    guard let data = FileManager.default.contents(atPath: path) else {
        stderrLine("cannot read \(path)"); return 2
    }
    var options = JeffJSUnminifyOptions()
    if let v = cliArg(args, "--indent").flatMap(Int.init) { options.indentWidth = v }
    if let v = cliArg(args, "--width").flatMap(Int.init) { options.maxLineLength = max(20, v) }
    if let v = cliArg(args, "--pos-comments").flatMap(Int.init) { options.positionCommentEvery = max(0, v) }
    if args.contains("--rename") {
        stderrLine("note: --rename is not implemented (needs scope analysis); output is unrenamed")
    }
    let source = String(decoding: data, as: UTF8.self)
    let t0 = CFAbsoluteTimeGetCurrent()
    let r = JeffJSUnminifier.format(source, options: options)
    let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
    if !r.ok { stderrLine("warning: \(path) did not tokenize (\(r.error ?? "?")); output is the source unchanged") }

    if isStack {
        guard let stack = cliArg(args, "--stack") else { stderrLine("--unminify-stack needs --stack \"<text>\""); return 2 }
        let exact = cliArg(args, "--stack-url")
        let base = (path as NSString).lastPathComponent
        let rewritten = r.rewriteStack(stack) { url in
            if let exact { return url == exact }
            var u = Substring(url)
            if let q = u.firstIndex(where: { $0 == "?" || $0 == "#" }) { u = u[..<q] }
            return u.split(separator: "/").last.map(String.init) == base || String(u) == path
        }
        print(rewritten)
        return 0
    }

    if args.contains("--check") {
        let t1 = CFAbsoluteTimeGetCurrent()
        let a = JeffJSUnminifier.tokenSignature(source)
        let b = JeffJSUnminifier.tokenSignature(r.text)
        let same = a.error == nil && b.error == nil && a.types == b.types && a.texts == b.texts
        var firstDiff = ""
        if !same {
            let n = min(a.types.count, b.types.count)
            var k = 0
            while k < n, a.types[k] == b.types[k], a.texts[k] == b.texts[k] { k += 1 }
            firstDiff = " first difference at token \(k): \(k < a.texts.count ? String(a.texts[k].prefix(40)) : "<end>") vs \(k < b.texts.count ? String(b.texts[k].prefix(40)) : "<end>")"
                + (a.error.map { " srcErr=\($0)" } ?? "") + (b.error.map { " outErr=\($0)" } ?? "")
        }
        print(String(format: "%@\t%d bytes -> %d bytes, %d lines -> %d lines, %d tokens, %d functions, format %.1f ms, map+text %.1f MB, tokens %@ (check %.0f ms)%@",
                     path, data.count, r.text.utf8.count, r.originalLineCount, r.formattedLineCount, r.tokenCount,
                     r.functionCount, ms, Double(r.memoryFootprint) / 1_048_576, same ? "IDENTICAL" : "DIFFER",
                     (CFAbsoluteTimeGetCurrent() - t1) * 1000, firstDiff))
        return same && r.ok ? 0 : 1
    }

    if let at = cliArg(args, "--at") {
        let parts = at.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { stderrLine("--at wants <line>:<col>"); return 2 }
        let context = cliArg(args, "--context").flatMap(Int.init) ?? 6
        guard let ex = r.excerpt(originalLine: parts[0], column: parts[1], context: context) else {
            stderrLine("position \(at) is outside \(path)"); return 1
        }
        print("\(path):\(parts[0]):\(parts[1]) -> unminified \(ex.targetLine):\(ex.targetColumn)")
        let width = String(ex.firstLine + ex.lines.count).count
        for (k, line) in ex.lines.enumerated() {
            let n = ex.firstLine + k
            let num = String(repeating: " ", count: max(0, width - String(n).count)) + String(n)
            print("\(n == ex.targetLine ? ">" : " ") \(num) | \(line)")
            if n == ex.targetLine {
                print("  " + String(repeating: " ", count: width) + " | " + String(repeating: " ", count: max(0, ex.targetColumn - 1)) + "^")
            }
        }
        if let fn = r.enclosingFunction(originalLine: parts[0], column: parts[1]) {
            let lines = fn.text.split(separator: "\n", omittingEmptySubsequences: false)
            print("enclosing function: line \(fn.firstLine), \(lines.count) lines: \(lines.first.map { String($0.prefix(100)) } ?? "")")
        }
        return 0
    }

    let outPath = cliArg(args, "--out")
    if let outPath {
        do { try r.text.write(toFile: outPath, atomically: true, encoding: .utf8) }
        catch { stderrLine("cannot write \(outPath): \(error)"); return 2 }
        stderrLine(String(format: "%@ -> %@ (%d -> %d bytes, %d lines, %.1f ms)", path, outPath,
                          data.count, r.text.utf8.count, r.formattedLineCount, ms))
    } else {
        FileHandle.standardOutput.write(r.text.data(using: .utf8)!)
    }
    if args.contains("--map") {
        var lines: [String] = []
        for (o, f) in r.mapRuns() {
            guard let a = r.originalLineColumn(offset: o), let b = r.formattedLineColumn(offset: f) else { continue }
            lines.append("\(a.line):\(a.column)\t\(b.line):\(b.column)")
        }
        let text = lines.joined(separator: "\n") + "\n"
        if let outPath {
            try? text.write(toFile: outPath + ".map.tsv", atomically: true, encoding: .utf8)
        } else {
            FileHandle.standardError.write(text.data(using: .utf8)!)
        }
    }
    return r.ok ? 0 : 1
}
