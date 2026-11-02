# Engine DOM + host bridges — Claude neuron

> Area: `Sources/JeffJS/DOM/` · Repo: engine · Last reviewed: 2026-11-02 (app 20c9d08 / engine 1bcbde2)

## Purpose
The DOM the app renders lives here: `DOMNode` (tree, attributes, shadow DOM, selector caches), the HTML tokenizer/tree
builder and the CSS selector parser/matcher. The same folder holds the engine-side *bridges* that expose the tree and
the web platform to page JS (`JeffJSDOMBridge` + extensions, events, fetch/XHR, WebSocket, storage, cookies, IndexedDB,
dynamic import, video, misc Web APIs). Input: HTML text / JS calls; output: a `DOMNode` tree plus mutation callbacks the
host (React Natively's `JSScriptEngine`, the CLI's `JeffJSEnvironment`, the tests) consumes. The app's own
`renderengine/DOM/` holds only helpers over these nodes (its copies of DOMNode/HTMLParser/CSSSelector were removed).

## Key files
- `DOMNode.swift` (+`+Siblings`, `+Shadow`, `+SelectorCache`) — the node: per-node `Mutex` state, ids, threading contract
  (file header), O(1) sibling positions, shadow roots / flat tree / slots, `:lang` + ancestor Bloom filter per selector epoch.
- `HTMLParser.swift` (`HTMLTreeBuilder`, HTML §13.2.6: insertion modes, adoption agency, foster parenting, foreign content,
  declarative `<template shadowrootmode>`), `HTMLTokenizer.swift` (§13.2.5, pull-driven over UTF-8 bytes), `HTMLToken.swift`,
  `HTMLEntities.swift` (2231 named refs, one packed string decoded lazily).
- `CSSSelector.swift` — selector grammar (`:is/:where/:not/:has`, `:nth-child(of S)`, legacy single-colon pseudo-elements),
  `CSSSelectorMatcher`, `CSSMatchContext` (`scope`, `shadowHost`), `CSSSelector.isSupported`.
- `JeffJSDOMBridge.swift` — `document` / element wrappers / `register(on:)` / `extractNode` / `wrapElement`; the shared
  element prototype (EP), per-interface prototypes from the host, DOMTokenList shared prototype, `documentBaseURL()`
  (reads only `<head>` children), `JeffJSHyperlinkURL`.
- `JeffJSDOMBridge+Interaction.swift` — DOM §4.2.3 mutation algorithms, native MutationObserver, node lifetimes
  (`collectDetachedNodes`), focus, `click()` + activation, innerText, dataset, `<details>`, labels.
- `+Scripts.swift` (script-insertion contract, see Invariants), `+Reflection.swift` (HTMLScriptElement IDL, `on*` accessors,
  `CSS.escape`, `document.__createContextualFragment`, `contentAttributeOverride`, `defaultChecked`),
  `+CharacterData.swift` (Text/Comment members over "replace data"), `+Shadow.swift` (attachShadow, slots, CE hooks),
  `+InlineStyle.swift` (`element.style` over a host block), `+Realms.swift` (one bridge per realm, wrapper routing).
- `JeffJSEventBridge.swift` — one `EventTarget` implementation + DOM dispatch; host API `__nativeEventBridge`.
- `JeffJSFetchBridge.swift` + `JeffJSFetchBody.swift` — `__nativeFetch` (fetch/XHR/beacon/keepalive), bodies both ways.
- `JeffJSRequestHeaders.swift` — Referer + `Sec-Fetch-*` rules shared with the app's loaders (`apply(to:…)`).
- `JeffJSCookieJar.swift` — `JeffJSCookieJar` protocol, `JeffJSMemoryCookieJar` (RFC 6265bis), `JeffJSCookieBridge` (`document.cookie`).
- `JeffJSStorageBridge.swift` + `JeffJSWebStorage.swift` — `__nativeStorage`, origin keys, quotas, `storage` events, store protocol.
- `JeffJSWebSocketBridge.swift` (`__nativeWebSocket`), `JeffJSIndexedDBBridge.swift` (`__nativeIDBBridge`, SQLite under
  Application Support/ReactNatively/`indexeddb_<scope>.sqlite3`), `JeffJSDynamicImportBridge.swift` (`__nativeDynamicImport`),
  `JeffJSWebAPIsBridge.swift` (performance, crypto, TextEncoder/Decoder, MessageChannel, Intl), `JeffJSVideoBridge.swift` (`__nativeVideo`).

## Invariants
- **DOMNode threading contract** (header of `DOMNode.swift`, engine 6cd832a): one writer thread, any number of readers; every
  mutable fact lives under the node's `Mutex`; a getter takes one lock, never two nodes' locks; lazy caches publish under
  the lock only if their input is unchanged; `nodeType/tagName/lowercasedTagName/id` are immutable. `DOMThreadSafetyTests`.
- The **selector epoch** (`DOMNode.selectorEpoch`, `bumpSelectorEpoch`, `Atomic`, release after the mutation / acquire on
  read) is bumped by parent changes, attribute mutations and node deallocation; every cache tagged by it is rebuilt past it.
  Readers (the app's HydraDOM build) compare it to decide a full re-run.
- **Node ids come from a counter** (`DOMNode.makeID`: random 64-bit process prefix + counter, shaped like a UUID) — never `UUID()` per node.
- Children point at their parent **weakly** (`weak var parent`): a DOMNode has a weak-reference side table, so every retain
  takes the slow path. Walks (`walkDescendantElements`, `CSSSelector` ancestor chains) read nodes **unretained**
  (`Unmanaged.passUnretained`); a new query/walk must not retain each scanned node. Removing the weak parent is the open big one.
- **Shadow DOM**: a shadow root is a DocumentFragment carrying `DOMShadowRootInfo`, kept in `State.shadowRoot` (never in
  `children`), whose stored `parent` is its **host**. Anything with DOM semantics uses `domParent` / stops at `isShadowRoot`
  (parentNode, `closest`, selector combinators, subtree MutationObservers, `contains`); rendering walks use
  `flatTreeChildren` / `flatTreeParent` (slots flatten recursively). `DOMNode.anyShadowRoots` false = plain `children`/`parent`.
- `HTMLParser.maximumDOMTreeDepth` = **512** (WebKit `HTMLConstructionSite::attachLater`): at 512 open elements a new
  element/comment closes the current node and becomes its sibling (unless attached by the same token). Never raise it
  without re-running the app's rung 03 `depth2000` on a 1 MB-stack build (`ParserNestingConformance`).
- **Script-inserted scripts** (header of `JeffJSDOMBridge+Scripts.swift`): the bridge runs "prepare" up to "already started"
  and calls `onScriptExecution` **once per script**, in tree order, after the whole insertion; the host runs inline classic
  scripts synchronously inside the callback (`document.__setCurrentScriptByID`), fetches external ones and runs them from a
  task, `async = false` ones in insertion order, `load`/`error` at the element. `DOMNode.scriptAlreadyStarted` is set for
  scripts present at registration and every fragment-parser script (innerHTML, DOMParser, …: they never run); hosts that
  parse markup later must set it themselves. `document.__createContextualFragment` keeps a fragment's scripts startable.
- **Every element wraps with one shared prototype (EP)**; `interfacePrototypesByTag` / text / comment prototypes come from
  the host's surface pass via `window.__rnSetNodeInterfaces(byTag, unknown, text, comment)` (chained to EP). A new per-tag
  IDL member goes on EP; the host step moves it. `Text`/`Comment` members are native on the CharacterData prototype
  (host's or the engine's own) — a host stub there shadows the accessor (rung 15 js09/m11).
- `document`'s chain is `HTMLDocument.prototype → Document.prototype` with `cookie`/`referrer` as prototype accessors,
  installed only when no host defined `Document` first.
- **Every script mutation goes through the mutation primitives** (`setAttributeValue`, insert/remove/replace in
  `+Interaction`, "replace data" in `+CharacterData`): MutationObserver record with the old value → custom-element hook
  (`document.__rnSetCEHook`, called synchronously at the end of each connecting/disconnecting/attribute mutation; `:defined`
  via `document.__rnCEDefined`) → the host's `onMutated(Set<UUID>)`. A new write path must do the same.
- `element.style` with `inlineStyleHost` set **before the style prototype is built**: `setProperty/removeProperty/
  getPropertyValue/getPropertyPriority/cssText` are natives over a per-element `JeffJSInlineStyleBlock` and store the
  serialisation as the `style` attribute through `setAttributeValue`; any other change of `style` re-parses on next access.
  Without a host the engine's key/value natives stay (`InlineStyleHostConformance`).
- **Fetch network leg off the host thread**: `prepareFetch` (host actor, reads bridge state) → `Task.detached` `runNetwork`
  (static, nonisolated: service-worker hook, preflight, request; touches nothing of the bridge) → one host job `finishFetch`
  at arrival. Any new host bridge that does I/O must follow this shape: no host-actor awaits between request and delivery
  (Home Depot's 100 ms answer landed after a 5 s race otherwise; `FetchBridgeTests.testResponseQueuedBeforeLaterTimer`).
- `JeffJSFetchBridge.hostServiceWorkerFetch` (static, set once, any thread) answers first for http(s); `cookieJar`
  decides cookies per `credentials` (omit / same-origin / include), falling back to the storage bridge's cookie string only
  with no jar; `applyRequestMetadata` adds Referer + Sec-Fetch-* from `JeffJSRequestHeaders`; keepalive quota 64 KiB.
- **`JeffJSRequestHeaders` is the one rule set** for Referer / `Sec-Fetch-Site/Mode/Dest` (pure, nonisolated): fetch/XHR
  here, document/script/style/image/font loads in the app. `Sec-Fetch-User` only when a caller asks; Fetch Metadata only to
  potentially trustworthy URLs; WebKit's cross-site trim to origin (`trimCrossSiteReferrer`) is on by default.
- **Cookies**: `JeffJSMemoryCookieJar` is a complete RFC 6265bis store (400-day cap, prefixes, HttpOnly hidden from
  `document.cookie`, SameSite on retrieval); partitioning is the host's (the app's `RNCookieJars`: one jar per top-level site).
- **Web Storage never uses `UserDefaults`** (watchOS aborted the app past the prefs cap). Areas are keyed by the serialized
  origin (`JeffJSWebStorageOrigin.key(for:)`; `blob:` → inner URL), quota writes throw `QuotaExceededError` and change
  nothing, `storage` events go as a task to every *other* live document of the origin sharing the area; sessionStorage is
  in-memory per (`browsingContext`, origin), process-wide (`JeffJSStorageBridge.sessionStore`). Hosts install `defaultStore`.
- **Realms**: with ≥ 2 bridges in `realmBridges` (`joinRealmRegistry` / `leaveRealmRegistry`), `wrapElement` routes a node to
  the bridge of its node document (`realmOwner(of:)`): one wrapper per node per realm, prototypes of that realm.
  `extractNode` is realm-agnostic. Host natives get the realm they were registered on as `ctx`.
- **Isolation**: bridge classes are `@JeffJSHostActor`; every other top-level declaration here is `nonisolated`
  (`EngineThreadingRuleTests.testTopLevelDeclarationsAreNonisolated` lists the DOM dir + bridge names as the host set).
  The app compiles the engine with MainActor default isolation, so an unannotated declaration hops to main.
- An async host callback that settles a promise must run a **microtask checkpoint**: `JeffJSDynamicImportBridge` calls
  `rt.executePendingJobs()` at `callDepth == 0` after resolving (`DynamicImportCheckpointTests`).

## Gotchas
- WebSocket frames were strings until 2026-10-18: binary out = the view's bytes, binary in = ArrayBuffer; `open` only after the
  handshake, exactly one `close` per socket, `sent` callbacks feed `bufferedAmount` (`WebSocketBridgeTests`).
- MessageChannel/MessagePort in `JeffJSWebAPIsBridge` still delivers through the global `setTimeout` — pages replace it
  (Meta's scheduler deadlocked); the app's `webAPIsPolyfill` overrides the port with `__rnTask` → `__rnQueueTask`.
- TextDecoder's native `decode` read `input.length` (an ArrayBuffer decoded to ""); the app's `WebPlatformGlue` replaces it —
  fix in the engine when touching it. Same family: `dataset instanceof DOMStringMap` false.
- Text strings are Swift Strings: `splitText` inside a surrogate pair yields U+FFFD halves; no live `Range` updates.
- `document.cookie` cannot set/overwrite HttpOnly; a Secure cookie needs a secure origin — a "missing" cookie is often that.
- `documentBaseURL()` only sees a `<base>` among `<head>` children (the app's `DocumentBaseURL` does the full §2.4.1 rule).
- `contentAttributeOverride` (names `value`/`checked`/`selected`) exists because the app's `attributes` hold a control's
  *state*; the content attribute lives in the app's `FormControlState`.
- Fetch has a legacy JSON-string callback payload beside `payloadObject`; new glue reads the object (bytes), not `body`.
- Storage keys that are not origins are the old root-domain scope (`JeffJSStorageBridge` "Legacy"); the legacy cookie
  namespace exists only for `RN_COOKIES_LEGACY=1` hosts.
- `HTMLParser.parse(allowDeclarativeShadowRoots:)` is true for the page parse, false for DOMParser; `scriptingEnabled` makes
  `<noscript>` raw text.

## Patterns to follow
- A host hook = an optional closure/static on the bridge (`computedStyleProvider`, `onFocusChange`, `onActivationBehavior`,
  `inlineStyleHost`, `hostServiceWorkerFetch`, `hostURLCache`, `cookieJar`) with a JS fallback or the engine's own default;
  the engine must work without the host (CLI + tests use `runScriptElementDefault`, `JeffJSMemoryCookieJar`, memory storage).
- Per-node caches: build into a local outside the lock, publish under it tagged with the epoch read *before* the inputs
  (`DOMNode+SelectorCache.swift`); sibling positions are tagged with the parent's `childrenVersion`.
- Walk iteratively with child snapshots (`walkDescendantElements`); never recurse per level on the host thread.
- Value ownership in bridges: every `getPropertyStr`/`toObject` result is owned and freed on all paths; setters dup
  (`JeffJSFetchBody.swift` header; `docs/PERFORMANCE_PLAN.md` Round 9). `[weak self]` in every registered native.
- Error texts must read like WebKit/JSC's (`"Can only call Element.attachShadow on instances of Element"`, DOMStringMap text).
- Old way not to copy: redefining `setProperty` & co. in JS over attribute reads (15–70 µs per write); running a bridge's
  I/O on the host actor; `UUID()` per node; per-realm reasoning without `realmOwner`.

## Debug switches
- `JEFFJS_COOKIE_DEBUG=1` — `[DocCookie] set <name> len before after visible` per `document.cookie` write,
  `[FetchCookie] attach|store` per fetch/XHR (`JeffJSCookieBridge.debug`).
- `JEFFJS_STORAGE_DEBUG=1` (`storage.debug`) — one `[WebStorage] set …` line per write; quota rejections always print.
- Config keys (plist, env `JEFFJS_<KEY>` with `.` → `_`): `storage.localQuotaBytes` (5 MB iOS / 1 MB watch),
  `storage.sessionQuotaBytes`, `storage.totalBudgetBytes` (50 / 8 MB) — `Config/JeffJSConfig.swift`.
- `__nativeFetch.setEnforceCORS(false)` — debug against servers without CORS headers (`enforceCORS`).
- App-side switches over this code: `RN_STYLE_NATIVE_BLOCK=0` (old JS style glue), `RN_COOKIES_LEGACY=1`, `RN_IFRAME_REALMS=0`,
  `RN_FRAME_REALM_DEBUG=1`, `JEFFJS_REGEX_WATCH=1` — see the app root doc.

## Cross-area links
- [Core](../Core/CLAUDE.md) — `JeffJSContext`/`JeffJSRuntime`, realms (`newRealm`), host actor, the regex input cache
  (`JeffJSRegexCaches.codeUnits`, keyed by string identity and revalidated by length because `appendInPlace` grows a string
  in place — any new per-string identity cache must do the same).
- [Parser](../Parser/CLAUDE.md), [Bytecode](../Bytecode/CLAUDE.md) — compiler side; not touched by DOM work.
- `../Environment/` — `JeffJSEnvironment` (CLI host of these bridges), `JeffJSPolyfills.fetchAndXHRPolyfill`.
- [React Natively app](../../../../../CLAUDE.md) — `JSScriptEngine` installs every host hook; the Safari-surface pass
  (`__rnSetNodeInterfaces`), `RNCookieJars`, `RNWebStorage`, `CSSOMInlineStyleHost`, `ServiceWorkers.swift`.
- [App DOM helpers](../../../../../React%20Natively/renderengine/DOM/CLAUDE.md) — `DocumentBaseURL`, `SVGAnimatedValues`,
  `TapActionability`, `VirtualDOM` over these nodes.

## Deep docs
- [`docs/DOM_TURBO_PROFILE.md`](../../../../../docs/DOM_TURBO_PROFILE.md) — DOM bridge profile of Instagram/Facebook/Home Depot
  (bridge 2–4 % of busy time; forced geometry reads are the next lever).
- [`docs/PERFORMANCE_PLAN.md` § "Round 9 — argument ownership"](../../../docs/PERFORMANCE_PLAN.md) — value ownership rules the bridges follow.
- [`README.md` § "Drive the DOM"](../../../README.md) — host usage of `JeffJSDOMBridge`.
- App `SPEC_LADDER_PLAN.md` § "Reddit on JeffJS" (shadow DOM), § "homedepot.com on JeffJS, part 2" (EP / interfaces),
  § "Web Storage" fix log — [`SPEC_LADDER_PLAN.md`](../../../../../SPEC_LADDER_PLAN.md).
- Tests: `DOMThreadSafetyTests`, `DOMBridgeFastPathConformance`, `DOMQueryBenchTests`, `DOMQueryFastPathTests`,
  `DOMSiblingPositionTests`, `ShadowDOMConformance`, `DeclarativeShadowDOMConformance`, `CSSScopingConformance`,
  `SelectorTests` (`testIsSupported` is a known failure per the app root doc, not re-run 2026-11-02), `HTMLParserTests`,
  `HTMLParsingConformance`, `ParserNestingConformance`, `DOMScriptPrepareConformance`, `DOMCharacterDataConformance`,
  `InlineStyleHostConformance`, `RealmConformance`, `CookieJarTests`, `FetchBridgeTests`, `WebSocketBridgeTests`,
  `StorageBridgeTests`, `WebStorageConformance`, `DynamicImportCheckpointTests`, `EngineThreadingRuleTests`.
  Run with `swift test -c release`.

## Suspected dead code
- `__nativeFetch.fetch(url, opts, callback)` (`JeffJSFetchBridge.swift` line 281) — confidence: medium — checked:
  `grep -rn "nativeFetch\.fetch" Sources Tests "React Natively"` → 0 call sites (the engine polyfill and the app use
  `startFetch`/`startFetchObject`/`startFetchDirect`).

## Suspected stale
- Root doc: "`JeffJSFetchBridge.hostURLCache` is set — TODO in `JSScriptEngine`". It is set: `JSScriptEngine.swift:2730`
  assigns `HTMLFetcher.sharedResourceCache`. The TODO is done.
- Root doc: "the DOM/ bridges' event-listener records and `JeffJSMutationObserverEntry` are still main-actor — open".
  Both are `nonisolated final class` now (`JeffJSDOMBridge+Interaction.swift:42`, `JeffJSEventBridge.swift:43`);
  `grep -n "@MainActor" Sources/JeffJS/DOM/*.swift` → 0.
