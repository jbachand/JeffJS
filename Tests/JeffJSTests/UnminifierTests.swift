// UnminifierTests.swift
// JeffJS — JeffJSUnminifier: the formatted text tokenizes to the same tokens,
// compiles to the same bytecode (positions aside) and runs the same; ASI,
// templates, regex literals, the position map, excerpts, stack rewriting,
// the script-source registry and the console caller location.
//
// Usage:
//   swift test -c release --filter UnminifierTests

import XCTest
@testable import JeffJS

@MainActor
final class UnminifierTests: XCTestCase {

    // MARK: helpers

    /// Formats `src`, checks the token round trip and returns the result.
    @discardableResult
    private func roundTrip(_ src: String, _ options: JeffJSUnminifyOptions = JeffJSUnminifyOptions(),
                           file: StaticString = #filePath, line: UInt = #line) -> JeffJSUnminified {
        let r = JeffJSUnminifier.format(src, options: options)
        XCTAssertTrue(r.ok, "did not tokenize: \(r.error ?? "")", file: file, line: line)
        let a = JeffJSUnminifier.tokenSignature(src)
        let b = JeffJSUnminifier.tokenSignature(r.text)
        XCTAssertNil(b.error, "formatted text does not tokenize", file: file, line: line)
        XCTAssertEqual(a.types, b.types, "token types differ for:\n\(src)\n---\n\(r.text)", file: file, line: line)
        XCTAssertEqual(a.texts, b.texts, "token texts differ for:\n\(src)\n---\n\(r.text)", file: file, line: line)
        return r
    }

    /// Position-free bytecode hash of `src` (every body compiled).
    private func codeHash(_ env: JeffJSEnvironment, _ src: String) -> UInt64? {
        let r = env.compileOnly(src, filename: "<hash>", hashBytecode: true, positionFree: true)
        XCTAssertNil(r.error, "compile error: \(r.error ?? "")")
        return r.bytecodeHash
    }

    private func evaluate(_ env: JeffJSEnvironment, _ src: String, filename: String = "<eval>") -> String? {
        switch env.eval(src, filename: filename) {
        case .success(let v): return v
        case .exception(let m): return "THROW " + m
        }
    }

    /// Runs `src` in a fresh environment; returns console output + the
    /// completion value (or the exception text).
    private func run(_ src: String) -> String {
        var out: [String] = []
        let env = JeffJSEnvironment()
        env.onConsoleMessage = { _, msg in out.append(msg) }
        let v = evaluate(env, src)
        out.append("=> \(v ?? "<nil>")")
        return out.joined(separator: "\n")
    }

    private static let fixtures = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("rn_fixtures")
    private static let bundles = [
        "homedepot-plp/module-bundles/133_Page.652cdc261c8544439097.js.bundle.js",
        "lowes/r/019_vendors.59f0b394.js",
        "nfl/r/041_page-a234d11d532c7f17.js",
    ]

    // MARK: real bundles

    /// The three real bundles: identical tokens, identical bytecode (positions
    /// aside), formatted in well under a second (release), position map spot check.
    func testRealBundlesRoundTrip() throws {
        var found = 0
        for rel in Self.bundles {
            let url = Self.fixtures.appendingPathComponent(rel)
            guard let data = FileManager.default.contents(atPath: url.path) else { continue }
            found += 1
            let src = String(decoding: data, as: UTF8.self)
            let t0 = CFAbsoluteTimeGetCurrent()
            let r = JeffJSUnminifier.format(src)
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            XCTAssertTrue(r.ok, rel)
            let a = JeffJSUnminifier.tokenSignature(src)
            let b = JeffJSUnminifier.tokenSignature(r.text)
            XCTAssertEqual(a.types.count, b.types.count, rel)
            XCTAssertTrue(a.types == b.types && a.texts == b.texts, "\(rel): token sequence differs")
            #if !DEBUG
            XCTAssertLessThan(ms, 1000, "\(rel): \(data.count) bytes formatted in \(Int(ms)) ms")
            #endif
            print(String(format: "[unminify] %@: %d -> %d bytes, %d lines, %d tokens, %.1f ms, %.1f MB held",
                         rel, data.count, r.text.utf8.count, r.formattedLineCount, r.tokenCount, ms,
                         Double(r.memoryFootprint) / 1_048_576))

            // Position map: every 997th token of the original lands on the
            // same token text in the formatted output, and back.
            let srcBytes = Array(src.utf8), outBytes = Array(r.text.utf8)
            var checked = 0
            let runs = r.mapRuns()
            for o in stride(from: 0, to: runs.count - 1, by: 97) {
                let orig = runs[o].original
                guard let (l, c) = r.originalLineColumn(offset: orig),
                      let (fl, fc) = r.formattedPosition(line: l, column: c),
                      let fo = r.formattedOffsetOf(line: fl, column: fc) else { XCTFail("unmapped"); continue }
                // Within a run the delta is constant: the bytes up to the next run match.
                let n = min(12, runs[o + 1].original - orig, outBytes.count - fo)
                if n <= 0 || srcBytes[orig] == 0x20 || srcBytes[orig] == 0x0A { continue }
                XCTAssertEqual(Array(srcBytes[orig ..< orig + n]), Array(outBytes[fo ..< fo + n]), "\(rel) @\(l):\(c)")
                if let (bl, bc) = r.originalPosition(line: fl, column: fc) {
                    XCTAssertEqual(bl, l); XCTAssertEqual(bc, c)
                }
                checked += 1
                if checked > 400 { break }
            }
        }
        if found == 0 { throw XCTSkip("no ~/rn_fixtures bundles on this machine") }
    }

    func testRealBundlesSameBytecode() throws {
        let env = JeffJSEnvironment()
        env.lazyFunctions = false
        var found = 0
        for rel in Self.bundles {
            let url = Self.fixtures.appendingPathComponent(rel)
            guard let data = FileManager.default.contents(atPath: url.path) else { continue }
            found += 1
            let src = String(decoding: data, as: UTF8.self)
            let r = JeffJSUnminifier.format(src)
            XCTAssertEqual(codeHash(env, src), codeHash(env, r.text), "\(rel): bytecode differs")
        }
        if found == 0 { throw XCTSkip("no ~/rn_fixtures bundles on this machine") }
    }

    // MARK: ASI

    func testASIHazardsKeepMeaning() {
        let cases: [String] = [
            "var a=1,b=2,c=3\na\n++b\nc;[a,b,c].join()",
            "function f(){return\n42}; String(f())",
            "function g(){return(\n42)}; g()",
            "var x=function(){return 7}\n(function(){return 1})\n; typeof x",
            "var y=[1,2]\n[0]\n; String(y)",
            "var t=String.raw\n`a${1}`\n; t",
            "var i=0;for(;;){if(++i>3)break\n}i",
            "var k=0;a:for(;;){k++\nbreak a\n}k",
            "function* h(){yield\n1}; String(h().next().value)",
            "var o={a:1}\nvar p=o.a\n-1\n;p",
            "var s='x'\n;/re/g.test(s)",
            "let q=1\nlet r=2\nq+r",
            "var u=1;u\n--\nu;u",
            "var n=1;n++\n;n",
            "throw0=1;try{throw new Error('e'+\n1)}catch(e){e.message}",
            "async function af(){return await\n1}; typeof af",
            "var obj={get\nx(){return 5}}; obj.x",
            "var v = 1 /*\n*/ + 2; v",
            "var w=function(){return 2}\n/*c*/(w)\n;w",
        ]
        let env = JeffJSEnvironment()
        env.lazyFunctions = false
        for src in cases {
            let r = roundTrip(src)
            XCTAssertEqual(run(src), run(r.text), "runs differently:\n\(src)\n---\n\(r.text)")
            XCTAssertEqual(codeHash(env, src), codeHash(env, r.text), "bytecode differs:\n\(src)\n---\n\(r.text)")
        }
    }

    func testNoNewlineAfterRestrictedKeywords() {
        // A long return value must not be pushed to the next line.
        let long = (0 ..< 60).map { "aa\($0)" }.joined(separator: "&&")
        let r = roundTrip("function f(){return \(long)}", JeffJSUnminifyOptions(maxLineLength: 40))
        XCTAssertFalse(r.text.contains("return\n"), r.text)
        let r2 = roundTrip("function f(){throw new Error(\"\(String(repeating: "x", count: 200))\")}",
                           JeffJSUnminifyOptions(maxLineLength: 40))
        XCTAssertTrue(r2.text.contains("throw new Error("), r2.text)
        let r3 = roundTrip("for(var i=0,j=\(long);i<j;i++){}", JeffJSUnminifyOptions(maxLineLength: 40))
        let header = r3.text.components(separatedBy: "{").first ?? ""
        XCTAssertFalse(header.contains("\n"), "newline in a for header:\n\(r3.text)")
    }

    // MARK: templates, regex, syntax coverage

    func testTemplateLiterals() {
        let src = "var a=1,b={c:2};var s=`x${a}y${`in${b.c}ner${`deep${a+1}`}`}z${{k:3}.k}w`,m=`line1\n  line2 ${a}\nline3`,t=String.raw`\\n${a}`;[s,m,t].join('|')"
        let r = roundTrip(src)
        XCTAssertEqual(run(src), run(r.text))
        XCTAssertTrue(r.text.contains("`line1\n  line2 ${a}\nline3`"), "template text changed:\n\(r.text)")
    }

    func testRegexAndDivision() {
        let src = """
        var a=4,b=2,g=1,x='a/b';if(a)/a\\/b/.test(x)&&(g=a/b/g);var r=[/[/]/,/=/g,a/=b,x.replace(/\\//g,'|')];\
        function f(){return/z+/i.test('ZZ')}var o={k:1}/2;{}/foo/.test('foo');var c=a++/2;typeof/x/;\
        var d=(a)/b/1;String([g,r,f(),o,c,d])
        """
        let r = roundTrip(src)
        XCTAssertEqual(run(src), run(r.text), r.text)
    }

    func testSyntaxCoverage() {
        let src = """
        "use strict";class A extends Object{#p=1;static s=2;static{A.t=3}get v(){return this.#p}set v(x){this.#p=x}\
        static async*gen(){yield*[1,2]}#m(){return #p in this}m(){return this.#m()}['comp'+1](){return 1}}\
        const{a:aa=1,...rest}={b:2},[p1,,p3=3]=[1,2];let n=1_000_000+0x1F+0b11+0o7+1n.toString().length;\
        var oc={d:{e:null}}?.d?.e??'dflt',lbl=0;outer:for(const k of[1,2]){for(const j in{z:1}){if(k>1)break outer;else if(j)continue outer;else{lbl++}}}\
        switch(n){case 1:case 2:lbl+=2;break;default:lbl+=1}do{lbl++}while(lbl<5);try{null.x}catch{lbl++}finally{lbl++}\
        var fnE=function*(){},arrow=async(x,y=2)=>({x,y}),iife=(function(){return this})(),nt=function(){return new.target}();\
        var obj={async*ag(){},get [Symbol.iterator](){return null},set z(v){},if:1,class:2,default:3,'q-r':4,5:6};\
        label2:{break label2}if(!n)n=-(-n)+ +n- -n;var del=delete obj.if,vo=void 0,io='if'in obj,ins=obj instanceof Object;\
        [new A().v,A.s,A.t,aa,rest.b,p1,p3,n,oc,lbl,obj.default,obj.class,del,vo,io,ins,typeof nt].join()
        """
        let r = roundTrip(src)
        XCTAssertEqual(run(src), run(r.text), r.text)
        let env = JeffJSEnvironment()
        env.lazyFunctions = false
        XCTAssertEqual(codeHash(env, src), codeHash(env, r.text))
    }

    func testCommentsKeptAndPositionComments() {
        let src = "/*! license */\nvar a=1;// trailing\nvar b=/*inline*/2;\n/* block\n   two lines */\nfunction f(){return a+b}f()"
        let r = roundTrip(src)
        XCTAssertTrue(r.text.contains("/*! license */"))
        XCTAssertTrue(r.text.contains("// trailing\n"))
        XCTAssertTrue(r.text.contains("/*inline*/"))
        XCTAssertEqual(run(src), run(r.text))
        let r2 = roundTrip("var a=1;var b=2;var c=3;var d=4;function f(){return a}", JeffJSUnminifyOptions(positionCommentEvery: 2))
        XCTAssertTrue(r2.text.contains("// <1:"), r2.text)
        XCTAssertEqual(run("var a=1;var b=2;var c=3;var d=4;function f(){return a};f()"),
                       run(r2.text + ";f()"))
    }

    func testFormattingShape() {
        let r = roundTrip("function f(a,b){if(a){return b}else{return{x:1,y:[1,2,3]}}}")
        XCTAssertEqual(r.text, """
        function f(a, b) {
          if (a) {
            return b
          } else {
            return { x: 1, y: [1, 2, 3] }
          }
        }

        """)
        let r2 = roundTrip("switch(x){case 1:a();break;default:b()}")
        XCTAssertEqual(r2.text, "switch (x) {\n  case 1:\n    a();\n    break;\n  default:\n    b()\n}\n")
    }

    func testBrokenSourceComesBackUnchanged() {
        let src = "var s = 'unterminated"
        let r = JeffJSUnminifier.format(src)
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.text, src)
        XCTAssertEqual(r.formattedPosition(line: 1, column: 5)?.column, 5)
    }

    // MARK: position map, excerpt, enclosing function, stacks

    func testPositionMapExcerptAndEnclosingFunction() {
        let src = "var a=1;function outer(x){var y=x+1;function inner(z){return z.missing.deep}return inner(y)}outer(a)"
        let r = roundTrip(src)
        // `.deep` access throws at `missing` (col of the `.` before `deep`).
        let col = (src.range(of: ".deep")!.lowerBound.utf16Offset(in: src)) + 1
        guard let (l, c) = r.formattedPosition(line: 1, column: col) else { return XCTFail() }
        let line = r.formattedLine(l)!
        let idx = line.utf8.index(line.utf8.startIndex, offsetBy: c - 1)
        XCTAssertTrue(String(line[idx...]).hasPrefix(".deep"), line)
        let ex = r.excerpt(originalLine: 1, column: col, context: 2)!
        XCTAssertEqual(ex.targetLine, l)
        XCTAssertEqual(ex.lines.count, 5)
        XCTAssertTrue(ex.lines[ex.targetLine - ex.firstLine].contains("return z.missing.deep"))
        let fn = r.enclosingFunction(originalLine: 1, column: col)!
        XCTAssertTrue(fn.text.hasPrefix("function inner(z) {"), fn.text)
        XCTAssertTrue(fn.text.hasSuffix("}"), fn.text)
        let outerCol = (src.range(of: "x+1")!.lowerBound.utf16Offset(in: src)) + 1
        XCTAssertTrue(r.enclosingFunction(originalLine: 1, column: outerCol)!.text.hasPrefix("function outer(x) {"))
        XCTAssertNil(r.enclosingFunction(originalLine: 1, column: 3))
        // Arrow with a block body and a method.
        let src2 = "var o={m(a){return[1].map(v=>{return v.q.w})}};o.m()"
        let r2 = roundTrip(src2)
        let c2 = (src2.range(of: ".w")!.lowerBound.utf16Offset(in: src2)) + 1
        XCTAssertTrue(r2.enclosingFunction(originalLine: 1, column: c2)!.text.hasPrefix("v => {"))
        let c3 = (src2.range(of: "[1]")!.lowerBound.utf16Offset(in: src2)) + 1
        XCTAssertTrue(r2.enclosingFunction(originalLine: 1, column: c3)!.text.hasPrefix("m(a) {"))
    }

    func testEngineStackPositionsMapThroughTheFormatter() {
        // The engine's own Error.stack line:col (UTF-8 columns) map to the
        // throwing expression in the formatted text.
        let src = "function f(){var é='ü';return null.x}function g(){return f()}var s;try{g()}catch(e){s=e.stack}s"
        let env = JeffJSEnvironment()
        let stack = evaluate(env, src, filename: "https://example.com/app.min.js?v=3") ?? ""
        let loc = JeffJSStackLocation.parse(stack)
        XCTAssertEqual(loc?.url, "https://example.com/app.min.js", stack)
        let r = roundTrip(src)
        let (l, c) = r.formattedPosition(line: loc!.line, column: loc!.column)!
        let line = r.formattedLine(l)!
        XCTAssertTrue(line.contains("return null.x"), line)
        let idx = line.utf8.index(line.utf8.startIndex, offsetBy: c - 1)
        XCTAssertTrue(String(line[idx...]).hasPrefix(".x") || String(line[idx...]).hasPrefix("null.x"), "\(line) @\(c)")
        let rewritten = r.rewriteStack(stack) { $0.hasSuffix("app.min.js") }
        XCTAssertTrue(rewritten.contains("-> unminified \(l):\(c)"), rewritten)
        XCTAssertTrue(rewritten.contains("return null.x"), rewritten)
    }

    func testStackLocationParsing() {
        XCTAssertEqual(JeffJSStackLocation.parse("foo@https://a.b/c.js:1:234"),
                       JeffJSStackLocation(url: "https://a.b/c.js", line: 1, column: 234))
        XCTAssertEqual(JeffJSStackLocation.parse("[https://a.b/c.js?x=1:2:3] TypeError: x"),
                       JeffJSStackLocation(url: "https://a.b/c.js?x=1", line: 2, column: 3))
        XCTAssertEqual(JeffJSStackLocation.parse("    at f (https://a.b/c.js:10:20)"),
                       JeffJSStackLocation(url: "https://a.b/c.js", line: 10, column: 20))
        XCTAssertEqual(JeffJSStackLocation.parse("[JeffJS #3] https://a.b/c.js?v=1: TypeError: no\nf@https://a.b/c.js:1:9"),
                       JeffJSStackLocation(url: "https://a.b/c.js", line: 1, column: 9))
        XCTAssertNil(JeffJSStackLocation.parse("global code@"))
        XCTAssertEqual(JeffJSStackLocation.all(in: "a@file:///x/y.js:1:2\nb@/tmp/z.js:3:4").count, 2)
    }

    // MARK: engine hooks used by the app

    func testScriptSourceRegistryAndConsoleCallerLocation() {
        var messages: [(String, String)] = []
        let env = JeffJSEnvironment()
        env.onConsoleMessage = { level, msg in messages.append((level, msg)) }
        JeffJSStdLib.setConsoleCallerLocation(ctx: env.context, enabled: true)
        let url = "https://cdn.example.com/bundle.min.js?h=abc"
        let src = "function warnIt(){console.warn('careful')}function failIt(){try{null.q}catch(e){console.error(e)}}warnIt();failIt();console.log('plain');1"
        _ = evaluate(env, src, filename: url)
        let span = JeffJSScriptSources.sourceBytes(forURL: "https://cdn.example.com/bundle.min.js")
        XCTAssertNotNil(span)
        XCTAssertEqual(span.map { String(decoding: Array($0), as: UTF8.self) }, src)
        XCTAssertEqual(messages.count, 3)
        let warnCol = (src.range(of: "console.warn")!.lowerBound.utf16Offset(in: src)) + 1
        XCTAssertTrue(messages[0].1.hasPrefix("[https://cdn.example.com/bundle.min.js:1:"), messages[0].1)
        if let loc = JeffJSStackLocation.parse(messages[0].1) {
            XCTAssertGreaterThanOrEqual(loc.column, warnCol)
            XCTAssertLessThan(loc.column, warnCol + 14)
        }
        let throwCol = (src.range(of: "null.q")!.lowerBound.utf16Offset(in: src)) + 1
        XCTAssertTrue(messages[1].1.hasPrefix("[https://cdn.example.com/bundle.min.js:1:"), messages[1].1)
        XCTAssertTrue(messages[1].1.contains("failIt@https://cdn.example.com/bundle.min.js:1:"), messages[1].1)
        if let loc = JeffJSStackLocation.parse(messages[1].1) {
            XCTAssertGreaterThanOrEqual(loc.column, throwCol)
            XCTAssertLessThan(loc.column, throwCol + 7)
        }
        XCTAssertEqual(messages[2].1, "plain")
        // Off: no prefix.
        JeffJSStdLib.setConsoleCallerLocation(ctx: env.context, enabled: false)
        messages.removeAll()
        _ = evaluate(env, "console.warn('w')", filename: url)
        XCTAssertEqual(messages.first?.1, "w")
    }
}

extension JeffJSUnminified {
    /// Formatted byte offset of a formatted line:column (tests).
    func formattedOffsetOf(line: Int, column: Int) -> Int? {
        Self.offset(line: line, column: column, starts: outLineStarts, limit: text.utf8.count)
    }
}
