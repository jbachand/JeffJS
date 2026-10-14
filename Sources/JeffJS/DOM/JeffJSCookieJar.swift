// JeffJSCookieJar.swift
// JeffJS — one HTTP cookie jar for a page: `document.cookie`, fetch/XHR and
// (in the host) every renderer request read and write the same store.
//
// The host supplies the jar (`JeffJSFetchBridge.cookieJar`,
// `JeffJSCookieBridge`, `JeffJSWebSocketBridge.cookieJar`); the engine ships
// `JeffJSMemoryCookieJar`, a complete in-memory RFC 6265bis store the CLI and
// the tests use and that a host can persist (`persistentData` /
// `init(site:persistentData:)`).
//
// Semantics (RFC 6265bis §5):
//   * parsing (§5.6): name/value, Expires (§5.1.1 cookie-date), Max-Age
//     (wins over Expires; <= 0 deletes), Domain (leading dot dropped, must
//     domain-match the request host, public suffixes rejected), Path (default
//     path §5.1.4), Secure, HttpOnly, SameSite (Strict/Lax/None, parsed and
//     stored); lifetimes are capped at 400 days;
//   * storage (§5.7): a cookie replaces the one with the same name, domain,
//     host-only flag and path (keeping its creation time); an expiry in the past
//     deletes; `document.cookie` cannot set or overwrite an HttpOnly cookie; a
//     Secure cookie needs a secure origin, and an insecure origin cannot shadow
//     a Secure one; `__Secure-` / `__Host-` prefixes are enforced;
//   * retrieval (§5.8.3): domain-match (host-only = exact host), path-match,
//     Secure only over https/wss (and loopback), HttpOnly only for HTTP,
//     SameSite=Strict/Lax only on same-site requests; longer paths first, then
//     older cookies; expired cookies are purged, never sent.
//
// Partitioning is the host's business: it gives each top-level site its own
// jar (React Natively: one per registrable domain, `RNCookieJars`), so the
// same third-party host embedded on two sites holds two independent cookies.
//
// Reads are cached per URL against the jar's generation (JeffJSMemoryCookieJar
// comment); `JEFFJS_COOKIE_STATS=1` prints call counts and times of the hot
// paths at exit, `JEFFJS_COOKIE_DEBUG=1` what each document.cookie write did.

import Foundation

nonisolated extension Character {
    fileprivate var isASCIIDigit: Bool { self >= "0" && self <= "9" }
}

// MARK: - Protocol

/// A cookie store with HTTP semantics. Called from any thread: implementations
/// must be thread-safe.
nonisolated public protocol JeffJSCookieJar: AnyObject, Sendable {
    /// The `Cookie:` header value for an HTTP(S)/WS(S) request to `url`, or nil
    /// when no cookie applies. `sameSite` is false for a request whose site
    /// differs from the top-level document's (SameSite=Strict/Lax withheld).
    func cookieHeader(for url: URL, sameSite: Bool) -> String?
    /// Stores the `Set-Cookie` lines of a response to `url` (one cookie each).
    func store(setCookieLines: [String], for url: URL)
    /// `document.cookie` for a document at `url` (no HttpOnly cookies).
    func documentCookie(for url: URL) -> String
    /// `document.cookie = value` for a document at `url`.
    func setDocumentCookie(_ cookieString: String, for url: URL)
}

nonisolated public extension JeffJSCookieJar {
    /// Stores the `Set-Cookie` header(s) of an HTTP response (the joined form
    /// Foundation's `allHeaderFields` gives is split back into cookies).
    func store(response: HTTPURLResponse, for url: URL? = nil) {
        guard let target = url ?? response.url else { return }
        let lines = JeffJSCookieParsing.setCookieLines(from: response)
        if !lines.isEmpty { store(setCookieLines: lines, for: target) }
    }
}

// MARK: - Cookie

/// One stored cookie (RFC 6265bis §5.7 storage model). Encoded with short
/// keys: the host persists these per site on small devices.
nonisolated public struct JeffJSCookie: Codable, Sendable, Equatable {
    public enum SameSite: String, Codable, Sendable { case unspecified = "", strict = "s", lax = "l", none = "n" }

    public var name: String
    public var value: String
    /// Canonical (lowercase, no leading dot) domain; the host for host-only cookies.
    public var domain: String
    public var hostOnly: Bool
    public var path: String
    /// Seconds since 1970; nil = session cookie.
    public var expires: Double?
    public var secure: Bool
    public var httpOnly: Bool
    public var sameSite: SameSite
    public var created: Double
    public var lastAccess: Double

    public var isSession: Bool { expires == nil }

    enum CodingKeys: String, CodingKey {
        case name = "n", value = "v", domain = "d", hostOnly = "h", path = "p", expires = "e"
        case secure = "s", httpOnly = "o", sameSite = "ss", created = "c", lastAccess = "a"
    }

    public init(name: String, value: String, domain: String, hostOnly: Bool, path: String,
                expires: Double?, secure: Bool, httpOnly: Bool, sameSite: SameSite,
                created: Double, lastAccess: Double) {
        self.name = name; self.value = value; self.domain = domain; self.hostOnly = hostOnly
        self.path = path; self.expires = expires; self.secure = secure; self.httpOnly = httpOnly
        self.sameSite = sameSite; self.created = created; self.lastAccess = lastAccess
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        value = try c.decode(String.self, forKey: .value)
        domain = try c.decode(String.self, forKey: .domain)
        hostOnly = try c.decodeIfPresent(Bool.self, forKey: .hostOnly) ?? false
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? "/"
        expires = try c.decodeIfPresent(Double.self, forKey: .expires)
        secure = try c.decodeIfPresent(Bool.self, forKey: .secure) ?? false
        httpOnly = try c.decodeIfPresent(Bool.self, forKey: .httpOnly) ?? false
        sameSite = try c.decodeIfPresent(SameSite.self, forKey: .sameSite) ?? .unspecified
        created = try c.decodeIfPresent(Double.self, forKey: .created) ?? 0
        lastAccess = try c.decodeIfPresent(Double.self, forKey: .lastAccess) ?? created
    }

    /// Only non-default flags are written (a cookie is ~60 bytes + name/value).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(value, forKey: .value)
        try c.encode(domain, forKey: .domain)
        if hostOnly { try c.encode(true, forKey: .hostOnly) }
        if path != "/" { try c.encode(path, forKey: .path) }
        try c.encodeIfPresent(expires.map { $0.rounded() }, forKey: .expires)
        if secure { try c.encode(true, forKey: .secure) }
        if httpOnly { try c.encode(true, forKey: .httpOnly) }
        if sameSite != .unspecified { try c.encode(sameSite, forKey: .sameSite) }
        try c.encode(created.rounded(), forKey: .created)
        try c.encode(lastAccess.rounded(), forKey: .lastAccess)
    }

    /// The (name, domain, host-only, path) identity of RFC 6265bis §5.7 step 23.
    func sameIdentity(_ o: JeffJSCookie) -> Bool {
        name == o.name && domain == o.domain && hostOnly == o.hostOnly && path == o.path
    }
}

// MARK: - Parsing and matching helpers

nonisolated public enum JeffJSCookieParsing {

    /// 400 days (RFC 6265bis §5.5 / §5.6.1–2: the cap on Expires and Max-Age).
    static let maxLifetime: Double = 400 * 24 * 3600

    // MARK: Hosts, sites

    /// Lowercased host of `url` ("" for `file:`), nil for schemes without cookies.
    static func cookieHost(of url: URL) -> String? {
        switch url.scheme?.lowercased() {
        case "http", "https", "ws", "wss":
            guard let h = url.host?.lowercased(), !h.isEmpty else { return nil }
            return h.hasSuffix(".") ? String(h.dropLast()) : h
        case "file":
            return ""
        default:
            return nil
        }
    }

    static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host.hasSuffix(".localhost") || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    /// https / wss, and loopback hosts (potentially trustworthy origins).
    static func isSecure(_ url: URL) -> Bool {
        let s = url.scheme?.lowercased() ?? ""
        if s == "https" || s == "wss" { return true }
        if s == "http" || s == "ws", let h = url.host?.lowercased() { return isLoopback(h) }
        return false
    }

    static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") { return true }   // IPv6
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.count <= 3 && $0.allSatisfy(\.isASCIIDigit) }
    }

    /// Multi-label public suffixes (ICANN and the common private ones) under
    /// which each label is its own site. Not the whole Public Suffix List:
    /// any other name is split at its last two labels.
    static let multiLabelSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "ltd.uk", "plc.uk", "me.uk", "net.uk", "sch.uk", "nhs.uk",
        "com.au", "net.au", "org.au", "edu.au", "gov.au", "asn.au", "id.au",
        "co.nz", "org.nz", "net.nz", "govt.nz", "ac.nz",
        "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp", "ad.jp", "ed.jp", "gr.jp", "lg.jp",
        "co.kr", "or.kr", "ne.kr", "go.kr", "ac.kr",
        "com.br", "net.br", "org.br", "gov.br", "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn",
        "com.mx", "org.mx", "gob.mx", "com.tr", "gov.tr", "com.tw", "org.tw", "com.hk", "org.hk",
        "com.sg", "edu.sg", "gov.sg", "co.in", "net.in", "org.in", "gov.in", "ac.in", "co.za", "org.za",
        "com.ar", "com.co", "com.pe", "com.ve", "com.ec", "com.uy", "com.py", "com.bo",
        "com.my", "com.ph", "com.vn", "co.th", "co.id", "or.id", "ac.id", "com.pk", "com.eg", "com.sa",
        "com.ng", "co.ke", "co.il", "org.il", "ac.il", "gov.il", "com.ua", "co.at", "or.at", "com.pl",
        "github.io", "gitlab.io", "herokuapp.com", "appspot.com", "blogspot.com", "cloudfront.net",
        "azurewebsites.net", "vercel.app", "netlify.app", "pages.dev", "workers.dev", "web.app",
        "firebaseapp.com", "fly.dev", "onrender.com", "s3.amazonaws.com", "glitch.me", "repl.co",
        "myshopify.com", "wordpress.com", "tumblr.com", "wixsite.com", "squarespace.com", "ngrok.io",
    ]

    /// True for a name no cookie may be scoped to (a TLD or a listed suffix).
    static func isPublicSuffix(_ domain: String) -> Bool {
        if domain.isEmpty { return true }
        if !domain.contains(".") { return domain != "localhost" }
        return multiLabelSuffixes.contains(domain)
    }

    /// The registrable domain ("site") of a host: `www.apple.com` → `apple.com`,
    /// `news.bbc.co.uk` → `bbc.co.uk`; IP addresses and single labels are their
    /// own site; `file:` pages share the site "file".
    public static func registrableDomain(ofHost rawHost: String) -> String {
        var host = rawHost.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        if host.isEmpty { return "file" }
        if isIPAddress(host) { return host }
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count > 2 else { return host }
        let lastTwo = labels[(labels.count - 2)...].joined(separator: ".")
        if multiLabelSuffixes.contains(lastTwo) {
            return labels[(labels.count - 3)...].joined(separator: ".")
        }
        let lastThree = labels[(labels.count - 3)...].joined(separator: ".")
        if multiLabelSuffixes.contains(lastThree), labels.count > 3 {
            return labels[(labels.count - 4)...].joined(separator: ".")
        }
        return lastTwo
    }

    /// The site of a URL (registrable domain; "file" for file: URLs, nil for
    /// schemes that have none, e.g. about:, data:).
    public static func site(of url: URL) -> String? {
        guard let host = cookieHost(of: url) else { return nil }
        return registrableDomain(ofHost: host)
    }

    /// RFC 6265bis §5.1.3 domain-match.
    static func domainMatches(_ host: String, _ domain: String) -> Bool {
        if host == domain { return true }
        guard host.hasSuffix("." + domain), !isIPAddress(host) else { return false }
        return true
    }

    // MARK: Paths

    /// The URL's path as sent on the wire (percent-encoded), "/" when empty.
    static func requestPath(of url: URL) -> String {
        let p = URLComponents(url: url, resolvingAgainstBaseURL: true)?.percentEncodedPath ?? url.path
        return p.isEmpty ? "/" : p
    }

    /// RFC 6265bis §5.1.4 default-path.
    static func defaultPath(of url: URL) -> String {
        let p = requestPath(of: url)
        guard p.hasPrefix("/"), let slash = p.lastIndex(of: "/"), slash != p.startIndex else { return "/" }
        return String(p[..<slash])
    }

    /// RFC 6265bis §5.1.4 path-match.
    static func pathMatches(_ requestPath: String, _ cookiePath: String) -> Bool {
        if requestPath == cookiePath { return true }
        guard requestPath.hasPrefix(cookiePath) else { return false }
        if cookiePath.hasSuffix("/") { return true }
        return requestPath[requestPath.index(requestPath.startIndex, offsetBy: cookiePath.count)] == "/"
    }

    // MARK: Set-Cookie header splitting

    /// Every `Set-Cookie` line of a response. Foundation joins repeated headers
    /// with ", " (`allHeaderFields`); the split keeps the commas inside an
    /// `Expires` date.
    public static func setCookieLines(from response: HTTPURLResponse) -> [String] {
        var joined: [String] = []
        for (k, v) in response.allHeaderFields {
            guard String(describing: k).caseInsensitiveCompare("set-cookie") == .orderedSame else { continue }
            joined.append(String(describing: v))
        }
        return joined.flatMap(splitSetCookieHeader)
    }

    /// Splits a combined `Set-Cookie` value (", " or newline joined) into cookies:
    /// a comma starts a new cookie only when the text after it reads `token=`
    /// before any `;` (a date's ", 21 Oct 2015 …" does not).
    public static func splitSetCookieHeader(_ value: String) -> [String] {
        var out: [String] = []
        let chars = Array(value)
        var start = 0
        var i = 0
        func flush(_ end: Int) {
            let s = String(chars[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { out.append(s) }
        }
        while i < chars.count {
            let c = chars[i]
            if c == "\n" || c == "\r" {
                flush(i); start = i + 1
            } else if c == "," {
                var j = i + 1
                while j < chars.count, chars[j] == " " || chars[j] == "\t" { j += 1 }
                var k = j
                while k < chars.count, chars[k] != "=", chars[k] != ";", chars[k] != ",", chars[k] != " " { k += 1 }
                if k < chars.count, chars[k] == "=", k > j {
                    flush(i); start = i + 1
                }
            }
            i += 1
        }
        flush(chars.count)
        return out
    }

    // MARK: Cookie dates (RFC 6265bis §5.1.1)

    private static func isDelimiter(_ b: UInt8) -> Bool {
        b == 0x09 || (0x20...0x2F).contains(b) || (0x3B...0x40).contains(b)
            || (0x5B...0x60).contains(b) || (0x7B...0x7E).contains(b)
    }

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    /// Seconds since 1970 for a cookie-date, nil when it does not parse.
    public static func parseCookieDate(_ s: String) -> Double? {
        var tokens: [[UInt8]] = []
        var cur: [UInt8] = []
        for b in s.utf8 {
            if isDelimiter(b) { if !cur.isEmpty { tokens.append(cur); cur = [] } } else { cur.append(b) }
        }
        if !cur.isEmpty { tokens.append(cur) }

        func leadingDigits(_ t: [UInt8], min: Int, max: Int) -> Int? {
            var n = 0, v = 0
            while n < t.count, (0x30...0x39).contains(t[n]) { v = v * 10 + Int(t[n] - 0x30); n += 1 }
            guard n >= min, n <= max else { return nil }
            return v
        }
        var time: (Int, Int, Int)?, day: Int?, month: Int?, year: Int?
        for t in tokens {
            if time == nil, let parsed = parseTime(t) { time = parsed; continue }
            if day == nil, let d = leadingDigits(t, min: 1, max: 2) { day = d; continue }
            if month == nil, t.count >= 3 {
                let prefix = String(decoding: t[0..<3], as: UTF8.self).lowercased()
                if let m = months.firstIndex(of: prefix) { month = m + 1; continue }
            }
            if year == nil, let y = leadingDigits(t, min: 2, max: 4) { year = y; continue }
        }
        guard let (hh, mm, ss) = time, let d = day, let mo = month, var y = year else { return nil }
        if (70...99).contains(y) { y += 1900 } else if (0...69).contains(y) { y += 2000 }
        guard (1...31).contains(d), y >= 1601, hh <= 23, mm <= 59, ss <= 59 else { return nil }
        let daysInMonth = [31, (y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard d <= daysInMonth[mo - 1] else { return nil }
        let days = daysFromCivil(y, mo, d)
        return Double(days * 86400 + hh * 3600 + mm * 60 + ss)
    }

    /// `hh:mm:ss` (1–2 digits each), optionally followed by non-digits.
    private static func parseTime(_ t: [UInt8]) -> (Int, Int, Int)? {
        var parts: [Int] = [], v = 0, n = 0, i = 0
        while i < t.count {
            let b = t[i]
            if (0x30...0x39).contains(b) {
                v = v * 10 + Int(b - 0x30); n += 1
                if n > 2 { return nil }
            } else if b == 0x3A, parts.count < 2 {
                guard n > 0 else { return nil }
                parts.append(v); v = 0; n = 0
            } else {
                break
            }
            i += 1
        }
        guard parts.count == 2, n > 0 else { return nil }
        return (parts[0], parts[1], v)
    }

    /// Days since 1970-01-01 of a proleptic Gregorian date (H. Hinnant).
    private static func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    // MARK: Set-Cookie parsing (RFC 6265bis §5.6 + §5.7 storage checks)

    /// Parses one set-cookie-string received for `url` into a cookie ready to
    /// store, or nil when the user agent must ignore it. `fromScript` = the
    /// non-HTTP API (`document.cookie`). An expiry in the past is returned as
    /// is (the store deletes the matching cookie).
    static func parse(_ line: String, url: URL, fromScript: Bool, now: Double) -> JeffJSCookie? {
        guard let host = cookieHost(of: url) else { return nil }
        // §5.6 step 1: control characters (except HTAB) → ignore.
        for b in line.utf8 where (b < 0x20 && b != 0x09) || b == 0x7F { return nil }

        let (pairPart, attrPart): (Substring, Substring?) = {
            if let semi = line.firstIndex(of: ";") { return (line[..<semi], line[line.index(after: semi)...]) }
            return (line[...], nil)
        }()
        var name: String, value: String
        if let eq = pairPart.firstIndex(of: "=") {
            name = pairPart[..<eq].trimmingCharacters(in: .whitespaces)
            value = pairPart[pairPart.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        } else {
            name = ""
            value = pairPart.trimmingCharacters(in: .whitespaces)
        }
        if name.isEmpty && value.isEmpty { return nil }
        if name.utf8.count + value.utf8.count > 4096 { return nil }

        var expires: Double? = nil, maxAge: Double? = nil
        var domainAttr: String? = nil, pathAttr: String? = nil
        var secure = false, httpOnly = false, sameSite = JeffJSCookie.SameSite.unspecified
        if let attrPart {
            for raw in attrPart.split(separator: ";", omittingEmptySubsequences: true) {
                let key: String, val: String
                if let eq = raw.firstIndex(of: "=") {
                    key = raw[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
                    val = raw[raw.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                } else {
                    key = raw.trimmingCharacters(in: .whitespaces).lowercased()
                    val = ""
                }
                if val.utf8.count > 1024 { continue }
                switch key {
                case "expires":
                    if let t = parseCookieDate(val) { expires = t }
                case "max-age":
                    guard let first = val.first, first == "-" || first.isASCIIDigit,
                          val.dropFirst().allSatisfy(\.isASCIIDigit) else { continue }
                    let delta = Double(val) ?? (first == "-" ? -1 : maxLifetime)
                    maxAge = delta <= 0 ? -Double.greatestFiniteMagnitude : now + min(delta, maxLifetime)
                case "domain":
                    guard !val.isEmpty else { continue }
                    var d = val.lowercased()
                    if d.hasPrefix(".") { d.removeFirst() }
                    domainAttr = d
                case "path":
                    pathAttr = (val.isEmpty || !val.hasPrefix("/")) ? nil : val
                case "secure": secure = true
                case "httponly": httpOnly = true
                case "samesite":
                    switch val.lowercased() {
                    case "strict": sameSite = .strict
                    case "lax": sameSite = .lax
                    case "none": sameSite = .none
                    default: sameSite = .unspecified
                    }
                default: break
                }
            }
        }

        // Expiry: Max-Age wins over Expires; both capped at 400 days.
        var expiry: Double? = nil
        if let maxAge { expiry = maxAge } else if let expires { expiry = min(expires, now + maxLifetime) }

        // §5.7 steps 5–7: Domain.
        var domain = host, hostOnly = true
        if let d = domainAttr, !d.isEmpty {
            if isPublicSuffix(d) {
                guard d == host else { return nil }   // host-only on the suffix itself
            } else {
                guard domainMatches(host, d) else { return nil }
                if isIPAddress(host), d != host { return nil }
                domain = d
                hostOnly = false
            }
        }
        if fromScript && httpOnly { return nil }                         // step 12
        if secure && !isSecure(url) { return nil }                       // step 9
        let path = pathAttr ?? defaultPath(of: url)

        // Prefixes (§4.1.3), case-insensitively.
        let lower = name.lowercased()
        if lower.hasPrefix("__secure-") && !(secure && isSecure(url)) { return nil }
        if lower.hasPrefix("__host-") && !(secure && isSecure(url) && hostOnly && path == "/") { return nil }
        if name.isEmpty, value.lowercased().hasPrefix("__secure-") || value.lowercased().hasPrefix("__host-") { return nil }

        return JeffJSCookie(name: name, value: value, domain: domain, hostOnly: hostOnly, path: path,
                            expires: expiry, secure: secure, httpOnly: httpOnly, sameSite: sameSite,
                            created: now, lastAccess: now)
    }
}

// MARK: - Statistics (JEFFJS_COOKIE_STATS=1)

/// Per-process counters for the jar's hot paths (calls, total and average
/// time, longest result, most cookies seen in a jar), printed on stderr at
/// exit when `JEFFJS_COOKIE_STATS=1`. One static Bool test per call when off
/// (a 100k-read loop measures the same with and without the counters).
nonisolated enum JeffJSCookieStats {
    static let enabled = ProcessInfo.processInfo.environment["JEFFJS_COOKIE_STATS"] == "1"
    struct Counter { var calls = 0; var nanos: UInt64 = 0; var maxLength = 0 }
    private static let lock = NSLock()
    private static var counters: [String: Counter] = [:]
    private static var maxJarCount = 0
    private static var registered = false

    @inline(__always) static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    static func record(_ key: String, start: UInt64, length: Int, jarCount: Int) {
        let dt = now() &- start
        lock.lock()
        var c = counters[key] ?? Counter()
        c.calls += 1; c.nanos &+= dt; c.maxLength = max(c.maxLength, length)
        counters[key] = c
        maxJarCount = max(maxJarCount, jarCount)
        if !registered { registered = true; atexit { JeffJSCookieStats.dump() } }
        lock.unlock()
    }

    static func dump() {
        lock.lock(); let snapshot = counters; let jarMax = maxJarCount; lock.unlock()
        var out = "[CookieStats] max cookies in jar: \(jarMax)\n"
        for key in snapshot.keys.sorted() {
            let c = snapshot[key]!
            let ms = Double(c.nanos) / 1e6
            let avg = c.calls > 0 ? Double(c.nanos) / Double(c.calls) / 1e3 : 0
            out += String(format: "[CookieStats] %-16@ calls=%8d total=%9.3f ms avg=%8.3f us maxlen=%d\n", key, c.calls, ms, avg, c.maxLength)
        }
        FileHandle.standardError.write(out.data(using: .utf8)!)
    }
}

// MARK: - In-memory jar

/// A complete, thread-safe cookie jar in memory. `site` is the partition's
/// top-level site (informational; the host keeps one jar per site). Session
/// cookies live as long as the instance; persistent ones can be saved with
/// `persistentData(maxBytes:)` and restored with `init(site:persistentData:)`.
///
/// Reads are cached. Pages read `document.cookie` constantly (Home Depot's
/// scripts and Akamai's sensor read it in every timer and event handler) and
/// every fetch/XHR/renderer request asks for its `Cookie:` header, while the
/// jar changes rarely. The serialized result of `matching` is kept per
/// (URL, http, sameSite) together with the jar's `generation` (bumped on
/// every change to `cookies`: store, document.cookie write, expiry purge,
/// cap eviction, removeAll, restore) and `validUntil`, the earliest expiry
/// among the jar's cookies when the entry was built. A hit is a dictionary
/// lookup under the lock; a miss does the RFC 6265bis scan as before. Expiry
/// still takes effect at the second: the entry is stale once `now` reaches
/// `validUntil`, and the miss purges.
///
/// `lastAccess` (what cap eviction and the persistence byte budget rank by)
/// is written by a miss as before; a hit only marks its entry as touched and
/// the touched entries' cookies get `lastAccess = now` the next time the jar
/// is about to change or be inspected (`flushTouchesLocked`), while the
/// entry's indices are still valid. Within one entry the cookies always shared
/// one `lastAccess` (a read stamped them all), so the ranking against cookies
/// not read since is preserved: a cookie a page keeps reading through the
/// cache is never the eviction victim. What changes is only the order among
/// entries read at different moments since the last change: all of them are
/// stamped alike at the flush. On a small watch jar (60 cookies) that is the
/// difference between two cookies the page both read since the last write.
nonisolated public final class JeffJSMemoryCookieJar: JeffJSCookieJar, @unchecked Sendable {

    public let site: String?
    public let maxCookies: Int
    private let clock: @Sendable () -> Date
    private let onChange: (@Sendable (_ persistentChanged: Bool) -> Void)?
    private let lock = NSLock()
    private var cookies: [JeffJSCookie] = []
    /// Changes whenever `cookies` does (see the class comment). Read under the lock.
    private var generation: UInt64 = 0
    private var matchCache: [MatchKey: MatchEntry] = [:]
    /// Entries kept before the cache is dropped whole (a page talks to a
    /// handful of hosts; the cap is only against a runaway of unique URLs).
    private static let matchCacheLimit = 256

    private struct MatchKey: Hashable {
        let url: URL
        let http: Bool
        let sameSite: Bool
    }

    private final class MatchEntry {
        let generation: UInt64
        /// The earliest expiry in the whole jar when the entry was built:
        /// from then on an expired cookie could exist and the scan must run.
        let validUntil: Double
        let value: String
        /// Positions in `cookies` of the matched cookies, valid while
        /// `generation` is the jar's (serialization order, not store order).
        let indices: [Int]
        /// Read through the cache since the last `flushTouchesLocked`.
        var touched = false
        init(generation: UInt64, validUntil: Double, value: String, indices: [Int]) {
            self.generation = generation; self.validUntil = validUntil; self.value = value; self.indices = indices
        }
    }

    /// The number of times the jar's cookies changed. A host can compare two
    /// readings to know whether a `cookieHeader`/`documentCookie` result it
    /// holds may have changed (not counting expiry).
    public var changeCount: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return generation
    }

    /// - Parameters:
    ///   - maxCookies: the jar's cap; past it expired cookies go first, then
    ///     the least recently used ones.
    ///   - onChange: called (outside the lock) after a store/delete changed the
    ///     jar; `persistentChanged` is true when a non-session cookie changed.
    public init(site: String? = nil, maxCookies: Int = 300,
                clock: @escaping @Sendable () -> Date = { Date() },
                onChange: (@Sendable (_ persistentChanged: Bool) -> Void)? = nil) {
        self.site = site
        self.maxCookies = max(1, maxCookies)
        self.clock = clock
        self.onChange = onChange
    }

    /// Restores the persistent cookies written by `persistentData(maxBytes:)`.
    public convenience init(site: String?, persistentData: Data?, maxCookies: Int = 300,
                            clock: @escaping @Sendable () -> Date = { Date() },
                            onChange: (@Sendable (_ persistentChanged: Bool) -> Void)? = nil) {
        self.init(site: site, maxCookies: maxCookies, clock: clock, onChange: onChange)
        if let persistentData, let list = try? JSONDecoder().decode([JeffJSCookie].self, from: persistentData) {
            let now = clock().timeIntervalSince1970
            cookies = Array(list.filter { ($0.expires ?? .infinity) > now }.prefix(self.maxCookies))
            generation &+= 1
        }
    }

    // MARK: Protocol

    public func cookieHeader(for url: URL, sameSite: Bool) -> String? {
        let t0 = JeffJSCookieStats.enabled ? JeffJSCookieStats.now() : 0
        let s = matching(url, http: true, sameSite: sameSite)
        let result: String? = s.isEmpty ? nil : s   // a stored cookie never serializes to ""
        if JeffJSCookieStats.enabled { JeffJSCookieStats.record("jar.cookieHeader", start: t0, length: result?.utf8.count ?? 0, jarCount: countLocked()) }
        return result
    }

    public func store(setCookieLines: [String], for url: URL) {
        let t0 = JeffJSCookieStats.enabled ? JeffJSCookieStats.now() : 0
        defer { if JeffJSCookieStats.enabled { JeffJSCookieStats.record("jar.store", start: t0, length: setCookieLines.count, jarCount: countLocked()) } }
        var persistentChanged = false, changed = false
        lock.lock()
        let now = clock().timeIntervalSince1970
        flushTouchesLocked(now: now)
        for line in setCookieLines {
            guard let c = JeffJSCookieParsing.parse(line, url: url, fromScript: false, now: now) else { continue }
            let r = insertLocked(c, url: url, fromScript: false, now: now)
            changed = changed || r.changed
            persistentChanged = persistentChanged || r.persistent
        }
        lock.unlock()
        if changed { onChange?(persistentChanged) }
    }

    public func documentCookie(for url: URL) -> String {
        let t0 = JeffJSCookieStats.enabled ? JeffJSCookieStats.now() : 0
        let result = matching(url, http: false, sameSite: true)
        if JeffJSCookieStats.enabled { JeffJSCookieStats.record("jar.documentCookie", start: t0, length: result.utf8.count, jarCount: countLocked()) }
        return result
    }

    public func setDocumentCookie(_ cookieString: String, for url: URL) {
        let t0 = JeffJSCookieStats.enabled ? JeffJSCookieStats.now() : 0
        defer { if JeffJSCookieStats.enabled { JeffJSCookieStats.record("jar.setDocCookie", start: t0, length: cookieString.utf8.count, jarCount: countLocked()) } }
        lock.lock()
        let now = clock().timeIntervalSince1970
        flushTouchesLocked(now: now)
        var result = (changed: false, persistent: false)
        if let c = JeffJSCookieParsing.parse(cookieString, url: url, fromScript: true, now: now) {
            result = insertLocked(c, url: url, fromScript: true, now: now)
        }
        lock.unlock()
        if result.changed { onChange?(result.persistent) }
    }

    // MARK: Inspection / persistence

    /// Every live cookie (expired ones purged).
    public var allCookies: [JeffJSCookie] {
        lock.lock(); defer { lock.unlock() }
        let now = clock().timeIntervalSince1970
        flushTouchesLocked(now: now)
        purgeExpiredLocked(now: now)
        return cookies
    }

    public func removeAll() {
        lock.lock()
        let had = !cookies.isEmpty
        cookies.removeAll()
        matchCache.removeAll()
        generation &+= 1
        lock.unlock()
        if had { onChange?(true) }
    }

    /// The persistent (non-session, unexpired) cookies as compact JSON, most
    /// recently used first, trimmed to `maxBytes`. Nil when there are none.
    public func persistentData(maxBytes: Int = .max) -> Data? {
        lock.lock()
        let now = clock().timeIntervalSince1970
        flushTouchesLocked(now: now)
        purgeExpiredLocked(now: now)
        var list = cookies.filter { !$0.isSession }
        lock.unlock()
        guard !list.isEmpty else { return nil }
        list.sort { $0.lastAccess > $1.lastAccess }
        let encoder = JSONEncoder()
        while !list.isEmpty {
            guard let data = try? encoder.encode(list) else { return nil }
            if data.count <= maxBytes { return data }
            list.removeLast(max(1, list.count / 8))
        }
        return nil
    }

    // MARK: Internals

    /// The serialized cookies for a request/document at `url` ("" when none),
    /// through the match cache (class comment).
    private func matching(_ url: URL, http: Bool, sameSite: Bool) -> String {
        let key = MatchKey(url: url, http: http, sameSite: sameSite)
        lock.lock(); defer { lock.unlock() }
        let now = clock().timeIntervalSince1970
        if let e = matchCache[key], e.generation == generation, now < e.validUntil {
            e.touched = true
            return e.value
        }
        guard let host = JeffJSCookieParsing.cookieHost(of: url) else { return "" }
        let path = JeffJSCookieParsing.requestPath(of: url)
        let secure = JeffJSCookieParsing.isSecure(url)
        purgeExpiredLocked(now: now)
        var out: [(cookie: JeffJSCookie, order: Int)] = []
        for i in cookies.indices {
            let c = cookies[i]
            if c.hostOnly ? (c.domain != host) : !JeffJSCookieParsing.domainMatches(host, c.domain) { continue }
            if !JeffJSCookieParsing.pathMatches(path, c.path) { continue }
            if c.secure && !secure { continue }
            if c.httpOnly && !http { continue }
            if !sameSite && (c.sameSite == .strict || c.sameSite == .lax) { continue }
            cookies[i].lastAccess = now
            out.append((c, i))
        }
        // §5.8.3 step 2: longer paths first, then earlier creation (then store order).
        out.sort { a, b in
            if a.cookie.path.count != b.cookie.path.count { return a.cookie.path.count > b.cookie.path.count }
            if a.cookie.created != b.cookie.created { return a.cookie.created < b.cookie.created }
            return a.order < b.order
        }
        let value = Self.serialize(out.map(\.cookie))
        if matchCache.count >= Self.matchCacheLimit { matchCache.removeAll(keepingCapacity: true) }
        matchCache[key] = MatchEntry(generation: generation, validUntil: earliestExpiryLocked(),
                                     value: value, indices: out.map(\.order))
        return value
    }

    private static func serialize(_ list: [JeffJSCookie]) -> String {
        list.map { $0.name.isEmpty ? $0.value : "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    private func countLocked() -> Int {
        lock.lock(); defer { lock.unlock() }
        return cookies.count
    }

    private func earliestExpiryLocked() -> Double {
        var t = Double.infinity
        for c in cookies { if let e = c.expires, e < t { t = e } }
        return t
    }

    /// Stamps `lastAccess = now` on the cookies of every entry read through the
    /// cache since the last flush (class comment). Must run before anything
    /// moves or removes a cookie: the entries' indices are positions.
    private func flushTouchesLocked(now: Double) {
        for e in matchCache.values where e.touched {
            e.touched = false
            guard e.generation == generation else { continue }
            for i in e.indices { cookies[i].lastAccess = now }
        }
    }

    private func purgeExpiredLocked(now: Double) {
        if cookies.contains(where: { ($0.expires ?? .infinity) <= now }) {
            flushTouchesLocked(now: now)
            cookies.removeAll { ($0.expires ?? .infinity) <= now }
            generation &+= 1
        }
    }

    /// RFC 6265bis §5.7 steps 15–24 for a parsed cookie.
    private func insertLocked(_ new: JeffJSCookie, url: URL, fromScript: Bool,
                              now: Double) -> (changed: Bool, persistent: Bool) {
        var cookie = new
        // Step 15: an insecure origin cannot overwrite/shadow a Secure cookie.
        if !cookie.secure && !JeffJSCookieParsing.isSecure(url) {
            let shadows = cookies.contains { old in
                old.secure && old.name == cookie.name
                    && (JeffJSCookieParsing.domainMatches(cookie.domain, old.domain)
                        || JeffJSCookieParsing.domainMatches(old.domain, cookie.domain))
                    && JeffJSCookieParsing.pathMatches(cookie.path, old.path)
            }
            if shadows { return (false, false) }
        }
        var removedPersistent = false
        if let idx = cookies.firstIndex(where: { $0.sameIdentity(cookie) }) {
            let old = cookies[idx]
            if fromScript && old.httpOnly { return (false, false) }   // step 23.2
            cookie.created = old.created                              // step 23.3
            cookies.remove(at: idx)
            generation &+= 1
            removedPersistent = !old.isSession
        }
        if let exp = cookie.expires, exp <= now {
            return (removedPersistent, removedPersistent)             // deletion only
        }
        cookies.append(cookie)
        generation &+= 1
        if cookies.count > maxCookies {
            purgeExpiredLocked(now: now)
            while cookies.count > maxCookies {
                // Evict the least recently used cookie other than the new one.
                var victim = 0
                for i in cookies.indices.dropLast() where cookies[i].lastAccess < cookies[victim].lastAccess { victim = i }
                cookies.remove(at: victim)
                generation &+= 1
            }
        }
        return (true, removedPersistent || !cookie.isSession)
    }
}

// MARK: - document.cookie

/// Installs `document.cookie` over a cookie jar, for the document at
/// `documentURL()`: a native accessor on `Document.prototype` (WebIDL §3.7.6 —
/// `Object.getOwnPropertyDescriptor(Document.prototype, 'cookie').get` is what
/// Akamai's sensor calls; akamai navigation fix, 2026-09-29), or on the document
/// object when no `Document.prototype` is in its chain. Only the page document
/// reads/writes the jar; any other document gets "" (a cookie-averse document,
/// HTML §3.1.3); a non-object `this` throws. Register after the DOM bridge (the
/// document object must exist); a host polyfill guarded by
/// `typeof document.cookie !== 'string'` then leaves it alone.
@MainActor
final class JeffJSCookieBridge {
    nonisolated static let debug = ProcessInfo.processInfo.environment["JEFFJS_COOKIE_DEBUG"] == "1"
    let jar: any JeffJSCookieJar
    var documentURL: () -> URL?
    /// The last `document.cookie` string handed to the page, as the engine
    /// string (one reference held here): a repeated read returns a dup of it
    /// instead of allocating a fresh string (the jar's own cache hands back
    /// the same Swift storage, so the `==` is a pointer test). Freed by
    /// `teardown()` before the context goes; never touched after that (the
    /// runtime's teardown frees whatever the page still held, this included),
    /// so there is no free in `deinit`.
    private var cachedCookie: (string: String, value: JeffJSValue)?

    init(jar: any JeffJSCookieJar, documentURL: @escaping () -> URL?) {
        self.jar = jar
        self.documentURL = documentURL
    }

    /// Gives back the engine string held by the getter cache. Call before the
    /// context is freed (`JeffJSEnvironment.teardown`); safe to call twice.
    func teardown() {
        cachedCookie?.value.freeValue()
        cachedCookie = nil
    }

    func register(on ctx: JeffJSContext) {
        let global = ctx.getGlobalObject()
        defer { global.freeValue() }
        let doc = ctx.getPropertyStr(obj: global, name: "document")
        defer { doc.freeValue() }
        guard doc.isObject else { return }
        weak var pageDocument = doc.toObject()
        let getter = ctx.newCFunction({ [weak self] ctx, thisVal, _ in
            guard thisVal.isObject else {
                return ctx.throwTypeError(message: "The Document.cookie getter can only be used on instances of Document")
            }
            guard thisVal.toObject() === pageDocument else { return ctx.newStringValue("") }
            guard let self, let url = self.documentURL() else { return ctx.newStringValue("") }
            let t0 = JeffJSCookieStats.enabled ? JeffJSCookieStats.now() : 0
            let s = self.jar.documentCookie(for: url)
            let v: JeffJSValue
            if let c = self.cachedCookie, c.string == s {
                v = c.value.dupValue()
            } else {
                v = ctx.newStringValue(s)
                self.cachedCookie?.value.freeValue()
                self.cachedCookie = (s, v.dupValue())
            }
            if JeffJSCookieStats.enabled { JeffJSCookieStats.record("js.get", start: t0, length: s.utf8.count, jarCount: 0) }
            return v
        }, name: "get cookie", length: 0)
        let setter = ctx.newCFunction({ [weak self] ctx, thisVal, args in
            guard thisVal.isObject else {
                return ctx.throwTypeError(message: "The Document.cookie setter can only be used on instances of Document")
            }
            guard thisVal.toObject() === pageDocument else { return JeffJSValue.undefined }
            guard let self, let url = self.documentURL() else { return JeffJSValue.undefined }
            let s = ctx.toSwiftString(args.first ?? .undefined) ?? ""
            let t0 = JeffJSCookieStats.enabled ? JeffJSCookieStats.now() : 0
            let before = JeffJSCookieBridge.debug ? self.jar.documentCookie(for: url).utf8.count : 0
            self.jar.setDocumentCookie(s, for: url)
            if JeffJSCookieStats.enabled { JeffJSCookieStats.record("js.set", start: t0, length: s.utf8.count, jarCount: 0) }
            if JeffJSCookieBridge.debug {
                // JEFFJS_COOKIE_DEBUG=1: what a page's write did (Google's
                // challenge only writes when document.cookie.length +
                // the new cookie stays under 4093, then reads it back).
                let name = s.split(separator: "=", maxSplits: 1).first.map(String.init) ?? ""
                let after = self.jar.documentCookie(for: url)
                let visible = after.split(separator: ";").contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix(name + "=") }
                print("[DocCookie] set \(name) len=\(s.utf8.count) url=\(url.absoluteString.prefix(80)) before=\(before) after=\(after.utf8.count) visible=\(visible)")
            }
            return JeffJSValue.undefined
        }, name: "set cookie", length: 1)
        // Document.prototype when it is on the document's chain (the DOM bridge's
        // `installDocumentInterfaces`), else the instance.
        var target = doc
        let ctor = ctx.getPropertyStr(obj: global, name: "Document")
        let proto = ctor.isObject ? ctx.getPropertyStr(obj: ctor, name: "prototype") : JeffJSValue.undefined
        ctor.freeValue()
        defer { proto.freeValue() }
        if proto.isObject, let p = proto.toObject() {
            var o = doc.toObject()?.proto
            while let cur = o, cur !== p { o = cur.proto }
            if o != nil { target = proto }
        }
        ctx.setPropertyGetSet(obj: target, name: "cookie", getter: getter, setter: setter)
    }
}
