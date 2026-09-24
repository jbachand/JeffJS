// FormControlAccessorsConformance.swift
// JeffJS — conformance group "FormControlAccessors": form control IDL
// attributes as WebIDL accessors (§3.7.6: configurable, enumerable, getter +
// setter, on the prototype — the bridge's shared element prototype — and
// never on the instance), and the [[DefineOwnProperty]] rules React's input
// value tracking relies on:
//
//   var d = Object.getOwnPropertyDescriptor(node.constructor.prototype, 'value');
//   Object.defineProperty(node, 'value', { configurable: true, get, set });
//   Object.defineProperty(node, 'value', { enumerable: d.enumerable });  // generic descriptor
//   node.value = x;  …  delete node.value;
//
// A generic descriptor (ES2023 6.2.6.3: neither value/writable nor get/set)
// never changes the kind of an existing property (10.1.6.3); JeffJS turned the
// accessor into a non-writable data property holding undefined, so React's
// strict-mode `node.value = x` threw "Cannot assign to read only property"
// and netflix.com unmounted its whole tree.

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    /// (name, JS expression that must evaluate to `true`).
    static let formControlAccessorCases: [(String, String)] = [
        // ---- [[DefineOwnProperty]] with a generic descriptor (plain objects)
        ("a generic {enumerable} descriptor keeps an accessor's get/set", """
            (function(){ 'use strict'; var o = {}, got = [];
              Object.defineProperty(o, 'v', { configurable: true, get: function(){ return 1; }, set: function(x){ got.push(x); } });
              Object.defineProperty(o, 'v', { enumerable: false });
              var d = Object.getOwnPropertyDescriptor(o, 'v'); o.v = 5;
              return typeof d.get === 'function' && typeof d.set === 'function' && !('value' in d) && !('writable' in d) &&
                d.enumerable === false && d.configurable === true && o.v === 1 && got.join() === '5'; })()
            """),
        ("an empty descriptor and {configurable: false} keep an accessor", """
            (function(){ var g = function(){ return 2; }, o = {};
              Object.defineProperty(o, 'v', { configurable: true, enumerable: true, get: g });
              Object.defineProperty(o, 'v', {}); Object.defineProperty(o, 'v', { configurable: false });
              var d = Object.getOwnPropertyDescriptor(o, 'v');
              return d.get === g && d.set === undefined && d.enumerable === true && d.configurable === false && o.v === 2; })()
            """),
        ("a generic descriptor that flips enumerable on a non-configurable accessor throws, the accessor stays", """
            (function(){ var o = {}; Object.defineProperty(o, 'v', { get: function(){ return 1; } });
              try { Object.defineProperty(o, 'v', { enumerable: true }); return false; }
              catch (e) { return e instanceof TypeError && typeof Object.getOwnPropertyDescriptor(o, 'v').get === 'function' && o.v === 1; } })()
            """),
        ("{writable: true} over an accessor still makes a data property (value undefined)", """
            (function(){ var o = {}; Object.defineProperty(o, 'v', { configurable: true, get: function(){ return 1; } });
              Object.defineProperty(o, 'v', { writable: true }); var d = Object.getOwnPropertyDescriptor(o, 'v'); o.v = 3;
              return d.value === undefined && d.writable === true && d.get === undefined && d.set === undefined && o.v === 3; })()
            """),
        ("Reflect.defineProperty and Object.defineProperties take the same path", """
            (function(){ var o = {}, s = 0;
              Object.defineProperty(o, 'a', { configurable: true, get: function(){ return 1; }, set: function(){ s++; } });
              Object.defineProperty(o, 'b', { configurable: true, get: function(){ return 2; }, set: function(){ s++; } });
              var r = Reflect.defineProperty(o, 'a', { enumerable: true }); Object.defineProperties(o, { b: { enumerable: true } });
              o.a = 1; o.b = 1; return r === true && s === 2 && o.a === 1 && o.b === 2 && Object.keys(o).join() === 'a,b'; })()
            """),
        ("a generic descriptor on a data property keeps its value and writability", """
            (function(){ var o = { v: 4 }; Object.defineProperty(o, 'v', { enumerable: false }); o.v = 5;
              var d = Object.getOwnPropertyDescriptor(o, 'v'); return d.value === 5 && d.writable === true && d.enumerable === false; })()
            """),
        // ---- descriptors on the prototype, none on the instance
        ("input value/defaultValue/checked/defaultChecked: configurable enumerable get+set on the prototype", """
            (function(){ var i = document.createElement('input'), P = Object.getPrototypeOf(i);
              return ['value', 'defaultValue', 'checked', 'defaultChecked'].every(function (n) {
                var d = Object.getOwnPropertyDescriptor(P, n);
                return !!d && typeof d.get === 'function' && typeof d.set === 'function' && d.configurable === true && d.enumerable === true; }); })()
            """),
        ("form control instances have no own IDL properties", """
            (function(){ var h = Object.prototype.hasOwnProperty;
              return ['input', 'textarea', 'select', 'option', 'button'].every(function (t) {
                var e = document.createElement(t);
                return !h.call(e, 'value') && !h.call(e, 'defaultValue') && !h.call(e, 'checked') && !h.call(e, 'defaultChecked'); }); })()
            """),
        // ---- React's inputValueTracking on a real input
        ("React tracker: define on the instance, generic redefine, strict set, read, delete, set", """
            (function(){ 'use strict'; var e = document.createElement('input'), P = Object.getPrototypeOf(e);
              var n = Object.getOwnPropertyDescriptor(P, 'value'), tracked = '' + e.value;
              Object.defineProperty(e, 'value', { configurable: true, get: function(){ return n.get.call(this); },
                set: function(x){ tracked = '' + x; n.set.call(this, x); } });
              Object.defineProperty(e, 'value', { enumerable: n.enumerable });
              var own = Object.getOwnPropertyDescriptor(e, 'value');
              e.value = 'abc'; var r1 = e.value;
              delete e.value; var gone = !Object.prototype.hasOwnProperty.call(e, 'value');
              e.value = 'def';
              return typeof own.get === 'function' && typeof own.set === 'function' && own.enumerable === true &&
                r1 === 'abc' && tracked === 'abc' && gone && e.value === 'def'; })()
            """),
        ("React tracker on a checkbox's checked", """
            (function(){ 'use strict'; var e = document.createElement('input'); e.type = 'checkbox';
              var n = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(e), 'checked'), tracked = '' + e.checked;
              Object.defineProperty(e, 'checked', { configurable: true, get: function(){ return n.get.call(this); },
                set: function(x){ tracked = '' + x; n.set.call(this, x); } });
              Object.defineProperty(e, 'checked', { enumerable: n.enumerable });
              e.checked = true; var r1 = e.checked; delete e.checked; e.checked = false;
              return r1 === true && tracked === 'true' && e.checked === false; })()
            """),
        ("strict assignments to every form IDL attribute do not throw", """
            (function(){ 'use strict'; var i = document.createElement('input'), t = document.createElement('textarea');
              i.value = 'a'; i.defaultValue = 'b'; i.checked = true; i.defaultChecked = false; t.value = 'x'; t.defaultValue = 'y';
              return t.value === 'x' && t.defaultValue === 'y' && i.defaultChecked === false; })()
            """),
        // ---- checked / defaultChecked
        ("defaultChecked reflects the checked content attribute (round trip)", """
            (function(){ var e = document.createElement('input'); e.type = 'checkbox'; var a = [e.defaultChecked, e.checked];
              e.defaultChecked = true; a.push(e.getAttribute('checked'), e.defaultChecked, e.checked);
              e.defaultChecked = false; a.push(e.hasAttribute('checked'), e.defaultChecked, e.checked);
              e.setAttribute('checked', 'checked'); a.push(e.defaultChecked);
              return a.join() === 'false,false,,true,true,false,false,false,true'; })()
            """),
        ("defaultChecked is undefined on other elements; an assignment is an own data property", """
            (function(){ var d = document.createElement('div'), a = d.defaultChecked; d.defaultChecked = 3;
              var od = Object.getOwnPropertyDescriptor(d, 'defaultChecked');
              return a === undefined && d.defaultChecked === 3 && !d.hasAttribute('checked') && od && od.writable === true; })()
            """),
    ]

    mutating func testFormControlAccessors() {
        var outcomes: [(Bool, String)] = []
        func onMain(_ body: @escaping @MainActor () -> Void) {
            if Thread.isMainThread { MainActor.assumeIsolated { body() } } else { DispatchQueue.main.sync { MainActor.assumeIsolated { body() } } }
        }
        func record(_ result: JeffJSEvalResult, _ name: String) {
            switch result {
            case .success(let value): outcomes.append((value == "true", "FormControlAccessors: \(name) -> \(value ?? "undefined")"))
            case .exception(let message): outcomes.append((false, "FormControlAccessors: \(name) threw \(message)"))
            }
        }
        onMain {
            let e = JeffJSEnvironment()
            for (name, js) in JeffJSTestRunner.formControlAccessorCases {
                record(e.eval(js, filename: "<form-accessors>"), name)
            }
            // A host that keeps the checkedness in `attributes` (the app's
            // FormControlState): defaultChecked reads the page's content
            // attribute through contentAttributeOverride, checked the state.
            if let dom = e.domBridge {
                dom.contentAttributeOverride = { node, name in
                    guard node.attributes["id"] == "fca", name == "checked" else { return .none }
                    return .some(nil)   // the page never set a checked content attribute
                }
                record(e.eval("""
                    (function(){ var i = document.createElement('input'); i.type = 'checkbox'; i.id = 'fca'; i.checked = true;
                      return i.checked === true && i.defaultChecked === false && i.getAttribute('checked') === null; })()
                    """, filename: "<form-accessors-override>"), "defaultChecked reads the host's content attribute, checked the state")
                dom.contentAttributeOverride = nil
            }
        }
        for (ok, message) in outcomes { assert(ok, message) }
    }
}
