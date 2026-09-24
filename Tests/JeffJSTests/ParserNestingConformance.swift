// ParserNestingConformance.swift
// JeffJS — "ParserNesting": how deeply the parser lets expressions nest.
//
// The parser used to stop at a fixed 200 counted frames ("expression too
// deeply nested"), which real minified bundles exceed: recaptcha__en.js line
// 1344 nests ~70 parenthesised assignments `(Z=(A=(b=(...` and every
// parenthesis cost three counted frames. The limit is now the native stack
// (as QuickJS's js_check_stack_overflow), and constructs that are only long
// rather than nested do not recurse at all:
//
//   - binary operator chains (`+`, `||`, `&&`, `??`, mixed precedences) are
//     parsed by precedence climbing: recursion depth is bounded by the number
//     of precedence levels, not by the number of operands;
//   - `c1 ? v1 : c2 ? v2 : ...` chains are parsed in a loop;
//   - genuinely nested constructs (parentheses, calls, arrays, objects,
//     arrows, functions) nest as far as the thread's stack allows and then
//     throw SyntaxError("stack overflow") instead of crashing.
//
// Every case is (name, JS expression that must evaluate to `true`). The
// conformance runner uses a 32 MB stack thread.

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    static let parserNestingCases: [(String, String)] = [
        ("a 10,000-operand + chain",
         "eval(Array(10000).fill('1').join('+')) === 10000"),
        ("a 100,000-operand string concatenation",
         "eval(Array(100000).fill('\"ab\"').join('+')).length === 200000"),
        ("|| / && / ?? / comma chains of 10,000 operands",
         "eval(Array(9999).fill('0').join('||') + '||7') === 7 && eval(Array(10000).fill('1').join('&&')) === 1 && eval(Array(9999).fill('null').join('??') + '??5') === 5 && eval('(' + Array(9999).fill('1').join(',') + ',9)') === 9"),
        ("short-circuit chains still short-circuit",
         "(function(){ var n = 0; function f(v){ n++; return v; } var r = eval(Array(5000).fill('f(0)').join('||') + '||f(3)||f(4)'); var s = eval('f(1)&&f(0)&&' + Array(5000).fill('f(1)').join('&&')); return r === 3 && s === 0 && n === 5003; })()"),
        ("mixed precedences in one long chain",
         "eval(Array(3000).fill('2*3-4/2+1').join('+')) === 15000 && eval('1+2*3**2%5-6/3<<1>>1|8^3&7') === 11 && eval(Array(1000).fill('1|2^3&4==4<5<<1+2*3').join('|')) === 3 && eval(Array(2000).fill('1<<2>>>1').join('>>')) === 2"),
        ("precedence and associativity are unchanged",
         "2 ** 3 ** 2 === 512 && (2 ** 3) ** 2 === 64 && 10 - 4 - 3 === 3 && 64 / 4 / 2 === 8 && 2 * 3 ** 2 === 18 && (null ?? (0 || 2)) === 2 && ((0 || null) ?? 3) === 3 && (null ?? 0 ?? 5) === 0 && 1 + 2 * 3 === 7 && (1 < 2 == true) && ('a' in {a: 1}) === true && 7 - 3 % 2 * 2 === 5 && (5 & 3 | 8 ^ 1) === 9 && ('b' + 1 + 2) === 'b12' && (1 + 2 + 'b') === '3b'"),
        ("`in` in a for head and in brackets inside it, `#x in o` brand checks",
         "(function(){ var o = {a: 1, b: 2}, k = [], n = 0; for (var p in o) k.push(p); for (var i = ['a' in o][0] ? 0 : 1, j = (('b' in o) ? 1 : 0); i < 1; i++) n += j; class C { #p = 1; static has(v){ return #p in v; } static both(v){ return #p in v === true; } } return k.join() === 'a,b' && n === 1 && C.has(new C()) && !C.has({}) && C.both(new C()); })()"),
        ("a 5,000-link ternary chain picks the right branch",
         "(function(){ var src = ''; for (var i = 0; i < 5000; i++) src += 'x===' + i + '?' + i + ':'; src += '-1'; var f = new Function('x', 'return ' + src); return f(0) === 0 && f(2500) === 2500 && f(4999) === 4999 && f(5000) === -1; })()"),
        ("ternary false branches that are assignments, arrows, patterns or yields",
         "(function(){ var x, y, a, b; var t = false ? 1 : x = 5; var g = false ? 1 : v => v * 2; var h = false ? 1 : (v) => v + 1; [a, b] = [1, 2]; var d = false ? 1 : false ? 2 : [a, b] = [3, 4]; var z = true ? 1 : y = 9; var gen = (function*(){ return false ? 1 : yield 7; })(); var af = false ? 1 : async () => 3; return t === 5 && x === 5 && g(4) === 8 && h(1) === 2 && a === 3 && b === 4 && Array.isArray(d) && z === 1 && y === undefined && gen.next().value === 7 && typeof af === 'function'; })()"),
        ("a ternary chain whose last branch is an assignment, compound and logical assignment",
         "(function(){ var o = {n: 1}, q = null; var r = 0 ? 1 : 0 ? 2 : o.n += 4; var s = 0 ? 1 : 0 ? 2 : q ??= 6; return r === 5 && o.n === 5 && s === 6 && q === 6; })()"),
        ("3,000 nested parentheses",
         "eval('('.repeat(3000) + '1' + ')'.repeat(3000)) === 1 && eval('(1+'.repeat(3000) + '1' + ')'.repeat(3000)) === 3001"),
        ("recaptcha-shaped nested parenthesised assignments",
         "(function(){ var n = 400, src = 'var v0'; for (var i = 1; i <= n; i++) src += ',v' + i; src += '; var r = '; for (var i = 0; i < n; i++) src += '(v' + i + '='; src += '[' + n + ']'; for (var i = 0; i < n; i++) src += ')'; src += '; r[0] === ' + n + ' && v0 === v' + (n - 1) + ';'; return eval(src) === true; })()"),
        ("2,000 nested arrays and objects",
         "(function(){ var r = eval('['.repeat(2000) + '1' + ']'.repeat(2000)), d = 0; while (Array.isArray(r)) { r = r[0]; d++; } var o = eval('({a:'.repeat(1) + '{a:'.repeat(1999) + '1' + '}'.repeat(2000) + ')'), e = 0; while (typeof o === 'object') { o = o.a; e++; } return d === 2000 && r === 1 && e === 2000 && o === 1; })()"),
        ("1,000 nested calls, arrows and functions",
         "(function(){ function f(v){ return v; } var c = eval('f('.repeat(1000) + '7' + ')'.repeat(1000)); var a = eval('(x=>'.repeat(1000) + '1' + ')'.repeat(1000)), d = 0; while (typeof a === 'function') { a = a(0); d++; } var m = eval('(x=>f('.repeat(500) + '2' + '))'.repeat(500)), e = 0; while (typeof m === 'function') { m = m(0); e++; } var g = eval('(function(){return '.repeat(500) + '3' + '})'.repeat(500)), k = 0; while (typeof g === 'function') { g = g(); k++; } return c === 7 && d === 1000 && a === 1 && e === 500 && m === 2 && k === 500 && g === 3; })()"),
        ("deep unary and ** chains",
         "eval('!'.repeat(20000) + '1') === true && eval('- '.repeat(20001) + '1') === -1 && eval(Array(2000).fill('1').join('**')) === 1"),
        ("nesting past the stack is a SyntaxError, not a crash",
         "(function(){ var bad = ['('.repeat(1000000) + '1' + ')'.repeat(1000000), '['.repeat(1000000) + ']'.repeat(1000000), 'f('.repeat(1000000), Array(1000000).fill('1').join('**'), '(x=>'.repeat(500000), '{'.repeat(1000000), '!'.repeat(3000000) + '1', 'a?b:('.repeat(500000), 'var ' + '['.repeat(1000000) + 'a' + ']'.repeat(1000000) + ' = 1', 'function f(' + '['.repeat(1000000) + ')', '({a:'.repeat(1000000), '`${'.repeat(1000000)]; var n = 0; for (var i = 0; i < bad.length; i++) { try { eval(bad[i]); } catch (e) { if (e instanceof SyntaxError) n++; } } return n === bad.length; })()"),
        ("parsing still works after a stack-overflow SyntaxError",
         "(function(){ try { eval('('.repeat(1000000)); } catch (e) {} return eval('(1+(2))*3') === 9; })()"),
        ("3,000 nested blocks with let bindings and a closure over them",
         "(function(){ var n = 3000, src = '', r; for (var i = 0; i < n; i++) src += '{ let v' + i + ' = ' + i + ';'; src += 'r = () => v0 + v' + (n - 1) + ';' + '}'.repeat(n); eval(src); return r() === n - 1; })()"),
        ("lookaheads over deep parens and patterns stay linear (would take minutes if quadratic)",
         "(function(){ var t = Date.now(), n = 0; try { eval('(a='.repeat(200000)); } catch (e) { n += e instanceof SyntaxError; } try { eval('({a:'.repeat(200000)); } catch (e) { n += e instanceof SyntaxError; } var a; eval('var ' + '['.repeat(3000) + 'a' + ']'.repeat(3000) + ' = ' + '['.repeat(3000) + '4' + ']'.repeat(3000)); return n === 2 && a === 4 && Date.now() - t < 20000; })()"),
        // (Sequential let-blocks compile in O(n^2) here as in QuickJS, so the
        // positive case stays small.)
        ("sequential blocks, and a clean error past 65,535 scopes in one function",
         "(function(){ var r = eval('var n = 0;' + '{ let q = 1; n += q; }'.repeat(3000) + 'n'); try { eval('{ let q; }'.repeat(70000)); return false; } catch (e) { return r === 3000 && e instanceof SyntaxError; } })()"),
        ("array literals past 16,384 / 65,535 elements keep values and holes",
         "(function(){ var a = eval('[' + Array(70000).fill('7').join(',') + ']'); var b = eval('[' + '1,'.repeat(20000) + ',2,,' + '3,'.repeat(50000) + ']'); var c = eval('[' + '1,'.repeat(20000) + '...[4,5],,6]'); return a.length === 70000 && a[69999] === 7 && b.length === 70003 && !(20000 in b) && b[20001] === 2 && !(20002 in b) && b[70002] === 3 && c.length === 20004 && c[20001] === 5 && c[20003] === 6; })()"),
        ("call argument counts: 60,000 work, past the u16 operand limits an error (as QuickJS), never a crash",
         "(function(){ function f(){ return arguments.length; } var ok = eval('f(' + Array(60000).fill('1').join(',') + ')') === 60000, n = 0; try { eval('f(' + Array(65535).fill('1').join(',') + ')'); } catch (e) { n += e instanceof Error; } try { eval('f(' + Array(70000).fill('1').join(',') + ')'); } catch (e) { n += e instanceof SyntaxError; } return ok && n === 2; })()"),
        ("deeply nested destructuring assignment and binding patterns",
         "(function(){ var a; eval('[' .repeat(300) + 'a' + ']'.repeat(300) + ' = ' + '['.repeat(300) + '5' + ']'.repeat(300)); var f = eval('(function(' + '['.repeat(200) + 'b' + ']'.repeat(200) + '){ return b; })'); return a === 5 && f(eval('['.repeat(200) + '6' + ']'.repeat(200))) === 6; })()"),
    ]

    mutating func testParserNesting() {
        runTrueCases("ParserNesting", JeffJSTestRunner.parserNestingCases)
    }
}
