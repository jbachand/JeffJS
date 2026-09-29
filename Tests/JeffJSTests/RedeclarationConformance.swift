// RedeclarationConformance.swift
// JeffJS — conformance group "Redeclaration" (early errors, ES §14.2.1 Block,
// §14.12.1 CaseBlock, §14.15.1 Catch, §15.2.1 function bodies, §16.1.1 Script,
// §14.3.3.1 BoundNames of patterns; Annex B.3.2.4 / B.3.4 allowances).
// A LexicallyDeclaredName may not be declared twice, nor also be a
// VarDeclaredName of the same scope (a `var` hoists through every block it sits
// in), nor a parameter name at a function's top level, nor the catch
// parameter's name in the catch block. JeffJS accepted all of them (the second
// `let` silently made another binding). The SyntaxError texts are JSC's.
//
// Every case is (name, JS expression that must evaluate to `true`).

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    static let redeclarationCases: [(String, String)] = [
        ("let / const / class declared twice in one scope",
         #"(function(){ var bad = ['let a; let a;', 'const b = 1; const b = 2;', 'class F {} let F;', 'let u; class u {}', 'let [p, p] = [];', 'const { t, t } = {};', 'for (let [q, q] of []) ;', 'switch (1) { case 1: let m; case 2: let m; }']; return bad.every(function(src){ try { (0, eval)(src); return false; } catch (e) { return e instanceof SyntaxError; } }); })()"#),
        ("let vs var in the same scope, either order, and a var hoisted through a block",
         #"(function(){ var bad = ['{ let c; var c; }', '{ var d; let d; }', 'let x; var x;', 'var y; let y;', '(function(){ let s; { var s; } })', '{ let v; { var v; } }', 'for (var i2 = 0; ; ) {} let i2;', '(function(){ let r; var r; })']; return bad.every(function(src){ try { (0, eval)(src); return false; } catch (e) { return e instanceof SyntaxError; } }); })()"#),
        ("let vs a parameter at the function's top level",
         #"(function(){ var bad = ['(function(a){ let a; })', '(a) => { let a; }', '(function(a = 1){ const a = 2; })', '(function([a]){ let a; })']; return bad.every(function(src){ try { (0, eval)(src); return false; } catch (e) { return e instanceof SyntaxError; } }); })()"#),
        ("function declarations vs lexical declarations",
         #"(function(){ var bad = ['{ let e; function e(){} }', 'let z; function z(){}', 'function w(){} let w;', '{ function f(){} var f; }', '"use strict"; { function k(){} function k(){} }', '(function(){ "use strict"; { function k(){} function k(){} } })']; return bad.every(function(src){ try { (0, eval)(src); return false; } catch (e) { return e instanceof SyntaxError; } }); })()"#),
        ("the catch parameter vs a let in its block",
         #"(function(){ var bad = ['try {} catch (h) { let h; }', 'try {} catch ([r, r]) {}', 'try {} catch ({ h }) { const h = 1; }']; return bad.every(function(src){ try { (0, eval)(src); return false; } catch (e) { return e instanceof SyntaxError; } }); })()"#),
        ("JSC's messages",
         #"(function(){ function msg(src){ try { (0, eval)(src); return 'ok'; } catch (e) { return e.message; } } return /Cannot declare a let variable twice: 'a'\./.test(msg('let a; let a;')) && /Cannot declare a var variable that shadows a let\/const\/class variable: 'x'\./.test(msg('let x; var x;')) && /Cannot declare a const variable twice: 'b'\./.test(msg('const b = 1; const b = 2;')) && /Cannot declare a class twice: 'u'\./.test(msg('let u; class u {}')) && /Cannot declare a function that shadows a let\/const\/class\/function variable 'z'\./.test(msg('let z; function z(){}')); })()"#),
        ("legal redeclarations stay legal",
         #"(function(){ var ok = ['var q1; var q1;', 'function f1(){} function f1(){}', 'var f2; function f2(){}', 'function f3(){} var f3;', 'let l1; { let l1; }', 'for (let i of []) { let i; }', 'for (var i3 = 0; i3 < 1; i3++) { let i3; }', 'try {} catch (h2) { var h2; }', 'try {} catch (h3) { { let h3; } }', '{ function k2(){} function k2(){} }', 'function g1(){ let arguments; }', '(function g2(){ let g2; })', '(function(a, b){ var a; function b(){} })', 'function g3(){ var q; function q(){} let r2; { function r2(){} } }', '(function(a, a){})', 'label: { let lb; } let lb;', 'switch (1) { case 1: function sf(){} break; case 2: function sf(){} }', 'let x5 = 1; (function(){ var x5 = 2; })();', 'let x6; { var y6; }']; return ok.every(function(src){ try { (0, eval)(src); return true; } catch (e) { return false; } }); })()"#),
        ("a direct eval's let is its own scope",
         #"(function(){ eval('let x7 = 1;'); eval('let x7 = 2;'); var x8 = 1; eval('let x8 = 2;'); return x8 === 1; })()"#),
    ]

    mutating func testRedeclaration() {
        runTrueCases("Redeclaration", JeffJSTestRunner.redeclarationCases)
    }
}
