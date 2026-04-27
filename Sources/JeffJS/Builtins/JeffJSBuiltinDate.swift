// JeffJSBuiltinDate.swift
// JeffJS — 1:1 Swift port of QuickJS JavaScript engine
//
// Port of QuickJS js_date_* functions from quickjs.c.
// Implements the Date built-in object (ECMA-262 sec 21.4).
//
// The Date object stores time internally as a Double representing
// milliseconds since the Unix epoch (1970-01-01T00:00:00Z), exactly
// as specified by ECMA-262. NaN indicates an invalid date.

import Foundation

// MARK: - Internal Date Constants

/// Milliseconds per day.
private let msPerDay: Double = 86400000.0

/// Milliseconds per hour.
private let msPerHour: Double = 3600000.0

/// Milliseconds per minute.
private let msPerMinute: Double = 60000.0

/// Milliseconds per second.
private let msPerSecond: Double = 1000.0

/// Maximum representable time value: +/- 8.64e15 ms (100 million days).
private let maxTimeValue: Double = 8.64e15

// MARK: - Date Arithmetic (ECMA-262 sec 21.4.1)

/// Day(t) = floor(t / msPerDay)
@inline(__always)
private func day(_ t: Double) -> Double {
    return Darwin.floor(t / msPerDay)
}

/// TimeWithinDay(t) = t modulo msPerDay
@inline(__always)
private func timeWithinDay(_ t: Double) -> Double {
    let r = t.truncatingRemainder(dividingBy: msPerDay)
    return r < 0 ? r + msPerDay : r
}

/// DaysInYear(y) — number of days in year y.
private func daysInYear(_ y: Double) -> Double {
    let yi = Int(y)
    if yi % 4 != 0 { return 365 }
    if yi % 100 != 0 { return 366 }
    if yi % 400 != 0 { return 365 }
    return 366
}

/// DayFromYear(y) — day number of the first day of year y.
private func dayFromYear(_ y: Double) -> Double {
    return 365.0 * (y - 1970.0)
         + Darwin.floor((y - 1969.0) / 4.0)
         - Darwin.floor((y - 1901.0) / 100.0)
         + Darwin.floor((y - 1601.0) / 400.0)
}

/// TimeFromYear(y) — time value at the start of year y.
@inline(__always)
private func timeFromYear(_ y: Double) -> Double {
    return msPerDay * dayFromYear(y)
}

/// YearFromTime(t) — the year containing time t.
private func yearFromTime(_ t: Double) -> Double {
    // Binary search for the year.
    var lo = Darwin.floor(t / msPerDay / 366.0) + 1970.0
    var hi = Darwin.floor(t / msPerDay / 365.0) + 1970.0

    if lo > hi { swap(&lo, &hi) }

    while lo < hi {
        let mid = Darwin.floor((lo + hi + 1) / 2.0)
        if timeFromYear(mid) <= t {
            lo = mid
        } else {
            hi = mid - 1
        }
    }
    return lo
}

/// InLeapYear(t) — 1 if t falls in a leap year, 0 otherwise.
@inline(__always)
private func inLeapYear(_ t: Double) -> Double {
    return daysInYear(yearFromTime(t)) == 366 ? 1 : 0
}

/// DayWithinYear(t) — zero-based day-of-year for time t.
@inline(__always)
private func dayWithinYear(_ t: Double) -> Double {
    return day(t) - dayFromYear(yearFromTime(t))
}

/// MonthFromTime(t) — zero-based month (0=Jan, 11=Dec).
private func monthFromTime(_ t: Double) -> Double {
    let d = dayWithinYear(t)
    let leap = inLeapYear(t)

    if d < 31 { return 0 }
    if d < 59 + leap { return 1 }
    if d < 90 + leap { return 2 }
    if d < 120 + leap { return 3 }
    if d < 151 + leap { return 4 }
    if d < 181 + leap { return 5 }
    if d < 212 + leap { return 6 }
    if d < 243 + leap { return 7 }
    if d < 273 + leap { return 8 }
    if d < 304 + leap { return 9 }
    if d < 334 + leap { return 10 }
    return 11
}

/// DateFromTime(t) — 1-based day of month.
private func dateFromTime(_ t: Double) -> Double {
    let d = dayWithinYear(t)
    let m = monthFromTime(t)
    let leap = inLeapYear(t)

    switch Int(m) {
    case 0:  return d + 1
    case 1:  return d - 30
    case 2:  return d - 58 - leap
    case 3:  return d - 89 - leap
    case 4:  return d - 119 - leap
    case 5:  return d - 150 - leap
    case 6:  return d - 180 - leap
    case 7:  return d - 211 - leap
    case 8:  return d - 242 - leap
    case 9:  return d - 272 - leap
    case 10: return d - 303 - leap
    case 11: return d - 333 - leap
    default: return Double.nan
    }
}

/// WeekDay(t) — day of week (0=Sunday, 6=Saturday).
@inline(__always)
private func weekDay(_ t: Double) -> Double {
    let r = (day(t) + 4).truncatingRemainder(dividingBy: 7)
    return r < 0 ? r + 7 : r
}

/// HourFromTime(t)
@inline(__always)
private func hourFromTime(_ t: Double) -> Double {
    let r = Darwin.floor(t / msPerHour).truncatingRemainder(dividingBy: 24)
    return r < 0 ? r + 24 : r
}

/// MinFromTime(t)
@inline(__always)
private func minFromTime(_ t: Double) -> Double {
    let r = Darwin.floor(t / msPerMinute).truncatingRemainder(dividingBy: 60)
    return r < 0 ? r + 60 : r
}

/// SecFromTime(t)
@inline(__always)
private func secFromTime(_ t: Double) -> Double {
    let r = Darwin.floor(t / msPerSecond).truncatingRemainder(dividingBy: 60)
    return r < 0 ? r + 60 : r
}

/// msFromTime(t)
@inline(__always)
private func msFromTime(_ t: Double) -> Double {
    let r = t.truncatingRemainder(dividingBy: msPerSecond)
    return r < 0 ? r + msPerSecond : r
}

/// MakeTime(hour, min, sec, ms)
private func makeTime(_ hour: Double, _ min: Double, _ sec: Double, _ ms: Double) -> Double {
    if hour.isNaN || min.isNaN || sec.isNaN || ms.isNaN { return Double.nan }
    if hour.isInfinite || min.isInfinite || sec.isInfinite || ms.isInfinite { return Double.nan }
    let h = Darwin.trunc(hour)
    let m = Darwin.trunc(min)
    let s = Darwin.trunc(sec)
    let milli = Darwin.trunc(ms)
    return h * msPerHour + m * msPerMinute + s * msPerSecond + milli
}

/// MakeDay(year, month, date)
private func makeDay(_ year: Double, _ month: Double, _ date: Double) -> Double {
    if year.isNaN || month.isNaN || date.isNaN { return Double.nan }
    if year.isInfinite || month.isInfinite || date.isInfinite { return Double.nan }

    let y = Darwin.trunc(year)
    let m = Darwin.trunc(month)
    let dt = Darwin.trunc(date)

    let ym = y + Darwin.floor(m / 12.0)
    let mn = m.truncatingRemainder(dividingBy: 12)
    let mnAdj = mn < 0 ? mn + 12 : mn

    // Day count for the first of the target month in the target year.
    let monthDays: [Double] = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
    let leap: Double = daysInYear(ym) == 366 ? 1 : 0
    let mdi = Int(mnAdj)
    let dayOffset = monthDays[mdi] + (mdi >= 2 ? leap : 0)

    let t = dayFromYear(ym) + dayOffset
    return t + dt - 1
}

/// MakeDate(day, time)
@inline(__always)
private func makeDate(_ day: Double, _ time: Double) -> Double {
    if day.isNaN || time.isNaN { return Double.nan }
    if day.isInfinite || time.isInfinite { return Double.nan }
    return day * msPerDay + time
}

/// TimeClip(time) — clamp to valid range or NaN.
@inline(__always)
private func timeClip(_ t: Double) -> Double {
    if t.isNaN || t.isInfinite { return Double.nan }
    if Swift.abs(t) > maxTimeValue { return Double.nan }
    return Darwin.trunc(t) + 0  // +0 converts -0 to +0
}

/// LocalTZA — local timezone offset in milliseconds.
/// This is a simplified implementation using Foundation.
private func localTZA() -> Double {
    return Double(-TimeZone.current.secondsFromGMT()) * msPerSecond
}

/// LocalTime(t) — convert UTC to local time.
private func localTime(_ t: Double) -> Double {
    return t - localTZA()
}

/// UTC(t) — convert local time to UTC.
private func utcTime(_ t: Double) -> Double {
    return t + localTZA()
}

// MARK: - Date Object Data

/// Extract the internal time value from a Date object.
/// Returns NaN if the object is not a Date or has invalid data.
private func getDateValue(_ thisVal: JeffJSValue) -> Double {
    guard let obj = thisVal.toObject() else { return Double.nan }
    guard obj.classID == JeffJSClassID.date.rawValue else { return Double.nan }
    if case .objectData(let v) = obj.payload {
        if v.isFloat64 { return v.toFloat64() }
        if v.isInt { return Double(v.toInt32()) }
    }
    return Double.nan
}

/// Set the internal time value on a Date object.
private func setDateValue(_ thisVal: JeffJSValue, _ t: Double) {
    guard let obj = thisVal.toObject() else { return }
    guard obj.classID == JeffJSClassID.date.rawValue else { return }
    obj.payload = .objectData(.newFloat64(timeClip(t)))
}

// MARK: - Date Parsing

/// Parse an ISO 8601 date string. Returns the time value in ms, or NaN.
/// Supports: YYYY, YYYY-MM, YYYY-MM-DD, YYYY-MM-DDTHH:mm, YYYY-MM-DDTHH:mm:ss,
/// YYYY-MM-DDTHH:mm:ss.sss, with optional timezone Z or +/-HH:mm.
private func parseISODate(_ str: String) -> Double {
    let chars = Array(str.utf8)
    let len = chars.count
    var pos = 0

    func peekChar() -> UInt8? { pos < len ? chars[pos] : nil }
    func nextChar() -> UInt8? {
        guard pos < len else { return nil }
        let c = chars[pos]; pos += 1; return c
    }

    func parseDigits(_ count: Int) -> Int? {
        var value = 0
        for _ in 0..<count {
            guard let c = nextChar(), c >= 0x30, c <= 0x39 else { return nil }
            value = value * 10 + Int(c - 0x30)
        }
        return value
    }

    func parseFraction() -> Double {
        var frac = 0.0
        var divisor = 1.0
        while let c = peekChar(), c >= 0x30, c <= 0x39 {
            _ = nextChar()
            divisor *= 10.0
            frac += Double(c - 0x30) / divisor
        }
        return frac
    }

    // Parse sign for extended years
    var yearSign: Double = 1.0
    if peekChar() == 0x2B { _ = nextChar(); yearSign = 1.0 } // '+'
    else if peekChar() == 0x2D { _ = nextChar(); yearSign = -1.0 } // '-'

    guard let year = parseDigits(yearSign != 1.0 ? 6 : 4) else { return Double.nan }
    let y = Double(year) * yearSign

    var month = 1.0
    var dateDay = 1.0
    var hour = 0.0
    var minute = 0.0
    var second = 0.0
    var ms = 0.0
    var isUTC = true // Date-only forms are interpreted as UTC per spec

    // Month
    if peekChar() == 0x2D { // '-'
        _ = nextChar()
        guard let m = parseDigits(2) else { return Double.nan }
        month = Double(m)
    }

    // Day
    if peekChar() == 0x2D { // '-'
        _ = nextChar()
        guard let d = parseDigits(2) else { return Double.nan }
        dateDay = Double(d)
    }

    // Time separator
    if peekChar() == 0x54 || peekChar() == 0x74 { // 'T' or 't'
        _ = nextChar()
        isUTC = false // Date-time forms default to local unless Z or offset

        guard let h = parseDigits(2) else { return Double.nan }
        hour = Double(h)

        guard peekChar() == 0x3A else { return Double.nan } // ':'
        _ = nextChar()

        guard let m = parseDigits(2) else { return Double.nan }
        minute = Double(m)

        if peekChar() == 0x3A { // ':'
            _ = nextChar()
            guard let s = parseDigits(2) else { return Double.nan }
            second = Double(s)

            if peekChar() == 0x2E { // '.'
                _ = nextChar()
                let frac = parseFraction()
                ms = Darwin.floor(frac * 1000.0 + 0.5)
            }
        }

        // Timezone
        if peekChar() == 0x5A || peekChar() == 0x7A { // 'Z' or 'z'
            _ = nextChar()
            isUTC = true
        } else if peekChar() == 0x2B || peekChar() == 0x2D { // '+' or '-'
            let tzSign: Double = peekChar() == 0x2D ? -1.0 : 1.0
            _ = nextChar()
            isUTC = true

            guard let tzH = parseDigits(2) else { return Double.nan }
            var tzM = 0
            if peekChar() == 0x3A { _ = nextChar() }
            if let m = parseDigits(2) { tzM = m }

            let tzOffset = tzSign * (Double(tzH) * 60.0 + Double(tzM))
            minute -= tzOffset
        }
    }

    // Build the date
    let dayVal = makeDay(y, month - 1, dateDay)
    let timeVal = makeTime(hour, minute, second, ms)
    var t = makeDate(dayVal, timeVal)

    if !isUTC {
        t = utcTime(t)
    }

    return timeClip(t)
}

/// Parse a date string. Tries ISO 8601 first, then falls back to
/// a simplified "natural" parser for common formats.
private func jsDateParse(_ str: String) -> Double {
    // Try ISO 8601 first.
    let isoResult = parseISODate(str)
    if !isoResult.isNaN { return isoResult }

    // Fallback: try Foundation's date parsing for common formats.
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")

    let formats = [
        "EEE, dd MMM yyyy HH:mm:ss zzz",     // RFC 2822
        "EEE MMM dd yyyy HH:mm:ss 'GMT'Z",    // toString() output
        "MMM dd, yyyy HH:mm:ss",               // US style
        "MMM dd yyyy",                          // Short US
        "yyyy/MM/dd HH:mm:ss",                 // Slash-separated
        "yyyy/MM/dd",
    ]

    for fmt in formats {
        formatter.dateFormat = fmt
        if let date = formatter.date(from: str) {
            return date.timeIntervalSince1970 * 1000.0
        }
    }

    return Double.nan
}

// MARK: - Date Constructor

/// Date() constructor implementation.
/// Handles: new Date(), new Date(value), new Date(dateString),
/// new Date(year, monthIndex, [day, hours, minutes, seconds, ms]).
func jsDate_constructor(_ ctx: JeffJSContext, _ thisVal: JeffJSValue,
                        _ argv: [JeffJSValue], _ isNew: Bool) -> JeffJSValue {
    if !isNew {
        // Called as a function — return a string like Date().
        let now = Date().timeIntervalSince1970 * 1000.0
        return .makeString(JeffJSString(swiftString: formatDateToString(now)))
    }

    // Get the prototype from the constructor (newTarget) so instances inherit Date.prototype methods
    let protoVal = ctx.getProperty(obj: thisVal, atom: JeffJSAtomID.JS_ATOM_prototype.rawValue)
    let proto = protoVal.toObject()
    let obj = jeffJS_createObject(ctx: ctx, proto: proto, classID: UInt16(JeffJSClassID.date.rawValue))
    var tv: Double

    if argv.isEmpty {
        // new Date() — current time
        tv = Date().timeIntervalSince1970 * 1000.0
    } else if argv.count == 1 {
        let v = argv[0]
        if v.isString, let s = v.stringValue {
            // new Date(dateString)
            tv = jsDateParse(s.toSwiftString())
        } else {
            // new Date(value) — milliseconds since epoch
            if v.isInt {
                tv = Double(v.toInt32())
            } else if v.isFloat64 {
                tv = v.toFloat64()
            } else {
                tv = Double.nan
            }
        }
    } else {
        // new Date(year, monthIndex, ...)
        func argToDouble(_ i: Int, _ def: Double) -> Double {
            guard i < argv.count else { return def }
            let v = argv[i]
            if v.isInt { return Double(v.toInt32()) }
            if v.isFloat64 { return v.toFloat64() }
            if v.isUndefined { return def }
            return Double.nan
        }

        var y = argToDouble(0, Double.nan)
        let m = argToDouble(1, 0)
        let dt = argToDouble(2, 1)
        let h = argToDouble(3, 0)
        let min = argToDouble(4, 0)
        let s = argToDouble(5, 0)
        let milli = argToDouble(6, 0)

        // Years 0-99 map to 1900-1999
        if !y.isNaN {
            let yi = Darwin.trunc(y)
            if yi >= 0 && yi <= 99 {
                y = 1900 + yi
            }
        }

        let dayVal = makeDay(y, m, dt)
        let timeVal = makeTime(h, min, s, milli)
        tv = timeClip(utcTime(makeDate(dayVal, timeVal)))
    }

    obj.payload = JeffJSObjectPayload.objectData(JeffJSValue.newFloat64(timeClip(tv)))
    return .makeObject(obj)
}

// MARK: - Date Static Methods

/// Date.now() — returns current time in milliseconds since epoch.
func jsDate_now(_ ctx: JeffJSContext, _ thisVal: JeffJSValue,
                _ argv: [JeffJSValue]) -> JeffJSValue {
    let ms = Date().timeIntervalSince1970 * 1000.0
    return .newFloat64(Darwin.trunc(ms))
}

/// Date.parse(string) — parse a date string.
func jsDate_parse(_ ctx: JeffJSContext, _ thisVal: JeffJSValue,
                  _ argv: [JeffJSValue]) -> JeffJSValue {
    guard argv.count >= 1, argv[0].isString, let s = argv[0].stringValue else {
        return .newFloat64(Double.nan)
    }
    return .newFloat64(jsDateParse(s.toSwiftString()))
}

/// Date.UTC(year, month, ...) — returns time value for UTC date.
func jsDate_UTC(_ ctx: JeffJSContext, _ thisVal: JeffJSValue,
                _ argv: [JeffJSValue]) -> JeffJSValue {
    func argToDouble(_ i: Int, _ def: Double) -> Double {
        guard i < argv.count else { return def }
        let v = argv[i]
        if v.isInt { return Double(v.toInt32()) }
        if v.isFloat64 { return v.toFloat64() }
        return Double.nan
    }

    var y = argToDouble(0, Double.nan)
    let m = argToDouble(1, 0)
    let dt = argToDouble(2, 1)
    let h = argToDouble(3, 0)
    let min = argToDouble(4, 0)
    let s = argToDouble(5, 0)
    let milli = argToDouble(6, 0)

    if !y.isNaN {
        let yi = Darwin.trunc(y)
        if yi >= 0 && yi <= 99 { y = 1900 + yi }
    }

    let dayVal = makeDay(y, m, dt)
    let timeVal = makeTime(h, min, s, milli)
    return .newFloat64(timeClip(makeDate(dayVal, timeVal)))
}

// MARK: - Date Prototype Getters

/// getTime()
func jsDate_getTime(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    return .newFloat64(getDateValue(thisVal))
}

/// getFullYear()
func jsDate_getFullYear(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let t = getDateValue(thisVal)
    if t.isNaN { return .newFloat64(Double.nan) }
    return .newFloat64(yearFromTime(localTime(t)))
}

/// getMonth()
func jsDate_getMonth(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let t = getDateValue(thisVal)
    if t.isNaN { return .newFloat64(Double.nan) }
    return .newFloat64(monthFromTime(localTime(t)))
}

/// getDate()
func jsDate_getDate(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let t = getDateValue(thisVal)
    if t.isNaN { return .newFloat64(Double.nan) }
    return .newFloat64(dateFromTime(localTime(t)))
}

/// getDay()
func jsDate_getDay(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let t = getDateValue(thisVal)
    if t.isNaN { return .newFloat64(Double.nan) }
    return .newFloat64(weekDay(localTime(t)))
}

/// getHours()
func jsDate_getHours(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let t = getDateValue(thisVal)
    if t.isNaN { return .newFloat64(Double.nan) }
    return .newFloat64(hourFromTime(localTime(t)))
}

/// getMinutes()
func jsDate_getMinutes(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let t = getDateValue(thisVal)
    if t.isNaN { return .newFloat64(Double.nan) }
    return .newFloat64(minFromTime(localTime(t)))
}

/// getSeconds()
func jsDate_getSeconds(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let t = getDateValue(thisVal)
    if t.isNaN { return .newFloat64(Double.nan) }
    return .newFloat64(secFromTime(localTime(t)))
}

/// getMilliseconds()
func jsDate_getMilliseconds(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let t = getDateValue(thisVal)
    if t.isNaN { return .newFloat64(Double.nan) }
    return .newFloat64(msFromTime(localTime(t)))
}

/// getTimezoneOffset() — returns offset in minutes (positive = west of UTC).
func jsDate_getTimezoneOffset(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let t = getDateValue(thisVal)
    if t.isNaN { return .newFloat64(Double.nan) }
    return .newFloat64((t - localTime(t)) / msPerMinute)
}

// MARK: - UTC Getters

func jsDate_getUTCFullYear(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let t = getDateValue(thisVal); if t.isNaN { return .newFloat64(Double.nan) }
    return .newFloat64(yearFromTime(t))
}

func jsDate_getUTCMonth(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let t = getDateValue(thisVal); if t.isNaN { return .newFloat64(Double.nan) }
    return .newFloat64(monthFromTime(t))
}

func jsDate_getUTCDate(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let t = getDateValue(thisVal); if t.isNaN { return .newFloat64(Double.nan) }
    return .newFloat64(dateFromTime(t))
}

func jsDate_getUTCDay(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let t = getDateValue(thisVal); if t.isNaN { return .newFloat64(Double.nan) }
    return .newFloat64(weekDay(t))
}

func jsDate_getUTCHours(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let t = getDateValue(thisVal); if t.isNaN { return .newFloat64(Double.nan) }
    return .newFloat64(hourFromTime(t))
}

func jsDate_getUTCMinutes(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let t = getDateValue(thisVal); if t.isNaN { return .newFloat64(Double.nan) }
    return .newFloat64(minFromTime(t))
}

func jsDate_getUTCSeconds(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let t = getDateValue(thisVal); if t.isNaN { return .newFloat64(Double.nan) }
    return .newFloat64(secFromTime(t))
}

func jsDate_getUTCMilliseconds(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let t = getDateValue(thisVal); if t.isNaN { return .newFloat64(Double.nan) }
    return .newFloat64(msFromTime(t))
}

// MARK: - Setters

/// Helper to extract optional argument as Double.
private func optArg(_ argv: [JeffJSValue], _ i: Int) -> Double? {
    guard i < argv.count else { return nil }
    let v = argv[i]
    if v.isUndefined { return nil }
    if v.isInt { return Double(v.toInt32()) }
    if v.isFloat64 { return v.toFloat64() }
    return Double.nan
}

/// setTime(timeValue)
func jsDate_setTime(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let v = optArg(argv, 0) ?? Double.nan
    setDateValue(thisVal, v)
    return .newFloat64(timeClip(v))
}

/// setMilliseconds(ms)
func jsDate_setMilliseconds(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    var t = getDateValue(thisVal)
    if t.isNaN { return .newFloat64(Double.nan) }
    t = localTime(t)
    let ms = optArg(argv, 0) ?? Double.nan
    let newTime = makeTime(hourFromTime(t), minFromTime(t), secFromTime(t), ms)
    let u = timeClip(utcTime(makeDate(day(t), newTime)))
    setDateValue(thisVal, u)
    return .newFloat64(u)
}

/// setSeconds([sec [, ms]])
func jsDate_setSeconds(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    var t = getDateValue(thisVal)
    if t.isNaN { return .newFloat64(Double.nan) }
    t = localTime(t)
    let s = optArg(argv, 0) ?? secFromTime(t)
    let ms = optArg(argv, 1) ?? msFromTime(t)
    let newTime = makeTime(hourFromTime(t), minFromTime(t), s, ms)
    let u = timeClip(utcTime(makeDate(day(t), newTime)))
    setDateValue(thisVal, u)
    return .newFloat64(u)
}

/// setMinutes([min [, sec [, ms]]])
func jsDate_setMinutes(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    var t = getDateValue(thisVal)
    if t.isNaN { return .newFloat64(Double.nan) }
    t = localTime(t)
    let m = optArg(argv, 0) ?? minFromTime(t)
    let s = optArg(argv, 1) ?? secFromTime(t)
    let ms = optArg(argv, 2) ?? msFromTime(t)
    let newTime = makeTime(hourFromTime(t), m, s, ms)
    let u = timeClip(utcTime(makeDate(day(t), newTime)))
    setDateValue(thisVal, u)
    return .newFloat64(u)
}

/// setHours([hour [, min [, sec [, ms]]]])
func jsDate_setHours(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    var t = getDateValue(thisVal)
    if t.isNaN { return .newFloat64(Double.nan) }
    t = localTime(t)
    let h = optArg(argv, 0) ?? hourFromTime(t)
    let m = optArg(argv, 1) ?? minFromTime(t)
    let s = optArg(argv, 2) ?? secFromTime(t)
    let ms = optArg(argv, 3) ?? msFromTime(t)
    let newTime = makeTime(h, m, s, ms)
    let u = timeClip(utcTime(makeDate(day(t), newTime)))
    setDateValue(thisVal, u)
    return .newFloat64(u)
}

/// setDate(date)
func jsDate_setDate(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    var t = getDateValue(thisVal)
    if t.isNaN { return .newFloat64(Double.nan) }
    t = localTime(t)
    let dt = optArg(argv, 0) ?? Double.nan
    let newDay = makeDay(yearFromTime(t), monthFromTime(t), dt)
    let u = timeClip(utcTime(makeDate(newDay, timeWithinDay(t))))
    setDateValue(thisVal, u)
    return .newFloat64(u)
}

/// setMonth([month [, date]])
func jsDate_setMonth(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    var t = getDateValue(thisVal)
    if t.isNaN { return .newFloat64(Double.nan) }
    t = localTime(t)
    let m = optArg(argv, 0) ?? monthFromTime(t)
    let dt = optArg(argv, 1) ?? dateFromTime(t)
    let newDay = makeDay(yearFromTime(t), m, dt)
    let u = timeClip(utcTime(makeDate(newDay, timeWithinDay(t))))
    setDateValue(thisVal, u)
    return .newFloat64(u)
}

/// setFullYear([year [, month [, date]]])
func jsDate_setFullYear(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    var t = getDateValue(thisVal)
    if t.isNaN { t = 0 }
    t = localTime(t)
    let y = optArg(argv, 0) ?? yearFromTime(t)
    let m = optArg(argv, 1) ?? monthFromTime(t)
    let dt = optArg(argv, 2) ?? dateFromTime(t)
    let newDay = makeDay(y, m, dt)
    let u = timeClip(utcTime(makeDate(newDay, timeWithinDay(t))))
    setDateValue(thisVal, u)
    return .newFloat64(u)
}

// MARK: - UTC Setters

func jsDate_setUTCMilliseconds(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let t = getDateValue(thisVal); if t.isNaN { return .newFloat64(Double.nan) }
    let ms = optArg(argv, 0) ?? Double.nan
    let newTime = makeTime(hourFromTime(t), minFromTime(t), secFromTime(t), ms)
    let u = timeClip(makeDate(day(t), newTime))
    setDateValue(thisVal, u); return .newFloat64(u)
}

func jsDate_setUTCSeconds(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let t = getDateValue(thisVal); if t.isNaN { return .newFloat64(Double.nan) }
    let s = optArg(argv, 0) ?? secFromTime(t)
    let ms = optArg(argv, 1) ?? msFromTime(t)
    let newTime = makeTime(hourFromTime(t), minFromTime(t), s, ms)
    let u = timeClip(makeDate(day(t), newTime))
    setDateValue(thisVal, u); return .newFloat64(u)
}

func jsDate_setUTCMinutes(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let t = getDateValue(thisVal); if t.isNaN { return .newFloat64(Double.nan) }
    let m = optArg(argv, 0) ?? minFromTime(t)
    let s = optArg(argv, 1) ?? secFromTime(t)
    let ms = optArg(argv, 2) ?? msFromTime(t)
    let newTime = makeTime(hourFromTime(t), m, s, ms)
    let u = timeClip(makeDate(day(t), newTime))
    setDateValue(thisVal, u); return .newFloat64(u)
}

func jsDate_setUTCHours(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let t = getDateValue(thisVal); if t.isNaN { return .newFloat64(Double.nan) }
    let h = optArg(argv, 0) ?? hourFromTime(t)
    let m = optArg(argv, 1) ?? minFromTime(t)
    let s = optArg(argv, 2) ?? secFromTime(t)
    let ms = optArg(argv, 3) ?? msFromTime(t)
    let newTime = makeTime(h, m, s, ms)
    let u = timeClip(makeDate(day(t), newTime))
    setDateValue(thisVal, u); return .newFloat64(u)
}

func jsDate_setUTCDate(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let t = getDateValue(thisVal); if t.isNaN { return .newFloat64(Double.nan) }
    let dt = optArg(argv, 0) ?? Double.nan
    let newDay = makeDay(yearFromTime(t), monthFromTime(t), dt)
    let u = timeClip(makeDate(newDay, timeWithinDay(t)))
    setDateValue(thisVal, u); return .newFloat64(u)
}

func jsDate_setUTCMonth(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let t = getDateValue(thisVal); if t.isNaN { return .newFloat64(Double.nan) }
    let m = optArg(argv, 0) ?? monthFromTime(t)
    let dt = optArg(argv, 1) ?? dateFromTime(t)
    let newDay = makeDay(yearFromTime(t), m, dt)
    let u = timeClip(makeDate(newDay, timeWithinDay(t)))
    setDateValue(thisVal, u); return .newFloat64(u)
}

func jsDate_setUTCFullYear(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    var t = getDateValue(thisVal)
    if t.isNaN { t = 0 }
    let y = optArg(argv, 0) ?? yearFromTime(t)
    let m = optArg(argv, 1) ?? monthFromTime(t)
    let dt = optArg(argv, 2) ?? dateFromTime(t)
    let newDay = makeDay(y, m, dt)
    let u = timeClip(makeDate(newDay, timeWithinDay(t)))
    setDateValue(thisVal, u); return .newFloat64(u)
}

// MARK: - Conversion Methods

private let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
private let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                          "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

/// Format a UTC time value into a full toString() format.
private func formatDateToString(_ t: Double) -> String {
    if t.isNaN { return "Invalid Date" }
    let lt = localTime(t)
    let y = Int(yearFromTime(lt))
    let m = Int(monthFromTime(lt))
    let d = Int(dateFromTime(lt))
    let wd = Int(weekDay(lt))
    let h = Int(hourFromTime(lt))
    let min = Int(minFromTime(lt))
    let sec = Int(secFromTime(lt))
    let tzOffsetMin = Int((t - lt) / msPerMinute)
    let tzSign = tzOffsetMin <= 0 ? "+" : "-"
    let tzH = abs(tzOffsetMin) / 60
    let tzM = abs(tzOffsetMin) % 60

    return String(format: "%@ %@ %02d %04d %02d:%02d:%02d GMT%@%02d%02d",
                  dayNames[wd], monthNames[m], d, y, h, min, sec,
                  tzSign, tzH, tzM)
}

/// toString()
func jsDate_toString(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let t = getDateValue(thisVal)
    return .makeString(JeffJSString(swiftString: formatDateToString(t)))
}

/// toDateString()
func jsDate_toDateString(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let t = getDateValue(thisVal)
    if t.isNaN { return .makeString(JeffJSString(swiftString: "Invalid Date")) }
    let lt = localTime(t)
    let y = Int(yearFromTime(lt))
    let m = Int(monthFromTime(lt))
    let d = Int(dateFromTime(lt))
    let wd = Int(weekDay(lt))
    let s = String(format: "%@ %@ %02d %04d", dayNames[wd], monthNames[m], d, y)
    return .makeString(JeffJSString(swiftString: s))
}

/// toTimeString()
func jsDate_toTimeString(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let t = getDateValue(thisVal)
    if t.isNaN { return .makeString(JeffJSString(swiftString: "Invalid Date")) }
    let lt = localTime(t)
    let h = Int(hourFromTime(lt))
    let min = Int(minFromTime(lt))
    let sec = Int(secFromTime(lt))
    let tzOffsetMin = Int((t - lt) / msPerMinute)
    let tzSign = tzOffsetMin <= 0 ? "+" : "-"
    let tzH = abs(tzOffsetMin) / 60
    let tzM = abs(tzOffsetMin) % 60
    let s = String(format: "%02d:%02d:%02d GMT%@%02d%02d", h, min, sec, tzSign, tzH, tzM)
    return .makeString(JeffJSString(swiftString: s))
}

/// toISOString()
func jsDate_toISOString(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let t = getDateValue(thisVal)
    if t.isNaN { return ctx.throwTypeError("Invalid time value") }
    let y = Int(yearFromTime(t))
    let m = Int(monthFromTime(t)) + 1
    let d = Int(dateFromTime(t))
    let h = Int(hourFromTime(t))
    let min = Int(minFromTime(t))
    let sec = Int(secFromTime(t))
    let ms = Int(msFromTime(t))

    let s: String
    if y >= 0 && y <= 9999 {
        s = String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", y, m, d, h, min, sec, ms)
    } else if y >= 0 {
        s = String(format: "+%06d-%02d-%02dT%02d:%02d:%02d.%03dZ", y, m, d, h, min, sec, ms)
    } else {
        s = String(format: "-%06d-%02d-%02dT%02d:%02d:%02d.%03dZ", -y, m, d, h, min, sec, ms)
    }
    return .makeString(JeffJSString(swiftString: s))
}

/// toUTCString()
func jsDate_toUTCString(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let t = getDateValue(thisVal)
    if t.isNaN { return .makeString(JeffJSString(swiftString: "Invalid Date")) }
    let y = Int(yearFromTime(t))
    let m = Int(monthFromTime(t))
    let d = Int(dateFromTime(t))
    let wd = Int(weekDay(t))
    let h = Int(hourFromTime(t))
    let min = Int(minFromTime(t))
    let sec = Int(secFromTime(t))
    let s = String(format: "%@, %02d %@ %04d %02d:%02d:%02d GMT",
                   dayNames[wd], d, monthNames[m], y, h, min, sec)
    return .makeString(JeffJSString(swiftString: s))
}

/// toLocaleDateString(), toLocaleTimeString(), toLocaleString()
func jsDate_toLocaleString(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let t = getDateValue(thisVal)
    if t.isNaN { return .makeString(JeffJSString(swiftString: "Invalid Date")) }
    let date = Date(timeIntervalSince1970: t / 1000.0)
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .medium
    return .makeString(JeffJSString(swiftString: formatter.string(from: date)))
}

func jsDate_toLocaleDateString(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let t = getDateValue(thisVal)
    if t.isNaN { return .makeString(JeffJSString(swiftString: "Invalid Date")) }
    let date = Date(timeIntervalSince1970: t / 1000.0)
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return .makeString(JeffJSString(swiftString: formatter.string(from: date)))
}

func jsDate_toLocaleTimeString(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let t = getDateValue(thisVal)
    if t.isNaN { return .makeString(JeffJSString(swiftString: "Invalid Date")) }
    let date = Date(timeIntervalSince1970: t / 1000.0)
    let formatter = DateFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .medium
    return .makeString(JeffJSString(swiftString: formatter.string(from: date)))
}

/// toJSON()
func jsDate_toJSON(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let t = getDateValue(thisVal)
    if t.isNaN || t.isInfinite { return .null }
    return jsDate_toISOString(ctx, thisVal, argv)
}

/// valueOf()
func jsDate_valueOf(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    return .newFloat64(getDateValue(thisVal))
}

/// [Symbol.toPrimitive](hint)
func jsDate_toPrimitive(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    // If hint is "number" or "default", return valueOf(); if "string", return toString().
    var hint = "default"
    if argv.count >= 1, argv[0].isString, let s = argv[0].stringValue {
        hint = s.toSwiftString()
    }

    if hint == "number" {
        return jsDate_valueOf(ctx, thisVal, [])
    }
    // "string" or "default" -> toString
    return jsDate_toString(ctx, thisVal, [])
}

// MARK: - Date Built-in Installation

/// Install the Date constructor and prototype on the global object.
func jeffJS_initDate(ctx: JeffJSContext, globalObj: JeffJSObject) {
    // Date.prototype inherits from Object.prototype per the spec.
    let objectProto = ctx.classProto[JSClassID.JS_CLASS_OBJECT.rawValue].toObject()
    let dateProto = jeffJS_createObject(ctx: ctx, proto: objectProto, classID: UInt16(JeffJSClassID.date.rawValue))
    dateProto.payload = JeffJSObjectPayload.objectData(JeffJSValue.newFloat64(Double.nan))

    // Prototype methods
    let protoMethods: [(String, Int, (JeffJSContext, JeffJSValue, [JeffJSValue]) -> JeffJSValue)] = [
        ("getTime", 0, jsDate_getTime),
        ("getFullYear", 0, jsDate_getFullYear),
        ("getMonth", 0, jsDate_getMonth),
        ("getDate", 0, jsDate_getDate),
        ("getDay", 0, jsDate_getDay),
        ("getHours", 0, jsDate_getHours),
        ("getMinutes", 0, jsDate_getMinutes),
        ("getSeconds", 0, jsDate_getSeconds),
        ("getMilliseconds", 0, jsDate_getMilliseconds),
        ("getTimezoneOffset", 0, jsDate_getTimezoneOffset),
        ("getUTCFullYear", 0, jsDate_getUTCFullYear),
        ("getUTCMonth", 0, jsDate_getUTCMonth),
        ("getUTCDate", 0, jsDate_getUTCDate),
        ("getUTCDay", 0, jsDate_getUTCDay),
        ("getUTCHours", 0, jsDate_getUTCHours),
        ("getUTCMinutes", 0, jsDate_getUTCMinutes),
        ("getUTCSeconds", 0, jsDate_getUTCSeconds),
        ("getUTCMilliseconds", 0, jsDate_getUTCMilliseconds),
        ("setTime", 1, jsDate_setTime),
        ("setMilliseconds", 1, jsDate_setMilliseconds),
        ("setSeconds", 2, jsDate_setSeconds),
        ("setMinutes", 3, jsDate_setMinutes),
        ("setHours", 4, jsDate_setHours),
        ("setDate", 1, jsDate_setDate),
        ("setMonth", 2, jsDate_setMonth),
        ("setFullYear", 3, jsDate_setFullYear),
        ("setUTCMilliseconds", 1, jsDate_setUTCMilliseconds),
        ("setUTCSeconds", 2, jsDate_setUTCSeconds),
        ("setUTCMinutes", 3, jsDate_setUTCMinutes),
        ("setUTCHours", 4, jsDate_setUTCHours),
        ("setUTCDate", 1, jsDate_setUTCDate),
        ("setUTCMonth", 2, jsDate_setUTCMonth),
        ("setUTCFullYear", 3, jsDate_setUTCFullYear),
        ("toString", 0, jsDate_toString),
        ("toDateString", 0, jsDate_toDateString),
        ("toTimeString", 0, jsDate_toTimeString),
        ("toISOString", 0, jsDate_toISOString),
        ("toUTCString", 0, jsDate_toUTCString),
        ("toGMTString", 0, jsDate_toUTCString),  // alias
        ("toLocaleString", 0, jsDate_toLocaleString),
        ("toLocaleDateString", 0, jsDate_toLocaleDateString),
        ("toLocaleTimeString", 0, jsDate_toLocaleTimeString),
        ("toJSON", 1, jsDate_toJSON),
        ("valueOf", 0, jsDate_valueOf),
    ]

    for (name, length, fn) in protoMethods {
        jeffJS_defineBuiltinFunc(ctx: ctx, obj: dateProto, name: name, length: length, func: fn)
    }

    // [Symbol.toPrimitive]
    jeffJS_defineBuiltinFunc(ctx: ctx, obj: dateProto, name: "[Symbol.toPrimitive]",
                             length: 1, func: jsDate_toPrimitive)

    // Date constructor object
    let dateCtor = jeffJS_createObject(ctx: ctx, proto: nil, classID: UInt16(JeffJSClassID.cFunction.rawValue))
    dateCtor.isConstructor = true
    dateCtor.extensible = true
    dateCtor.payload = .cFunc(
        realm: ctx,
        cFunction: .constructorOrFunc({ ctxArg, thisArg, args, isNew in
            return jsDate_constructor(ctxArg, thisArg, args, isNew)
        }),
        length: 7,
        cproto: UInt8(JS_CFUNC_CONSTRUCTOR_OR_FUNC),
        magic: 0
    )

    // Date.prototype on constructor
    let dateProtoVal = JeffJSValue.makeObject(dateProto)
    jeffJS_addProperty(ctx: ctx, obj: dateCtor,
                       atom: JeffJSAtomID.JS_ATOM_prototype.rawValue,
                       flags: [])
    dateCtor.setOwnPropertyValue(
        atom: JeffJSAtomID.JS_ATOM_prototype.rawValue,
        value: dateProtoVal)

    // Date.prototype.constructor = Date
    jeffJS_addProperty(ctx: ctx, obj: dateProto,
                       atom: JeffJSAtomID.JS_ATOM_constructor.rawValue,
                       flags: [.writable, .configurable])
    dateProto.setOwnPropertyValue(
        atom: JeffJSAtomID.JS_ATOM_constructor.rawValue,
        value: JeffJSValue.makeObject(dateCtor))

    // Static methods
    jeffJS_defineBuiltinFunc(ctx: ctx, obj: dateCtor, name: "now", length: 0, func: jsDate_now)
    jeffJS_defineBuiltinFunc(ctx: ctx, obj: dateCtor, name: "parse", length: 1, func: jsDate_parse)
    jeffJS_defineBuiltinFunc(ctx: ctx, obj: dateCtor, name: "UTC", length: 7, func: jsDate_UTC)

    // Install on global
    jeffJS_setPropertyStr(ctx: ctx, obj: globalObj, name: "Date", value: .makeObject(dateCtor))
}
