// IntlFormatStylesConformance.swift
// JeffJS — conformance group "IntlFormatStyles" (ECMA-402 §16.5 NumberFormat
// notation scientific / engineering and unit display long / short / narrow with
// CLDR unit names; §17.5 RelativeTimeFormat style short / narrow and
// formatToParts). They printed "10,000 bit" / "16 hours ago" for every style:
// reddit's Intl feature test (`1E4 bits`) failed, so its vote counts took the
// "5.0k" fallback, and `faceplate-timeago` (narrow) wrapped its credit bar.
// Expected strings are ICU's (node / Safari).

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    static let intlFormatStylesCases: [(String, String)] = [
        ("reddit's feature test: scientific + unit long",
         #"new Intl.NumberFormat('en', { style: 'unit', unit: 'bit', unitDisplay: 'long', notation: 'scientific' }).format(1e4) === '1E4 bits'"#),
        ("scientific and engineering notation",
         #"new Intl.NumberFormat('en', { notation: 'scientific' }).format(12345) === '1.235E4' && new Intl.NumberFormat('en', { notation: 'engineering' }).format(12345) === '12.345E3' && new Intl.NumberFormat('en', { notation: 'scientific' }).format(1e4) === '1E4'"#),
        ("unit display: long plural, short, narrow, compound",
         #"new Intl.NumberFormat('en', { style: 'unit', unit: 'kilobyte', unitDisplay: 'long' }).format(2) === '2 kilobytes' && new Intl.NumberFormat('en', { style: 'unit', unit: 'kilobyte', unitDisplay: 'long' }).format(1) === '1 kilobyte' && new Intl.NumberFormat('en', { style: 'unit', unit: 'hour', unitDisplay: 'narrow' }).format(16) === '16h' && new Intl.NumberFormat('en', { style: 'unit', unit: 'mile-per-hour', unitDisplay: 'long' }).format(3) === '3 miles per hour' && new Intl.NumberFormat('en', { style: 'unit', unit: 'bit', unitDisplay: 'short' }).format(10000) === '10,000 bit'"#),
        ("RelativeTimeFormat long / short / narrow",
         #"new Intl.RelativeTimeFormat('en').format(-16, 'hour') === '16 hours ago' && new Intl.RelativeTimeFormat('en', { style: 'short' }).format(-16, 'hour') === '16 hr. ago' && new Intl.RelativeTimeFormat('en', { style: 'narrow' }).format(-16, 'hour') === '16h ago' && new Intl.RelativeTimeFormat('en', { style: 'narrow' }).format(-3, 'days') === '3d ago'"#),
        ("RelativeTimeFormat with a BCP 47 extension tag (reddit's en-US-u-nu-latn) does not trap",
         #"new Intl.RelativeTimeFormat('en-US-u-nu-latn', { style: 'narrow', numeric: 'always' }).format(-16, 'hour') === '16h ago'"#),
        ("RelativeTimeFormat formatToParts: the number's parts carry the unit",
         #"JSON.stringify(new Intl.RelativeTimeFormat('en', { style: 'narrow' }).formatToParts(-16, 'hour')) === '[{"type":"integer","value":"16","unit":"hour"},{"type":"literal","value":"h ago"}]' && JSON.stringify(new Intl.RelativeTimeFormat('en').formatToParts(2, 'days')) === '[{"type":"literal","value":"in "},{"type":"integer","value":"2","unit":"day"},{"type":"literal","value":" days"}]'"#),
        ("compact notation parts keep their compact literal",
         #"new Intl.NumberFormat('en-US', { notation: 'compact' }).formatToParts(5015).some(function(p){ return p.type === 'compact'; }) && new Intl.NumberFormat('en-US', { notation: 'compact' }).format(5015) === '5K'"#),
    ]

    /// Intl is installed by the environment (JeffJSWebAPIsBridge), not the bare context.
    mutating func testIntlFormatStyles() {
        var outcomes: [(Bool, String)] = []
        func onMain(_ body: @escaping @JeffJSHostActor () -> Void) {
            if Thread.isMainThread { JeffJSHostActor.assumeIsolated { body() } } else { DispatchQueue.main.sync { JeffJSHostActor.assumeIsolated { body() } } }
        }
        onMain {
            let e = JeffJSEnvironment()
            for (name, js) in JeffJSTestRunner.intlFormatStylesCases {
                switch e.eval(js, filename: "<intl-format-styles>") {
                case .success(let v): outcomes.append((v == "true", "IntlFormatStyles: \(name) -> \(v ?? "undefined")"))
                case .exception(let m): outcomes.append((false, "IntlFormatStyles: \(name) threw \(m)"))
                }
            }
        }
        for (ok, message) in outcomes { assert(ok, message) }
    }
}
