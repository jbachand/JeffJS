// DOMBridgeBenchTests.swift
// JeffJS — per-call cost of the hot JS → native DOM calls a framework commit
// makes (React/Preact/Vue/Lit all reduce to these). Prints timings, no
// assertions. Run in release:
//   swift test -c release --filter DOMBridgeBenchTests

import XCTest
@testable import JeffJS

final class DOMBridgeBenchTests: XCTestCase {

    static let workload = """
    (function() {
      var N = 2000, R = 5, out = [];
      var now = __hrnow;
      function bench(label, fn) {
        fn(); // warm
        var best = 1e18;
        for (var r = 0; r < R; r++) {
          var t0 = now(); var ops = fn(); var dt = now() - t0;
          if (dt / ops < best) best = dt / ops;
        }
        out.push(label + '=' + (best * 1e6).toFixed(0));
        return best;
      }
      var host = document.createElement('div');
      document.body.appendChild(host);
      var els = [], texts = [];
      for (var i = 0; i < N; i++) {
        var e = document.createElement('div'); host.appendChild(e); els.push(e);
        var t = document.createTextNode('x'); e.appendChild(t); texts.push(t);
      }
      bench('createElement', function() { for (var i = 0; i < N; i++) document.createElement('span'); return N; });
      bench('createTextNode', function() { for (var i = 0; i < N; i++) document.createTextNode('t'); return N; });
      bench('setAttribute', function() { for (var i = 0; i < N; i++) els[i].setAttribute('data-k', 'v' + (i & 7)); return N; });
      bench('getAttribute', function() { var c = 0; for (var i = 0; i < N; i++) if (els[i].getAttribute('data-k')) c++; return N; });
      bench('removeAttribute', function() { for (var i = 0; i < N; i++) { els[i].removeAttribute('data-k'); } return N; });
      bench('className=', function() { for (var i = 0; i < N; i++) els[i].className = 'c' + (i & 3); return N; });
      bench('style.color=', function() { for (var i = 0; i < N; i++) els[i].style.color = (i & 1) ? 'red' : 'blue'; return N; });
      bench('style.setProperty', function() { for (var i = 0; i < N; i++) els[i].style.setProperty('margin-top', (i & 7) + 'px'); return N; });
      bench('textContent=', function() { for (var i = 0; i < N; i++) els[i].textContent = 'v' + (i & 7); return N; });
      for (var i = 0; i < N; i++) texts[i] = els[i].firstChild;
      bench('text.data=', function() { for (var i = 0; i < N; i++) texts[i].data = 'd' + (i & 7); return N; });
      bench('text.nodeValue=', function() { for (var i = 0; i < N; i++) texts[i].nodeValue = 'n' + (i & 7); return N; });
      bench('classList.add', function() { for (var i = 0; i < N; i++) els[i].classList.add('on'); return N; });
      bench('classList.remove', function() { for (var i = 0; i < N; i++) els[i].classList.remove('on'); return N; });
      bench('classList.toggle', function() { for (var i = 0; i < N; i++) els[i].classList.toggle('t'); return N; });
      bench('parentNode', function() { var c = 0; for (var i = 0; i < N; i++) if (els[i].parentNode) c++; return N; });
      bench('firstChild', function() { var c = 0; for (var i = 0; i < N; i++) if (els[i].firstChild) c++; return N; });
      bench('nextSibling walk', function() { var c = 0, n = host.firstChild; while (n) { c++; n = n.nextSibling; } return c; });
      bench('childNodes[i]', function() { var cn = host.childNodes, c = 0; for (var i = 0; i < N; i++) if (cn[i]) c++; return N; });
      bench('childNodes.length', function() { var c = 0; for (var i = 0; i < N; i++) c += els[i].childNodes.length; return N; });
      bench('insertBefore+removeChild', function() {
        var p = document.createElement('div'), a = document.createElement('i');
        p.appendChild(a);
        for (var i = 0; i < N; i++) { var b = els[i]; p.insertBefore(b, a); p.removeChild(b); }
        for (var i = 0; i < N; i++) host.appendChild(els[i]);
        return 2 * N + N;
      });
      bench('appendChild(new)', function() {
        var p = document.createElement('div');
        for (var i = 0; i < N; i++) p.appendChild(document.createElement('b'));
        return N;
      });
      // A React-commit-like workload: build, fill, insert, then update and walk.
      var total = bench('WORKLOAD', function() {
        var root = document.createElement('div');
        var made = [];
        for (var i = 0; i < N; i++) {
          var e = document.createElement(i & 1 ? 'span' : 'div');
          e.setAttribute('class', 'item i' + (i & 15));
          e.setAttribute('data-id', '' + i);
          e.style.color = 'red';
          e.style.setProperty('padding-left', (i & 7) + 'px');
          var t = document.createTextNode('row ' + i);
          e.appendChild(t);
          root.appendChild(e);
          made.push(e);
        }
        host.appendChild(root);
        for (var i = 0; i < N; i++) {
          var e = made[i];
          e.classList.toggle('sel');
          e.firstChild.data = 'upd ' + i;
          if (e.getAttribute('data-id') === '7') e.removeAttribute('data-id');
          e.textContent = 'x' + (i & 3);
        }
        var c = 0, n = root.firstChild;
        while (n) { if (n.parentNode === root) c++; n = n.nextSibling; }
        host.removeChild(root);
        return 1;
      });
      out.push('WORKLOAD_ms=' + total.toFixed(2));
      return out.join('\\n');
    })()
    """

    @JeffJSHostActor
    func testBench() {
        let env = JeffJSEnvironment(configuration: .init(viewportWidth: 390, viewportHeight: 844))
        let ctx = env.context
        let g = ctx.getGlobalObject()
        ctx.setPropertyFunc(obj: g, name: "__hrnow", fn: { _, _, _ in
            .newFloat64(Double(DispatchTime.now().uptimeNanoseconds) / 1e6)
        }, length: 0)
        g.freeValue()
        switch env.eval(Self.workload) {
        case .success(let s):
            for line in (s ?? "").split(separator: "\n") {
                let parts = line.split(separator: "=")
                print(String(format: "BENCH %-28@ %10@ %@", String(parts[0]) as NSString,
                             String(parts[1]) as NSString,
                             (parts[0] == "WORKLOAD_ms" ? "" : (parts[0] == "WORKLOAD" ? "ns (whole workload)" : "ns/call")) as NSString))
            }
        case .exception(let m): XCTFail("threw: \(m)")
        }
    }
}

extension DOMBridgeBenchTests {
    /// Runs one workload piece for a long time (for `sample`); set
    /// DOM_BENCH_PROFILE=<js expression body> to pick it.
    @JeffJSHostActor
    func testProfileLoop() {
        guard let body = ProcessInfo.processInfo.environment["DOM_BENCH_PROFILE"] else { return }
        let env = JeffJSEnvironment(configuration: .init(viewportWidth: 390, viewportHeight: 844))
        let t0 = DispatchTime.now().uptimeNanoseconds
        switch env.eval(body) {
        case .success(let s): print("PROFILE result \(s ?? "") in \(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6) ms")
        case .exception(let m): XCTFail("threw: \(m)")
        }
    }
}
