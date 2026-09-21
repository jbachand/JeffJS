// JeffJSIntlBridge.swift
// Native (Foundation-backed) ECMA-402 `Intl` for JeffJS.
//
// The engine used to ship no Intl at all, so hosts installed empty
// constructors just to make `typeof Intl.NumberFormat === 'function'` pass —
// and every `.format()` threw. This bridge provides a real implementation:
//
//   - Intl.NumberFormat        NumberFormatter (decimal/percent/currency/unit,
//                              fraction + significant digits, grouping,
//                              compact notation, formatToParts)
//   - Intl.DateTimeFormat      DateFormatter (dateStyle/timeStyle or component
//                              options through dateFormat(fromTemplate:),
//                              real resolved timeZone, formatToParts,
//                              formatRange)
//   - Intl.Collator            level-wise locale compare (usable as a sort
//                              callback; `.compare` is bound)
//   - Intl.PluralRules         CLDR rules for en + a table for common locales
//   - Intl.RelativeTimeFormat  English rules (numeric always/auto)
//   - Intl.ListFormat          conjunction/disjunction/unit
//   - Intl.DisplayNames        Locale.localizedString
//   - Intl.Locale, Intl.Segmenter (grapheme), getCanonicalLocales,
//     supportedValuesOf, supportedLocalesOf
//
// Shape follows JeffJSWebAPIsBridge: the heavy lifting is compiled Swift, the
// constructor/prototype plumbing is one eval'd JS shim (same trick as
// TextEncoder) that captures a hidden native namespace object and deletes it
// from the global, so `Intl` is the only new global. Registered from
// JeffJSWebAPIsBridge BEFORE polyfills, so host `typeof Intl`-guarded stubs
// skip themselves.
//
// Ownership (PERFORMANCE_PLAN.md Round 9): callees borrow their arguments —
// nothing here stores or returns an argument without dup'ing it, every
// getPropertyStr()/toObject() result is released, and values handed to
// setPropertyStr() are consumed by it.

import Foundation

/// Either a resolved option record or the JS exception to propagate.
/// (`Result` needs `Error` conformance, which a raw `JeffJSValue` has not.)
enum JeffJSIntlResolve<T> {
    case ok(T)
    case failed(JeffJSValue)
}

@MainActor
final class JeffJSIntlBridge {

    // MARK: - Resolved option records (Swift-side, keyed by the `_k` cache key
    // stored on the JS resolved-options object, so a format call reads exactly
    // one property instead of a dozen).

    struct NumberSpec {
        var locale: String = "en-US"
        var style: String = "decimal"
        var currency: String? = nil
        var currencyDisplay: String = "symbol"
        var unit: String? = nil
        var unitDisplay: String = "short"
        var minInt: Int = 1
        var minFrac: Int = 0
        var maxFrac: Int = 3
        var minSig: Int? = nil
        var maxSig: Int? = nil
        var useGrouping: Bool = true
        var notation: String = "standard"
        var compactDisplay: String = "short"
        var signDisplay: String = "auto"

        var key: String {
            return [locale, style, currency ?? "-", currencyDisplay, unit ?? "-", unitDisplay,
                    String(minInt), String(minFrac), String(maxFrac),
                    minSig.map(String.init) ?? "-", maxSig.map(String.init) ?? "-",
                    useGrouping ? "g" : "-", notation, compactDisplay, signDisplay].joined(separator: "|")
        }
    }

    struct DateSpec {
        var locale: String = "en-US"
        var timeZone: String = TimeZone.current.identifier
        var pattern: String = "M/d/y"
        var calendar: String = "gregory"
        var key: String { return locale + "|" + timeZone + "|" + pattern }
    }

    struct CollatorSpec {
        var locale: String = "en-US"
        var usage: String = "sort"
        var sensitivity: String = "variant"
        var ignorePunctuation: Bool = false
        var numeric: Bool = false
        var caseFirst: String = "false"
        var key: String {
            return [locale, usage, sensitivity, ignorePunctuation ? "p" : "-",
                    numeric ? "n" : "-", caseFirst].joined(separator: "|")
        }
    }

    // MARK: - Caches

    private var numberSpecs: [String: NumberSpec] = [:]
    private var dateSpecs: [String: DateSpec] = [:]
    private var collatorSpecs: [String: CollatorSpec] = [:]
    private var numberFormatters: [String: NumberFormatter] = [:]
    private var dateFormatters: [String: DateFormatter] = [:]
    private var locales: [String: Locale] = [:]

    private static let cacheLimit = 256

    // MARK: - Registration

    func register(on ctx: JeffJSContext) {
        let global = ctx.getGlobalObject()
        defer { global.freeValue() }

        let n = ctx.newObject()
        installHooks(ctx: ctx, n: n)
        _ = ctx.setPropertyStr(obj: global, name: "__jeffjsIntlNative", value: n)

        let shim = ctx.eval(input: JeffJSIntlBridge.shimJS,
                            filename: "<intl-shim>",
                            evalFlags: JS_EVAL_TYPE_GLOBAL)
        shim.freeValue()
    }

    func teardown() {
        numberSpecs.removeAll()
        dateSpecs.removeAll()
        collatorSpecs.removeAll()
        numberFormatters.removeAll()
        dateFormatters.removeAll()
        locales.removeAll()
    }

    // MARK: - JS value helpers

    private func optString(_ ctx: JeffJSContext, _ obj: JeffJSValue, _ name: String) -> String? {
        guard obj.isObject else { return nil }
        let v = ctx.getPropertyStr(obj: obj, name: name)
        defer { v.freeValue() }
        if v.isUndefined || v.isNull || v.isException { return nil }
        return ctx.toSwiftString(v)
    }

    private func optDouble(_ ctx: JeffJSContext, _ obj: JeffJSValue, _ name: String) -> Double? {
        guard obj.isObject else { return nil }
        let v = ctx.getPropertyStr(obj: obj, name: name)
        defer { v.freeValue() }
        if v.isUndefined || v.isNull || v.isException { return nil }
        guard let d = ctx.toFloat64(v), d.isFinite else { return nil }
        return d
    }

    private func optInt(_ ctx: JeffJSContext, _ obj: JeffJSValue, _ name: String) -> Int? {
        guard let d = optDouble(ctx, obj, name) else { return nil }
        return Int(d)
    }

    private func optBool(_ ctx: JeffJSContext, _ obj: JeffJSValue, _ name: String) -> Bool? {
        guard obj.isObject else { return nil }
        let v = ctx.getPropertyStr(obj: obj, name: name)
        defer { v.freeValue() }
        if v.isUndefined || v.isNull || v.isException { return nil }
        if let s = ctx.toSwiftString(v), !v.isBool {
            // useGrouping accepts "auto" | "always" | "min2" | "false"
            return s != "false"
        }
        return ctx.toBool(v)
    }

    /// Reads a JS string-or-array-of-strings argument into a Swift array.
    private func stringList(_ ctx: JeffJSContext, _ val: JeffJSValue) -> [String] {
        if val.isUndefined || val.isNull { return [] }
        if val.isString { return [ctx.toSwiftString(val) ?? ""] }
        guard val.isObject else {
            if let s = ctx.toSwiftString(val) { return [s] }
            return []
        }
        let lenVal = ctx.getPropertyStr(obj: val, name: "length")
        defer { lenVal.freeValue() }
        guard let lenD = ctx.toFloat64(lenVal), lenD.isFinite, lenD > 0 else {
            // A non-array object (e.g. an Intl.Locale) — use its string form.
            if let s = ctx.toSwiftString(val), !s.isEmpty, s != "[object Object]" { return [s] }
            return []
        }
        var out: [String] = []
        let len = min(Int(lenD), 1024)
        for i in 0..<len {
            let item = ctx.getPropertyUint32(obj: val, index: UInt32(i))
            if let s = ctx.toSwiftString(item) { out.append(s) }
            item.freeValue()
        }
        return out
    }

    private func newStringArray(_ ctx: JeffJSContext, _ items: [String]) -> JeffJSValue {
        let arr = ctx.newArray()
        for (i, s) in items.enumerated() {
            _ = ctx.setPropertyUint32(obj: arr, index: UInt32(i), value: ctx.newStringValue(s))
        }
        ctx.setArrayLength(arr, Int64(items.count))
        return arr
    }

    private func newPartsArray(_ ctx: JeffJSContext, _ parts: [(String, String)]) -> JeffJSValue {
        let arr = ctx.newArray()
        for (i, p) in parts.enumerated() {
            let o = ctx.newObject()
            _ = ctx.setPropertyStr(obj: o, name: "type", value: ctx.newStringValue(p.0))
            _ = ctx.setPropertyStr(obj: o, name: "value", value: ctx.newStringValue(p.1))
            _ = ctx.setPropertyUint32(obj: arr, index: UInt32(i), value: o)
        }
        ctx.setArrayLength(arr, Int64(parts.count))
        return arr
    }

    // MARK: - Locale helpers

    static func canonicalizeTag(_ raw: String, allowUnderscore: Bool = false) -> String? {
        if !allowUnderscore && raw.contains("_") { return nil }
        let tag = raw.replacingOccurrences(of: "_", with: "-")
        if tag.isEmpty { return nil }
        var parts = tag.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty else { return nil }
        let lang = parts[0]
        guard lang.count >= 2, lang.count <= 8,
              lang.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        parts[0] = lang.lowercased()
        var i = 1
        var seenExtension = false
        while i < parts.count {
            let p = parts[i]
            if p.isEmpty { return nil }
            if p.count == 1 { seenExtension = true; parts[i] = p.lowercased(); i += 1; continue }
            if seenExtension { parts[i] = p.lowercased(); i += 1; continue }
            guard p.count <= 8, p.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
            if p.count == 4, p.allSatisfy({ $0.isLetter }) {
                parts[i] = p.prefix(1).uppercased() + p.dropFirst().lowercased()
            } else if p.count == 2, p.allSatisfy({ $0.isLetter }) {
                parts[i] = p.uppercased()
            } else if p.count == 3, p.allSatisfy({ $0.isNumber }) {
                parts[i] = p
            } else {
                parts[i] = p.lowercased()
            }
            i += 1
        }
        return parts.joined(separator: "-")
    }

    static func defaultLocaleTag() -> String {
        let id = Locale.current.identifier
        return canonicalizeTag(id, allowUnderscore: true) ?? "en-US"
    }

    /// Throws (returns) a RangeError for a structurally invalid language tag,
    /// which is what ECMA-402 does before any option is read.
    private func validateLocales(_ ctx: JeffJSContext, _ val: JeffJSValue) -> JeffJSValue? {
        for raw in stringList(ctx, val) where JeffJSIntlBridge.canonicalizeTag(raw) == nil {
            return ctx.throwRangeError(message: "Invalid language tag: \(raw)")
        }
        return nil
    }

    /// First usable tag from a `locales` argument, else the system default.
    private func resolveLocaleTag(_ ctx: JeffJSContext, _ val: JeffJSValue) -> String {
        for raw in stringList(ctx, val) {
            if let c = JeffJSIntlBridge.canonicalizeTag(raw) { return c }
        }
        return JeffJSIntlBridge.defaultLocaleTag()
    }

    private func locale(_ tag: String) -> Locale {
        if let l = locales[tag] { return l }
        let l = Locale(identifier: tag)
        if locales.count > JeffJSIntlBridge.cacheLimit { locales.removeAll() }
        locales[tag] = l
        return l
    }

    private func cacheNumber(_ spec: NumberSpec) {
        if numberSpecs.count > JeffJSIntlBridge.cacheLimit { numberSpecs.removeAll(); numberFormatters.removeAll() }
        numberSpecs[spec.key] = spec
    }
    private func cacheDate(_ spec: DateSpec) {
        if dateSpecs.count > JeffJSIntlBridge.cacheLimit { dateSpecs.removeAll(); dateFormatters.removeAll() }
        dateSpecs[spec.key] = spec
    }
    private func cacheCollator(_ spec: CollatorSpec) {
        if collatorSpecs.count > JeffJSIntlBridge.cacheLimit { collatorSpecs.removeAll() }
        collatorSpecs[spec.key] = spec
    }

    private func specKey(_ ctx: JeffJSContext, _ args: [JeffJSValue]) -> String? {
        guard args.count > 0 else { return nil }
        return optString(ctx, args[0], "_k")
    }
}

// MARK: - Intl.NumberFormat

extension JeffJSIntlBridge {

    /// Currencies whose minor-unit count is not 2.
    private static let currencyDigits: [String: Int] = [
        "BIF": 0, "CLP": 0, "DJF": 0, "GNF": 0, "ISK": 0, "JPY": 0, "KMF": 0,
        "KRW": 0, "PYG": 0, "RWF": 0, "UGX": 0, "UYI": 0, "VND": 0, "VUV": 0,
        "XAF": 0, "XOF": 0, "XPF": 0,
        "BHD": 3, "IQD": 3, "JOD": 3, "KWD": 3, "LYD": 3, "OMR": 3, "TND": 3,
    ]

    func resolveNumberSpec(_ ctx: JeffJSContext, locales: JeffJSValue,
                           options: JeffJSValue) -> JeffJSIntlResolve<NumberSpec> {
        if let e = validateLocales(ctx, locales) { return .failed(e) }
        var spec = NumberSpec()
        spec.locale = resolveLocaleTag(ctx, locales)

        let style = optString(ctx, options, "style") ?? "decimal"
        guard ["decimal", "percent", "currency", "unit"].contains(style) else {
            return .failed(ctx.throwRangeError(
                message: "Value \(style) out of range for Intl.NumberFormat options property style"))
        }
        spec.style = style

        if let cur = optString(ctx, options, "currency") {
            let ok = cur.count == 3 && cur.allSatisfy { $0.isASCII && $0.isLetter }
            guard ok else {
                return .failed(ctx.throwRangeError(message: "Invalid currency code : \(cur)"))
            }
            spec.currency = cur.uppercased()
        }
        if style == "currency" && spec.currency == nil {
            return .failed(ctx.throwTypeError(message: "Currency code is required with currency style."))
        }
        if let cd = optString(ctx, options, "currencyDisplay") {
            guard ["symbol", "code", "name", "narrowSymbol"].contains(cd) else {
                return .failed(ctx.throwRangeError(
                    message: "Value \(cd) out of range for Intl.NumberFormat options property currencyDisplay"))
            }
            spec.currencyDisplay = cd
        }
        spec.unit = optString(ctx, options, "unit")
        if style == "unit" && spec.unit == nil {
            return .failed(ctx.throwTypeError(message: "unit must be provided with unit style."))
        }
        if let ud = optString(ctx, options, "unitDisplay") { spec.unitDisplay = ud }

        if let n = optString(ctx, options, "notation") {
            guard ["standard", "compact", "scientific", "engineering"].contains(n) else {
                return .failed(ctx.throwRangeError(
                    message: "Value \(n) out of range for Intl.NumberFormat options property notation"))
            }
            spec.notation = n
        }
        if let cd = optString(ctx, options, "compactDisplay") { spec.compactDisplay = cd }
        if let sd = optString(ctx, options, "signDisplay") {
            guard ["auto", "never", "always", "exceptZero", "negative"].contains(sd) else {
                return .failed(ctx.throwRangeError(
                    message: "Value \(sd) out of range for Intl.NumberFormat options property signDisplay"))
            }
            spec.signDisplay = sd
        }

        // Digit defaults per style.
        switch style {
        case "percent": spec.minFrac = 0; spec.maxFrac = 0
        case "currency":
            let d = JeffJSIntlBridge.currencyDigits[spec.currency ?? ""] ?? 2
            spec.minFrac = d; spec.maxFrac = d
        default: spec.minFrac = 0; spec.maxFrac = 3
        }
        if spec.notation == "compact" {
            // Compact defaults to "round to a short form" unless the caller asks.
            spec.minFrac = 0
            spec.maxFrac = 0
        }

        if let mi = optInt(ctx, options, "minimumIntegerDigits") {
            guard mi >= 1 && mi <= 21 else {
                return .failed(ctx.throwRangeError(message: "minimumIntegerDigits value is out of range."))
            }
            spec.minInt = mi
        }
        if let mn = optInt(ctx, options, "minimumFractionDigits") {
            guard mn >= 0 && mn <= 100 else {
                return .failed(ctx.throwRangeError(message: "minimumFractionDigits value is out of range."))
            }
            spec.minFrac = mn
            spec.maxFrac = max(spec.maxFrac, mn)
        }
        if let mx = optInt(ctx, options, "maximumFractionDigits") {
            guard mx >= 0 && mx <= 100 else {
                return .failed(ctx.throwRangeError(message: "maximumFractionDigits value is out of range."))
            }
            guard mx >= spec.minFrac else {
                return .failed(ctx.throwRangeError(
                    message: "maximumFractionDigits value is out of range."))
            }
            spec.maxFrac = mx
        }

        if let ms = optInt(ctx, options, "minimumSignificantDigits") {
            guard ms >= 1 && ms <= 21 else {
                return .failed(ctx.throwRangeError(message: "minimumSignificantDigits value is out of range."))
            }
            spec.minSig = ms
            if spec.maxSig == nil { spec.maxSig = 21 }
        }
        if let xs = optInt(ctx, options, "maximumSignificantDigits") {
            guard xs >= 1 && xs <= 21 else {
                return .failed(ctx.throwRangeError(message: "maximumSignificantDigits value is out of range."))
            }
            spec.maxSig = xs
            if spec.minSig == nil { spec.minSig = 1 }
        }
        if let g = optBool(ctx, options, "useGrouping") { spec.useGrouping = g }

        return .ok(spec)
    }

    func numberFormatter(_ spec: NumberSpec, overrideMaxFrac: Int? = nil) -> NumberFormatter {
        let key = spec.key + "|of:" + (overrideMaxFrac.map(String.init) ?? "-")
        if let f = numberFormatters[key] { return f }
        let f = NumberFormatter()
        f.locale = locale(spec.locale)
        switch spec.style {
        case "percent": f.numberStyle = .percent
        case "currency":
            switch spec.currencyDisplay {
            case "code": f.numberStyle = .currencyISOCode
            case "name": f.numberStyle = .currencyPlural
            default: f.numberStyle = .currency
            }
            if let c = spec.currency { f.currencyCode = c }
        default: f.numberStyle = .decimal
        }
        f.usesGroupingSeparator = spec.useGrouping
        f.minimumIntegerDigits = spec.minInt
        if let mn = spec.minSig, let mx = spec.maxSig, overrideMaxFrac == nil {
            f.usesSignificantDigits = true
            f.minimumSignificantDigits = mn
            f.maximumSignificantDigits = mx
        } else {
            f.usesSignificantDigits = false
            f.minimumFractionDigits = overrideMaxFrac != nil ? 0 : spec.minFrac
            f.maximumFractionDigits = overrideMaxFrac ?? spec.maxFrac
        }
        // ECMA-402 rounds half away from zero ("halfExpand"); Foundation
        // defaults to banker's rounding, which would print 2.5 -> "2".
        f.roundingMode = .halfUp
        if numberFormatters.count > JeffJSIntlBridge.cacheLimit { numberFormatters.removeAll() }
        numberFormatters[key] = f
        return f
    }

    /// Compact notation: scaled value, suffix, and the fraction digits to use.
    static func compactScale(_ a: Double) -> (value: Double, suffix: String, maxFrac: Int) {
        let units: [(Double, String)] = [(1e12, "T"), (1e9, "B"), (1e6, "M"), (1e3, "K")]
        var idx = -1
        for (i, u) in units.enumerated() where a >= u.0 { idx = i; break }
        func round(_ v: Double) -> (Double, Int) {
            let frac = v < 10 ? 1 : 0
            let p = pow(10.0, Double(frac))
            return (((v * p).rounded()) / p, frac)
        }
        if idx < 0 {
            let (r, f) = round(a)
            return (r, "", f)
        }
        var scaled = a / units[idx].0
        var (rounded, frac) = round(scaled)
        if rounded >= 1000 && idx > 0 {
            idx -= 1
            scaled = a / units[idx].0
            (rounded, frac) = round(scaled)
        }
        return (rounded, units[idx].1, frac)
    }

    func formatNumber(_ spec: NumberSpec, _ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-∞" : "∞" }

        var body: String
        if spec.notation == "compact" {
            let sign = value < 0 ? "-" : ""
            let (scaled, suffix, frac) = JeffJSIntlBridge.compactScale(abs(value))
            let f = numberFormatter(spec, overrideMaxFrac: frac)
            body = sign + (f.string(from: NSNumber(value: scaled)) ?? "\(scaled)") + suffix
        } else {
            let f = numberFormatter(spec)
            body = f.string(from: NSNumber(value: value)) ?? "\(value)"
        }

        switch spec.signDisplay {
        case "never":
            if let m = f_minusSign(spec), body.hasPrefix(m) { body.removeFirst(m.count) }
            else if body.hasPrefix("-") { body.removeFirst() }
        case "always", "exceptZero":
            let isZero = value == 0 || (value.isNaN == false && abs(value) < Double.leastNormalMagnitude)
            if value > 0 || (spec.signDisplay == "always" && isZero) {
                body = (f_plusSign(spec) ?? "+") + body
            }
        default: break
        }

        if spec.style == "unit", let unit = spec.unit {
            let short = unit.split(separator: "-").last.map(String.init) ?? unit
            body = body + " " + (spec.unitDisplay == "narrow" ? short : short)
        }
        return body
    }

    private func f_minusSign(_ spec: NumberSpec) -> String? { return numberFormatter(spec).minusSign }
    private func f_plusSign(_ spec: NumberSpec) -> String? { return numberFormatter(spec).plusSign }

    /// Basic formatToParts: classifies the formatted string with the
    /// formatter's own symbols (group/decimal/currency/percent/sign).
    func numberParts(_ spec: NumberSpec, _ value: Double) -> [(String, String)] {
        let text = formatNumber(spec, value)
        if value.isNaN { return [("nan", text)] }
        if value.isInfinite {
            var out: [(String, String)] = []
            if text.hasPrefix("-") { out.append(("minusSign", "-")) }
            out.append(("infinity", text.hasPrefix("-") ? String(text.dropFirst()) : text))
            return out
        }
        let f = numberFormatter(spec)
        var tokens: [(String, String)] = []   // (literal, part type), longest first
        func add(_ s: String?, _ type: String) {
            guard let s, !s.isEmpty else { return }
            tokens.append((s, type))
        }
        if spec.style == "currency" {
            add(f.currencySymbol, "currency")
            add(spec.currency, "currency")
        }
        if spec.style == "percent" { add(f.percentSymbol, "percentSign") }
        add(f.minusSign, "minusSign")
        add("-", "minusSign")
        add(f.plusSign, "plusSign")
        add("+", "plusSign")
        add(f.groupingSeparator, "group")
        add(f.decimalSeparator, "decimal")
        if spec.notation == "compact" {
            for s in ["K", "M", "B", "T"] { add(s, "compact") }
        }
        tokens.sort { $0.0.count > $1.0.count }

        var parts: [(String, String)] = []
        var digits = ""
        var seenDecimal = false
        func flushDigits() {
            guard !digits.isEmpty else { return }
            parts.append((seenDecimal ? "fraction" : "integer", digits))
            digits = ""
        }
        var literal = ""
        func flushLiteral() {
            guard !literal.isEmpty else { return }
            parts.append(("literal", literal))
            literal = ""
        }

        var idx = text.startIndex
        outer: while idx < text.endIndex {
            let ch = text[idx]
            if ch.isNumber && ch.isASCII {
                flushLiteral()
                digits.append(ch)
                idx = text.index(after: idx)
                continue
            }
            for (lit, type) in tokens {
                if text[idx...].hasPrefix(lit) {
                    flushDigits()
                    flushLiteral()
                    if type == "decimal" { seenDecimal = true }
                    parts.append((type, lit))
                    idx = text.index(idx, offsetBy: lit.count)
                    continue outer
                }
            }
            flushDigits()
            literal.append(ch)
            idx = text.index(after: idx)
        }
        flushDigits()
        flushLiteral()
        return parts
    }
}

// MARK: - Intl.DateTimeFormat

extension JeffJSIntlBridge {

    private static func styleFor(_ s: String?) -> DateFormatter.Style? {
        switch s {
        case "full": return .full
        case "long": return .long
        case "medium": return .medium
        case "short": return .short
        default: return nil
        }
    }

    /// Splits an ICU pattern into (field char, text) runs, honouring '' quoting.
    static func patternTokens(_ pattern: String) -> [(field: Character?, text: String)] {
        var out: [(Character?, String)] = []
        let chars = Array(pattern)
        var i = 0
        var literal = ""
        func flush() { if !literal.isEmpty { out.append((nil, literal)); literal = "" } }
        while i < chars.count {
            let c = chars[i]
            if c == "'" {
                // Quoted literal; '' is an escaped quote.
                if i + 1 < chars.count && chars[i + 1] == "'" { literal.append("'"); i += 2; continue }
                i += 1
                while i < chars.count {
                    if chars[i] == "'" {
                        if i + 1 < chars.count && chars[i + 1] == "'" { literal.append("'"); i += 2; continue }
                        i += 1
                        break
                    }
                    literal.append(chars[i]); i += 1
                }
                continue
            }
            if c.isLetter && c.isASCII {
                flush()
                var run = String(c)
                var j = i + 1
                while j < chars.count && chars[j] == c { run.append(c); j += 1 }
                out.append((c, run))
                i = j
                continue
            }
            literal.append(c)
            i += 1
        }
        flush()
        return out
    }

    static func partType(for field: Character) -> String {
        switch field {
        case "G": return "era"
        case "y", "Y", "u", "U", "r": return "year"
        case "M", "L": return "month"
        case "d": return "day"
        case "D": return "dayOfYear"
        case "E", "e", "c": return "weekday"
        case "a", "b", "B": return "dayPeriod"
        case "h", "H", "K", "k": return "hour"
        case "m": return "minute"
        case "s": return "second"
        case "S": return "fractionalSecond"
        case "z", "Z", "v", "V", "O", "X", "x": return "timeZoneName"
        case "w", "W": return "weekOfYear"
        case "q", "Q": return "quarter"
        default: return "literal"
        }
    }

    /// Rewrites the hour field of a pattern for an explicit hour12/hourCycle.
    static func applyHourCycle(_ pattern: String, hour12: Bool?, hourCycle: String?) -> String {
        var target: Character? = nil
        var wantPeriod: Bool? = nil
        if let hc = hourCycle {
            switch hc {
            case "h11": target = "K"; wantPeriod = true
            case "h12": target = "h"; wantPeriod = true
            case "h23": target = "H"; wantPeriod = false
            case "h24": target = "k"; wantPeriod = false
            default: break
            }
        }
        if let h12 = hour12 {
            target = h12 ? "h" : "H"
            wantPeriod = h12
        }
        guard let t = target else { return pattern }
        var out = ""
        var hadHour = false
        var hasPeriod = false
        for tok in patternTokens(pattern) {
            guard let f = tok.field else {
                out += tok.text.contains("'") ? tok.text : quoteLiteral(tok.text)
                continue
            }
            if "hHKk".contains(f) {
                hadHour = true
                out += String(repeating: String(t), count: tok.text.count)
            } else if f == "a" || f == "b" || f == "B" {
                hasPeriod = true
                if wantPeriod == false { continue }
                out += tok.text
            } else {
                out += tok.text
            }
        }
        if hadHour, wantPeriod == true, !hasPeriod { out += " a" }
        return out
    }

    private static func quoteLiteral(_ s: String) -> String {
        // Only letters need quoting inside an ICU pattern.
        if s.allSatisfy({ !($0.isLetter && $0.isASCII) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
    }

    func resolveDateSpec(_ ctx: JeffJSContext, locales: JeffJSValue,
                         options: JeffJSValue) -> JeffJSIntlResolve<(DateSpec, [(String, String)])> {
        if let e = validateLocales(ctx, locales) { return .failed(e) }
        var spec = DateSpec()
        spec.locale = resolveLocaleTag(ctx, locales)
        var echo: [(String, String)] = []

        if let tzName = optString(ctx, options, "timeZone") {
            guard let z = TimeZone(identifier: tzName) ?? TimeZone(abbreviation: tzName.uppercased()) else {
                return .failed(ctx.throwRangeError(message: "Invalid time zone specified: \(tzName)"))
            }
            // ECMA-402 canonicalises GMT/UTC to "UTC" and otherwise keeps the
            // IANA spelling the caller asked for (Foundation reports "GMT").
            let upper = tzName.uppercased()
            if upper == "UTC" || upper == "GMT" || upper == "Z" || upper == "ETC/UTC" || upper == "ETC/GMT" {
                spec.timeZone = "UTC"
            } else if let known = TimeZone.knownTimeZoneIdentifiers.first(
                        where: { $0.caseInsensitiveCompare(tzName) == .orderedSame }) {
                spec.timeZone = known
            } else {
                spec.timeZone = z.identifier
            }
        } else {
            spec.timeZone = TimeZone.current.identifier
        }

        let loc = locale(spec.locale)
        let dateStyle = optString(ctx, options, "dateStyle")
        let timeStyle = optString(ctx, options, "timeStyle")
        for (name, v) in [("dateStyle", dateStyle), ("timeStyle", timeStyle)] {
            if let v {
                guard ["full", "long", "medium", "short"].contains(v) else {
                    return .failed(ctx.throwRangeError(
                        message: "Value \(v) out of range for Intl.DateTimeFormat options property \(name)"))
                }
                echo.append((name, v))
            }
        }

        let hour12 = optBool(ctx, options, "hour12")
        let hourCycle = optString(ctx, options, "hourCycle")

        if dateStyle != nil || timeStyle != nil {
            let df = DateFormatter()
            df.locale = loc
            df.dateStyle = JeffJSIntlBridge.styleFor(dateStyle) ?? .none
            df.timeStyle = JeffJSIntlBridge.styleFor(timeStyle) ?? .none
            spec.pattern = df.dateFormat ?? "M/d/y"
            spec.pattern = JeffJSIntlBridge.applyHourCycle(spec.pattern, hour12: hour12, hourCycle: hourCycle)
        } else {
            var template = ""
            func comp(_ name: String, _ map: [String: String], _ allowed: [String]) -> JeffJSValue? {
                guard let v = optString(ctx, options, name) else { return nil }
                guard allowed.contains(v) else {
                    return ctx.throwRangeError(
                        message: "Value \(v) out of range for Intl.DateTimeFormat options property \(name)")
                }
                template += map[v] ?? ""
                echo.append((name, v))
                return nil
            }
            let textual = ["narrow", "short", "long"]
            let numeric = ["numeric", "2-digit"]
            if let e = comp("weekday", ["narrow": "EEEEE", "short": "E", "long": "EEEE"], textual) { return .failed(e) }
            if let e = comp("era", ["narrow": "GGGGG", "short": "G", "long": "GGGG"], textual) { return .failed(e) }
            if let e = comp("year", ["numeric": "y", "2-digit": "yy"], numeric) { return .failed(e) }
            if let e = comp("month",
                            ["numeric": "M", "2-digit": "MM", "narrow": "MMMMM", "short": "MMM", "long": "MMMM"],
                            numeric + textual) { return .failed(e) }
            if let e = comp("day", ["numeric": "d", "2-digit": "dd"], numeric) { return .failed(e) }

            var hourChar = "j"
            if let hc = hourCycle {
                switch hc {
                case "h11": hourChar = "K"
                case "h12": hourChar = "h"
                case "h23": hourChar = "H"
                case "h24": hourChar = "k"
                default: break
                }
                echo.append(("hourCycle", hc))
            }
            if let h12 = hour12 { hourChar = h12 ? "h" : "H" }
            if let hv = optString(ctx, options, "hour") {
                guard numeric.contains(hv) else {
                    return .failed(ctx.throwRangeError(
                        message: "Value \(hv) out of range for Intl.DateTimeFormat options property hour"))
                }
                template += hv == "2-digit" ? hourChar + hourChar : hourChar
                echo.append(("hour", hv))
                if let h12 = hour12 { echo.append(("hour12", h12 ? "true" : "false")) }
            }
            if let e = comp("minute", ["numeric": "m", "2-digit": "mm"], numeric) { return .failed(e) }
            if let e = comp("second", ["numeric": "s", "2-digit": "ss"], numeric) { return .failed(e) }
            if let e = comp("timeZoneName",
                            ["short": "z", "long": "zzzz", "shortOffset": "O", "longOffset": "OOOO",
                             "shortGeneric": "v", "longGeneric": "vvvv"],
                            ["short", "long", "shortOffset", "longOffset", "shortGeneric", "longGeneric"]) {
                return .failed(e)
            }

            if template.isEmpty {
                // No component options at all: the ECMA-402 default is a
                // numeric year/month/day.
                template = "yMd"
                echo.append(("year", "numeric"))
                echo.append(("month", "numeric"))
                echo.append(("day", "numeric"))
            }
            spec.pattern = DateFormatter.dateFormat(fromTemplate: template, options: 0, locale: loc) ?? "M/d/y"
            if hour12 != nil || hourCycle != nil {
                spec.pattern = JeffJSIntlBridge.applyHourCycle(spec.pattern, hour12: hour12, hourCycle: hourCycle)
            }
        }
        return .ok((spec, echo))
    }

    func dateFormatter(_ spec: DateSpec, pattern: String? = nil) -> DateFormatter {
        let pat = pattern ?? spec.pattern
        let key = spec.locale + "|" + spec.timeZone + "|" + pat
        if let f = dateFormatters[key] { return f }
        let f = DateFormatter()
        f.locale = locale(spec.locale)
        f.timeZone = TimeZone(identifier: spec.timeZone) ?? TimeZone.current
        f.dateFormat = pat
        if dateFormatters.count > JeffJSIntlBridge.cacheLimit { dateFormatters.removeAll() }
        dateFormatters[key] = f
        return f
    }

    func formatDate(_ spec: DateSpec, _ ms: Double) -> String {
        let date = Date(timeIntervalSince1970: ms / 1000.0)
        return dateFormatter(spec).string(from: date)
    }

    func dateParts(_ spec: DateSpec, _ ms: Double) -> [(String, String)] {
        let date = Date(timeIntervalSince1970: ms / 1000.0)
        var out: [(String, String)] = []
        for tok in JeffJSIntlBridge.patternTokens(spec.pattern) {
            guard let f = tok.field else {
                if !tok.text.isEmpty { out.append(("literal", tok.text)) }
                continue
            }
            let type = JeffJSIntlBridge.partType(for: f)
            let value = dateFormatter(spec, pattern: tok.text).string(from: date)
            out.append((type, value))
        }
        return out
    }
}

// MARK: - Intl.Collator

extension JeffJSIntlBridge {

    func resolveCollatorSpec(_ ctx: JeffJSContext, locales: JeffJSValue,
                             options: JeffJSValue) -> JeffJSIntlResolve<CollatorSpec> {
        if let e = validateLocales(ctx, locales) { return .failed(e) }
        var spec = CollatorSpec()
        spec.locale = resolveLocaleTag(ctx, locales)
        if let u = optString(ctx, options, "usage") {
            guard ["sort", "search"].contains(u) else {
                return .failed(ctx.throwRangeError(
                    message: "Value \(u) out of range for Intl.Collator options property usage"))
            }
            spec.usage = u
        }
        if let s = optString(ctx, options, "sensitivity") {
            guard ["base", "accent", "case", "variant"].contains(s) else {
                return .failed(ctx.throwRangeError(
                    message: "Value \(s) out of range for Intl.Collator options property sensitivity"))
            }
            spec.sensitivity = s
        }
        if let p = optBool(ctx, options, "ignorePunctuation") { spec.ignorePunctuation = p }
        if let n = optBool(ctx, options, "numeric") { spec.numeric = n }
        if let c = optString(ctx, options, "caseFirst") {
            guard ["upper", "lower", "false"].contains(c) else {
                return .failed(ctx.throwRangeError(
                    message: "Value \(c) out of range for Intl.Collator options property caseFirst"))
            }
            spec.caseFirst = c
        }
        return .ok(spec)
    }

    /// Level-wise compare: base letters, then accents, then case. Foundation's
    /// locale compare collapses case/diacritics inconsistently across
    /// platforms, so each strength is applied explicitly — which is also what
    /// makes `.sort(collator.compare)` stable and ICU-like ("a" < "b" < "B").
    func collate(_ spec: CollatorSpec, _ a: String, _ b: String) -> Int {
        var x = a, y = b
        if spec.ignorePunctuation {
            let drop: (Character) -> Bool = { $0.isPunctuation || $0.isSymbol || $0.isWhitespace }
            x.removeAll(where: drop)
            y.removeAll(where: drop)
        }
        let loc = locale(spec.locale)

        var base: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if spec.numeric { base.insert(.numeric) }
        let r1 = x.compare(y, options: base, range: nil, locale: loc)
        if r1 != .orderedSame { return r1 == .orderedAscending ? -1 : 1 }
        if spec.sensitivity == "base" { return 0 }

        if spec.sensitivity == "accent" || spec.sensitivity == "variant" {
            var accentOpts: String.CompareOptions = [.caseInsensitive]
            if spec.numeric { accentOpts.insert(.numeric) }
            let r2 = x.compare(y, options: accentOpts, range: nil, locale: loc)
            if r2 != .orderedSame { return r2 == .orderedAscending ? -1 : 1 }
        }
        if spec.sensitivity == "accent" { return 0 }

        // Case level: lowercase sorts first unless caseFirst says otherwise.
        let ax = Array(x), ay = Array(y)
        let n = min(ax.count, ay.count)
        for i in 0..<n where ax[i] != ay[i] {
            let al = ax[i].isLowercase, bl = ay[i].isLowercase
            if al != bl {
                let lowerFirst = spec.caseFirst != "upper"
                if al { return lowerFirst ? -1 : 1 }
                return lowerFirst ? 1 : -1
            }
        }
        if ax.count != ay.count { return ax.count < ay.count ? -1 : 1 }
        if x == y { return 0 }
        return x < y ? -1 : 1
    }
}

// MARK: - Intl.PluralRules

extension JeffJSIntlBridge {

    /// CLDR plural categories. `en` is exact (cardinal and ordinal); the table
    /// covers the locales an app is most likely to ship, everything else
    /// falls back to "other".
    static func pluralCategory(locale tag: String, type: String,
                               value: Double, fractionDigits: Int) -> String {
        let lang = tag.split(separator: "-").first.map(String.init)?.lowercased() ?? "en"
        let n = abs(value)
        let i = floor(n)
        let v = fractionDigits
        let iInt = Int(i.truncatingRemainder(dividingBy: 1e15))

        if type == "ordinal" {
            guard lang == "en" else { return "other" }
            let mod10 = iInt % 10, mod100 = iInt % 100
            if mod10 == 1 && mod100 != 11 { return "one" }
            if mod10 == 2 && mod100 != 12 { return "two" }
            if mod10 == 3 && mod100 != 13 { return "few" }
            return "other"
        }

        switch lang {
        case "en", "de", "it", "es", "nl", "sv", "da", "nb", "no", "el", "fi", "he", "hu", "tr":
            return (n == 1 && v == 0) ? "one" : "other"
        case "pt":
            return (i == 0 || i == 1) ? "one" : "other"
        case "fr":
            if i == 0 || i == 1 { return "one" }
            return "other"
        case "ru", "uk":
            let mod10 = iInt % 10, mod100 = iInt % 100
            if v == 0 && mod10 == 1 && mod100 != 11 { return "one" }
            if v == 0 && (2...4).contains(mod10) && !(12...14).contains(mod100) { return "few" }
            if v == 0 && (mod10 == 0 || (5...9).contains(mod10) || (11...14).contains(mod100)) { return "many" }
            return "other"
        case "pl":
            let mod10 = iInt % 10, mod100 = iInt % 100
            if v == 0 && iInt == 1 { return "one" }
            if v == 0 && (2...4).contains(mod10) && !(12...14).contains(mod100) { return "few" }
            if v == 0 { return "many" }
            return "other"
        case "ar":
            let mod100 = iInt % 100
            if n == 0 { return "zero" }
            if n == 1 { return "one" }
            if n == 2 { return "two" }
            if (3...10).contains(mod100) { return "few" }
            if (11...99).contains(mod100) { return "many" }
            return "other"
        case "ja", "zh", "ko", "th", "vi", "id", "ms":
            return "other"
        default:
            return (n == 1 && v == 0) ? "one" : "other"
        }
    }

    /// Number of visible fraction digits of `value` after min/max clamping.
    static func fractionDigitCount(_ value: Double, minFrac: Int, maxFrac: Int) -> Int {
        if value == floor(value) { return minFrac }
        var s = String(format: "%.\(max(0, min(maxFrac, 20)))f", abs(value))
        while s.hasSuffix("0") { s.removeLast() }
        guard let dot = s.firstIndex(of: ".") else { return minFrac }
        let digits = s.distance(from: s.index(after: dot), to: s.endIndex)
        return max(minFrac, digits)
    }
}

// MARK: - Intl.RelativeTimeFormat / ListFormat / DisplayNames / Segmenter

extension JeffJSIntlBridge {

    static let relativeUnits = ["second", "minute", "hour", "day", "week",
                                "month", "quarter", "year"]

    static func normalizeUnit(_ unit: String) -> String? {
        var u = unit.lowercased()
        if u.hasSuffix("s") && u != "s" { u = String(u.dropLast()) }
        return relativeUnits.contains(u) ? u : nil
    }

    /// English relative time. `numeric: "auto"` uses the CLDR named forms
    /// (yesterday/today/tomorrow, last/this/next <unit>, now).
    static func relativeTime(locale tag: String, numeric: String,
                             value: Double, unit: String) -> String {
        let lang = tag.split(separator: "-").first.map(String.init)?.lowercased() ?? "en"
        if numeric == "auto" && (value == -1 || value == 0 || value == 1) && lang == "en" {
            switch unit {
            case "day":
                if value == -1 { return "yesterday" }
                if value == 0 { return "today" }
                return "tomorrow"
            case "second":
                // Only "now" is named; +/-1 second stays numeric.
                if value == 0 { return "now" }
            case "minute", "hour":
                // "this minute"/"this hour" exist; -1/+1 stay numeric.
                if value == 0 { return "this \(unit)" }
            default:
                if value == -1 { return "last \(unit)" }
                if value == 0 { return "this \(unit)" }
                return "next \(unit)"
            }
        }
        if lang != "en" {
            let f = RelativeDateTimeFormatter()
            f.locale = Locale(identifier: tag)
            f.dateTimeStyle = numeric == "auto" ? .named : .numeric
            let seconds: Double
            switch unit {
            case "second": seconds = value
            case "minute": seconds = value * 60
            case "hour": seconds = value * 3600
            case "day": seconds = value * 86400
            case "week": seconds = value * 604800
            case "month": seconds = value * 2629800
            case "quarter": seconds = value * 7889400
            default: seconds = value * 31557600
            }
            return f.localizedString(fromTimeInterval: seconds)
        }
        let magnitude = abs(value)
        let noun = magnitude == 1 ? unit : unit + "s"
        let numberText = magnitude == floor(magnitude)
            ? String(Int(magnitude))
            : String(magnitude)
        if value < 0 { return "\(numberText) \(noun) ago" }
        return "in \(numberText) \(noun)"
    }

    static func formatList(locale tag: String, type: String, items: [String]) -> String {
        if items.isEmpty { return "" }
        if items.count == 1 { return items[0] }
        let lang = tag.split(separator: "-").first.map(String.init)?.lowercased() ?? "en"
        if type == "unit" { return items.joined(separator: ", ") }
        if lang != "en", type == "conjunction" {
            let lf = ListFormatter()
            lf.locale = Locale(identifier: tag)
            if let s = lf.string(from: items) { return s }
        }
        let word = type == "disjunction" ? "or" : "and"
        if items.count == 2 { return items[0] + " " + word + " " + items[1] }
        let head = items.dropLast().joined(separator: ", ")
        return head + ", " + word + " " + (items.last ?? "")
    }

    static func displayName(locale tag: String, type: String, code: String) -> String? {
        let loc = Locale(identifier: tag)
        switch type {
        case "region": return loc.localizedString(forRegionCode: code.uppercased())
        case "script": return loc.localizedString(forScriptCode: code.capitalized)
        case "currency": return loc.localizedString(forCurrencyCode: code.uppercased())
        case "calendar", "dateTimeField": return code
        default:
            let normalized = code.replacingOccurrences(of: "_", with: "-")
            return loc.localizedString(forIdentifier: normalized)
                ?? loc.localizedString(forLanguageCode: normalized)
        }
    }

    /// Locale tag components (Intl.Locale).
    static func localeComponents(_ tag: String) -> (language: String, script: String?,
                                                    region: String?, baseName: String)? {
        guard let canonical = canonicalizeTag(tag) else { return nil }
        let parts = canonical.split(separator: "-").map(String.init)
        var language = parts[0]
        if language == "root" { language = "und" }
        var script: String? = nil
        var region: String? = nil
        var base = [language]
        var i = 1
        while i < parts.count {
            let p = parts[i]
            if p.count == 1 { break }   // extension sequence
            if script == nil && region == nil && p.count == 4 && p.allSatisfy({ $0.isLetter }) {
                script = p; base.append(p)
            } else if region == nil && ((p.count == 2 && p.allSatisfy { $0.isLetter }) ||
                                        (p.count == 3 && p.allSatisfy { $0.isNumber })) {
                region = p; base.append(p)
            } else {
                base.append(p)
            }
            i += 1
        }
        return (language, script, region, base.joined(separator: "-"))
    }

    static func graphemes(_ s: String) -> [(String, Int)] {
        var out: [(String, Int)] = []
        var idx = 0
        for ch in s {
            let str = String(ch)
            out.append((str, idx))
            idx += str.utf16.count
        }
        return out
    }

    static func supportedValues(_ key: String) -> [String]? {
        switch key {
        case "calendar": return ["gregory"]
        case "collation": return ["default"]
        case "currency": return ["AUD", "BRL", "CAD", "CHF", "CNY", "EUR", "GBP", "HKD",
                                 "INR", "JPY", "KRW", "MXN", "NOK", "NZD", "RUB", "SEK",
                                 "SGD", "TRY", "USD", "ZAR"]
        case "numberingSystem": return ["latn"]
        case "timeZone": return TimeZone.knownTimeZoneIdentifiers.sorted()
        case "unit": return ["byte", "celsius", "centimeter", "day", "degree", "fahrenheit",
                             "foot", "gigabyte", "gram", "hour", "inch", "kilogram",
                             "kilometer", "liter", "megabyte", "meter", "mile",
                             "millimeter", "millisecond", "minute", "month", "ounce",
                             "percent", "pound", "second", "week", "year"]
        default: return nil
        }
    }

    /// Basic BestAvailableLocale: keeps the requested tags Foundation knows.
    static func supportedLocales(_ tags: [String]) -> [String] {
        var available = Set<String>()
        for id in Locale.availableIdentifiers {
            available.insert(id.replacingOccurrences(of: "_", with: "-").lowercased())
        }
        var out: [String] = []
        for t in tags {
            guard let c = canonicalizeTag(t) else { continue }
            var probe = c.lowercased()
            var matched = false
            while true {
                if available.contains(probe) { matched = true; break }
                guard let dash = probe.lastIndex(of: "-") else { break }
                probe = String(probe[probe.startIndex..<dash])
            }
            if matched { out.append(c) }
        }
        return out
    }
}

// MARK: - Native hook installation

extension JeffJSIntlBridge {

    private func makeResolved(_ ctx: JeffJSContext, _ entries: [(String, JeffJSValue)],
                              key: String) -> JeffJSValue {
        let o = ctx.newObject()
        var names: [String] = []
        for (k, v) in entries {
            _ = ctx.setPropertyStr(obj: o, name: k, value: v)
            names.append(k)
        }
        _ = ctx.setPropertyStr(obj: o, name: "_k", value: ctx.newStringValue(key))
        _ = ctx.setPropertyStr(obj: o, name: "_pub", value: newStringArray(ctx, names))
        return o
    }

    func installHooks(ctx: JeffJSContext, n: JeffJSValue) {

        // ---- NumberFormat ----

        ctx.setPropertyFunc(obj: n, name: "resolveNumber", fn: { [weak self] ctx, _, args in
            guard let self else { return .undefined }
            let locales = args.count > 0 ? args[0] : JeffJSValue.undefined
            let options = args.count > 1 ? args[1] : JeffJSValue.undefined
            switch self.resolveNumberSpec(ctx, locales: locales, options: options) {
            case .failed(let e): return e
            case .ok(let spec):
                self.cacheNumber(spec)
                var entries: [(String, JeffJSValue)] = [
                    ("locale", ctx.newStringValue(spec.locale)),
                    ("numberingSystem", ctx.newStringValue("latn")),
                    ("style", ctx.newStringValue(spec.style)),
                ]
                if let c = spec.currency {
                    entries.append(("currency", ctx.newStringValue(c)))
                    entries.append(("currencyDisplay", ctx.newStringValue(spec.currencyDisplay)))
                    entries.append(("currencySign", ctx.newStringValue("standard")))
                }
                if let u = spec.unit {
                    entries.append(("unit", ctx.newStringValue(u)))
                    entries.append(("unitDisplay", ctx.newStringValue(spec.unitDisplay)))
                }
                entries.append(("minimumIntegerDigits", .newInt32(Int32(spec.minInt))))
                if spec.minSig == nil {
                    entries.append(("minimumFractionDigits", .newInt32(Int32(spec.minFrac))))
                    entries.append(("maximumFractionDigits", .newInt32(Int32(spec.maxFrac))))
                } else {
                    entries.append(("minimumSignificantDigits", .newInt32(Int32(spec.minSig ?? 1))))
                    entries.append(("maximumSignificantDigits", .newInt32(Int32(spec.maxSig ?? 21))))
                }
                entries.append(("useGrouping", spec.useGrouping
                                ? ctx.newStringValue("auto") : JeffJSValue.newBool(false)))
                entries.append(("notation", ctx.newStringValue(spec.notation)))
                entries.append(("signDisplay", ctx.newStringValue(spec.signDisplay)))
                if spec.notation == "compact" {
                    entries.append(("compactDisplay", ctx.newStringValue(spec.compactDisplay)))
                }
                return self.makeResolved(ctx, entries, key: spec.key)
            }
        }, length: 2)

        ctx.setPropertyFunc(obj: n, name: "formatNumber", fn: { [weak self] ctx, _, args in
            guard let self, args.count > 1 else { return ctx.newStringValue("") }
            let spec = self.specKey(ctx, args).flatMap { self.numberSpecs[$0] } ?? NumberSpec()
            let v = ctx.toFloat64(args[1]) ?? Double.nan
            return ctx.newStringValue(self.formatNumber(spec, v))
        }, length: 2)

        ctx.setPropertyFunc(obj: n, name: "formatNumberParts", fn: { [weak self] ctx, _, args in
            guard let self, args.count > 1 else { return ctx.newArray() }
            let spec = self.specKey(ctx, args).flatMap { self.numberSpecs[$0] } ?? NumberSpec()
            let v = ctx.toFloat64(args[1]) ?? Double.nan
            return self.newPartsArray(ctx, self.numberParts(spec, v))
        }, length: 2)

        // ---- DateTimeFormat ----

        ctx.setPropertyFunc(obj: n, name: "resolveDate", fn: { [weak self] ctx, _, args in
            guard let self else { return .undefined }
            let locales = args.count > 0 ? args[0] : JeffJSValue.undefined
            let options = args.count > 1 ? args[1] : JeffJSValue.undefined
            switch self.resolveDateSpec(ctx, locales: locales, options: options) {
            case .failed(let e): return e
            case .ok(let (spec, echo)):
                self.cacheDate(spec)
                var entries: [(String, JeffJSValue)] = [
                    ("locale", ctx.newStringValue(spec.locale)),
                    ("calendar", ctx.newStringValue(spec.calendar)),
                    ("numberingSystem", ctx.newStringValue("latn")),
                    ("timeZone", ctx.newStringValue(spec.timeZone)),
                ]
                for (k, v) in echo {
                    if k == "hour12" {
                        entries.append((k, JeffJSValue.newBool(v == "true")))
                    } else {
                        entries.append((k, ctx.newStringValue(v)))
                    }
                }
                return self.makeResolved(ctx, entries, key: spec.key)
            }
        }, length: 2)

        ctx.setPropertyFunc(obj: n, name: "formatDate", fn: { [weak self] ctx, _, args in
            guard let self, args.count > 1 else { return ctx.newStringValue("") }
            let spec = self.specKey(ctx, args).flatMap { self.dateSpecs[$0] } ?? DateSpec()
            let ms = ctx.toFloat64(args[1]) ?? 0
            return ctx.newStringValue(self.formatDate(spec, ms))
        }, length: 2)

        ctx.setPropertyFunc(obj: n, name: "formatDateParts", fn: { [weak self] ctx, _, args in
            guard let self, args.count > 1 else { return ctx.newArray() }
            let spec = self.specKey(ctx, args).flatMap { self.dateSpecs[$0] } ?? DateSpec()
            let ms = ctx.toFloat64(args[1]) ?? 0
            return self.newPartsArray(ctx, self.dateParts(spec, ms))
        }, length: 2)

        // ---- Collator ----

        ctx.setPropertyFunc(obj: n, name: "resolveCollator", fn: { [weak self] ctx, _, args in
            guard let self else { return .undefined }
            let locales = args.count > 0 ? args[0] : JeffJSValue.undefined
            let options = args.count > 1 ? args[1] : JeffJSValue.undefined
            switch self.resolveCollatorSpec(ctx, locales: locales, options: options) {
            case .failed(let e): return e
            case .ok(let spec):
                self.cacheCollator(spec)
                let entries: [(String, JeffJSValue)] = [
                    ("locale", ctx.newStringValue(spec.locale)),
                    ("usage", ctx.newStringValue(spec.usage)),
                    ("sensitivity", ctx.newStringValue(spec.sensitivity)),
                    ("ignorePunctuation", JeffJSValue.newBool(spec.ignorePunctuation)),
                    ("collation", ctx.newStringValue("default")),
                    ("numeric", JeffJSValue.newBool(spec.numeric)),
                    ("caseFirst", ctx.newStringValue(spec.caseFirst)),
                ]
                return self.makeResolved(ctx, entries, key: spec.key)
            }
        }, length: 2)

        ctx.setPropertyFunc(obj: n, name: "compare", fn: { [weak self] ctx, _, args in
            guard let self, args.count > 2 else { return .newInt32(0) }
            let spec = self.specKey(ctx, args).flatMap { self.collatorSpecs[$0] } ?? CollatorSpec()
            let a = ctx.toSwiftString(args[1]) ?? ""
            let b = ctx.toSwiftString(args[2]) ?? ""
            return .newInt32(Int32(self.collate(spec, a, b)))
        }, length: 3)

        // ---- PluralRules ----

        ctx.setPropertyFunc(obj: n, name: "resolvePlural", fn: { [weak self] ctx, _, args in
            guard let self else { return .undefined }
            let locales = args.count > 0 ? args[0] : JeffJSValue.undefined
            let options = args.count > 1 ? args[1] : JeffJSValue.undefined
            let tag = self.resolveLocaleTag(ctx, locales)
            let type = self.optString(ctx, options, "type") ?? "cardinal"
            guard ["cardinal", "ordinal"].contains(type) else {
                return ctx.throwRangeError(
                    message: "Value \(type) out of range for Intl.PluralRules options property type")
            }
            let minFrac = self.optInt(ctx, options, "minimumFractionDigits") ?? 0
            let maxFrac = self.optInt(ctx, options, "maximumFractionDigits") ?? max(3, minFrac)
            let cats = type == "ordinal" ? ["few", "one", "other", "two"] : ["one", "other"]
            let entries: [(String, JeffJSValue)] = [
                ("locale", ctx.newStringValue(tag)),
                ("type", ctx.newStringValue(type)),
                ("minimumIntegerDigits", .newInt32(1)),
                ("minimumFractionDigits", .newInt32(Int32(minFrac))),
                ("maximumFractionDigits", .newInt32(Int32(maxFrac))),
                ("pluralCategories", self.newStringArray(ctx, cats)),
            ]
            return self.makeResolved(ctx, entries, key: tag + "|" + type)
        }, length: 2)

        ctx.setPropertyFunc(obj: n, name: "plural", fn: { [weak self] ctx, _, args in
            guard let self, args.count > 1 else { return ctx.newStringValue("other") }
            let tag = self.optString(ctx, args[0], "locale") ?? "en"
            let type = self.optString(ctx, args[0], "type") ?? "cardinal"
            let minFrac = self.optInt(ctx, args[0], "minimumFractionDigits") ?? 0
            let maxFrac = self.optInt(ctx, args[0], "maximumFractionDigits") ?? 3
            let v = ctx.toFloat64(args[1]) ?? Double.nan
            if v.isNaN || v.isInfinite { return ctx.newStringValue("other") }
            let digits = JeffJSIntlBridge.fractionDigitCount(v, minFrac: minFrac, maxFrac: maxFrac)
            return ctx.newStringValue(
                JeffJSIntlBridge.pluralCategory(locale: tag, type: type, value: v, fractionDigits: digits))
        }, length: 2)

        // ---- RelativeTimeFormat / ListFormat / DisplayNames ----

        ctx.setPropertyFunc(obj: n, name: "relative", fn: { ctx, _, args in
            guard args.count > 3 else { return ctx.newStringValue("") }
            let tag = ctx.toSwiftString(args[0]) ?? "en"
            let numeric = ctx.toSwiftString(args[1]) ?? "always"
            let value = ctx.toFloat64(args[2]) ?? 0
            let rawUnit = ctx.toSwiftString(args[3]) ?? ""
            guard let unit = JeffJSIntlBridge.normalizeUnit(rawUnit) else {
                return ctx.throwRangeError(message: "Invalid unit argument for format() '\(rawUnit)'")
            }
            guard value.isFinite else {
                return ctx.throwRangeError(message: "Value need to be finite number for format()")
            }
            return ctx.newStringValue(
                JeffJSIntlBridge.relativeTime(locale: tag, numeric: numeric, value: value, unit: unit))
        }, length: 4)

        ctx.setPropertyFunc(obj: n, name: "list", fn: { [weak self] ctx, _, args in
            guard let self, args.count > 2 else { return ctx.newStringValue("") }
            let tag = ctx.toSwiftString(args[0]) ?? "en"
            let type = ctx.toSwiftString(args[1]) ?? "conjunction"
            let items = self.stringList(ctx, args[2])
            return ctx.newStringValue(JeffJSIntlBridge.formatList(locale: tag, type: type, items: items))
        }, length: 3)

        ctx.setPropertyFunc(obj: n, name: "display", fn: { ctx, _, args in
            guard args.count > 2 else { return .undefined }
            let tag = ctx.toSwiftString(args[0]) ?? "en"
            let type = ctx.toSwiftString(args[1]) ?? "language"
            let code = ctx.toSwiftString(args[2]) ?? ""
            guard let name = JeffJSIntlBridge.displayName(locale: tag, type: type, code: code) else {
                return .undefined
            }
            return ctx.newStringValue(name)
        }, length: 3)

        // ---- Locale / canonicalisation / supported values ----

        ctx.setPropertyFunc(obj: n, name: "localeParts", fn: { ctx, _, args in
            let tag = args.count > 0 ? (ctx.toSwiftString(args[0]) ?? "") : ""
            guard let c = JeffJSIntlBridge.canonicalizeTag(tag),
                  let parts = JeffJSIntlBridge.localeComponents(tag) else {
                return ctx.throwRangeError(message: "Invalid language tag: \(tag)")
            }
            let o = ctx.newObject()
            _ = ctx.setPropertyStr(obj: o, name: "tag", value: ctx.newStringValue(c))
            _ = ctx.setPropertyStr(obj: o, name: "language", value: ctx.newStringValue(parts.language))
            if let s = parts.script {
                _ = ctx.setPropertyStr(obj: o, name: "script", value: ctx.newStringValue(s))
            }
            if let r = parts.region {
                _ = ctx.setPropertyStr(obj: o, name: "region", value: ctx.newStringValue(r))
            }
            _ = ctx.setPropertyStr(obj: o, name: "baseName", value: ctx.newStringValue(parts.baseName))
            return o
        }, length: 1)

        ctx.setPropertyFunc(obj: n, name: "canonical", fn: { [weak self] ctx, _, args in
            guard let self else { return ctx.newArray() }
            let raw = args.count > 0 ? self.stringList(ctx, args[0]) : []
            var out: [String] = []
            for t in raw {
                guard let c = JeffJSIntlBridge.canonicalizeTag(t) else {
                    return ctx.throwRangeError(message: "Invalid language tag: \(t)")
                }
                if !out.contains(c) { out.append(c) }
            }
            return self.newStringArray(ctx, out)
        }, length: 1)

        ctx.setPropertyFunc(obj: n, name: "supportedValues", fn: { [weak self] ctx, _, args in
            guard let self else { return ctx.newArray() }
            let key = args.count > 0 ? (ctx.toSwiftString(args[0]) ?? "") : ""
            guard let vals = JeffJSIntlBridge.supportedValues(key) else {
                return ctx.throwRangeError(message: "Invalid key: \(key)")
            }
            return self.newStringArray(ctx, vals)
        }, length: 1)

        ctx.setPropertyFunc(obj: n, name: "supportedLocales", fn: { [weak self] ctx, _, args in
            guard let self else { return ctx.newArray() }
            let raw = args.count > 0 ? self.stringList(ctx, args[0]) : []
            for t in raw where JeffJSIntlBridge.canonicalizeTag(t) == nil {
                return ctx.throwRangeError(message: "Invalid language tag: \(t)")
            }
            return self.newStringArray(ctx, JeffJSIntlBridge.supportedLocales(raw))
        }, length: 2)

        // ---- Segmenter ----

        ctx.setPropertyFunc(obj: n, name: "segments", fn: { ctx, _, args in
            let s = args.count > 0 ? (ctx.toSwiftString(args[0]) ?? "") : ""
            let segs = JeffJSIntlBridge.graphemes(s)
            let arr = ctx.newArray()
            for (i, seg) in segs.enumerated() {
                let o = ctx.newObject()
                _ = ctx.setPropertyStr(obj: o, name: "segment", value: ctx.newStringValue(seg.0))
                _ = ctx.setPropertyStr(obj: o, name: "index", value: .newInt32(Int32(seg.1)))
                _ = ctx.setPropertyStr(obj: o, name: "input", value: ctx.newStringValue(s))
                _ = ctx.setPropertyUint32(obj: arr, index: UInt32(i), value: o)
            }
            ctx.setArrayLength(arr, Int64(segs.count))
            return arr
        }, length: 1)

        ctx.setPropertyFunc(obj: n, name: "timeZone", fn: { ctx, _, _ in
            return ctx.newStringValue(TimeZone.current.identifier)
        }, length: 0)

        ctx.setPropertyFunc(obj: n, name: "defaultLocale", fn: { ctx, _, _ in
            return ctx.newStringValue(JeffJSIntlBridge.defaultLocaleTag())
        }, length: 0)
    }
}

// MARK: - JS shim (constructors + prototypes over the native hooks)

extension JeffJSIntlBridge {

    static let shimJS: String = #"""
    (function () {
      var g = (typeof globalThis !== 'undefined') ? globalThis
            : (typeof window !== 'undefined') ? window : this;
      var N = g.__jeffjsIntlNative;
      try { delete g.__jeffjsIntlNative; } catch (e) {}
      if (!N) { return; }

      function hide(o, k, v) {
        try {
          Object.defineProperty(o, k, { value: v, writable: true, configurable: true, enumerable: false });
        } catch (e) { try { o[k] = v; } catch (e2) {} }
      }
      // An own, already-bound method. It closes over the resolved-options
      // record rather than over the instance: `fn.bind(this)` stored on the
      // instance would be a reference cycle, and cycles are never collected
      // during a run.
      function ownMethod(o, name, fn) { hide(o, name, fn); }
      function pub(r) {
        var out = {};
        var keys = (r && r._pub) || [];
        for (var i = 0; i < keys.length; i++) { out[keys[i]] = r[keys[i]]; }
        return out;
      }
      function toTime(d) {
        var t = (d === undefined) ? Date.now() : Number(d);
        if (!isFinite(t)) { throw new RangeError('Invalid time value'); }
        return t;
      }

      // ---------------- Intl.NumberFormat ----------------
      function NumberFormat(locales, options) {
        if (!(this instanceof NumberFormat)) { return new NumberFormat(locales, options); }
        var r = N.resolveNumber(locales, options);
        hide(this, '_r', r);
        ownMethod(this, 'format', function format(value) {
          return N.formatNumber(r, value === undefined ? NaN : Number(value));
        });
      }
      NumberFormat.prototype.format = function (value) {
        return N.formatNumber(this._r, value === undefined ? NaN : Number(value));
      };
      NumberFormat.prototype.formatToParts = function (value) {
        return N.formatNumberParts(this._r, value === undefined ? NaN : Number(value));
      };
      NumberFormat.prototype.formatRange = function (a, b) {
        var x = this.format(a), y = this.format(b);
        return x === y ? x : (x + '–' + y);
      };
      NumberFormat.prototype.resolvedOptions = function () { return pub(this._r); };

      // ---------------- Intl.DateTimeFormat ----------------
      function DateTimeFormat(locales, options) {
        if (!(this instanceof DateTimeFormat)) { return new DateTimeFormat(locales, options); }
        var r = N.resolveDate(locales, options);
        hide(this, '_r', r);
        ownMethod(this, 'format', function format(date) {
          return N.formatDate(r, toTime(date));
        });
      }
      DateTimeFormat.prototype.format = function (date) {
        return N.formatDate(this._r, toTime(date));
      };
      DateTimeFormat.prototype.formatToParts = function (date) {
        return N.formatDateParts(this._r, toTime(date));
      };
      DateTimeFormat.prototype.formatRange = function (start, end) {
        var a = N.formatDate(this._r, toTime(start));
        var b = N.formatDate(this._r, toTime(end));
        return a === b ? a : (a + ' – ' + b);
      };
      DateTimeFormat.prototype.formatRangeToParts = function (start, end) {
        var a = N.formatDateParts(this._r, toTime(start));
        var b = N.formatDateParts(this._r, toTime(end));
        var out = [], i;
        for (i = 0; i < a.length; i++) { a[i].source = 'startRange'; out.push(a[i]); }
        out.push({ type: 'literal', value: ' – ', source: 'shared' });
        for (i = 0; i < b.length; i++) { b[i].source = 'endRange'; out.push(b[i]); }
        return out;
      };
      DateTimeFormat.prototype.resolvedOptions = function () { return pub(this._r); };

      // ---------------- Intl.Collator ----------------
      function Collator(locales, options) {
        if (!(this instanceof Collator)) { return new Collator(locales, options); }
        var r = N.resolveCollator(locales, options);
        hide(this, '_r', r);
        ownMethod(this, 'compare', function compare(a, b) {
          return N.compare(r, String(a), String(b));
        });
      }
      Collator.prototype.compare = function (a, b) {
        return N.compare(this._r, String(a), String(b));
      };
      Collator.prototype.resolvedOptions = function () { return pub(this._r); };

      // ---------------- Intl.PluralRules ----------------
      function PluralRules(locales, options) {
        if (!(this instanceof PluralRules)) { return new PluralRules(locales, options); }
        var r = N.resolvePlural(locales, options);
        hide(this, '_r', r);
        ownMethod(this, 'select', function select(value) {
          return N.plural(r, Number(value));
        });
      }
      PluralRules.prototype.select = function (value) { return N.plural(this._r, Number(value)); };
      PluralRules.prototype.selectRange = function (a, b) {
        var x = N.plural(this._r, Number(a)), y = N.plural(this._r, Number(b));
        return x === y ? x : 'other';
      };
      PluralRules.prototype.resolvedOptions = function () { return pub(this._r); };

      // ---------------- Intl.RelativeTimeFormat ----------------
      function RelativeTimeFormat(locales, options) {
        if (!(this instanceof RelativeTimeFormat)) { return new RelativeTimeFormat(locales, options); }
        var o = options || {};
        var numeric = o.numeric === undefined ? 'always' : String(o.numeric);
        if (numeric !== 'always' && numeric !== 'auto') {
          throw new RangeError('Value ' + numeric + ' out of range for Intl.RelativeTimeFormat options property numeric');
        }
        var style = o.style === undefined ? 'long' : String(o.style);
        if (style !== 'long' && style !== 'short' && style !== 'narrow') {
          throw new RangeError('Value ' + style + ' out of range for Intl.RelativeTimeFormat options property style');
        }
        var loc = N.canonical(locales)[0] || N.defaultLocale();
        hide(this, '_locale', loc);
        hide(this, '_numeric', numeric);
        hide(this, '_style', style);
        ownMethod(this, 'format', function format(value, unit) {
          return N.relative(loc, numeric, Number(value), String(unit));
        });
      }
      RelativeTimeFormat.prototype.format = function (value, unit) {
        return N.relative(this._locale, this._numeric, Number(value), String(unit));
      };
      RelativeTimeFormat.prototype.formatToParts = function (value, unit) {
        return [{ type: 'literal', value: this.format(value, unit) }];
      };
      RelativeTimeFormat.prototype.resolvedOptions = function () {
        return { locale: this._locale, style: this._style, numeric: this._numeric,
                 numberingSystem: 'latn' };
      };

      // ---------------- Intl.ListFormat ----------------
      function ListFormat(locales, options) {
        if (!(this instanceof ListFormat)) { return new ListFormat(locales, options); }
        var o = options || {};
        var type = o.type === undefined ? 'conjunction' : String(o.type);
        if (type !== 'conjunction' && type !== 'disjunction' && type !== 'unit') {
          throw new RangeError('Value ' + type + ' out of range for Intl.ListFormat options property type');
        }
        var style = o.style === undefined ? 'long' : String(o.style);
        var loc = N.canonical(locales)[0] || N.defaultLocale();
        hide(this, '_locale', loc);
        hide(this, '_type', type);
        hide(this, '_style', style);
        ownMethod(this, 'format', function format(list) {
          return N.list(loc, type, listToArray(list));
        });
      }
      var listToArray = function (list) {
        if (list === undefined || list === null) { return []; }
        if (typeof list === 'string') { return [list]; }
        var out = [], i;
        if (typeof list.length === 'number') {
          for (i = 0; i < list.length; i++) { out.push(String(list[i])); }
          return out;
        }
        return out;
      };
      ListFormat.prototype.format = function (list) {
        return N.list(this._locale, this._type, listToArray(list));
      };
      ListFormat.prototype.formatToParts = function (list) {
        return [{ type: 'literal', value: this.format(list) }];
      };
      ListFormat.prototype.resolvedOptions = function () {
        return { locale: this._locale, type: this._type, style: this._style };
      };

      // ---------------- Intl.DisplayNames ----------------
      function DisplayNames(locales, options) {
        if (!(this instanceof DisplayNames)) {
          throw new TypeError("Constructor Intl.DisplayNames requires 'new'");
        }
        var o = options || {};
        var type = o.type === undefined ? undefined : String(o.type);
        if (type === undefined) { throw new TypeError('type must be provided'); }
        var loc = N.canonical(locales)[0] || N.defaultLocale();
        var fallback = o.fallback === undefined ? 'code' : String(o.fallback);
        hide(this, '_locale', loc);
        hide(this, '_type', type);
        hide(this, '_style', o.style === undefined ? 'long' : String(o.style));
        hide(this, '_fallback', fallback);
        ownMethod(this, 'of', function of(code) {
          var c = String(code);
          var name = N.display(loc, type, c);
          if (name === undefined) { return fallback === 'none' ? undefined : c; }
          return name;
        });
      }
      DisplayNames.prototype.of = function (code) {
        var c = String(code);
        var name = N.display(this._locale, this._type, c);
        if (name === undefined) { return this._fallback === 'none' ? undefined : c; }
        return name;
      };
      DisplayNames.prototype.resolvedOptions = function () {
        return { locale: this._locale, style: this._style, type: this._type,
                 fallback: this._fallback };
      };

      // ---------------- Intl.Locale ----------------
      function Locale(tag, options) {
        if (!(this instanceof Locale)) {
          throw new TypeError("Constructor Intl.Locale requires 'new'");
        }
        var p = N.localeParts(String(tag && tag.toString ? tag.toString() : tag));
        var o = options || {};
        this.language = o.language === undefined ? p.language : String(o.language);
        if (p.script !== undefined || o.script !== undefined) {
          this.script = o.script === undefined ? p.script : String(o.script);
        }
        if (p.region !== undefined || o.region !== undefined) {
          this.region = o.region === undefined ? p.region : String(o.region);
        }
        var base = this.language;
        if (this.script) { base += '-' + this.script; }
        if (this.region) { base += '-' + this.region; }
        this.baseName = base;
        hide(this, '_tag', base);
      }
      Locale.prototype.toString = function () { return this._tag; };
      Locale.prototype.maximize = function () { return this; };
      Locale.prototype.minimize = function () { return this; };
      Locale.prototype.toJSON = function () { return this._tag; };

      // ---------------- Intl.Segmenter (grapheme) ----------------
      function makeSegments(arr) {
        var segs = {};
        hide(segs, 'containing', function (i) {
          var at = Number(i) || 0;
          for (var k = 0; k < arr.length; k++) {
            var s = arr[k];
            if (at >= s.index && at < s.index + s.segment.length) { return s; }
          }
          return undefined;
        });
        if (typeof Symbol !== 'undefined' && typeof Symbol.iterator !== 'undefined') {
          hide(segs, Symbol.iterator, function () {
            var i = 0;
            var it = {
              next: function () {
                return i < arr.length ? { value: arr[i++], done: false }
                                      : { value: undefined, done: true };
              }
            };
            it[Symbol.iterator] = function () { return this; };
            return it;
          });
        }
        return segs;
      }
      function Segmenter(locales, options) {
        if (!(this instanceof Segmenter)) {
          throw new TypeError("Constructor Intl.Segmenter requires 'new'");
        }
        var o = options || {};
        var granularity = o.granularity === undefined ? 'grapheme' : String(o.granularity);
        if (granularity !== 'grapheme' && granularity !== 'word' && granularity !== 'sentence') {
          throw new RangeError('Value ' + granularity + ' out of range for Intl.Segmenter options property granularity');
        }
        hide(this, '_locale', N.canonical(locales)[0] || N.defaultLocale());
        hide(this, '_granularity', granularity);
        ownMethod(this, 'segment', function segment(input) {
          return makeSegments(N.segments(String(input)));
        });
      }
      Segmenter.prototype.segment = function (input) {
        return makeSegments(N.segments(String(input)));
      };
      Segmenter.prototype.resolvedOptions = function () {
        return { locale: this._locale, granularity: this._granularity };
      };

      // ---------------- namespace ----------------
      var ctors = [NumberFormat, DateTimeFormat, Collator, PluralRules, RelativeTimeFormat,
                   ListFormat, DisplayNames, Segmenter];
      for (var i = 0; i < ctors.length; i++) {
        hide(ctors[i], 'supportedLocalesOf', function (locales) { return N.supportedLocales(locales); });
      }

      var Intl = {};
      hide(Intl, 'NumberFormat', NumberFormat);
      hide(Intl, 'DateTimeFormat', DateTimeFormat);
      hide(Intl, 'Collator', Collator);
      hide(Intl, 'PluralRules', PluralRules);
      hide(Intl, 'RelativeTimeFormat', RelativeTimeFormat);
      hide(Intl, 'ListFormat', ListFormat);
      hide(Intl, 'DisplayNames', DisplayNames);
      hide(Intl, 'Locale', Locale);
      hide(Intl, 'Segmenter', Segmenter);
      hide(Intl, 'getCanonicalLocales', function (locales) { return N.canonical(locales); });
      hide(Intl, 'supportedValuesOf', function (key) { return N.supportedValues(String(key)); });
      if (typeof Symbol !== 'undefined' && typeof Symbol.toStringTag !== 'undefined') {
        hide(Intl, Symbol.toStringTag, 'Intl');
      }

      g.Intl = Intl;
      if (typeof window !== 'undefined' && window !== g) { window.Intl = Intl; }

      // ---------------- locale-aware builtins ----------------
      var DATE_KEYS = ['weekday', 'era', 'year', 'month', 'day', 'dateStyle'];
      var TIME_KEYS = ['hour', 'minute', 'second', 'timeStyle', 'dayPeriod',
                       'fractionalSecondDigits'];
      function hasAny(o, keys) {
        if (!o) { return false; }
        for (var i = 0; i < keys.length; i++) { if (o[keys[i]] !== undefined) { return true; } }
        return false;
      }
      function withDefaults(options, wantDate, wantTime) {
        var o = {}, k;
        if (options) { for (k in options) { o[k] = options[k]; } }
        if (!hasAny(options, DATE_KEYS) && !hasAny(options, TIME_KEYS)) {
          if (wantDate) { o.year = 'numeric'; o.month = 'numeric'; o.day = 'numeric'; }
          if (wantTime) { o.hour = 'numeric'; o.minute = 'numeric'; o.second = 'numeric'; }
        }
        return o;
      }
      function dateMethod(wantDate, wantTime) {
        return function (locales, options) {
          var t = Number(this);
          if (!isFinite(t)) { return 'Invalid Date'; }
          return new DateTimeFormat(locales, withDefaults(options, wantDate, wantTime)).format(t);
        };
      }
      hide(Number.prototype, 'toLocaleString', function (locales, options) {
        return new NumberFormat(locales, options).format(Number(this));
      });
      hide(Date.prototype, 'toLocaleDateString', dateMethod(true, false));
      hide(Date.prototype, 'toLocaleTimeString', dateMethod(false, true));
      hide(Date.prototype, 'toLocaleString', dateMethod(true, true));
      hide(String.prototype, 'localeCompare', function (that, locales, options) {
        return new Collator(locales, options).compare(String(this), String(that));
      });
      hide(Array.prototype, 'toLocaleString', function (locales, options) {
        var out = [];
        for (var i = 0; i < this.length; i++) {
          var v = this[i];
          out.push((v === undefined || v === null) ? '' : v.toLocaleString(locales, options));
        }
        return out.join(',');
      });
    })();
    """#
}
