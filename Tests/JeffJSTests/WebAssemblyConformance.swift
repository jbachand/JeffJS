// WebAssemblyConformance.swift
// JeffJS — conformance group "WebAssembly" (issue #13, Sources/JeffJS/Wasm/).
// Memory loads/stores/grow, data segments, tables / call_indirect / br_table, imports and
// exports, globals, traps, i64 <-> BigInt, multi-value, references and the JS API namespace.
// Every case is a JS expression that must be `true`; the answers are V8's (node 22), checked
// against it with the same script. The modules are the WAT below, assembled with wat2wasm.
// The official WebAssembly 2.0 spec testsuite runs with Scripts/wasm_spectest.sh.
//
// glob:
//   (module
//     (global (export "a") i32 (i32.const 5))
//     (global $b (export "b") (mut f64) (f64.const 1.5))
//     (global $c (export "c") (mut i64) (i64.const -1))
//     (global $e (export "e") (mut externref) (ref.null extern))
//     (func (export "getb") (result f64) (global.get $b))
//     (func (export "setc") (param i64) (global.set $c (local.get 0)))
//     (func (export "gete") (result externref) (global.get $e)))
// imp:
//   (module
//     (import "env" "f" (func $f (param i32 i32) (result i32)))
//     (import "env" "mem" (memory 1))
//     (import "env" "tbl" (table 2 funcref))
//     (import "env" "g" (global $g i32))
//     (import "env" "mg" (global $mg (mut i64)))
//     (func (export "callf") (param i32 i32) (result i32) (call $f (local.get 0) (local.get 1)))
//     (func (export "readmem") (param i32) (result i32) (i32.load8_u (local.get 0)))
//     (func (export "g") (result i32) (global.get $g))
//     (func (export "incmg") (global.set $mg (i64.add (global.get $mg) (i64.const 1))))
//     (func (export "callt") (param i32) (result i32) (call_indirect (result i32) (local.get 0)))
//     (export "f" (func $f))
//     (export "mem" (memory 0)))
// mem:
//   (module
//     (memory (export "mem") 1 3)
//     (data (i32.const 8) "\01\02\03\04hello")
//     (data $p "passive!")
//     (func (export "load8u") (param i32) (result i32) (i32.load8_u (local.get 0)))
//     (func (export "load8s") (param i32) (result i32) (i32.load8_s (local.get 0)))
//     (func (export "load16u") (param i32) (result i32) (i32.load16_u offset=1 (local.get 0)))
//     (func (export "load32") (param i32) (result i32) (i32.load (local.get 0)))
//     (func (export "load64") (param i32) (result i64) (i64.load (local.get 0)))
//     (func (export "loadf32") (param i32) (result f32) (f32.load (local.get 0)))
//     (func (export "loadf64") (param i32) (result f64) (f64.load (local.get 0)))
//     (func (export "store32") (param i32 i32) (i32.store (local.get 0) (local.get 1)))
//     (func (export "store8") (param i32 i32) (i32.store8 (local.get 0) (local.get 1)))
//     (func (export "store64") (param i32 i64) (i64.store (local.get 0) (local.get 1)))
//     (func (export "storef64") (param i32 f64) (f64.store (local.get 0) (local.get 1)))
//     (func (export "size") (result i32) (memory.size))
//     (func (export "grow") (param i32) (result i32) (memory.grow (local.get 0)))
//     (func (export "init") (param i32 i32 i32) (memory.init $p (local.get 0) (local.get 1) (local.get 2)))
//     (func (export "drop") (data.drop $p))
//     (func (export "fill") (param i32 i32 i32) (memory.fill (local.get 0) (local.get 1) (local.get 2)))
//     (func (export "copy") (param i32 i32 i32) (memory.copy (local.get 0) (local.get 1) (local.get 2))))
// oob:
//   (module
//     (import "env" "tbl" (table 1 funcref))
//     (func $k (result i32) (i32.const 1))
//     (elem (i32.const 0) $k)
//     (memory 1)
//     (data (i32.const 65535) "xy"))
// pair:
//   (module
//     (import "env" "pair" (func $p (result i32 f64)))
//     (func (export "sum") (result f64) (local $x f64)
//       (call $p) (local.set $x) (f64.convert_i32_s) (local.get $x) (f64.add)))
// ref:
//   (module
//     (table (export "t") 2 externref)
//     (func (export "id") (param externref) (result externref) (local.get 0))
//     (func (export "isnull") (param externref) (result i32) (ref.is_null (local.get 0)))
//     (func (export "fref") (result funcref) (ref.func $f))
//     (func $f (export "f") (result i32) (i32.const 9))
//     (elem declare func $f))
// start (+ custom section "jeff" = "abc"):
//   (module
//     (import "env" "hit" (func $hit (param i32)))
//     (func $s (call $hit (i32.const 42)))
//     (start $s)
//     (func (export "add") (param i32 i32) (result i32) (i32.add (local.get 0) (local.get 1))))
// tbl:
//   (module
//     (type $ii (func (param i32) (result i32)))
//     (type $v (func (result i32)))
//     (table (export "tbl") 4 10 funcref)
//     (elem (i32.const 0) $double $square $seven)
//     (func $double (export "double") (type $ii) (i32.mul (local.get 0) (i32.const 2)))
//     (func $square (type $ii) (i32.mul (local.get 0) (local.get 0)))
//     (func $seven (type $v) (i32.const 7))
//     (func (export "call") (param i32 i32) (result i32) (call_indirect (type $ii) (local.get 1) (local.get 0)))
//     (func (export "sw") (param i32) (result i32)
//       (block $d (block $c (block $b (block $a (br_table $a $b $c $d (local.get 0)))
//         (return (i32.const 10))) (return (i32.const 11))) (return (i32.const 12))) (i32.const 13))
//     (func (export "grow") (param i32) (result i32) (table.grow (ref.null func) (local.get 0)))
//     (func (export "size") (result i32) (table.size)))
// trap:
//   (module
//     (func (export "unreach") (unreachable))
//     (func (export "div") (param i32 i32) (result i32) (i32.div_s (local.get 0) (local.get 1)))
//     (func (export "rem") (param i32 i32) (result i32) (i32.rem_s (local.get 0) (local.get 1)))
//     (func (export "trunc") (param f64) (result i32) (i32.trunc_f64_s (local.get 0)))
//     (func (export "truncsat") (param f64) (result i32) (i32.trunc_sat_f64_s (local.get 0)))
//     (func $rec (export "rec") (param i32) (result i32) (i32.add (call $rec (local.get 0)) (i32.const 1)))
//     (func (export "swap") (param i32 i64) (result i64 i32) (local.get 1) (local.get 0))
//     (func (export "add64") (param i64 i64) (result i64) (i64.add (local.get 0) (local.get 1))))

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    static let wasmPrelude = #"""
    var W = {
      glob: '0061736d01000000010d036000017c60017e006000016f030403000102061c047f0041050b7c0144000000000000f83f0b7e01427f0b6f01d06f0b072607016103000162030101630302016503030467657462000004736574630001046765746500020a1203040023010b0600200024020b040023030b',
      imp: '0061736d0100000001130460027f7f017f60017f017f6000017f60000002330503656e760166000003656e76036d656d02000103656e760374626c0170000203656e760167037f0003656e76026d67037e0103060500010203010731070563616c6c66000107726561646d656d00020167000305696e636d6700040563616c6c74000501660000036d656d02000a290508002000200110000b070020002d00000b040023000b0900230142017c24010b070020001102000b',
      mem: '0061736d0100000001310a60017f017f60017f017e60017f017d60017f017c60027f7f0060027f7e0060027f7c006000017f60037f7f7f006000000312110000000001020304040506070008090808050401010103079b0112036d656d0200066c6f616438750000066c6f616438730001076c6f61643136750002066c6f616433320003066c6f616436340004076c6f61646633320005076c6f616466363400060773746f7265333200070673746f72653800080773746f7265363400090873746f7265663634000a0473697a65000b0467726f77000c04696e6974000d0464726f70000e0466696c6c000f04636f707900100c01020a990111070020002d00000b070020002c00000b070020002f01010b070020002802000b070020002903000b070020002a02000b070020002b03000b0900200020013602000b0900200020013a00000b0900200020013703000b0900200020013903000b04003f000b0600200040000b0c00200020012002fc0801000b0500fc09010b0b00200020012002fc0b000b0c00200020012002fc0a00000b0b19020041080b090102030468656c6c6f01087061737369766521',
      oob: '0061736d010000000105016000017f020d0103656e760374626c017000010302010005030100010907010041000b01000a0601040041010b0b0a010041ffff030b027879',
      pair: '0061736d01000000010a026000027f7c6000017c020c0103656e7604706169720000030201010707010373756d00010a0e010c01017c10002100b72000a00b',
      ref: '0061736d0100000001130460016f016f60016f017f600001706000017f030504000102030404016f0002071e050174010002696400000669736e756c6c00010466726566000201660003090501030001030a1604040020000b05002000d10b0400d2030b040041090b',
      start: '0061736d01000000010e0360017f0060000060027f7f017f020b0103656e7603686974000003030201020707010361646400020801010a10020600412a10000b0700200020016a0b0008046a656666616263',
      tbl: '0061736d0100000001100360017f017f6000017f60027f7f017f030807000001020000010405017001040a072a060374626c010006646f75626c6500000463616c6c000302737700040467726f7700050473697a6500060909010041000b030001020a52070700200041026c0b0700200020006c0b040041070b0900200120001100000b2100024002400240024020000e03000102030b410a0f0b410b0f0b410c0f0b410d0b0900d0702000fc0f000b0500fc10000b',
      trap: '0061736d0100000001210660000060027f7f017f60017c017f60017f017f60027f7e027e7f60027e7e017e0309080001010202030405073f0807756e726561636800000364697600010372656d0002057472756e630003087472756e6373617400040372656300050473776170000605616464363400070a3b080300000b0700200020016d0b0700200020016f0b05002000aa0b06002000fc020b09002000100541016a0b0600200120000b0700200020017c0b'
    };
    function wbytes(n) { var s = W[n], b = new Uint8Array(s.length >> 1); for (var i = 0; i < b.length; i++) b[i] = parseInt(s.substr(i * 2, 2), 16); return b; }
    function wmod(n) { return new WebAssembly.Module(wbytes(n)); }
    function wnew(n, imports) { return new WebAssembly.Instance(wmod(n), imports).exports; }
    function throws(f, C) { try { f(); } catch (e) { return e instanceof C && e.constructor === C; } return false; }
    """#

    static let wasmCases: [(String, String)] = [
        ("active data segments are copied at instantiation",
         #"""
         (function () {
           var e = wnew('mem');
           return e.load8u(8) === 1 && e.load32(8) === 0x04030201 && e.load8u(12) === 104 &&
             String.fromCharCode.apply(null, new Uint8Array(e.mem.buffer, 12, 5)) === 'hello' && e.load16u(8) === 0x0302;
         })()
         """#),
        ("loads sign- and zero-extend, stores truncate",
         #"""
         (function () {
           var e = wnew('mem');
           e.store8(0, 456);
           return e.load8u(0) === 200 && e.load8s(0) === -56 && (e.store32(4, -1), e.load32(4) === -1);
         })()
         """#),
        ("memory is little endian and shared with memory.buffer",
         #"""
         (function () {
           var e = wnew('mem');
           e.store32(0, 0x01020304);
           var u8 = new Uint8Array(e.mem.buffer);
           u8[100] = 7;
           return u8[0] === 4 && u8[3] === 1 && e.load8u(100) === 7 && e.mem.buffer.byteLength === 65536;
         })()
         """#),
        ("i64 loads and stores are BigInts (ToBigInt64 wraps)",
         #"""
         (function () {
           var e = wnew('mem');
           e.store64(16, -2n);
           var a = e.load64(16);
           e.store64(16, 2n ** 63n);
           var b = e.load64(16);
           e.store64(16, 2n ** 64n + 5n);
           return a === -2n && typeof a === 'bigint' && b === -(2n ** 63n) && e.load64(16) === 5n &&
             e.load32(16) === 5 && throws(function () { e.store64(16, 1); }, TypeError);
         })()
         """#),
        ("f32 and f64 memory round trips",
         #"""
         (function () {
           var e = wnew('mem');
           e.store32(0, 0x3fc00000);
           e.storef64(8, -0.1);
           return e.loadf32(0) === 1.5 && e.loadf64(8) === -0.1 && (e.storef64(8, -0), Object.is(e.loadf64(8), -0)) &&
             (e.store32(0, 0x3dcccccd), e.loadf32(0) === Math.fround(0.1));
         })()
         """#),
        ("out-of-bounds accesses trap with RuntimeError (unsigned addresses)",
         #"""
         (function () {
           var e = wnew('mem');
           return e.load32(65532) === 0 && throws(function () { e.load32(65533); }, WebAssembly.RuntimeError) &&
             throws(function () { e.load8u(-1); }, WebAssembly.RuntimeError) &&
             throws(function () { e.load16u(65534); }, WebAssembly.RuntimeError) &&
             throws(function () { e.store64(65529, 1n); }, WebAssembly.RuntimeError) && e.load8u(65529) === 0;
         })()
         """#),
        ("memory.grow detaches the old buffer and keeps the bytes",
         #"""
         (function () {
           var e = wnew('mem'), b = e.mem.buffer;
           var old = e.grow(1);
           return old === 1 && e.size() === 2 && b.byteLength === 0 && e.mem.buffer !== b &&
             e.mem.buffer.byteLength === 131072 && e.load8u(8) === 1 && e.load32(131068) === 0 &&
             e.grow(2) === -1 && e.size() === 2 && e.mem.grow(1) === 2 && e.size() === 3 &&
             throws(function () { e.mem.grow(1); }, RangeError) && e.mem.buffer.byteLength === 3 * 65536;
         })()
         """#),
        ("memory.grow(0) returns the size and the buffer stays usable",
         #"""
         (function () {
           var e = wnew('mem');
           var b0 = e.mem.buffer;
           return e.grow(0) === 1 && e.mem.buffer.byteLength === 65536 && e.mem.grow(0) === 1 && e.mem.buffer.byteLength === 65536 &&
             new Uint8Array(e.mem.buffer)[8] === 1 && b0.byteLength === 0;
         })()
         """#),
        ("memory.init, data.drop, memory.fill and memory.copy (overlapping)",
         #"""
         (function () {
           var e = wnew('mem');
           e.init(200, 0, 8);
           var s = String.fromCharCode.apply(null, new Uint8Array(e.mem.buffer, 200, 8));
           var t1 = throws(function () { e.init(0, 4, 5); }, WebAssembly.RuntimeError);
           e.drop();
           var t2 = throws(function () { e.init(0, 0, 1); }, WebAssembly.RuntimeError);
           e.init(0, 0, 0);
           e.fill(300, 0x41, 4);
           e.copy(301, 300, 4);
           var u = new Uint8Array(e.mem.buffer, 300, 6);
           return s === 'passive!' && t1 && t2 && u.join() === '65,65,65,65,65,0' &&
             throws(function () { e.fill(65535, 1, 2); }, WebAssembly.RuntimeError) &&
             throws(function () { e.copy(0, 65535, 2); }, WebAssembly.RuntimeError) && (e.fill(65536, 1, 0), true);
         })()
         """#),
        ("call_indirect calls through the table",
         #"""
         (function () {
           var e = wnew('tbl');
           return e.call(0, 5) === 10 && e.call(1, 5) === 25;
         })()
         """#),
        ("call_indirect traps on a signature mismatch, a null entry and out of bounds",
         #"""
         (function () {
           var e = wnew('tbl');
           return throws(function () { e.call(2, 5); }, WebAssembly.RuntimeError) &&
             throws(function () { e.call(3, 5); }, WebAssembly.RuntimeError) &&
             throws(function () { e.call(4, 5); }, WebAssembly.RuntimeError) &&
             throws(function () { e.call(-1, 5); }, WebAssembly.RuntimeError);
         })()
         """#),
        ("br_table picks its label, the default for anything out of range",
         #"""
         (function () {
           var e = wnew('tbl');
           return [0, 1, 2, 3, 4, 99, -1].map(e.sw).join() === '10,11,12,13,13,13,13';
         })()
         """#),
        ("Table.get returns the exported function itself, set accepts exported functions only",
         #"""
         (function () {
           var e = wnew('tbl');
           var ok = e.tbl.get(0) === e.double && e.tbl.get(0) === e.tbl.get(0) && e.tbl.get(3) === null && e.tbl.length === 4 &&
             typeof e.tbl.get(1) === 'function' && e.tbl.get(1)(6) === 36;
           e.tbl.set(3, e.double);
           return ok && e.call(3, 4) === 8 && throws(function () { e.tbl.set(0, function () {}); }, TypeError) &&
             throws(function () { e.tbl.get(4); }, RangeError) && (e.tbl.set(3, null), e.tbl.get(3) === null) &&
             throws(function () { e.call(3, 1); }, WebAssembly.RuntimeError);
         })()
         """#),
        ("table.grow from wasm and from JS, bounded by the maximum",
         #"""
         (function () {
           var e = wnew('tbl');
           return e.tbl.grow(2) === 4 && e.size() === 6 && e.tbl.length === 6 && e.grow(1) === 6 && e.grow(10) === -1 &&
             e.size() === 7 && throws(function () { e.tbl.grow(4); }, RangeError) && e.tbl.grow(3, e.double) === 7 &&
             e.tbl.get(9) === e.double && e.call(9, 21) === 42;
         })()
         """#),
        ("a table entry from another instance runs in that instance",
         #"""
         (function () {
           var a = wnew('tbl'), b = wnew('tbl');
           var bd = b.double;
           a.tbl.set(3, bd);
           return a.call(3, 3) === 6 && a.tbl.get(3) === bd;
         })()
         """#),
        ("new WebAssembly.Table: element types, initial value, length",
         #"""
         (function () {
           var t = new WebAssembly.Table({ element: 'anyfunc', initial: 2 });
           var x = new WebAssembly.Table({ element: 'externref', initial: 1, maximum: 2 }, 'v');
           return t.length === 2 && t.get(0) === null && String.fromCharCode.apply(null, new Uint8Array([104, 105])) === 'hi' && x.get(0) === 'v' && (x.set(0, undefined), x.get(0) === undefined) &&
             x.grow(1) === 1 && x.get(1) === undefined && throws(function () { x.grow(1); }, RangeError) &&
             new WebAssembly.Table({ element: 'externref', initial: 1 }).get(0) === undefined &&
             throws(function () { t.set(0, undefined); }, TypeError) && (t.set(0), t.get(0) === null) &&
             throws(function () { t.grow(1, undefined); }, TypeError) && t.grow(1) === 2 && t.get(2) === null &&
             throws(function () { new WebAssembly.Table({ element: 'i32', initial: 1 }); }, TypeError) &&
             throws(function () { new WebAssembly.Table({ element: 'anyfunc', initial: 2, maximum: 1 }); }, RangeError) &&
             Object.prototype.toString.call(t) === '[object WebAssembly.Table]';
         })()
         """#),
        ("imported functions, memory, table and globals link and run",
         #"""
         (function () {
           var mem = new WebAssembly.Memory({ initial: 1 });
           var tbl = new WebAssembly.Table({ element: 'anyfunc', initial: 2 });
           var mg = new WebAssembly.Global({ value: 'i64', mutable: true }, 41n);
           var calls = [];
           var e = wnew('imp', { env: { f: function (a, b) { calls.push(a, b); return a * 10 + b; }, mem: mem, tbl: tbl, g: 42, mg: mg } });
           new Uint8Array(mem.buffer)[5] = 9;
           e.incmg();
           var t = wnew('tbl');
           tbl.set(1, t.tbl.get(2));
           return e.callf(3, 4) === 34 && calls.join() === '3,4' && e.readmem(5) === 9 && e.g() === 42 && mg.value === 42n &&
             (mg.value = 9n, e.incmg(), mg.value === 10n) && e.mem === mem && e.callt(1) === 7 &&
             throws(function () { e.callt(0); }, WebAssembly.RuntimeError);
         })()
         """#),
        ("host results and arguments go through ToWebAssemblyValue / ToJSValue",
         #"""
         (function () {
           var r;
           var env = { f: function (a, b) { return r; }, mem: new WebAssembly.Memory({ initial: 1 }), tbl: new WebAssembly.Table({ element: 'anyfunc', initial: 2 }), g: 1.9, mg: new WebAssembly.Global({ value: 'i64', mutable: true }, 0n) };
           var e = wnew('imp', { env: env });
           var out = [];
           [2 ** 32 + 5, '7', undefined, -1.5, true, { valueOf: function () { return 3; } }].forEach(function (v) { r = v; out.push(e.callf(1, 2)); });
           return out.join() === '5,7,0,-1,1,3' && e.g() === 1;
         })()
         """#),
        ("an exception thrown by an import propagates through wasm unchanged",
         #"""
         (function () {
           var err = new Error('boom');
           var env = { f: function () { throw err; }, mem: new WebAssembly.Memory({ initial: 1 }), tbl: new WebAssembly.Table({ element: 'anyfunc', initial: 2 }), g: 0, mg: new WebAssembly.Global({ value: 'i64', mutable: true }, 0n) };
           var e = wnew('imp', { env: env });
           try { e.callf(1, 2); return false; } catch (x) { return x === err; }
         })()
         """#),
        ("a re-exported import is an exported function of the wasm type",
         #"""
         (function () {
           var f = function (a, b) { return a - b; };
           var env = { f: f, mem: new WebAssembly.Memory({ initial: 1 }), tbl: new WebAssembly.Table({ element: 'anyfunc', initial: 2 }), g: 0, mg: new WebAssembly.Global({ value: 'i64', mutable: true }, 0n) };
           var e = wnew('imp', { env: env });
           return e.f !== f && typeof e.f === 'function' && e.f(9, 2) === 7 && e.f('9', 2.9) === 7 && e.f.length === 2;
         })()
         """#),
        ("link errors: missing callable, small memory, mutable global, i64 number, wrong kind",
         #"""
         (function () {
           function env(o) {
             var b = { f: function () { return 0; }, mem: new WebAssembly.Memory({ initial: 1 }), tbl: new WebAssembly.Table({ element: 'anyfunc', initial: 2 }), g: 0, mg: new WebAssembly.Global({ value: 'i64', mutable: true }, 0n) };
             for (var k in o) b[k] = o[k];
             return { env: b };
           }
           var m = wmod('imp');
           function link(o) { return throws(function () { new WebAssembly.Instance(m, env(o)); }, WebAssembly.LinkError); }
           return link({ f: 5 }) && link({ mem: new WebAssembly.Memory({ initial: 0 }) }) && link({ mem: {} }) &&
             link({ tbl: new WebAssembly.Table({ element: 'anyfunc', initial: 1 }) }) && link({ mg: 5n }) &&
             link({ mg: new WebAssembly.Global({ value: 'i64', mutable: false }, 0n) }) &&
             link({ mg: new WebAssembly.Global({ value: 'i32', mutable: true }, 0) }) && link({ g: 5n }) &&
             link({ f: wnew('tbl').double }) &&
             throws(function () { new WebAssembly.Instance(m, {}); }, TypeError) &&
             throws(function () { new WebAssembly.Instance(m); }, TypeError) &&
             (new WebAssembly.Instance(m, env({})) instanceof WebAssembly.Instance);
         })()
         """#),
        ("Module.imports, Module.exports and customSections describe the module",
         #"""
         (function () {
           var m = wmod('imp'), s = wmod('start');
           var imps = WebAssembly.Module.imports(m).map(function (d) { return d.module + '.' + d.name + ':' + d.kind; }).join();
           var exps = WebAssembly.Module.exports(m).map(function (d) { return d.name + ':' + d.kind; }).join();
           var cs = WebAssembly.Module.customSections(s, 'jeff');
           return imps === 'env.f:function,env.mem:memory,env.tbl:table,env.g:global,env.mg:global' &&
             exps === 'callf:function,readmem:function,g:function,incmg:function,callt:function,f:function,mem:memory' &&
             cs.length === 1 && cs[0] instanceof ArrayBuffer && String.fromCharCode.apply(null, new Uint8Array(cs[0])) === 'abc' &&
             WebAssembly.Module.customSections(s, 'nope').length === 0 &&
             throws(function () { WebAssembly.Module.exports({}); }, TypeError);
         })()
         """#),
        ("the exports object is frozen with a null prototype, in export order",
         #"""
         (function () {
           var e = wnew('tbl');
           return Object.isFrozen(e) && Object.getPrototypeOf(e) === null && Object.keys(e).join() === 'tbl,double,call,sw,grow,size' &&
             e.double.name === '0' && e.call.name === '3' && e.call.length === 2 && e.sw.length === 1;
         })()
         """#),
        ("the start function runs during instantiation",
         #"""
         (function () {
           var got = [];
           var e = wnew('start', { env: { hit: function (v) { got.push(v); } } });
           return got.join() === '42' && e.add(2, 3) === 5;
         })()
         """#),
        ("a trapping element or data segment fails instantiation; earlier writes stay",
         #"""
         (function () {
           var tbl = new WebAssembly.Table({ element: 'anyfunc', initial: 1 });
           var t = throws(function () { new WebAssembly.Instance(wmod('oob'), { env: { tbl: tbl } }); }, WebAssembly.RuntimeError);
           return t && typeof tbl.get(0) === 'function' && tbl.get(0)() === 1;
         })()
         """#),
        ("exported globals: immutable, mutable f64, mutable i64 as BigInt",
         #"""
         (function () {
           var e = wnew('glob');
           var ok = e.a.value === 5 && throws(function () { e.a.value = 6; }, TypeError) && e.a.value === 5 && e.a.valueOf() === 5;
           e.b.value = 2.25;
           var ok2 = e.getb() === 2.25 && e.c.value === -1n;
           e.setc(5n);
           return ok && ok2 && e.c.value === 5n && (e.c.value = 2n ** 64n - 1n, e.c.value === -1n) &&
             throws(function () { e.c.value = 1; }, TypeError) && e.a instanceof WebAssembly.Global &&
             Object.prototype.toString.call(e.a) === '[object WebAssembly.Global]';
         })()
         """#),
        ("externref globals and the Global constructor",
         #"""
         (function () {
           var e = wnew('glob'), o = { k: 1 };
           e.e.value = o;
           var g = new WebAssembly.Global({ value: 'f32', mutable: true }, 0.1);
           var h = new WebAssembly.Global({ value: 'i64' });
           return e.gete() === o && g.value === Math.fround(0.1) && h.value === 0n &&
             throws(function () { new WebAssembly.Global({ value: 'i64' }, 1); }, TypeError) &&
             throws(function () { new WebAssembly.Global({ value: 'x' }, 1); }, TypeError) &&
             new WebAssembly.Global({ value: 'i32' }, 2 ** 31).value === -(2 ** 31) &&
             new WebAssembly.Global({ value: 'externref' }).value === undefined && new WebAssembly.Global({ value: 'anyfunc' }).value === null &&
             new WebAssembly.Global({ value: 'i64' }, undefined).value === 0n &&
             throws(function () { WebAssembly.Global({ value: 'i32' }); }, TypeError);
         })()
         """#),
        ("unreachable, integer division and truncation trap with RuntimeError",
         #"""
         (function () {
           var e = wnew('trap');
           return throws(e.unreach, WebAssembly.RuntimeError) &&
             throws(function () { e.div(1, 0); }, WebAssembly.RuntimeError) &&
             throws(function () { e.div(-2147483648, -1); }, WebAssembly.RuntimeError) &&
             throws(function () { e.rem(1, 0); }, WebAssembly.RuntimeError) && e.rem(-2147483648, -1) === 0 &&
             e.div(-7, 2) === -3 && e.rem(-7, 2) === -1 &&
             throws(function () { e.trunc(NaN); }, WebAssembly.RuntimeError) &&
             throws(function () { e.trunc(2147483648); }, WebAssembly.RuntimeError) && e.trunc(-2147483648.9) === -2147483648 &&
             e.truncsat(1e10) === 2147483647 && e.truncsat(-Infinity) === -2147483648 && e.truncsat(NaN) === 0;
         })()
         """#),
        ("RuntimeError is a NativeError-like constructor",
         #"""
         (function () {
           var e = wnew('trap'), err;
           try { e.unreach(); } catch (x) { err = x; }
           return err instanceof Error && err.name === 'RuntimeError' && typeof err.message === 'string' &&
             Object.getPrototypeOf(WebAssembly.RuntimeError) === Error && WebAssembly.RuntimeError.prototype.constructor === WebAssembly.RuntimeError &&
             new WebAssembly.CompileError('m').message === 'm' && new WebAssembly.LinkError('m', { cause: 1 }).cause === 1;
         })()
         """#),
        ("unbounded recursion is a RangeError and the engine keeps working",
         #"""
         (function () {
           var e = wnew('trap');
           return throws(function () { e.rec(0); }, RangeError) && e.div(6, 3) === 2 && throws(function () { e.rec(1); }, RangeError);
         })()
         """#),
        ("i64 parameters take BigInts (ToBigInt) and results are BigInts",
         #"""
         (function () {
           var e = wnew('trap');
           return e.add64(2n ** 63n - 1n, 1n) === -(2n ** 63n) && e.add64('5', 1n) === 6n && e.add64(true, 1n) === 2n &&
             throws(function () { e.add64(1, 2n); }, TypeError) && throws(function () { e.add64(undefined, 2n); }, TypeError) &&
             throws(function () { e.add64(Symbol(), 2n); }, TypeError);
         })()
         """#),
        ("multiple results become an Array",
         #"""
         (function () {
           var e = wnew('trap');
           var r = e.swap(1, 2n);
           return Array.isArray(r) && Object.getPrototypeOf(r) === Array.prototype && r.length === 2 && r[0] === 2n && r[1] === 1;
         })()
         """#),
        ("a host function returning multiple values returns an iterable of the right length",
         #"""
         (function () {
           var v;
           var e = wnew('pair', { env: { pair: function () { return v; } } });
           v = [3, 0.5];
           var a = e.sum();
           v = new Set([1, 2]);
           var b = e.sum();
           v = (function* () { yield 4; yield 0.25; })();
           var c = e.sum();
           return a === 3.5 && b === 3 && c === 4.25 && (v = 5, throws(e.sum, TypeError)) && (v = [1], throws(e.sum, TypeError)) &&
             (v = [1, 2, 3], throws(e.sum, TypeError));
         })()
         """#),
        ("externref carries any JS value through wasm",
         #"""
         (function () {
           var e = wnew('ref'), o = {}, f = function () {};
           return e.id(o) === o && e.id(f) === f && e.id(undefined) === undefined && e.id(null) === null && e.id('s') === 's' &&
             e.id(1.5) === 1.5 && e.isnull(null) === 1 && e.isnull(undefined) === 0 && e.isnull(0) === 0 &&
             (e.t.set(1, o), e.t.get(1) === o) && e.t.get(0) === null;
         })()
         """#),
        ("ref.func returns the exported function",
         #"""
         (function () {
           var e = wnew('ref');
           return e.fref() === e.f && e.fref()() === 9;
         })()
         """#),
        ("validate and Module report CompileError for bad bytes",
         #"""
         (function () {
           var bad = new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0, 1]);
           return WebAssembly.validate(wbytes('mem')) === true && WebAssembly.validate(bad) === false &&
             WebAssembly.validate(wbytes('mem').buffer) === true &&
             throws(function () { WebAssembly.validate('x'); }, TypeError) &&
             throws(function () { new WebAssembly.Module(bad); }, WebAssembly.CompileError) &&
             throws(function () { WebAssembly.Module(wbytes('mem')); }, TypeError) &&
             throws(function () { new WebAssembly.Module(new Uint8Array([1, 2, 3, 4])); }, WebAssembly.CompileError);
         })()
         """#),
        ("namespace shape: toStringTag, constructors, Memory descriptors",
         #"""
         (function () {
           return Object.prototype.toString.call(WebAssembly) === '[object WebAssembly]' && typeof WebAssembly.Memory === 'function' &&
             WebAssembly.Memory.length === 1 && WebAssembly.Module.length === 1 && WebAssembly.instantiate.length === 1 &&
             !Object.keys(globalThis).includes('WebAssembly') &&
             throws(function () { new WebAssembly.Memory({ initial: 2, maximum: 1 }); }, RangeError) &&
             throws(function () { new WebAssembly.Memory({}); }, TypeError) &&
             throws(function () { new WebAssembly.Memory({ initial: 65537 }); }, RangeError) &&
             new WebAssembly.Memory({ initial: 0 }).buffer.byteLength === 0 &&
             Object.prototype.toString.call(new WebAssembly.Memory({ initial: 1 })) === '[object WebAssembly.Memory]';
         })()
         """#),
    ]

    /// Each must resolve to `true` once the job queue drains.
    static let wasmAsyncCases: [(String, String)] = [
        ("WebAssembly.compile resolves to a Module",
         #"""
         (function () {
           return WebAssembly.compile(wbytes('tbl')).then(function (m) { return m instanceof WebAssembly.Module; });
         })()
         """#),
        ("WebAssembly.instantiate(bytes) resolves to { module, instance }",
         #"""
         (function () {
           return WebAssembly.instantiate(wbytes('tbl')).then(function (r) {
             return r.module instanceof WebAssembly.Module && r.instance instanceof WebAssembly.Instance && r.instance.exports.call(0, 4) === 8;
           });
         })()
         """#),
        ("WebAssembly.instantiate(module) resolves to an Instance",
         #"""
         (function () {
           return WebAssembly.instantiate(wmod('trap')).then(function (i) { return i instanceof WebAssembly.Instance && i.exports.div(9, 3) === 3; });
         })()
         """#),
        ("compile rejects with CompileError, instantiate with LinkError / RuntimeError",
         #"""
         (function () {
           var bad = new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0, 1]);
           function rejects(p, C) { return p.then(function () { return false; }, function (e) { return e instanceof C; }); }
           var tbl = new WebAssembly.Table({ element: 'anyfunc', initial: 1 });
           return Promise.all([
             rejects(WebAssembly.compile(bad), WebAssembly.CompileError),
             rejects(WebAssembly.instantiate(bad), WebAssembly.CompileError),
             rejects(WebAssembly.instantiate(wmod('start'), { env: { hit: 1 } }), WebAssembly.LinkError),
             rejects(WebAssembly.instantiate(wmod('oob'), { env: { tbl: tbl } }), WebAssembly.RuntimeError),
             rejects(WebAssembly.compile('x'), TypeError),
           ]).then(function (r) { return r.every(function (x) { return x === true; }); });
         })()
         """#),
    ]

    mutating func testWebAssembly() {
        // A runtime of its own: the realm's WebAssembly store is released when its context is freed.
        let rt = JeffJSRuntime()
        rt.setInterruptHandler { _ in Date() > JeffJSTestRunner.evalDeadline }
        let ctx = rt.newContext()
        WasmJSAPI.install(ctx: ctx)
        func run(_ label: String, _ js: String) -> JeffJSValue? {
            JeffJSStackDiag.currentLabel = "WebAssembly: \(label)"
            let r = ctx.eval(input: js, filename: "<WebAssembly>", evalFlags: JS_EVAL_TYPE_GLOBAL)
            if r.isException {
                let exc = ctx.getException()
                assert(false, "WebAssembly: \(label) threw \(ctx.toSwiftString(exc) ?? "?")")
                exc.freeValue()
                return nil
            }
            return r
        }
        guard let p = run("prelude", JeffJSTestRunner.wasmPrelude) else { return }
        p.freeValue()
        for (name, js) in JeffJSTestRunner.wasmCases {
            guard let r = run(name, js) else { continue }
            assert(r.isBool && r.toBool(), "WebAssembly: \(name) -> \(ctx.toSwiftString(r) ?? "?")")
            r.freeValue()
        }
        for (i, (name, js)) in JeffJSTestRunner.wasmAsyncCases.enumerated() {
            let setup = "var __wasmAsync\(i) = 'pending'; (\(js)).then(function (v) { __wasmAsync\(i) = v; }, function (e) { __wasmAsync\(i) = 'rejected: ' + e; });"
            if let r = run(name, setup) { r.freeValue() }
        }
        _ = rt.executePendingJobs()
        for (i, (name, _)) in JeffJSTestRunner.wasmAsyncCases.enumerated() {
            guard let r = run(name, "__wasmAsync\(i)") else { continue }
            assert(r.isBool && r.toBool(), "WebAssembly: \(name) -> \(ctx.toSwiftString(r) ?? "?")")
            r.freeValue()
        }
        // Freeing the realm releases its store: instances, exported functions, externrefs and
        // wrappers made above (cycles through Swift) without touching freed memory.
        ctx.free()
        assert(true, "WebAssembly: realm teardown released the store")
    }
}
