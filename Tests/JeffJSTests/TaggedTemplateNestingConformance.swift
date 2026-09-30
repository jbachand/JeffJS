// TaggedTemplateNestingConformance.swift
// JeffJS — conformance group "TaggedTemplateNesting" (ES §13.3 MemberExpression :
// MemberExpression TemplateLiteral, §13.2.8 TemplateLiteral substitutions). A tagged
// template inside a template substitution — Lit's `html\`${items.map(i => html\`<li>${i}</li>\`)}\``,
// reddit's shreddit bundles — was a SyntaxError: the call-suffix loop refused every
// TOK_TEMPLATE while `inTemplateExpr` was set, a guard left over from before the
// substitution zeroed the tokenizer's template level (since then the closing `}` is a
// plain brace, so a template token there is always a tagged template).
//
// Every case is (name, JS expression that must evaluate to `true`).

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    static let taggedTemplateNestingCases: [(String, String)] = [
        ("tagged template directly inside a substitution",
         #"(function(){ function f(s){ return s.raw.join('|'); } return `${f`a`}` === 'a' && `<${f`x${1}y`}>` === '<x|y>'; })()"#),
        ("member-expression tag inside a substitution",
         #"(function(){ var o = { t: function(s, v){ return s[0] + v; } }; return `[${o.t`n=${5}`}]` === '[n=5]'; })()"#),
        ("tagged template in an arrow inside a call inside a substitution (Lit map)",
         #"(function(){ var e = { x: function(s){ var r = s[0]; for (var i = 1; i < arguments.length; i++) r += arguments[i] + s[i]; return r; } }; return e.x`<ul>${[1,2].map(t => e.x`<li>${t}</li>`).join('')}</ul>` === '<ul><li>1</li><li>2</li></ul>'; })()"#),
        ("tagged inside tagged, three levels",
         #"(function(){ function h(s){ var r = s[0]; for (var i = 1; i < arguments.length; i++) r += arguments[i] + s[i]; return r; } return h`a${h`b${h`c${1}`}`}d` === 'abc1d'; })()"#),
        ("the template object is per site and frozen inside a substitution",
         #"(function(){ var seen = []; function t(s){ seen.push(s); return ''; } for (var i = 0; i < 2; i++) `${t`q`}`; return seen.length === 2 && seen[0] === seen[1] && Object.isFrozen(seen[0]); })()"#),
        ("parenthesised and comma tags keep this = undefined",
         #"(function(){ 'use strict'; var o = { f: function(){ return this; } }; return `${(0, o.f)`x`}` === 'undefined' && `${(o.f)`x`}` !== 'undefined'; })()"#),
        ("an object literal and a tagged template in one substitution",
         #"(function(){ function f(s){ return s[0]; } return `${ {a: f`k`}.a }` === 'k'; })()"#),
        ("lazily compiled function bodies with nested tagged templates",
         #"(function(){ var g = new Function('h', 'return function(xs){ return h`[${xs.map(x => h`(${x})`).join(",")}]`; }'); function h(s){ var r = s[0]; for (var i = 1; i < arguments.length; i++) r += arguments[i] + s[i]; return r; } return g(h)([1, 2]) === '[(1),(2)]'; })()"#),
    ]

    mutating func testTaggedTemplateNesting() {
        runTrueCases("TaggedTemplateNesting", JeffJSTestRunner.taggedTemplateNestingCases)
    }
}
