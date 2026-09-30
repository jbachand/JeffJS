// RegExpPropertyEscapeConformance.swift
// JeffJS — conformance group "RegExpPropertyEscape" (ES §22.2.2.9 UnicodePropertyValueExpression,
// tables 66-67): `\p{…}` / `\P{…}` accept every General_Category value and binary property by its
// canonical name *or alias* (PropertyValueAliases.txt / PropertyAliases.txt), with the scalar's
// own Unicode properties. homedepot.com's my-homepage bundle compiles /([\p{Alpha}\p{N}_]|$)/u
// at load and threw "invalid Unicode property: Alpha" (the page's home content never mounted);
// Lu / Lt / Lm / Lo / N / Nl / No were approximations (Lu was the Uppercase property, N any
// numeric type, Nl "digit" numeric type).
//
// Every case is (name, JS expression that must evaluate to `true`).

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    static let regExpPropertyEscapeCases: [(String, String)] = [
        ("binary property aliases: Alpha, Upper, Lower, WSpace, AHex, Hex, IDS, IDC",
         #"/^\p{Alpha}+$/u.test("aé中") && !/\p{Alpha}/u.test("1") && /\p{Upper}/u.test("A") && !/\p{Upper}/u.test("a") && /\p{Lower}/u.test("a") && /\p{WSpace}/u.test(" ") && /\p{AHex}/u.test("F") && !/\p{AHex}/u.test("Ｆ") && /\p{Hex}/u.test("Ｆ") && /\p{IDS}/u.test("a") && !/\p{IDS}/u.test("1") && /\p{IDC}/u.test("1")"#),
        ("the homedepot pattern: [\\p{Alpha}\\p{N}_] in a class, and its complement",
         #"(function(){ var r = /([\p{Alpha}\p{N}_]|$)/u; var m = "--x9".match(r); return m.index === 2 && m[1] === "x" && /[\P{Alpha}]/u.test("1") && !/[\P{Alpha}]/u.test("a"); })()"#),
        ("General_Category by value: Lu is gc=Lu (not the Uppercase property), Lt, Lm, Lo",
         #"/\p{Lu}/u.test("A") && !/\p{Lu}/u.test("Ⓐ") && /\p{Upper}/u.test("Ⓐ") && /\p{Lt}/u.test("ǅ") && !/\p{Lt}/u.test("A") && /\p{Lm}/u.test("ʰ") && !/\p{Lm}/u.test("a") && /\p{Lo}/u.test("中") && !/\p{Lo}/u.test("a")"#),
        ("N / Nd / Nl / No and their long names",
         #"/\p{N}/u.test("Ⅷ") && /\p{Nl}/u.test("Ⅷ") && !/\p{Nd}/u.test("Ⅷ") && /\p{Nd}/u.test("٣") && /\p{No}/u.test("½") && /\p{Number}/u.test("7") && /\p{Decimal_Number}/u.test("7") && /\p{digit}/u.test("7")"#),
        ("gc aliases: punct, cntrl, Combining_Mark, LC, Sc, Sm, Pd, Zs",
         #"/\p{punct}/u.test("!") && /\p{cntrl}/u.test("\u0007") && /\p{Combining_Mark}/u.test("́") && /\p{LC}/u.test("a") && !/\p{LC}/u.test("中") && /\p{Sc}/u.test("$") && /\p{Sm}/u.test("+") && /\p{Pd}/u.test("-") && /\p{Zs}/u.test(" ")"#),
        ("gc= / General_Category= forms and negation",
         #"/\p{gc=Lu}/u.test("A") && /\p{General_Category=Letter}/u.test("x") && /\P{L}/u.test("1") && !/\P{L}/u.test("x")"#),
        ("more binary properties: Math, Dash, Ideo, Emoji_Presentation / EPres, Ext, QMark, RI, ExtPict",
         #"/\p{Math}/u.test("+") && /\p{Dash}/u.test("—") && /\p{Ideo}/u.test("中") && /\p{EPres}/u.test("\u{1F600}") && /\p{Emoji_Presentation}/u.test("\u{1F600}") && /\p{Ext}/u.test("·") && /\p{QMark}/u.test("\"") && /\p{RI}/u.test("\u{1F1FA}") && /\p{ExtPict}/u.test("\u{1F600}")"#),
        ("supplementary letters count as Alphabetic / L (plane 1 and plane 3)",
         #"/\p{Alpha}/u.test("\u{10400}") && /\p{L}/u.test("\u{10400}") && /\p{Alpha}/u.test("\u{30000}") && /\p{Ideo}/u.test("\u{30000}")"#),
        ("an unknown property is still a SyntaxError",
         #"(function(){ try { new RegExp("\\p{NotAProperty}", "u"); return false; } catch (e) { return e instanceof SyntaxError; } })()"#),
    ]

    mutating func testRegExpPropertyEscape() {
        runTrueCases("RegExpPropertyEscape", JeffJSTestRunner.regExpPropertyEscapeCases)
    }
}
