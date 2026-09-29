// SyntaxErrorTextConformance.swift
// JeffJS — conformance group "SyntaxErrorText". A SyntaxError's `message` is the
// bare text, worded as JavaScriptCore words it ("Unexpected token '}'",
// "Unexpected end of script", "Unexpected identifier 'b'", "Cannot use the keyword
// 'class' as a variable name."); the location is in `line` / `column` (and, for a
// script, in `stack`), never in the message. The engine prefixed every parse
// error with `file:line:col: ` and appended the source line and a caret, in its
// own (QuickJS-derived) wording. The engine's own diagnostic line keeps both.
// Found on the way and fixed with it (ES §13.2.4 / §13.3 / §15.1 / §14.15 /
// §12.7.2 / §12.9.5 early errors): a missing ',' between array elements,
// arguments, parameters, object properties or pattern elements was accepted
// (`[1 2]` was [1, 2]); `try {}` without catch/finally was accepted; reserved
// words were accepted as var / function / class names (`var class = 1`); an
// unterminated regexp at the end of input was accepted; a tokenizer error inside
// a template substitution (`\`${\``) did not fail the parse.
//
// Every case is (name, JS expression that must evaluate to `true`).

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    static let syntaxErrorTextCases: [(String, String)] = [
        ("helper", #"(globalThis.__se = function(src){ try { (0, eval)(src); return 'no error'; } catch (e) { return e instanceof SyntaxError ? e.message : e.name + ': ' + e.message; } }) !== undefined"#),
        ("the message carries no location, source line or caret",
         #"(function(){ var m = __se('var x = 1;\n  a b'); return m === "Unexpected identifier 'b'" && m.indexOf(':') < 0 && m.indexOf('\n') < 0 && m.indexOf('^') < 0; })()"#),
        ("line / column hold the location (1-based, the offending token)",
         #"(function(){ try { (0, eval)('var x = 1;\n  a b'); } catch (e) { return e.line === 2 && e.column === 5 && !Object.keys(e).length; } })()"#),
        ("Unexpected token / end of script / identifier / keyword / number / string (JSC)",
         #"__se('({a:})') === "Unexpected token '}'" && __se('a +') === 'Unexpected end of script' && __se('(') === 'Unexpected end of script' && __se('a true') === "Unexpected keyword 'true'" && __se('a 1.5e3') === "Unexpected number '1.5e3'" && __se("a 'abc'") === "Unexpected string literal 'abc'" && __se('a ...b') === "Unexpected token '...'" && __se('x = 1 +;') === "Unexpected token ';'" && __se('a #x') === 'Unexpected private name #x' && __se('a 10n') === "Unexpected token '10n'""#),
        ("new Function reports the same text",
         #"(function(){ try { new Function('a b'); } catch (e) { return e instanceof SyntaxError && e.message === "Unexpected identifier 'b'"; } })()"#),
        ("reserved words as binding names (JSC text)",
         #"__se('var class = 1') === "Cannot use the keyword 'class' as a variable name." && __se('var x, if = 1') === "Cannot use the keyword 'if' as a variable name." && __se('const class = 1') === "Cannot use the keyword 'class' as a lexical variable name." && __se('function class(){}') === "Cannot use the keyword 'class' as a function name." && __se('function f(class){}') === "Cannot use the keyword 'class' as a parameter name." && __se('try{}catch(class){}') === "Cannot use the keyword 'class' as a catch parameter name." && __se('class if {}') === "Cannot use the keyword 'if' as a class name." && __se('var enum = 1') === "Cannot use the reserved word 'enum' as a variable name." && __se("'use strict'; var static = 1") === "Cannot use the reserved word 'static' as a variable name in strict mode." && __se('var [class] = []') === "Cannot use the keyword 'class' as a variable name.""#),
        ("contextual keywords stay usable as names",
         #"__se('var of = 1, let_ = 2, yield = 3, await = 4, static = 5, async = 6, get = 7, set = 8; function of2(){}') === 'no error' && __se('var o = { class: 1, if: 2 }; o.class + o.if') === 'no error' && __se('class A { static of(){} }') === 'no error' && __se('(class extends Object {})') === 'no error'"#),
        ("a missing comma is a SyntaxError (was accepted: [1 2] was [1, 2])",
         #"__se('[1 2]') === "Unexpected number '2'. Expected either a closing ']' or a ',' following an array element." && __se('Math.max(1 2)') === "Unexpected number '2'. Expected ')' to end an argument list." && __se('new Object(1 2)') === "Unexpected number '2'. Expected ')' to end an argument list." && __se('({a: 1 b: 2})') === "Unexpected identifier 'b'. Expected '}' to end an object literal." && __se('function f(a b){}') === "Unexpected identifier 'b'. Expected a ')' or a ',' after a parameter declaration." && __se('var [a b] = []') === "Unexpected identifier 'b'. Expected either a closing ']' or a ',' following an element destructuring pattern." && __se('var {a b} = {}') === "Unexpected identifier 'b'. Expected either a closing '}' or an ',' after a property destructuring pattern.""#),
        ("trailing commas and elisions still parse",
         #"__se('[1, , 2, ]; f => 0; Math.max(1, 2, ); ({a: 1, b: 2, }); (function(a, b, ){}); var [x, , y, ] = [1, 2, 3]; var {p, q, } = {};') === 'no error'"#),
        ("statement-level texts (JSC)",
         #"__se('break') === "'break' is only valid inside a switch or loop statement." && __se('continue') === "'continue' is only valid inside a loop statement." && __se('break foo;') === "Cannot use the undeclared label 'foo'." && __se('throw\n1') === "Cannot have a newline after 'throw'." && __se("'use strict'; with (a) {}") === "'with' statements are not valid in strict mode." && __se('const x;') === "Unexpected token ';'. const declared variable 'x' must have an initializer." && __se('function (){}') === 'Function statements must have a name.' && __se('try {} ; 5') === "Unexpected token ';'. Try statements must have at least a catch or finally block." && __se('try {}') === 'Unexpected end of script' && __se('class A { constructor(){} constructor(){} }') === 'Cannot declare multiple constructors in a single class.'"#),
        ("tokenizer texts (JSC)",
         #"__se("'abc") === 'Unexpected EOF' && __se('`abc') === 'Unexpected EOF' && __se('`${`') === 'Unexpected EOF' && __se('/abc') === "Unterminated regular expression literal '/abc'" && __se('x = /a\n/') === "Unterminated regular expression literal '/a'" && __se('var 1a') === 'No identifiers allowed directly after numeric literal' && __se('@') === "Invalid character: '@'" && __se('/* x') === 'Multiline comment was not closed properly' && __se('0x') === "No hexadecimal digits after '0x'" && __se('1e') === 'Non-number found after exponent indicator'"#),
        ("a script's parse error has its location in the stack; eval keeps the caller's frames",
         #"(function f(){ try { (0, eval)('a b'); } catch (e) { return typeof e.stack === 'string' && e.stack.indexOf('<eval>') < 0 && e.stack.indexOf('f@') === 0; } })()"#),
    ]

    mutating func testSyntaxErrorText() {
        runTrueCases("SyntaxErrorText", JeffJSTestRunner.syntaxErrorTextCases)
    }
}
