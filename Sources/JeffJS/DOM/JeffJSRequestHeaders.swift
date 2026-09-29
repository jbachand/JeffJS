// JeffJSRequestHeaders.swift
// JeffJS — the request headers a browser computes for every fetch (nonisolated:
// hosts call it from any thread; React Natively compiles the engine with
// MainActor default isolation):
// `Referer` (W3C Referrer Policy + Fetch §4.1 "main fetch" step "determine
// request's referrer") and the Fetch Metadata request headers `Sec-Fetch-Site`,
// `Sec-Fetch-Mode`, `Sec-Fetch-Dest` (+ `Sec-Fetch-User` when a caller asks for
// it on a user-activated navigation).
//
// Pure functions of (client document URL, target URL, mode, destination,
// request referrer, referrer policies, redirect chain). The fetch bridge calls
// `apply(to:…)` for `fetch()` / XHR; a host (React Natively's renderer) calls the
// same function for document / script / style / image / font loads, so the rules
// exist once.
//
//   * Referrer Policy §8.3: the referrer is stripped of credentials and fragment
//     (§8.4), only http(s) referrers are sent (WebKit's rule: a `file:` / `data:` /
//     `about:` document sends none), a URL longer than 4096 bytes is cut to its
//     origin, and the policy (`""` = the default `strict-origin-when-cross-origin`)
//     decides between the full URL, the origin (`https://host[:port]/`) and none.
//     WebKit then trims a cross-site referrer to its origin whatever the policy
//     (ITP, Safari 13.1+; checked against WKWebView: `unsafe-url` to another site
//     sends `https://host/`) — `trimCrossSiteReferrer`, on by default.
//   * Fetch Metadata §2 / §5.1: only sent to a potentially trustworthy URL
//     (https/wss, `localhost` / `*.localhost`, 127.0.0.0/8, ::1). Site compares
//     the request's origin with every URL of the redirect chain: same origin →
//     `same-origin`, same schemeful site (registrable domain) → `same-site`,
//     else `cross-site`; a navigation the user started (or a request with no
//     client) is `none`.
import Foundation

// MARK: - Referrer policy

nonisolated public enum JeffJSReferrerPolicy: String, Sendable, CaseIterable {
    case empty = ""
    case noReferrer = "no-referrer"
    case noReferrerWhenDowngrade = "no-referrer-when-downgrade"
    case sameOrigin = "same-origin"
    case origin = "origin"
    case strictOrigin = "strict-origin"
    case originWhenCrossOrigin = "origin-when-cross-origin"
    case strictOriginWhenCrossOrigin = "strict-origin-when-cross-origin"
    case unsafeURL = "unsafe-url"

    /// Referrer Policy §3 "default referrer policy" (HTML: strict-origin-when-cross-origin).
    public static let defaultPolicy: JeffJSReferrerPolicy = .strictOriginWhenCrossOrigin

    /// A policy token (`referrerpolicy` attribute, fetch's `referrerPolicy`),
    /// ASCII case-insensitive. Unknown tokens give nil (the attribute's
    /// invalid-value default is the empty state: callers use `?? .empty`).
    public init?(token: String?) {
        guard let t = token?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return nil }
        self.init(rawValue: t)
    }

    /// Referrer Policy §8.1 "parse a referrer policy from a Referrer-Policy
    /// header": comma-separated tokens, the last recognised non-empty one wins.
    public static func fromHeader(_ value: String?) -> JeffJSReferrerPolicy? {
        guard let value else { return nil }
        var policy: JeffJSReferrerPolicy?
        for part in value.split(separator: ",") {
            if let p = JeffJSReferrerPolicy(token: String(part)), p != .empty { policy = p }
        }
        return policy
    }

    /// HTML §4.2.5.3 `<meta name="referrer" content>`: ASCII-lowercased, the
    /// legacy keywords mapped (`never` → no-referrer, `default` → the default
    /// policy, `always` → unsafe-url, `origin-when-crossorigin` →
    /// origin-when-cross-origin); an empty or unknown value is ignored (nil).
    public static func fromMetaContent(_ content: String?) -> JeffJSReferrerPolicy? {
        guard let v = content?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !v.isEmpty else { return nil }
        switch v {
        case "never": return .noReferrer
        case "default": return defaultPolicy
        case "always": return .unsafeURL
        case "origin-when-crossorigin": return .originWhenCrossOrigin
        default:
            let p = JeffJSReferrerPolicy(rawValue: v)
            return p == .empty ? nil : p
        }
    }

    /// The policy actually applied: the request's own, else the document's,
    /// else the default (Fetch "main fetch" step 8 + Referrer Policy §8.3 step 1).
    public static func effective(request: JeffJSReferrerPolicy,
                                 document: JeffJSReferrerPolicy) -> JeffJSReferrerPolicy {
        if request != .empty { return request }
        if document != .empty { return document }
        return defaultPolicy
    }
}

/// A request's referrer (Fetch §2.2.5): the client's document (`about:client`,
/// the default), none (`referrer: ""`), or an explicit same-origin URL.
nonisolated public enum JeffJSRequestReferrer: Equatable, Sendable {
    case client
    case noReferrer
    case url(URL)

    /// Fetch's `Request` constructor step for `init.referrer`: `""` → no
    /// referrer; a URL parsed against `baseURL`; `about:client`, a parse
    /// failure's fallback, or a URL that is not same-origin with the client →
    /// client. nil (option absent) → client.
    public static func fromInit(_ value: String?, baseURL: URL?, clientURL: URL?) -> JeffJSRequestReferrer {
        guard let value else { return .client }
        if value.isEmpty { return .noReferrer }
        let parsed: URL? = {
            if let abs = URL(string: value), abs.scheme != nil { return abs }
            if let baseURL, let rel = URL(string: value, relativeTo: baseURL) { return rel.absoluteURL }
            return nil
        }()
        guard let parsed else { return .client }
        if parsed.absoluteString == "about:client" { return .client }
        if let clientURL, JeffJSRequestHeaders.sameOrigin(parsed, clientURL) { return .url(parsed) }
        return .client
    }
}

// MARK: - Header computation

nonisolated public enum JeffJSRequestHeaders {

    /// The headers this module owns (removed from a request before the
    /// computed ones are set: `Referer` and `Sec-*` are forbidden request
    /// headers, a page cannot set them).
    public static let ownedHeaderNames = ["Referer", "Sec-Fetch-Site", "Sec-Fetch-Mode", "Sec-Fetch-Dest", "Sec-Fetch-User"]

    /// The browser-computed headers for one request.
    ///
    /// - Parameters:
    ///   - documentURL: the request's client (the document whose script or
    ///     parser started it): the default referrer and the request's origin.
    ///     nil = no client (a navigation the user typed).
    ///   - target: the URL being requested (the current URL of the redirect chain).
    ///   - mode: `navigate` / `cors` / `no-cors` / `same-origin` / `websocket`.
    ///   - destination: `document` / `script` / `style` / `image` / `font` /
    ///     `iframe` / … ; `""` (fetch/XHR) is sent as `empty`.
    ///   - referrer: the request's referrer (`.client` = `documentURL`).
    ///   - policy: the request's referrer policy (`.empty` = the document's).
    ///   - documentPolicy: the client's referrer policy (`.empty` = default).
    ///   - previousURLs: earlier URLs of a redirect chain (Site is the worst over all).
    ///   - userNavigation: a navigation the user started (Site `none`).
    ///   - sendUserHeader: also send `Sec-Fetch-User: ?1` on such a navigation.
    ///   - trimCrossSiteReferrer: WebKit's cap of a cross-site `Referer` at the origin.
    public static func headers(documentURL: URL?,
                               target: URL,
                               mode: String,
                               destination: String,
                               referrer: JeffJSRequestReferrer = .client,
                               policy: JeffJSReferrerPolicy = .empty,
                               documentPolicy: JeffJSReferrerPolicy = .empty,
                               previousURLs: [URL] = [],
                               userNavigation: Bool = false,
                               sendUserHeader: Bool = false,
                               trimCrossSiteReferrer: Bool = true) -> [String: String] {
        var out: [String: String] = [:]
        let effectivePolicy = JeffJSReferrerPolicy.effective(request: policy, document: documentPolicy)
        let source: URL? = {
            switch referrer {
            case .client: return userNavigation ? nil : documentURL
            case .noReferrer: return nil
            case .url(let u): return u
            }
        }()
        if let source, var value = referrerValue(source: source, target: target, policy: effectivePolicy) {
            if trimCrossSiteReferrer, !sameSite(source, target),
               let originOnly = strippedReferrer(source, originOnly: true) {
                value = originOnly
            }
            out["Referer"] = value
        }
        if isPotentiallyTrustworthy(target) {
            out["Sec-Fetch-Dest"] = destination.isEmpty ? "empty" : destination
            out["Sec-Fetch-Mode"] = mode.isEmpty ? "cors" : mode
            if userNavigation || documentURL == nil {
                out["Sec-Fetch-Site"] = "none"
            } else {
                out["Sec-Fetch-Site"] = fetchSite(initiator: documentURL!, urls: previousURLs + [target])
            }
            if userNavigation && sendUserHeader && mode == "navigate" { out["Sec-Fetch-User"] = "?1" }
        }
        return out
    }

    /// Replaces the owned headers of `request` with `headers(…)` for its URL.
    public static func apply(to request: inout URLRequest,
                             documentURL: URL?,
                             mode: String,
                             destination: String,
                             referrer: JeffJSRequestReferrer = .client,
                             policy: JeffJSReferrerPolicy = .empty,
                             documentPolicy: JeffJSReferrerPolicy = .empty,
                             previousURLs: [URL] = [],
                             userNavigation: Bool = false,
                             sendUserHeader: Bool = false,
                             trimCrossSiteReferrer: Bool = true) {
        guard let target = request.url else { return }
        for name in ownedHeaderNames { request.setValue(nil, forHTTPHeaderField: name) }
        let computed = headers(documentURL: documentURL, target: target, mode: mode, destination: destination,
                               referrer: referrer, policy: policy, documentPolicy: documentPolicy,
                               previousURLs: previousURLs, userNavigation: userNavigation,
                               sendUserHeader: sendUserHeader, trimCrossSiteReferrer: trimCrossSiteReferrer)
        for (name, value) in computed { request.setValue(value, forHTTPHeaderField: name) }
    }

    // MARK: Referrer Policy §8.3

    /// The `Referer` value for `source` → `target` under `policy`
    /// (`.empty` = the default policy), or nil for no header.
    public static func referrerValue(source: URL, target: URL, policy: JeffJSReferrerPolicy) -> String? {
        guard let full = strippedReferrer(source, originOnly: false),
              let originOnly = strippedReferrer(source, originOnly: true) else { return nil }
        // §8.3 step 6: a referrer URL longer than 4096 bytes becomes its origin.
        let url = full.utf8.count > 4096 ? originOnly : full
        let downgrade = isPotentiallyTrustworthy(source) && !isPotentiallyTrustworthy(target)
        let same = sameOrigin(source, target)
        switch policy == .empty ? JeffJSReferrerPolicy.defaultPolicy : policy {
        case .noReferrer: return nil
        case .origin: return originOnly
        case .unsafeURL: return url
        case .strictOrigin: return downgrade ? nil : originOnly
        case .strictOriginWhenCrossOrigin, .empty:
            if same { return url }
            return downgrade ? nil : originOnly
        case .sameOrigin: return same ? url : nil
        case .originWhenCrossOrigin: return same ? url : originOnly
        case .noReferrerWhenDowngrade: return downgrade ? nil : url
        }
    }

    /// Referrer Policy §8.4 "strip url for use as a referrer": no credentials,
    /// no fragment; `originOnly` also drops path and query (path becomes "/").
    /// Only http(s) URLs are referrers (WebKit `SecurityPolicy::generateReferrerHeader`).
    public static func strippedReferrer(_ url: URL, originOnly: Bool) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var c = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let host = c.host, !host.isEmpty else { return nil }
        c.scheme = scheme
        c.user = nil
        c.password = nil
        c.fragment = nil
        c.host = host.lowercased()
        if c.port == defaultPort(scheme) { c.port = nil }
        if originOnly {
            c.percentEncodedPath = "/"
            c.percentEncodedQuery = nil
        } else if c.percentEncodedPath.isEmpty {
            c.percentEncodedPath = "/"
        }
        return c.string
    }

    // MARK: Origins and sites

    /// A tuple origin (scheme, host, port), or nil for an opaque origin
    /// (`file:`, `data:`, `about:`, `blob:` without an inner http(s) URL).
    public nonisolated struct Origin: Equatable, Sendable {
        public let scheme: String
        public let host: String
        public let port: Int
    }

    public static func origin(of url: URL) -> Origin? {
        guard let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "blob", let inner = URL(string: String(url.absoluteString.dropFirst(5))) {
            return origin(of: inner)
        }
        guard ["http", "https", "ws", "wss"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return Origin(scheme: scheme, host: host, port: url.port ?? defaultPort(scheme) ?? 0)
    }

    /// The ASCII serialization of `url`'s origin (`https://host[:port]`, the
    /// `Origin` header's value), or nil for an opaque origin.
    public static func serializedOrigin(_ url: URL) -> String? {
        guard let o = origin(of: url) else { return nil }
        let host = o.host.contains(":") ? "[\(o.host)]" : o.host
        return o.port == defaultPort(o.scheme) ? "\(o.scheme)://\(host)" : "\(o.scheme)://\(host):\(o.port)"
    }

    public static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        guard let oa = origin(of: a), let ob = origin(of: b) else { return false }
        return oa == ob
    }

    /// HTML "same site" (schemeful): same scheme and the same registrable
    /// domain (or the same host when a host has none: IPs, `localhost`, a
    /// public suffix itself).
    public static func sameSite(_ a: URL, _ b: URL) -> Bool {
        guard let oa = origin(of: a), let ob = origin(of: b) else { return false }
        guard oa.scheme == ob.scheme else { return false }
        if oa.host == ob.host { return true }
        guard let ra = registrableDomain(oa.host), let rb = registrableDomain(ob.host) else { return false }
        return ra == rb
    }

    /// Fetch Metadata §5.1 `Sec-Fetch-Site` over a redirect chain.
    public static func fetchSite(initiator: URL, urls: [URL]) -> String {
        var value = "same-origin"
        for url in urls {
            if sameOrigin(initiator, url) { continue }
            value = "same-site"
            if !sameSite(initiator, url) { return "cross-site" }
        }
        return value
    }

    /// Secure Contexts §3.1/§3.2 "potentially trustworthy URL": `about:blank`,
    /// `about:srcdoc`, `data:`, and URLs whose origin is https/wss, a loopback
    /// IP, `localhost` / `*.localhost`, or `file:`.
    public static func isPotentiallyTrustworthy(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        switch scheme {
        case "https", "wss", "file", "data": return true
        case "about":
            let s = url.absoluteString.lowercased()
            return s == "about:blank" || s == "about:srcdoc"
        case "http", "ws":
            guard var host = url.host?.lowercased() else { return false }
            if host.hasSuffix(".") { host.removeLast() }
            if host == "localhost" || host.hasSuffix(".localhost") { return true }
            if host == "::1" || host == "[::1]" { return true }
            let parts = host.split(separator: ".")
            if parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }), parts[0] == "127" { return true }
            return false
        default:
            return false
        }
    }

    private static func defaultPort(_ scheme: String) -> Int? {
        switch scheme {
        case "http", "ws": return 80
        case "https", "wss": return 443
        default: return nil
        }
    }

    // MARK: Registrable domain

    /// The registrable domain (eTLD+1) of `host`, or nil when it has none (an
    /// IP address, a single label, or a public suffix itself). The public
    /// suffix is the longest match in `multiLabelSuffixes`, else the last
    /// label: an abridged Public Suffix List (the multi-label ICANN suffixes
    /// real sites use plus the common private hosting suffixes), not the full
    /// ~10 000-rule list.
    public static func registrableDomain(_ host: String) -> String? {
        var h = host.lowercased()
        if h.hasSuffix(".") { h.removeLast() }
        if h.contains(":") { return nil }   // IPv6
        let labels = h.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard labels.count >= 2, !labels.contains(where: { $0.isEmpty }) else { return nil }
        if labels.allSatisfy({ UInt8($0) != nil }) { return nil }   // IPv4
        var suffixLabels = 1
        let maxCheck = min(4, labels.count)
        if maxCheck >= 2 {
            for n in stride(from: maxCheck, through: 2, by: -1) {
                let candidate = labels.suffix(n).joined(separator: ".")
                if multiLabelSuffixes.contains(candidate) { suffixLabels = n; break }
            }
        }
        guard labels.count > suffixLabels else { return nil }
        return labels.suffix(suffixLabels + 1).joined(separator: ".")
    }

    /// Multi-label public suffixes (Public Suffix List, abridged).
    static let multiLabelSuffixes: Set<String> = [
        // United Kingdom
        "co.uk", "org.uk", "me.uk", "ltd.uk", "plc.uk", "net.uk", "sch.uk", "ac.uk", "gov.uk", "nhs.uk", "police.uk",
        // Australia / New Zealand
        "com.au", "net.au", "org.au", "edu.au", "gov.au", "asn.au", "id.au",
        "co.nz", "net.nz", "org.nz", "govt.nz", "ac.nz", "geek.nz", "school.nz",
        // Asia
        "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp", "ed.jp", "gr.jp", "lg.jp",
        "co.kr", "ne.kr", "or.kr", "go.kr", "ac.kr", "re.kr",
        "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn", "ac.cn",
        "com.hk", "net.hk", "org.hk", "gov.hk", "edu.hk", "idv.hk",
        "com.tw", "net.tw", "org.tw", "gov.tw", "edu.tw", "idv.tw",
        "com.sg", "net.sg", "org.sg", "gov.sg", "edu.sg",
        "com.my", "net.my", "org.my", "gov.my", "edu.my",
        "co.in", "net.in", "org.in", "firm.in", "gen.in", "ind.in", "ac.in", "gov.in", "edu.in",
        "co.id", "or.id", "ac.id", "go.id", "web.id",
        "co.th", "in.th", "ac.th", "go.th", "or.th",
        "com.ph", "net.ph", "org.ph", "gov.ph", "edu.ph",
        "com.vn", "net.vn", "org.vn", "gov.vn", "edu.vn",
        "com.pk", "net.pk", "org.pk", "gov.pk", "edu.pk",
        "co.il", "org.il", "net.il", "ac.il", "gov.il",
        "com.tr", "net.tr", "org.tr", "gov.tr", "edu.tr",
        "com.sa", "net.sa", "org.sa", "gov.sa", "edu.sa",
        "co.ae", "net.ae", "org.ae", "gov.ae",
        // Americas
        "com.br", "net.br", "org.br", "gov.br", "edu.br", "art.br", "blog.br",
        "com.mx", "net.mx", "org.mx", "gob.mx", "edu.mx",
        "com.ar", "net.ar", "org.ar", "gob.ar", "gov.ar", "edu.ar",
        "com.co", "net.co", "org.co", "gov.co", "edu.co",
        "com.pe", "net.pe", "org.pe", "gob.pe", "edu.pe",
        "com.ve", "co.ve", "com.ec", "com.uy", "com.py", "com.bo",
        "qc.ca", "on.ca", "bc.ca", "ab.ca",
        // Europe / Africa
        "co.at", "or.at", "ac.at", "gv.at",
        "com.pl", "net.pl", "org.pl", "gov.pl", "edu.pl",
        "com.es", "nom.es", "org.es", "gob.es", "edu.es",
        "com.pt", "org.pt", "gov.pt", "edu.pt",
        "com.gr", "net.gr", "org.gr", "gov.gr", "edu.gr",
        "com.ua", "net.ua", "org.ua", "gov.ua", "in.ua",
        "com.ru", "net.ru", "org.ru", "msk.ru", "spb.ru",
        "co.za", "org.za", "net.za", "gov.za", "ac.za", "web.za",
        "com.ng", "org.ng", "gov.ng", "edu.ng",
        "co.ke", "or.ke", "ac.ke", "go.ke",
        "com.eg", "org.eg", "gov.eg", "edu.eg",
        // Private suffixes (PSL "PRIVATE DOMAINS" section, the common hosts)
        "github.io", "githubusercontent.com", "gitlab.io", "herokuapp.com",
        "appspot.com", "blogspot.com", "firebaseapp.com", "web.app", "page.link",
        "cloudfront.net", "s3.amazonaws.com", "elasticbeanstalk.com",
        "azurewebsites.net", "cloudapp.net", "azureedge.net", "azurestaticapps.net", "trafficmanager.net",
        "netlify.app", "vercel.app", "now.sh", "pages.dev", "workers.dev",
        "fly.dev", "onrender.com", "glitch.me", "repl.co", "surge.sh",
        "global.ssl.fastly.net", "myshopify.com", "wixsite.com",
        "blogspot.co.uk", "readthedocs.io", "ngrok.io", "ngrok-free.app",
        "dyndns.org", "duckdns.org",
    ]
}

// MARK: - fetch() / XHR

extension JeffJSFetchBridge {
    /// `Referer` + `Sec-Fetch-*` for a `fetch()` / XHR request: destination
    /// `empty`, the request's mode, `init.referrer` / `init.referrerPolicy`
    /// over the document's (`referrerPolicy`, `documentURL`).
    func applyRequestMetadata(spec: JeffJSFetchSpec, to request: inout URLRequest) {
        guard sendsRequestMetadata else { return }
        let client = documentURL ?? baseURL
        let referrer = JeffJSRequestReferrer.fromInit(spec.referrer, baseURL: baseURL, clientURL: client)
        JeffJSRequestHeaders.apply(
            to: &request, documentURL: client,
            mode: spec.mode.isEmpty ? "cors" : spec.mode, destination: "",
            referrer: referrer,
            policy: JeffJSReferrerPolicy(token: spec.referrerPolicy) ?? .empty,
            documentPolicy: referrerPolicy)
    }
}
