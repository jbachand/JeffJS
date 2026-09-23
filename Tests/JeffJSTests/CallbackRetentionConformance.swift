// CallbackRetentionConformance.swift
// JeffJS — conformance group "CallbackRetention": native code that calls into
// JS with a function (or receiver / arguments) it only borrows from storage
// the callee can change while it runs. `callFunction` borrows everything
// (QuickJS `JS_Call`), so such a site must hold its own references for the
// call (`JeffJSContext.callRetained`); otherwise the running callee — with its
// closure variables — is freed under it and the next closure read sees
// `undefined` (the React Natively timer glue hit exactly this with a
// `clearInterval(id)` inside the interval callback).
//
// Every case mutates that storage from inside the callback, allocates, then
// reads its closure / arguments, with zombie mode on and the object pool off
// so a release of something still in use is counted as a touch.

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    /// (name, JS expression that must evaluate to `true`), engine-only.
    static let callbackRetentionEngineCases: [(String, String)] = [
        ("getter deletes its own property", """
            (function(){ var mk = function(){ var cap = {n: 7};
                return { get x(){ delete this.x; __cbChurn(); return cap.n; } }; };
              var o = mk(); return o.x === 7 && o.x === undefined; })()
            """),
        ("setter deletes its own property", """
            (function(){ var mk = function(){ var cap = {n: 9};
                return { set y(v){ delete this.y; __cbChurn(); this.z = cap.n + v; } }; };
              var o = mk(); o.y = 1; return o.z === 10; })()
            """),
        ("inherited getter redefined from inside itself", """
            (function(){ var p = {};
              Object.defineProperty(p, 'x', { configurable: true, get: (function(){ var cap = {n: 8};
                return function g(){ Object.defineProperty(p, 'x', {value: 1, configurable: true}); __cbChurn();
                  g.hits = (g.hits | 0) + 1; return cap.n + g.hits - 1; }; })() });
              var o = Object.create(p); return o.x === 8 && o.x === 1; })()
            """),
        ("inherited setter redefined from inside itself", """
            (function(){ var p = {}, seen;
              Object.defineProperty(p, 'y', { configurable: true, set: (function(){ var cap = {n: 2};
                return function(v){ Object.defineProperty(p, 'y', {value: 0, writable: true, configurable: true});
                  __cbChurn(); seen = cap.n * v; }; })() });
              var o = Object.create(p); o.y = 21; return seen === 42; })()
            """),
        ("Map.forEach callback deletes its entry", """
            (function(){ var m = new Map(); m.set({k: 1}, {n: 5}); m.set({k: 2}, {n: 6}); var got = [];
              m.forEach(function(v, k){ m.delete(k); __cbChurn(); got.push(v.n + k.k); });
              return got.join() === '6,8' && m.size === 0; })()
            """),
        ("Set.forEach callback clears the set", """
            (function(){ var s = new Set([{n: 3}, {n: 4}]); var got = [];
              s.forEach(function(v, v2, set){ set.clear(); __cbChurn(); got.push(v.n + v2.n); });
              return got.join() === '6' && s.size === 0; })()
            """),
        ("proxy get trap revokes its own proxy", """
            (function(){ var r = Proxy.revocable({a: 1}, { tag: 5, get: function(t, k){ r.revoke(); __cbChurn(); return t.a + this.tag; } });
              var v = r.proxy.foo; var threw = false; try { r.proxy.foo; } catch (e) { threw = e instanceof TypeError; }
              return v === 6 && threw; })()
            """),
        ("proxy set/has traps revoke their own proxy", """
            (function(){ var out = [];
              var r1 = Proxy.revocable({a: 1}, { set: function(t, k, v){ r1.revoke(); __cbChurn(); out.push(t.a + v); return true; } });
              r1.proxy.q = 2;
              var r2 = Proxy.revocable({b: 3}, { has: function(t, k){ r2.revoke(); __cbChurn(); out.push(t.b); return true; } });
              var h = 'q' in r2.proxy;
              return out.join() === '3,3' && h === true; })()
            """),
        ("sort comparator mutates the array's sort property", """
            (function(){ var a = [3, 1, 2], n = 0; var cmp = (function(){ var cap = {d: 0};
                return function(x, y){ a.sort = null; n++; __cbChurn(); return x - y + cap.d; }; })();
              a.sort(cmp); return a.join() === '1,2,3' && a.sort === null && n > 0; })()
            """),
        ("sort comparator that throws releases the collected elements", """
            (function(){ var a = [{v: 2}, {v: 1}]; try { a.sort(function(){ throw 1; }); } catch (e) {}
              return a[0].v + a[1].v === 3; })()
            """),
        ("Promise then handler reassigns the handler", """
            (function(){ var h = (function(){ var cap = {n: 2}; return function(v){ h = null; __cbChurn(); globalThis.__cbThen = v * cap.n; }; })();
              Promise.resolve(4).then(h); h = undefined; return true; })()
            """),
    ]

    /// Checked after the microtask drain that follows the engine cases.
    static let callbackRetentionEngineFollowUps: [(String, String)] = [
        ("Promise then handler reassigns the handler (settled)", "globalThis.__cbThen === 8"),
        ("Promise.finally adopts a promise from onFinally (settled)", "globalThis.__cbFinally === 1"),
    ]

    /// DOM / host cases, run in a JeffJSEnvironment on the main thread.
    static let callbackRetentionDOMCases: [(String, String)] = [
        ("listener removes itself and adds a new one during dispatch", """
            (function(){ var et = new EventTarget(), log = [];
              var mk = function(tag){ var cap = {tag: tag};
                var f = function(){ et.removeEventListener('x', f); et.addEventListener('x', mk(tag + 1)); __cbChurn(); log.push(cap.tag); };
                return f; };
              et.addEventListener('x', mk(1)); et.dispatchEvent(new Event('x')); et.dispatchEvent(new Event('x'));
              return log.join() === '1,2'; })()
            """),
        ("once listener and handleEvent object removed during dispatch", """
            (function(){ var d = document.createElement('div'), log = [];
              d.addEventListener('y', (function(){ var cap = {n: 1}; return function(){ __cbChurn(); log.push(cap.n); }; })(), { once: true });
              var obj = { n: 2, handleEvent: function(){ d.removeEventListener('y', obj); obj = null; __cbChurn(); log.push(this.n); } };
              d.addEventListener('y', obj); d.dispatchEvent(new Event('y')); d.dispatchEvent(new Event('y'));
              return log.join() === '1,2'; })()
            """),
        ("on-handler replaces itself during dispatch", """
            (function(){ var d = document.createElement('div'), log = [];
              d.onfoo = (function(){ var cap = {n: 1}; return function(){ d.onfoo = function(){ log.push(2); }; __cbChurn(); log.push(cap.n); }; })();
              d.dispatchEvent(new Event('foo')); d.dispatchEvent(new Event('foo')); return log.join() === '1,2'; })()
            """),
        ("MutationObserver callback disconnects and observes again", """
            (function(){ var el = document.createElement('div'); globalThis.__cbMO = 'pending'; var n = 0;
              var mo = new MutationObserver((function(){ var cap = {k: 3}; return function(recs, obs){
                obs.disconnect(); obs.observe(el, {attributes: true}); __cbChurn(); n++;
                if (n === 1) el.setAttribute('b', '2');
                else { obs.disconnect(); globalThis.__cbMO = cap.k === 3 && recs.length === 1 && recs[0].attributeName === 'b' && obs === mo; } }; })());
              mo.observe(el, {attributes: true}); el.setAttribute('a', '1'); return true; })()
            """),
        ("MutationObserver callback (settled)", "globalThis.__cbMO === true"),
        ("video event callback re-registers itself", """
            (function(){ globalThis.__cbVideoLog = []; var id = '00000000-0000-0000-0000-00000000c0de';
              __nativeVideo.registerEventCallback(id, (function(){ var cap = {n: 1}; return function(name, detail){
                __nativeVideo.registerEventCallback(id, function(name2){ __cbVideoLog.push(name2); });
                __cbChurn(); __cbVideoLog.push(name + cap.n + detail.t); }; })());
              return true; })()
            """),
    ]

    /// Evaluate `code` (expected true) with zombie mode forced on and the pool
    /// off; require zero touches on freed values while it ran.
    private mutating func evalRetainedNoTouches(_ ctx: JeffJSContext, _ label: String, _ code: String) {
        let saved = (jeffJSZombiesEnabled, jeffJS_refDebugMode, jeffJSObjectPoolDisabled)
        jeffJSZombiesEnabled = true; jeffJS_refDebugMode = true; jeffJSObjectPoolDisabled = true
        let before = JeffJSZombieDebug.touches
        evalCheckBool(ctx, code, expect: true)
        _ = ctx.rt.executePendingJobs()
        let touched = JeffJSZombieDebug.touches - before
        (jeffJSZombiesEnabled, jeffJS_refDebugMode, jeffJSObjectPoolDisabled) = saved
        assert(touched == 0, "CallbackRetention: \(label): \(touched) touch(es) on freed values")
    }

    private static let cbChurnSource =
        "function __cbChurn(){ var a = []; for (var i = 0; i < 300; i++) a.push({i: i, s: 'x' + i}); return a.length; }"

    mutating func testCallbackRetention() {
        // Engine sites (accessors, Map/Set forEach, proxy traps, sort, promise
        // jobs) on their own runtime, like FreedValueTouches.
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        evalCheckBool(ctx, "\(Self.cbChurnSource); true", expect: true)
        for (name, js) in Self.callbackRetentionEngineCases {
            evalRetainedNoTouches(ctx, name, js)
        }
        evalRetainedNoTouches(ctx, "Promise.finally adopts a promise from onFinally", """
            (function(){ Promise.resolve(1).finally(function(){ return new Promise(function(r){ r(2); }); })
              .then(function(v){ __cbChurn(); globalThis.__cbFinally = v; }); return true; })()
            """)
        for (name, js) in Self.callbackRetentionEngineFollowUps {
            evalRetainedNoTouches(ctx, name, js)
        }

        // quickjs-libc style timers (JeffJSStdLib): an interval / timeout that
        // clears itself from inside its callback. cancelTimer released the
        // entry's callback and arguments mid-call, and pollTimers released
        // them a second time afterwards.
        JeffJSStdLib.addTimers(ctx: ctx)
        evalRetainedNoTouches(ctx, "StdLib timers clear themselves from inside the callback", """
            (function(){ globalThis.__cbTimers = [];
              var iv = setInterval((function(){ var cap = {n: 1}; return function(arg){ clearInterval(iv); __cbChurn(); __cbTimers.push('i' + cap.n + arg.a); }; })(), 0, {a: 'x'});
              var to = setTimeout((function(){ var cap = {n: 2}; return function(arg){ clearTimeout(to); __cbChurn(); __cbTimers.push('t' + cap.n + arg.a); }; })(), 0, {a: 'y'});
              return true; })()
            """)
        do {
            let saved = (jeffJSZombiesEnabled, jeffJS_refDebugMode, jeffJSObjectPoolDisabled)
            jeffJSZombiesEnabled = true; jeffJS_refDebugMode = true; jeffJSObjectPoolDisabled = true
            let before = JeffJSZombieDebug.touches
            for _ in 0..<3 { _ = JeffJSStdLib.pollTimers(ctx: ctx) }
            let touched = JeffJSZombieDebug.touches - before
            (jeffJSZombiesEnabled, jeffJS_refDebugMode, jeffJSObjectPoolDisabled) = saved
            assert(touched == 0, "CallbackRetention: StdLib pollTimers: \(touched) touch(es) on freed values")
        }
        evalRetainedNoTouches(ctx, "StdLib timers fired once each", "__cbTimers.sort().join() === 'i1x,t2y'")
        _ = rt

        testCallbackRetentionHost()
    }

    /// The DOM / media / GCD-timer sites need a JeffJSEnvironment, which is
    /// main-actor bound: build it on the main thread (the conformance thread
    /// waits; XCTest's wait spins the main run loop, which also delivers the
    /// environment's DispatchSource interval and its main-actor task).
    private mutating func testCallbackRetentionHost() {
        var outcomes: [(Bool, String)] = []
        var env: JeffJSEnvironment?
        let onMain: (() -> Void) -> Void = { body in
            if Thread.isMainThread { body() } else { DispatchQueue.main.sync(execute: body) }
        }
        // Zombie mode for the whole window, including the run-loop turns in
        // which the interval fires (nothing else runs JS meanwhile).
        let saved = (jeffJSZombiesEnabled, jeffJS_refDebugMode, jeffJSObjectPoolDisabled)
        jeffJSZombiesEnabled = true; jeffJS_refDebugMode = true; jeffJSObjectPoolDisabled = true
        let touchesBefore = JeffJSZombieDebug.touches
        @MainActor func check(_ e: JeffJSEnvironment, _ name: String, _ js: String) {
            switch e.eval(js, filename: "<callback-retention>") {
            case .success(let value):
                outcomes.append((value == "true", "CallbackRetention: \(name) -> \(value ?? "undefined")"))
            case .exception(let message):
                outcomes.append((false, "CallbackRetention: \(name) threw \(message)"))
            }
        }

        onMain {
            MainActor.assumeIsolated {
                do {
                    let e = JeffJSEnvironment()
                    env = e
                    // Runtime init re-reads the debug flags from the process
                    // environment: switch zombie mode (back) on after it.
                    jeffJSZombiesEnabled = true; jeffJS_refDebugMode = true; jeffJSObjectPoolDisabled = true
                    e.eval(Self.cbChurnSource)
                    for (name, js) in JeffJSTestRunner.callbackRetentionDOMCases { check(e, name, js) }
                    // Media events arrive from the player; deliver two by hand.
                    let id = "00000000-0000-0000-0000-00000000c0de"
                    e.videoBridge?.fireEventCallback(nodeIDStr: id, eventName: "play", detail: ["t": 5.0])
                    e.videoBridge?.fireEventCallback(nodeIDStr: id, eventName: "pause", detail: [:])
                    check(e, "video event callback re-registers itself (settled)",
                          "__cbVideoLog.join() === 'play15,pause'")
                    // GCD-backed interval that clears itself: the table held the
                    // only reference to the callback.
                    check(e, "setInterval callback clears itself", """
                        (function(){ globalThis.__cbIv = [];
                          var id = setInterval((function(){ var cap = {n: 4}; return function(){ clearInterval(id); __cbChurn(); __cbIv.push(cap.n); }; })(), 1);
                          return true; })()
                        """)
                }
            }
        }
        // Let the interval fire (main run loop) and its task run.
        var fired = false
        for _ in 0..<100 where !fired {
            Thread.sleep(forTimeInterval: 0.02)
            onMain {
                MainActor.assumeIsolated {
                    if case .success(let v) = env?.eval("__cbIv.length > 0") { fired = v == "true" }
                }
            }
        }
        onMain {
            MainActor.assumeIsolated {
                do {
                    if let e = env {
                        // Give a (wrongly) surviving interval a chance to fire again.
                        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                        check(e, "setInterval callback cleared itself and read its closure",
                              "__cbIv.join() === '4'")
                    }
                }
            }
        }
        let touches = JeffJSZombieDebug.touches - touchesBefore
        (jeffJSZombiesEnabled, jeffJS_refDebugMode, jeffJSObjectPoolDisabled) = saved
        outcomes.append((fired, "CallbackRetention: setInterval never fired"))
        for (ok, message) in outcomes { assert(ok, message) }
        assert(touches == 0, "CallbackRetention: host cases: \(touches) touch(es) on freed values")
    }
}
