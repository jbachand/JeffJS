// IteratorCloseConformance.swift
// JeffJS — conformance group "IteratorClose" (ES §14.7.5.7 ForIn/OfBodyEvaluation,
// §7.4.11 IteratorClose, §8.6.3 IteratorBindingInitialization).
// Every `for (x of it)` that ran to completion called it.return(): the done
// exit fell through into the break label's iterator_close. return() is for
// abrupt completions only (break, return, throw, continue to an outer label,
// a throwing head); a loop whose next() reports done, or whose next() throws,
// must not call it. The same record-done rule governs spread and array
// destructuring (close only when the pattern finishes before the iterator).
//
// Every case is (name, JS expression that must evaluate to `true`).
// `mk(n, log)` builds an iterable yielding 1..n that logs next/return.

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    private static let iterCloseMk =
        "function mk(n, log, ret){ return { [Symbol.iterator](){ var i = 0; return { next(){ log.push('next'); return i < n ? {value: ++i, done: false} : {done: true}; }, return(){ log.push('return'); return ret ? ret() : {}; } }; } }; } "

    private static func iterCloseCase(_ body: String) -> String {
        "(function(){ \(iterCloseMk)\(body) })()"
    }

    static let iteratorCloseCases: [(String, String)] = [
        ("normal completion does not call return()",
         iterCloseCase("var log = []; for (const x of mk(2, log)) ; return log.join() === 'next,next,next';")),
        ("normal completion with a pattern head does not call return()",
         iterCloseCase("var log = [], o = {}; for (const {a} of mk(2, log)) ; for (o.v of mk(1, log)) ; for ([o.w] of [[1]]) ; return o.v === 1 && o.w === 1 && log.join() === 'next,next,next,next,next';")),
        ("break calls return() exactly once",
         iterCloseCase("var log = []; for (const x of mk(5, log)) { if (x === 2) break; } return log.join() === 'next,next,return';")),
        ("return in the body calls return() once and keeps the value",
         iterCloseCase("var log = []; var r = (function(){ for (const x of mk(5, log)) return x * 10; })(); return r === 10 && log.join() === 'next,return';")),
        ("throw in the body calls return() once and propagates",
         iterCloseCase("var log = [], e; try { for (const x of mk(5, log)) throw 'boom'; } catch (err) { e = err; } return e === 'boom' && log.join() === 'next,return';")),
        ("continue to an outer label closes the inner iterator",
         iterCloseCase("var log = []; outer: for (var i = 0; i < 2; i++) { for (const x of mk(5, log)) continue outer; } return log.join() === 'next,return,next,return';")),
        ("inner continue does not close",
         iterCloseCase("var log = []; for (const x of mk(2, log)) continue; return log.join() === 'next,next,next';")),
        ("a throwing destructuring head closes the iterator",
         "(function(){ var log = []; var it = { [Symbol.iterator](){ return { next(){ log.push('next'); return {value: null, done: false}; }, return(){ log.push('return'); return {}; } }; } }; var e; try { for (const {a} of it) ; } catch (err) { e = err; } return e instanceof TypeError && log.join() === 'next,return'; })()"),
        ("a throwing default in the head closes the iterator",
         iterCloseCase("var log = [], e; try { for (const [a = (function(){ throw 'dflt'; })()] of [[]]) ; } catch (err) { e = err; } try { for (const x of mk(3, log)) { var [q = (function(){ throw 'd2'; })()] = []; } } catch (err) { e += err; } return e === 'dfltd2' && log.join() === 'next,return';")),
        ("return() throwing during a body throw keeps the body's throw",
         iterCloseCase("var log = [], e; try { for (const x of mk(5, log, function(){ throw 'fromReturn'; })) throw 'body'; } catch (err) { e = err; } return e === 'body' && log.join() === 'next,return';")),
        ("return() throwing on break propagates",
         iterCloseCase("var log = [], e; try { for (const x of mk(5, log, function(){ throw 'fromReturn'; })) break; } catch (err) { e = err; } return e === 'fromReturn' && log.join() === 'next,return';")),
        ("return() answering a non-object on break is a TypeError",
         iterCloseCase("var log = [], e; try { for (const x of mk(5, log, function(){ return 1; })) break; } catch (err) { e = err; } return e instanceof TypeError && log.join() === 'next,return';")),
        ("next() throwing does not call return()",
         "(function(){ var log = [], e; var it = { [Symbol.iterator](){ return { next(){ log.push('next'); throw 'nx'; }, return(){ log.push('return'); return {}; } }; } }; try { for (const x of it) ; } catch (err) { e = err; } return e === 'nx' && log.join() === 'next'; })()"),
        ("spread runs to completion without return()",
         iterCloseCase("var log = []; var a = [...mk(2, log)]; var m = Math.max(...mk(3, log)); return a.join() === '1,2' && m === 3 && log.indexOf('return') < 0 && log.length === 7;")),
        ("Array.from runs to completion without return()",
         iterCloseCase("var log = []; return Array.from(mk(2, log)).join() === '1,2' && log.join() === 'next,next,next';")),
        ("[a] = it closes when the pattern ends first",
         iterCloseCase("var log = [], a; [a] = mk(3, log); var [b, c] = mk(3, log); return a === 1 && b === 1 && c === 2 && log.join() === 'next,return,next,next,return';")),
        ("[a, b, c, d] = it does not close and stops calling next() after done",
         iterCloseCase("var log = [], a, b, c, d; [a, b, c, d] = mk(2, log); var [e, , f, g] = mk(1, log); return a === 1 && b === 2 && c === undefined && d === undefined && e === 1 && f === undefined && log.join() === 'next,next,next,next,next';")),
        ("[a, ...r] = it drains without return()",
         iterCloseCase("var log = [], a, r, o = {}; [a, ...r] = mk(3, log); var [b, ...s] = mk(1, log); [o.f, ...o.t] = mk(2, log); return a === 1 && r.join() === '2,3' && b === 1 && s.length === 0 && o.f === 1 && o.t.join() === '2' && log.indexOf('return') < 0;")),
        ("[a] = it with a done iterator does not close",
         iterCloseCase("var log = [], a; [a] = mk(0, log); return a === undefined && log.join() === 'next';")),
        ("yield* runs to completion without return()",
         iterCloseCase("var log = []; function* g(){ yield* mk(2, log); } return [...g()].join() === '1,2' && log.indexOf('return') < 0;")),
        ("generator return() closes the for-of iterator it is suspended in",
         iterCloseCase("var log = []; function* g(){ for (const x of mk(5, log)) yield x; } var it = g(); it.next(); var r = it.return(7); return r.value === 7 && r.done === true && log.join() === 'next,return';")),
        ("a generator run to completion by for-of is not returned",
         "(function(){ var fin = 0; function* g(){ try { yield 1; yield 2; } finally { fin++; } } var s = 0; for (const x of g()) s += x; var gen = g(); for (const x of gen) break; return s === 3 && fin === 2 && gen.next().done === true; })()"),
        ("nested loops: inner completes, outer breaks",
         iterCloseCase("var log = []; for (const x of mk(3, log)) { for (const y of mk(1, log)) ; break; } return log.join() === 'next,next,next,return';")),
    ]

    mutating func testIteratorClose() {
        runTrueCases("IteratorClose", JeffJSTestRunner.iteratorCloseCases)

        // for await: the async path does not go through for_of_next; its done
        // exit must skip the close too, and break must still close.
        let (_, ctx) = makeCtx()
        let js = "var __ic = 'pending'; (async function(){ \(JeffJSTestRunner.iterCloseMk)var log = []; for await (const x of mk(2, log)) ; var l2 = []; for await (const x of mk(3, l2)) break; __ic = log.join() + '|' + l2.join(); })().catch(function(e){ __ic = 'threw ' + e; });"
        JeffJSStackDiag.currentLabel = "IteratorClose: for await"
        let r = ctx.eval(input: js, filename: "<IteratorClose>", evalFlags: JS_EVAL_TYPE_GLOBAL)
        assert(!r.isException, "IteratorClose: for await threw at eval")
        r.freeValue()
        _ = ctx.rt.executePendingJobs()
        let v = ctx.eval(input: "__ic", filename: "<IteratorClose>", evalFlags: JS_EVAL_TYPE_GLOBAL)
        let got = ctx.toSwiftString(v) ?? "?"
        assert(got == "next,next,next|next,return", "IteratorClose: for await -> \(got)")
        v.freeValue()
    }
}
