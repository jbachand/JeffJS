// JeffJSGlobalSnapshot.swift
// JeffJS — Persist user-added globalThis properties across launches.
//
// Unlike the bytecode cache (which speeds up parse+compile of replayed
// commands), this captures the *result* of user evaluation: any property
// the user added or replaced on globalThis after env init. On restore the
// values are written directly back onto globalThis — no commands are
// replayed, so side effects (fetch, DOM mutation, etc.) never re-fire.
//
// Format is a simple tagged-tree JSON produced/consumed by the JS scripts
// in this file. Functions, DOM nodes, native objects, and class instances
// are skipped — the names are reported back so the caller can surface them.
//
// Cycles are handled with a numeric id table and explicit `ref` nodes.

import Foundation

// MARK: - Public Result Types

/// Result of `JeffJSEnvironment.snapshotUserGlobals()`.
public struct JeffJSSnapshotResult {
    /// JSON blob suitable for `restoreUserGlobals(from:)`.
    public let json: String
    /// User keys whose values could not be serialized (functions, native, etc.).
    /// Each entry is `(propertyPath, reason)` — e.g. `("t", "function")`.
    public let skipped: [(key: String, why: String)]
}

/// Result of `JeffJSEnvironment.restoreUserGlobals(from:)`.
public struct JeffJSRestoreResult {
    /// Number of top-level globalThis keys that were restored.
    public let restored: Int
}

// MARK: - JS Scripts

enum JeffJSGlobalSnapshot {

    /// Serializes user-added globalThis own properties to a tagged JSON tree.
    ///
    /// Function expression — Swift invokes it as `(serializeScript)([names])`
    /// so the baseline list never becomes a global variable. Returns the JSON
    /// string `{"keys": {...}, "skipped": [{key, why}, ...]}`.
    static let serializeScript: String = #"""
    (function(__snapshot_baseline) {
      var baseline = Object.create(null);
      for (var i = 0; i < __snapshot_baseline.length; i++) {
        baseline[__snapshot_baseline[i]] = true;
      }

      var skipped = [];
      var nextId = 0;
      var seen = new Map();

      function classOf(v) {
        return Object.prototype.toString.call(v).slice(8, -1);
      }

      function ser(v, path) {
        if (v === undefined) return { t: 'u' };
        if (v === null) return { t: 'n' };

        var ty = typeof v;
        if (ty === 'boolean') return { t: 'b', v: v };
        if (ty === 'number') {
          if (v !== v) return { t: 'num', v: 'NaN' };
          if (v === Infinity) return { t: 'num', v: 'Inf' };
          if (v === -Infinity) return { t: 'num', v: '-Inf' };
          return { t: 'num', v: v };
        }
        if (ty === 'string') return { t: 's', v: v };
        if (ty === 'bigint') return { t: 'bi', v: v.toString() };
        if (ty === 'symbol') {
          skipped.push({ key: path, why: 'symbol' });
          return null;
        }
        if (ty === 'function') {
          skipped.push({ key: path, why: 'function' });
          return null;
        }
        if (ty !== 'object') {
          skipped.push({ key: path, why: 'unknown:' + ty });
          return null;
        }

        // Object: cycle check first
        if (seen.has(v)) {
          return { t: 'ref', id: seen.get(v) };
        }

        var cls = classOf(v);

        if (cls === 'Date') {
          var did = nextId++;
          seen.set(v, did);
          return { t: 'date', id: did, v: v.getTime() };
        }

        if (cls === 'RegExp') {
          var rid = nextId++;
          seen.set(v, rid);
          return { t: 'rx', id: rid, src: v.source, flg: v.flags };
        }

        if (cls === 'Map') {
          var mid = nextId++;
          seen.set(v, mid);
          var entries = [];
          v.forEach(function(val, key) {
            var ks = ser(key, path + '<key>');
            var vs = ser(val, path + '<val>');
            if (ks && vs) entries.push([ks, vs]);
          });
          return { t: 'map', id: mid, e: entries };
        }

        if (cls === 'Set') {
          var sid = nextId++;
          seen.set(v, sid);
          var items = [];
          v.forEach(function(val) {
            var sv = ser(val, path + '<elem>');
            if (sv) items.push(sv);
          });
          return { t: 'set', id: sid, e: items };
        }

        if (Array.isArray(v)) {
          var aid = nextId++;
          seen.set(v, aid);
          var arr = [];
          for (var i = 0; i < v.length; i++) {
            if (i in v) {
              var ai = ser(v[i], path + '[' + i + ']');
              arr.push(ai || { t: 'u' });
            } else {
              arr.push({ t: 'hole' });
            }
          }
          return { t: 'a', id: aid, v: arr };
        }

        // Plain object only — anything with a custom prototype is skipped.
        var proto = Object.getPrototypeOf(v);
        if (proto !== Object.prototype && proto !== null) {
          skipped.push({ key: path, why: 'class:' + cls });
          return null;
        }

        var oid = nextId++;
        seen.set(v, oid);
        var props = {};
        var names = Object.getOwnPropertyNames(v);
        for (var ni = 0; ni < names.length; ni++) {
          var name = names[ni];
          var desc = Object.getOwnPropertyDescriptor(v, name);
          if (!desc || !('value' in desc)) continue; // skip getters/setters
          var sv = ser(desc.value, path + '.' + name);
          if (sv) props[name] = sv;
        }
        return { t: 'o', id: oid, v: props };
      }

      var keysOut = {};
      var globalKeys = Object.getOwnPropertyNames(globalThis);
      for (var gi = 0; gi < globalKeys.length; gi++) {
        var gk = globalKeys[gi];
        if (baseline[gk]) continue;
        var gdesc = Object.getOwnPropertyDescriptor(globalThis, gk);
        if (!gdesc || !('value' in gdesc)) {
          skipped.push({ key: gk, why: 'getter' });
          continue;
        }
        var gs = ser(gdesc.value, gk);
        if (gs) keysOut[gk] = gs;
      }

      return JSON.stringify({ keys: keysOut, skipped: skipped });
    })
    """#

    /// Restores user globals from a JSON blob produced by `serializeScript`.
    /// Function expression — Swift invokes it as `(restoreScript)("blob")` so
    /// the blob never becomes a global variable. Returns the count of
    /// top-level keys successfully restored.
    ///
    /// All `for-in` loops are converted to C-style for loops over
    /// `Object.keys()` because JeffJS's interpreter has a bug where a
    /// `try/catch` inside a `for-in` body terminates the loop after the
    /// first iteration.
    static let restoreScript: String = #"""
    (function(__snapshot_blob) {
      var data;
      try { data = JSON.parse(__snapshot_blob); } catch (e) { return 0; }
      if (!data || !data.keys) return 0;

      var byId = Object.create(null);

      // First pass: allocate shells for every node with an id so cycles
      // and back-references resolve to the same instance.
      function alloc(node) {
        if (!node || typeof node !== 'object') return;
        switch (node.t) {
          case 'a': {
            byId[node.id] = new Array(node.v.length);
            for (var i = 0; i < node.v.length; i++) alloc(node.v[i]);
            break;
          }
          case 'o': {
            byId[node.id] = {};
            var oks = Object.keys(node.v);
            for (var oi = 0; oi < oks.length; oi++) alloc(node.v[oks[oi]]);
            break;
          }
          case 'date':
            byId[node.id] = new Date(node.v);
            break;
          case 'rx':
            try { byId[node.id] = new RegExp(node.src, node.flg); }
            catch (e) { byId[node.id] = new RegExp(''); }
            break;
          case 'map': {
            byId[node.id] = new Map();
            for (var mi = 0; mi < node.e.length; mi++) {
              alloc(node.e[mi][0]);
              alloc(node.e[mi][1]);
            }
            break;
          }
          case 'set': {
            byId[node.id] = new Set();
            for (var si = 0; si < node.e.length; si++) alloc(node.e[si]);
            break;
          }
        }
      }

      // Second pass: fill in shells and resolve primitives.
      function resolve(node) {
        if (!node) return undefined;
        switch (node.t) {
          case 'u':   return undefined;
          case 'n':   return null;
          case 'b':   return node.v;
          case 's':   return node.v;
          case 'num':
            if (node.v === 'NaN')  return NaN;
            if (node.v === 'Inf')  return Infinity;
            if (node.v === '-Inf') return -Infinity;
            return node.v;
          case 'bi':  return BigInt(node.v);
          case 'hole':return undefined;
          case 'ref': return byId[node.id];
          case 'a': {
            var arr = byId[node.id];
            for (var i = 0; i < node.v.length; i++) arr[i] = resolve(node.v[i]);
            return arr;
          }
          case 'o': {
            var obj = byId[node.id];
            var oks2 = Object.keys(node.v);
            for (var oi2 = 0; oi2 < oks2.length; oi2++) {
              obj[oks2[oi2]] = resolve(node.v[oks2[oi2]]);
            }
            return obj;
          }
          case 'date': return byId[node.id];
          case 'rx':   return byId[node.id];
          case 'map': {
            var m = byId[node.id];
            for (var mi2 = 0; mi2 < node.e.length; mi2++) {
              m.set(resolve(node.e[mi2][0]), resolve(node.e[mi2][1]));
            }
            return m;
          }
          case 'set': {
            var s = byId[node.id];
            for (var si2 = 0; si2 < node.e.length; si2++) s.add(resolve(node.e[si2]));
            return s;
          }
          default: return undefined;
        }
      }

      // Top-level keys: allocate all shells first so refs across keys work.
      var topKeys = Object.keys(data.keys);
      for (var ai = 0; ai < topKeys.length; ai++) alloc(data.keys[topKeys[ai]]);

      // Then assign each. We need a try/catch per assignment so that one
      // unsupported key doesn't poison the rest, and JeffJS's for-in/try
      // bug forces us to use C-style iteration over Object.keys().
      var restored = 0;
      for (var ri = 0; ri < topKeys.length; ri++) {
        var rk = topKeys[ri];
        try {
          globalThis[rk] = resolve(data.keys[rk]);
          restored++;
        } catch (e) {}
      }
      return restored;
    })
    """#

    /// Deletes every globalThis own property that is not in the baseline.
    /// Function expression — Swift invokes it as `(clearScript)([names])`.
    /// Returns the number of keys cleared.
    static let clearScript: String = #"""
    (function(__snapshot_baseline) {
      var baseline = Object.create(null);
      for (var i = 0; i < __snapshot_baseline.length; i++) {
        baseline[__snapshot_baseline[i]] = true;
      }
      var keys = Object.getOwnPropertyNames(globalThis);
      var cleared = 0;
      for (var ki = 0; ki < keys.length; ki++) {
        var k = keys[ki];
        if (baseline[k]) continue;
        try {
          delete globalThis[k];
          cleared++;
        } catch (e) {}
      }
      return cleared;
    })
    """#

    /// Lists every globalThis own property name. Used by `JeffJSEnvironment`
    /// to capture the baseline at the end of `init`.
    static let listGlobalsScript: String = #"""
    (function() {
      return JSON.stringify(Object.getOwnPropertyNames(globalThis));
    })()
    """#

    // MARK: - Helpers

    /// Encodes a Swift string array as a JS array literal (`["a","b"]`).
    /// Used to inject the baseline name list into the JS scripts.
    static func jsArrayLiteral(_ names: [String]) -> String {
        guard let data = try? JSONEncoder().encode(names),
              let str = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return str
    }

    /// Encodes a Swift string as a JS string literal (`"escaped"`). Used to
    /// inject the snapshot blob into the restore script.
    static func jsStringLiteral(_ s: String) -> String {
        guard let data = try? JSONEncoder().encode(s),
              let str = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return str
    }

    /// Decodes the JSON blob produced by `serializeScript` and extracts the
    /// `skipped` list (`[{key, why}, ...]`) without forcing a full Codable
    /// model on the data — `keys` stays opaque and is round-tripped as-is.
    static func decodeSkipped(from json: String) -> [(key: String, why: String)] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["skipped"] as? [[String: Any]] else {
            return []
        }
        return arr.compactMap { entry in
            guard let key = entry["key"] as? String,
                  let why = entry["why"] as? String else { return nil }
            return (key, why)
        }
    }
}
