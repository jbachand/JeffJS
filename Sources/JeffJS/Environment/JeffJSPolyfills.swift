// JeffJSPolyfills.swift
// Essential JavaScript polyfills for the JeffJS environment.
//
// These provide browser-like globals (DOMException, Event, Node constants,
// location, navigator, history, viewport, matchMedia) so that the DOM
// bridges and standard JavaScript code work correctly.
//
// Extracted from JSScriptEngine.swift's polyfill constants.

import Foundation

// MARK: - JeffJSPolyfills

/// Essential polyfills for the JeffJS environment.
/// Static properties contain JavaScript source strings that are evaluated
/// during environment initialization.
public enum JeffJSPolyfills {

    // MARK: - String Escaping

    /// Escapes a Swift string for safe embedding in JS single-quoted strings.
    public static func escapeJSString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    // MARK: - Globals Polyfill

    /// DOMException, process.env, global aliases, Event/CustomEvent constructors,
    /// Node type constants, window stubs.
    public static let globalsPolyfill = #"""
(function(){
  if (typeof window.DOMException === 'undefined') {
    window.DOMException = function DOMException(message, name) {
      this.message = message || '';
      this.name = name || 'Error';
      this.code = DOMException._codes[this.name] || 0;
      if (Error.captureStackTrace) Error.captureStackTrace(this, DOMException);
    };
    window.DOMException.prototype = Object.create(Error.prototype);
    window.DOMException.prototype.constructor = window.DOMException;
    window.DOMException._codes = {
      IndexSizeError:1,HierarchyRequestError:3,WrongDocumentError:4,InvalidCharacterError:5,
      NoModificationAllowedError:7,NotFoundError:8,NotSupportedError:9,InUseAttributeError:10,
      InvalidStateError:11,SyntaxError:12,InvalidModificationError:13,NamespaceError:14,
      InvalidAccessError:15,TypeMismatchError:17,SecurityError:18,NetworkError:19,
      AbortError:20,URLMismatchError:21,QuotaExceededError:22,TimeoutError:23,
      InvalidNodeTypeError:24,DataCloneError:25,EncodingError:0,NotReadableError:0,
      UnknownError:0,ConstraintError:0,DataError:0,TransactionInactiveError:0,
      ReadOnlyError:0,VersionError:0,OperationError:0
    };
    var _dc = window.DOMException._codes;
    for (var _dn in _dc) { if (_dc.hasOwnProperty(_dn)) window.DOMException[_dn] = _dc[_dn]; }
  }
  if (typeof process === 'undefined') {
    window.process = { env: { NODE_ENV: 'development' }, version: '', versions: {}, platform: 'browser' };
  }
  try {
    if (typeof self === 'undefined') window.self = window;
    if (typeof globalThis !== 'undefined') {
      globalThis.window = window;
      globalThis.document = document;
      globalThis.self = window;
      globalThis.process = window.process;
      if (typeof globalThis.global === 'undefined') globalThis.global = globalThis;
    }
    if (typeof window.top === 'undefined') window.top = window;
    if (typeof window.parent === 'undefined') window.parent = window;
    if (typeof window.frames === 'undefined') window.frames = window;
  } catch (e) {}
  if (typeof window.Event === 'undefined') {
    window.Event = function Event(type, opts) {
      this.type = type;
      this.bubbles = (opts && opts.bubbles) || false;
      this.cancelable = (opts && opts.cancelable) || false;
      this.composed = (opts && opts.composed) || false;
      this.defaultPrevented = false;
      this.target = null;
      this.currentTarget = null;
      this.eventPhase = 0;
      this.timeStamp = Date.now();
    };
    window.Event.prototype.preventDefault = function() { this.defaultPrevented = true; };
    window.Event.prototype.stopPropagation = function() { this._stopped = true; };
    window.Event.prototype.stopImmediatePropagation = function() { this._stopped = true; this._immediateStopped = true; };
  }
  if (typeof window.CustomEvent === 'undefined') {
    window.CustomEvent = function CustomEvent(type, opts) {
      window.Event.call(this, type, opts);
      this.detail = (opts && opts.detail) !== undefined ? opts.detail : null;
    };
    window.CustomEvent.prototype = Object.create(window.Event.prototype);
    window.CustomEvent.prototype.constructor = window.CustomEvent;
  }
  if (typeof window.Node === 'undefined') {
    window.Node = {};
  }
  window.Node.ELEMENT_NODE = 1;
  window.Node.TEXT_NODE = 3;
  window.Node.COMMENT_NODE = 8;
  window.Node.DOCUMENT_NODE = 9;
  window.Node.DOCUMENT_FRAGMENT_NODE = 11;
  if (typeof window.open === 'undefined') window.open = function() { return null; };
  if (typeof window.close === 'undefined') window.close = function() {};
  if (typeof window.focus === 'undefined') window.focus = function() {};
  if (typeof window.blur === 'undefined') window.blur = function() {};
  if (typeof window.print === 'undefined') window.print = function() {};
  if (typeof window.alert === 'undefined') window.alert = function() {};
  if (typeof window.confirm === 'undefined') window.confirm = function() { return false; };
  if (typeof window.prompt === 'undefined') window.prompt = function() { return null; };
})();
"""#

    // MARK: - Dynamic Polyfills

    /// Location polyfill with URL parsing and __parseURL helper.
    public static func locationPolyfill(for baseURL: URL) -> String {
        let href = escapeJSString(baseURL.absoluteString)
        let origin = escapeJSString(baseURL.scheme.flatMap { scheme in
            baseURL.host.map { host in
                if let port = baseURL.port {
                    return "\(scheme)://\(host):\(port)"
                }
                return "\(scheme)://\(host)"
            }
        } ?? "")
        let host = escapeJSString(baseURL.host ?? "")
        let hostname = host
        let path = escapeJSString(baseURL.path.isEmpty ? "/" : baseURL.path)
        let search = escapeJSString(baseURL.query.map { "?\($0)" } ?? "")
        let hash = escapeJSString(baseURL.fragment.map { "#\($0)" } ?? "")
        let protocolValue = escapeJSString(baseURL.scheme.map { "\($0):" } ?? "")
        return """
        (function() {
          function __parseURL(url, base) {
            var a = { href:'', origin:'', protocol:'', host:'', hostname:'', port:'', pathname:'/', search:'', hash:'' };
            try {
              var s = String(url || '');
              if (s && !/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(s) && base) {
                var bOrigin = base.origin || (base.protocol + '//' + base.host);
                if (s.charAt(0) === '/') { s = bOrigin + s; }
                else {
                  var bPath = base.pathname || '/';
                  s = bOrigin + bPath.substring(0, bPath.lastIndexOf('/') + 1) + s;
                }
              }
              var m = s.match(/^([a-zA-Z][a-zA-Z0-9+.-]*:)\\/\\/([^/?#]*)([^?#]*)(\\?[^#]*)?(#.*)?$/);
              if (m) {
                a.protocol = m[1] || '';
                var hostPort = m[2] || '';
                a.pathname = m[3] || '/';
                a.search = m[4] || '';
                a.hash = m[5] || '';
                var hm = hostPort.match(/^(.+?)(?::(\\d+))?$/);
                a.hostname = hm ? hm[1] : hostPort;
                a.port = hm && hm[2] ? hm[2] : '';
                a.host = a.port ? (a.hostname + ':' + a.port) : a.hostname;
                a.origin = a.protocol + '//' + a.host;
                a.href = a.origin + a.pathname + a.search + a.hash;
              } else {
                a.href = s;
              }
            } catch(e) {}
            if (!a.pathname) a.pathname = '/';
            return a;
          }
          var __parsed = __parseURL('\(href)');
          var __loc = {
            href: __parsed.href || '\(href)',
            origin: __parsed.origin || '\(origin)',
            protocol: __parsed.protocol || '\(protocolValue)',
            host: __parsed.host || '\(host)',
            hostname: __parsed.hostname || '\(hostname)',
            port: __parsed.port || '',
            pathname: __parsed.pathname || '\(path)',
            search: __parsed.search || '\(search)',
            hash: __parsed.hash || '\(hash)',
            assign: function(url) { __loc.__setHref(String(url || __loc.href)); },
            replace: function(url) { __loc.__setHref(String(url || __loc.href)); },
            reload: function() {},
            toString: function() { return __loc.href; },
            __setHref: function(newHref) {
              var p = __parseURL(newHref, __loc);
              __loc.href = p.href;
              __loc.origin = p.origin;
              __loc.protocol = p.protocol;
              __loc.host = p.host;
              __loc.hostname = p.hostname;
              __loc.port = p.port;
              __loc.pathname = p.pathname;
              __loc.search = p.search;
              __loc.hash = p.hash;
              if (typeof __nativeLocationDidChange === 'function') {
                __nativeLocationDidChange(p.href);
              }
            }
          };
          window.__parseURL = __parseURL;
          window.location = __loc;
        })();
        """
    }

    /// Navigator polyfill with userAgent, plugins, mimeTypes.
    public static func navigatorPolyfill(userAgent: String) -> String {
        let escapedUA = escapeJSString(userAgent)
        return """
        (function() {
          if (typeof window.navigator === 'undefined') {
            window.navigator = {};
          }
          if (!window.navigator.userAgent) window.navigator.userAgent = '\(escapedUA)';
          if (!window.navigator.vendor) window.navigator.vendor = 'Apple Computer, Inc.';
          if (!window.navigator.platform) window.navigator.platform = 'MacIntel';
          if (!window.navigator.language) window.navigator.language = 'en-US';
          if (!window.navigator.languages) window.navigator.languages = ['en-US', 'en'];
          if (typeof window.navigator.maxTouchPoints === 'undefined') window.navigator.maxTouchPoints = 5;
          if (!window.navigator.product) window.navigator.product = 'Gecko';
          if (!window.navigator.appName) window.navigator.appName = 'Netscape';
          if (!window.navigator.appVersion) window.navigator.appVersion = '5.0';
          if (typeof window.navigator.plugins === 'undefined' || (Array.isArray(window.navigator.plugins) && window.navigator.plugins.length === 0)) {
            var __pdfPlugin = { name: 'PDF Viewer', description: 'Portable Document Format', filename: 'internal-pdf-viewer', length: 1 };
            var __pdfMime = { type: 'application/pdf', suffixes: 'pdf', description: 'Portable Document Format', enabledPlugin: __pdfPlugin };
            __pdfPlugin[0] = __pdfMime;
            __pdfPlugin.item = function(i) { return i === 0 ? this[0] : null; };
            __pdfPlugin.namedItem = function() { return null; };
            var __pluginArr = [__pdfPlugin];
            __pluginArr.item = function(i) { return this[i] || null; };
            __pluginArr.namedItem = function(name) { for (var j = 0; j < this.length; j++) { if (this[j].name === name) return this[j]; } return null; };
            __pluginArr.refresh = function() {};
            window.navigator.plugins = __pluginArr;
          }
          if (typeof window.navigator.mimeTypes === 'undefined' || (Array.isArray(window.navigator.mimeTypes) && window.navigator.mimeTypes.length === 0)) {
            var __pdfMT = { type: 'application/pdf', suffixes: 'pdf', description: 'Portable Document Format', enabledPlugin: window.navigator.plugins[0] || null };
            var __mimeArr = [__pdfMT];
            __mimeArr.item = function(i) { return this[i] || null; };
            __mimeArr.namedItem = function(name) { for (var j = 0; j < this.length; j++) { if (this[j].type === name) return this[j]; } return null; };
            window.navigator.mimeTypes = __mimeArr;
          }
          if (typeof window.navigator.cookieEnabled === 'undefined') window.navigator.cookieEnabled = true;
          if (typeof window.navigator.onLine === 'undefined') window.navigator.onLine = true;
          if (typeof window.navigator.webdriver === 'undefined') window.navigator.webdriver = false;
          if (typeof window.navigator.sendBeacon !== 'function') {
            window.navigator.sendBeacon = function(url, data) { return true; };
          }
          if (typeof window.navigator.vibrate !== 'function') {
            window.navigator.vibrate = function() { return true; };
          }
          if (typeof window.navigator.javaEnabled !== 'function') {
            window.navigator.javaEnabled = function() { return false; };
          }
        })();
        """
    }

    /// History API polyfill with pushState, replaceState, back, forward, go.
    public static func historyPolyfill(for baseURL: URL) -> String {
        let initialURL = escapeJSString(baseURL.absoluteString)
        return """
        (function() {
          var __entries = [{state: null, url: '\(initialURL)'}];
          var __index = 0;

          function __updateLocation(url) {
            if (url && window.location && window.location.__setHref) {
              window.location.__setHref(String(url));
            } else if (url && window.location) {
              window.location.href = String(url);
            }
          }

          function __dispatchPopState(state) {
            try {
              var evt;
              if (typeof PopStateEvent === 'function') {
                evt = new PopStateEvent('popstate', { state: state });
              } else {
                evt = new Event('popstate');
                evt.state = state;
              }
              if (typeof window.dispatchEvent === 'function') {
                window.dispatchEvent(evt);
              }
            } catch(e) {
              try {
                var evt2 = new Event('popstate');
                evt2.state = state;
                if (typeof window.dispatchEvent === 'function') window.dispatchEvent(evt2);
              } catch(e2) {}
            }
          }

          window.history = {
            get length() { return __entries.length; },
            get state() { return __entries[__index] ? __entries[__index].state : null; },
            scrollRestoration: 'auto',
            pushState: function(state, title, url) {
              var resolvedURL = url ? String(url) : window.location.href;
              __updateLocation(resolvedURL);
              __entries = __entries.slice(0, __index + 1);
              __entries.push({state: state !== undefined ? state : null, url: window.location.href});
              __index = __entries.length - 1;
            },
            replaceState: function(state, title, url) {
              if (url) __updateLocation(String(url));
              __entries[__index] = {state: state !== undefined ? state : null, url: window.location.href};
            },
            back: function() {
              if (__index > 0) {
                __index -= 1;
                __updateLocation(__entries[__index].url);
                __dispatchPopState(__entries[__index].state);
              }
            },
            forward: function() {
              if (__index < __entries.length - 1) {
                __index += 1;
                __updateLocation(__entries[__index].url);
                __dispatchPopState(__entries[__index].state);
              }
            },
            go: function(delta) {
              var next = __index + Number(delta || 0);
              if (next >= 0 && next < __entries.length && next !== __index) {
                __index = next;
                __updateLocation(__entries[__index].url);
                __dispatchPopState(__entries[__index].state);
              }
            }
          };
        })();
        """
    }

    /// Viewport dimensions, screen object, and matchMedia() polyfill.
    public static func viewportAndMediaPolyfill(
        width: Double,
        height: Double,
        pixelRatio: Double
    ) -> String {
        let w = Int(width)
        let h = Int(height)
        return #"""
(function() {
  window.innerWidth = \#(w);
  window.innerHeight = \#(h);
  window.outerWidth = \#(w);
  window.outerHeight = \#(h);
  window.devicePixelRatio = \#(pixelRatio);
  window.__mediaQueryWidth = \#(w);
  window.screen = {
    width: \#(w),
    height: \#(h),
    availWidth: \#(w),
    availHeight: \#(h),
    colorDepth: 24,
    pixelDepth: 24
  };

  function parsePx(query, key) {
    var re = new RegExp(key + '\\s*:\\s*([0-9]+)px', 'i');
    var match = re.exec(query);
    return match ? Number(match[1]) : null;
  }

  function evaluateMediaQuery(query) {
    var text = String(query || '').toLowerCase();
    if (!text) return false;
    var width = Number(window.__mediaQueryWidth || window.innerWidth || 0);
    var height = Number(window.innerHeight || 0);
    var preferred = String(window.__nativePreferredColorScheme || 'light').toLowerCase();
    var matches = true;

    var minWidth = parsePx(text, 'min-width');
    if (minWidth != null) matches = matches && width >= minWidth;
    var maxWidth = parsePx(text, 'max-width');
    if (maxWidth != null) matches = matches && width <= maxWidth;
    var minHeight = parsePx(text, 'min-height');
    if (minHeight != null) matches = matches && height >= minHeight;
    var maxHeight = parsePx(text, 'max-height');
    if (maxHeight != null) matches = matches && height <= maxHeight;

    if (text.indexOf('prefers-color-scheme: dark') !== -1) {
      matches = matches && preferred === 'dark';
    }
    if (text.indexOf('prefers-color-scheme: light') !== -1) {
      matches = matches && preferred !== 'dark';
    }
    if (text.indexOf('orientation: landscape') !== -1) {
      matches = matches && width >= height;
    }
    if (text.indexOf('orientation: portrait') !== -1) {
      matches = matches && height > width;
    }

    return matches;
  }

  if (typeof window.matchMedia === 'undefined') {
    window.matchMedia = function(query) {
      var listeners = [];
      var media = String(query || '');
      var mql = {
        matches: evaluateMediaQuery(media),
        media: media,
        onchange: null,
        addListener: function(listener) {
          if (typeof listener === 'function') listeners.push(listener);
        },
        removeListener: function(listener) {
          listeners = listeners.filter(function(item) { return item !== listener; });
        },
        addEventListener: function(type, listener) {
          if (type === 'change' && typeof listener === 'function') listeners.push(listener);
        },
        removeEventListener: function(type, listener) {
          if (type !== 'change') return;
          listeners = listeners.filter(function(item) { return item !== listener; });
        },
        dispatchEvent: function(event) {
          if (!event || event.type !== 'change') return true;
          for (var i = 0; i < listeners.length; i++) {
            try { listeners[i].call(this, event); } catch (e) {}
          }
          if (typeof this.onchange === 'function') {
            try { this.onchange.call(this, event); } catch (e) {}
          }
          return true;
        }
      };
      return mql;
    };
  }
})();
"""#
    }

    // MARK: - Fetch & XHR Polyfill

    /// fetch(), XMLHttpRequest, localStorage, sessionStorage, chrome.storage.
    /// Wires window.fetch() → __nativeFetch native bridge.
    public static let fetchAndXHRPolyfill = #"""
(function(){
  if (typeof Promise === 'undefined') {
    return;
  }

  if (typeof AbortController === 'undefined') {
    function NativeAbortSignal() {
      this.aborted = false;
      this.reason = undefined;
      this._listeners = [];
    }
    NativeAbortSignal.prototype.addEventListener = function(type, listener) {
      if (type !== 'abort' || typeof listener !== 'function') return;
      this._listeners.push(listener);
    };
    NativeAbortSignal.prototype.removeEventListener = function(type, listener) {
      if (type !== 'abort' || typeof listener !== 'function') return;
      this._listeners = this._listeners.filter(function(item) { return item !== listener; });
    };
    NativeAbortSignal.prototype._dispatchAbort = function() {
      var event = { type: 'abort', target: this };
      for (var i = 0; i < this._listeners.length; i++) {
        try { this._listeners[i].call(this, event); } catch (e) {}
      }
      if (typeof this.onabort === 'function') {
        try { this.onabort.call(this, event); } catch (e) {}
      }
    };

    function NativeAbortController() {
      this.signal = new NativeAbortSignal();
    }
    NativeAbortController.prototype.abort = function(reason) {
      if (this.signal.aborted) return;
      this.signal.aborted = true;
      this.signal.reason = reason;
      this.signal._dispatchAbort();
    };

    window.AbortController = NativeAbortController;
    window.AbortSignal = NativeAbortSignal;
  }

  window.__makeAbortError = function() {
    var err = new Error('The operation was aborted.');
    err.name = 'AbortError';
    return err;
  };

  {
    window.__fetchPending = {};

    window.__fetchCallback = function(requestID, resultJSON, errorText) {
      var entry = window.__fetchPending[requestID];
      if (!entry || entry.settled) return;
      entry.settled = true;
      delete window.__fetchPending[requestID];

      if (entry.signal && entry.abortHandler) {
        try { entry.signal.removeEventListener('abort', entry.abortHandler); } catch(e) {}
      }

      if (errorText) {
        if (String(errorText) === 'AbortError') {
          entry.reject(window.__makeAbortError());
        } else {
          entry.reject(new Error(String(errorText)));
        }
        return;
      }

      var payload = {};
      try {
        payload = JSON.parse(String(resultJSON || '{}'));
      } catch (e) {
        entry.reject(e);
        return;
      }

      try {
        var headersMap = payload.headers || {};
        var bodyText = String(payload.body || '');
        var statusCode = Number(payload.status || 0);
        var statusTextStr = String(payload.statusText || '');
        var hdr = { _map: {} };
        for (var hk in headersMap) {
          if (headersMap.hasOwnProperty(hk)) hdr._map[String(hk).toLowerCase()] = String(headersMap[hk]);
        }
        hdr.get = function(n) { var v = this._map[String(n).toLowerCase()]; return v !== undefined ? v : null; };
        hdr.has = function(n) { return String(n).toLowerCase() in this._map; };
        hdr.forEach = function(cb) { for (var k in this._map) { if (this._map.hasOwnProperty(k)) cb(this._map[k], k); } };
        hdr.entries = function() { var a = []; for (var k in this._map) { if (this._map.hasOwnProperty(k)) a.push([k, this._map[k]]); } return a; };
        hdr.keys = function() { var a = []; for (var k in this._map) { if (this._map.hasOwnProperty(k)) a.push(k); } return a; };
        hdr.values = function() { var a = []; for (var k in this._map) { if (this._map.hasOwnProperty(k)) a.push(this._map[k]); } return a; };
        hdr.set = function(n, v) { this._map[String(n).toLowerCase()] = String(v); };
        hdr.append = function(n, v) { var k = String(n).toLowerCase(); this._map[k] = this._map[k] ? this._map[k] + ', ' + String(v) : String(v); };
        hdr.delete = function(n) { delete this._map[String(n).toLowerCase()]; };

        var resp = {
          status: statusCode,
          statusText: statusTextStr,
          ok: statusCode >= 200 && statusCode < 300,
          headers: hdr,
          url: String(payload.url || ''),
          redirected: !!payload.redirected,
          bodyUsed: false,
          type: 'basic',
          _body: bodyText,
          text: function() { this.bodyUsed = true; return Promise.resolve(this._body); },
          json: function() { this.bodyUsed = true; return Promise.resolve(JSON.parse(this._body)); },
          clone: function() {
            var c = {}; for (var k in this) c[k] = this[k];
            c.bodyUsed = false; c._body = this._body; return c;
          },
          blob: function() { this.bodyUsed = true; return Promise.resolve(this._body); },
          arrayBuffer: function() { this.bodyUsed = true; return Promise.resolve(this._body); }
        };
        entry.resolve(resp);
      } catch (e2) {
        entry.reject(e2);
      }
    };

    window.fetch = function(input, init) {
      window._f = {};
      window._f.url = (typeof Request !== 'undefined' && input instanceof Request)
        ? String(input.url || '') : String(input || '');
      window._f.init = init || {};
      if (typeof Request !== 'undefined' && input instanceof Request) {
        if (!window._f.init.method && input.method && input.method !== 'GET') {
          window._f.init.method = input.method;
        }
      }
      window._f.so = {};
      if (window._f.init.method) window._f.so.method = String(window._f.init.method);
      if (window._f.init.headers) {
        if (typeof Headers !== 'undefined' && window._f.init.headers instanceof Headers) {
          window._f.so.headers = {};
          window._f.init.headers.forEach(function(v, k) { window._f.so.headers[k] = v; });
        } else { window._f.so.headers = window._f.init.headers; }
      }
      if (window._f.init.body !== undefined && window._f.init.body !== null) window._f.so.body = String(window._f.init.body);
      if (window._f.init.credentials) window._f.so.credentials = window._f.init.credentials;
      if (window._f.init.mode) window._f.so.mode = window._f.init.mode;
      if (window._f.init.cache) window._f.so.cache = window._f.init.cache;
      if (window._f.init.redirect) window._f.so.redirect = window._f.init.redirect;
      window._f.optsStr = JSON.stringify(window._f.so);
      window._f.signal = window._f.init.signal || null;
      window._f.rid = __nativeFetch.startFetchDirect(window._f.url, window._f.optsStr, window.__fetchCallback);
      window.__fetchPending[window._f.rid] = { settled: false, signal: window._f.signal, abortHandler: null };

      return new Promise(function(resolve, reject) {
        if (window._f.signal && window._f.signal.aborted) {
          reject(window.__makeAbortError());
          return;
        }
        var e = window.__fetchPending[window._f.rid];
        if (e) { e.resolve = resolve; e.reject = reject; }

        if (window._f.signal && typeof window._f.signal.addEventListener === 'function') {
          var rid = window._f.rid;
          e.abortHandler = function() {
            if (e.settled) return;
            e.settled = true;
            delete window.__fetchPending[rid];
            __nativeFetch.cancelFetch(rid);
            reject(window.__makeAbortError());
          };
          window._f.signal.addEventListener('abort', e.abortHandler);
        }
      });
    };
  }

  {
    function XHR() {
      this.readyState = 0;
      this.status = 0;
      this.responseText = '';
      this.onreadystatechange = null;
      this.onload = null;
      this.onerror = null;
      this._method = 'GET';
      this._url = '';
      this._headers = {};
    }

    XHR.prototype.open = function(method, url) {
      this._method = String(method || 'GET');
      this._url = String(url || '');
      this.readyState = 1;
      if (this.onreadystatechange) this.onreadystatechange();
    };

    XHR.prototype.setRequestHeader = function(name, value) {
      this._headers[String(name)] = String(value);
    };

    XHR.prototype.send = function(body) {
      var self = this;
      fetch(this._url, {
        method: this._method,
        headers: this._headers,
        body: body
      }).then(function(resp){
        self.status = resp.status;
        return resp.text();
      }).then(function(text){
        self.responseText = String(text || '');
        self.readyState = 4;
        if (self.onreadystatechange) self.onreadystatechange();
        if (self.onload) self.onload();
      }).catch(function(err){
        self.readyState = 4;
        if (self.onreadystatechange) self.onreadystatechange();
        if (self.onerror) self.onerror(err);
      });
    };

    window.XMLHttpRequest = XHR;
  }

  if (typeof localStorage === 'undefined') {
    window.localStorage = {
      getItem: function(key) {
        var value = __nativeStorage.get('local_storage', String(key));
        return value == null ? null : String(value);
      },
      setItem: function(key, value) {
        __nativeStorage.set('local_storage', String(key), String(value));
      },
      removeItem: function(key) {
        __nativeStorage.remove('local_storage', String(key));
      },
      clear: function() {
        __nativeStorage.clear('local_storage');
      },
      key: function(index) {
        var keys = __nativeStorage.keys('local_storage');
        return (index >= 0 && index < keys.length) ? keys[index] : null;
      },
      get length() {
        return __nativeStorage.keys('local_storage').length;
      }
    };
  }

  if (typeof sessionStorage === 'undefined') {
    window.sessionStorage = {
      getItem: function(key) {
        var value = __nativeStorage.get('session_storage', String(key));
        return value == null ? null : String(value);
      },
      setItem: function(key, value) {
        __nativeStorage.set('session_storage', String(key), String(value));
      },
      removeItem: function(key) {
        __nativeStorage.remove('session_storage', String(key));
      },
      clear: function() {
        __nativeStorage.clear('session_storage');
      },
      key: function(index) {
        var keys = __nativeStorage.keys('session_storage');
        return (index >= 0 && index < keys.length) ? keys[index] : null;
      },
      get length() {
        return __nativeStorage.keys('session_storage').length;
      }
    };
  }
})();
"""#
}
