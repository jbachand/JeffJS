// JeffJSStringPool.swift
// JeffJS — short Latin-1 strings are recycled instead of freed.
//
// A temporary string (`"k" + i`, a number turned into text, a substring) is
// two allocations and two frees: the string object and its code-unit block
// (quickjs has one, `JSString` with the characters after the header; a Swift
// class cannot carry a tail). On the string-building kernels malloc and free
// were about half of the instructions. A flat 8-bit string that dies with a
// block of 16...128 bytes is parked here, object and block together, and the
// next short string takes it: no malloc, no free, no object initialisation.
//
// The pool is per thread (a string may die on a thread other than the one
// that made it; it then joins that thread's pool), bounded (four size
// classes of 32), and only ever holds strings nothing else references: the
// dying value's Swift reference must be the last one, so a string an atom
// table, a regex cache or a Swift local still holds is released as before.
// Switch: `string.pool` (`JEFFJS_STRING_POOL=0` frees every string).

import Foundation

nonisolated(unsafe) let jeffJSStringPoolEnabled = JeffJSConfig.stringPool

#if canImport(Darwin)

/// Per class: one count word followed by `perClass` object pointers.
nonisolated private let jeffJSStringPoolPerClass = 32
nonisolated private let jeffJSStringPoolStride = 33
nonisolated private let jeffJSStringPoolClasses = 4

nonisolated(unsafe) private let jeffJSStringPoolKey: pthread_key_t = {
    var k = pthread_key_t()
    pthread_key_create(&k) { raw in
        // Thread exit: give the parked strings back.
        let base = raw.assumingMemoryBound(to: UInt.self)
        for c in 0..<jeffJSStringPoolClasses {
            let n = Int(base[c * jeffJSStringPoolStride])
            for i in 0..<n {
                if let p = UnsafeRawPointer(bitPattern: base[c * jeffJSStringPoolStride + 1 + i]) {
                    Unmanaged<JeffJSString>.fromOpaque(p).release()
                }
            }
        }
        free(raw)
    }
    return k
}()

@inline(__always)
nonisolated private func jeffJS_stringPoolBase(create: Bool) -> UnsafeMutablePointer<UInt>? {
    if let p = pthread_getspecific(jeffJSStringPoolKey) { return p.assumingMemoryBound(to: UInt.self) }
    if !create { return nil }
    let words = jeffJSStringPoolClasses * jeffJSStringPoolStride
    guard let p = calloc(words, MemoryLayout<UInt>.size) else { return nil }
    pthread_setspecific(jeffJSStringPoolKey, p)
    return p.assumingMemoryBound(to: UInt.self)
}

/// A parked string whose block holds at least `count` bytes (1...64), owned
/// by the caller, or nil.
@inline(__always)
nonisolated func jeffJS_stringPoolTake(_ count: Int) -> JeffJSString? {
    guard let base = jeffJS_stringPoolBase(create: false) else { return nil }
    let slot = ((count &+ 15) >> 4 &- 1) &* jeffJSStringPoolStride   // class of blocks >= count rounded up to 16
    let n = base[slot]
    if n == 0 { return nil }
    base[slot] = n &- 1
    guard let p = UnsafeRawPointer(bitPattern: base[slot &+ Int(n)]) else { return nil }
    return Unmanaged<JeffJSString>.fromOpaque(p).takeRetainedValue()
}

/// Called with the last JS reference to a flat string gone: parks the string
/// when it qualifies, releases it otherwise. Consumes the value's reference.
@inline(never)
nonisolated func jeffJS_stringPoolPutOrRelease(_ ptr: UnsafeRawPointer) {
    var s = Unmanaged<JeffJSString>.fromOpaque(ptr).takeRetainedValue()   // the dying value's reference
    guard !s.isWideChar, s.cachedAtom == 0, s.atomType == 0, !s.freeMark,
          isKnownUniquelyReferenced(&s) else { return }                    // released as `s` goes out of scope
    let cap = s.unitBlockCapacity
    guard cap >= 16, cap <= 128, let base = jeffJS_stringPoolBase(create: true) else { return }
    let cls = (cap >> 4 > jeffJSStringPoolClasses ? jeffJSStringPoolClasses : cap >> 4) &- 1
    let slot = cls &* jeffJSStringPoolStride
    let n = Int(base[slot])
    if n >= jeffJSStringPoolPerClass { return }
    base[slot &+ 1 &+ n] = UInt(bitPattern: Unmanaged.passRetained(s).toOpaque())   // the pool's reference
    base[slot] = UInt(n &+ 1)
}

#else

@inline(__always) nonisolated func jeffJS_stringPoolTake(_ count: Int) -> JeffJSString? { nil }
@inline(__always) nonisolated func jeffJS_stringPoolPutOrRelease(_ ptr: UnsafeRawPointer) {
    Unmanaged<JeffJSString>.fromOpaque(ptr).release()
}

#endif
