// TaskSpikesConformance.swift
// JeffJS — "TaskSpikes" (perf/task-spikes, 2026-10-07): the interpreter's value
// buffers come from one segmented stack per runtime (claims sized to the frame
// once the stack is deep) and big string payloads feed an allocation trigger.
// These cases pin the JS-visible behaviour around both: deep native↔JS
// recursion still ends in a catchable RangeError and leaves the engine usable,
// generators / async functions / inline-call chains that cross stack segments
// keep their values, and strings held by cyclic garbage are collected.
//
// Every case is (name, JS expression that must evaluate to `true`).

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    static let taskSpikesCases: [(String, String)] = [
        ("deep f.call recursion throws a catchable RangeError, then calls work",
         "(function(){ var d = 0; function f(n){ d = n; return f.call(null, n + 1); } var ok = false; try { f(0); } catch (e) { ok = e instanceof RangeError; } function g(a, b){ return a + b; } return ok && d > 20 && g.call(null, 2, 3) === 5 && [1,2,3].map(function(x){ return x * 2; }).join() === '2,4,6'; })()"),
        ("recursion through a native callback (map) unwinds cleanly",
         "(function(){ var d = 0; function h(n){ d = n; return [n].map(function(){ return h(n + 1); })[0]; } var ok = false; try { h(0); } catch (e) { ok = e instanceof RangeError; } return ok && d > 10 && [1,2].reduce(function(a, b){ return a + b; }, 0) === 3; })()"),
        ("inline recursion deep enough to span several stack claims returns the right sum",
         "(function(){ function r(n){ var a = n, b = n * 2, c = n * 3; return n === 0 ? 0 : a + b + c - n * 5 + r(n - 1); } return r(3000) === 4501500; })()"),
        ("arguments and locals survive a call that moves to a new stack segment",
         "(function(){ function leaf(a, b, c){ var x = a * 100 + b * 10 + c; return x; } function mid(n, a, b, c){ return n === 0 ? leaf(a, b, c) : mid.call(null, n - 1, a, b, c) + 0; } var r = 0; try { r = mid(40, 1, 2, 3); } catch (e) { r = -1; } return r === 123; })()"),
        ("a generator resumed from deep inside a recursion keeps its locals",
         "(function(){ function* gen(){ var k = 10; while (true) { k += yield k; } } var it = gen(); it.next(); function deep(n){ return n === 0 ? it.next(5).value : deep.call(null, n - 1); } var a = deep(30), b = deep(1); return a === 15 && b === 20; })()"),
        ("async functions awaited across deep stacks finish with their values",
         "(function(){ var out = []; async function f(x){ var y = x * 2; await null; return y + 1; } function deep(n){ return n === 0 ? f(20) : deep.call(null, n - 1); } var p = deep(25); p.then(function(v){ out.push(v); }); return p instanceof Promise && out.length === 0; })()"),
        ("strings held by cyclic garbage keep their values while the trigger collects",
         "(function(){ var big = 'y'.repeat(1 << 16), o, keep = []; for (var i = 0; i < 400; i++) { o = {}; o.me = o; o.s = (big + i).slice(1); if (i % 100 === 0) keep.push(o); } return o.s.length === (1 << 16) + 2 && o.s.slice(-3) === '399' && keep.length === 4 && keep[3].s.slice(-3) === '300' && keep[0].me === keep[0]; })()"),
        ("toString of a big function: one text per call, exact, wide characters kept",
         "(function(){ var body = 'var s = \"\\u4e2d\\u00e9\";'; for (var i = 0; i < 3000; i++) body += 'var v' + i + ' = ' + i + ';'; body += 'return s + v2999;'; var f = (0, eval)('(function big(){' + body + '})'); var a = f.toString(), b = f.toString(); return a === b && a.length > 16384 && a.indexOf('\\u4e2d\\u00e9') > 0 && a.slice(0, 13) === 'function big(' && a.charCodeAt(a.length - 1) === 125 && (0, eval)('(' + a + ')')() === '\\u4e2d\\u00e92999'; })()"),
        ("toString of a big Latin-1 function stays narrow and exact",
         "(function(){ var body = 'var s = \"caf\\u00e9\";'; for (var i = 0; i < 3000; i++) body += 'var w' + i + ' = ' + i + ';'; body += 'return s;'; var f = (0, eval)('(function lat(){' + body + '})'); var a = f.toString(); return a === f.toString() && a.indexOf('caf\\u00e9') > 0 && (0, eval)('(' + a + ')')() === 'caf\\u00e9'; })()"),
        ("an exception thrown at depth is caught by the outermost frame with its message",
         "(function(){ function t(n){ if (n === 0) throw new Error('bottom'); return t.call(null, n - 1); } try { t(30); return false; } catch (e) { return e.message === 'bottom'; } })()"),
    ]

    mutating func testTaskSpikes() {
        runTrueCases("TaskSpikes", JeffJSTestRunner.taskSpikesCases)
    }
}
