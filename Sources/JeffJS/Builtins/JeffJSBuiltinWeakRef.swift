// JeffJSBuiltinWeakRef.swift
// JeffJS -- 1:1 Swift port of QuickJS JavaScript engine
//
// Port of WeakRef and FinalizationRegistry built-ins from QuickJS.
//
// QuickJS source reference: quickjs.c --
//   js_weakref_constructor, js_weakref_deref,
//   js_finrec_constructor, js_finrec_register, js_finrec_unregister,
//   JSWeakRefData, JSFinalizationRegistryData, JSFinRecEntry,
//   weak_ref_finalizer, weak_ref_gc_mark, etc.

import Foundation

// MARK: - JSWeakRefData

/// Internal data for a WeakRef object.
/// Mirrors QuickJS `JSWeakRefData`.
///
/// Holds a weak reference to the target (object or non-registered symbol).
/// When the target is garbage collected the weak reference is invalidated
/// and `deref()` returns undefined.
final class JSWeakRefData {
    /// The weak reference cell pointing at the target object.
    /// `nil` after the target has been collected or the WeakRef finalized.
    var weakRef: JeffJSWeakRef?

    /// The raw target value.  Kept as a JeffJSValue so we can return it
    /// from `deref()`.  When the weak ref is invalidated this is set to
    /// `.undefined`.
    var target: JeffJSValue

    init(weakRef: JeffJSWeakRef?, target: JeffJSValue) {
        self.weakRef = weakRef
        self.target = target
    }
}

// MARK: - JSFinRecEntry

/// One entry in a FinalizationRegistry's registered-target list.
/// Mirrors QuickJS `JSFinRecEntry`.
///
/// QuickJS layout:
/// ```c
/// typedef struct JSFinRecEntry {
///     struct list_head link;
///     JSWeakRefHeader weakref_hdr;  /* weak ref to target */
///     JSValue held_value;
///     JSValue token;                /* unregister token (object or symbol) */
///     int has_token;
/// } JSFinRecEntry;
/// ```
final class JSFinRecEntry {
    /// Link node for the finalization registry's entry list.
    var link: ListNode = ListNode()

    /// Weak reference to the target object.
    var weakRef: JeffJSWeakRef?

    /// The raw target value (for identity comparison during unregister).
    var target: JeffJSValue = .undefined

    /// The value passed to the cleanup callback when the target is collected.
    var heldValue: JeffJSValue = .undefined

    /// Optional unregister token.  Must be an object or non-registered symbol.
    var token: JeffJSValue = .undefined

    /// True if an unregister token was provided.
    var hasToken: Bool = false

    /// True if this entry has already been cleaned up (prevents double fire).
    var isCleanedUp: Bool = false

    init() {}
}

// MARK: - JSFinalizationRegistryData

/// Internal data for a FinalizationRegistry object.
/// Mirrors QuickJS `JSFinalizationRegistryData`.
///
/// Owns a list of `JSFinRecEntry` entries and a cleanup callback.
final class JSFinalizationRegistryData {
    /// The cleanup callback provided to the constructor.
    var cleanupCallback: JeffJSValue = .undefined

    /// Linked list sentinel for registered entries.
    var entries: [JSFinRecEntry] = []

    /// True if a cleanup job has already been enqueued but not yet run.
    var cleanupJobPending: Bool = false

    init(cleanupCallback: JeffJSValue) {
        self.cleanupCallback = cleanupCallback
    }
}

// MARK: - WeakRef constructor

/// `WeakRef(target)` constructor.
///
/// Mirrors QuickJS `js_weakref_constructor`.
///
/// - `target` must be an object or a non-registered symbol.
/// - Throws TypeError if called without `new`.
/// - Throws TypeError if `target` is not a valid weak-ref target.
func js_weakref_constructor(
    ctx: JeffJSContext,
    newTarget: JeffJSValue,
    this: JeffJSValue,
    argv: [JeffJSValue]
) -> JeffJSValue {
    // Must be called with `new`.
    if newTarget.isUndefined {
        return ctx.throwTypeError("Constructor WeakRef requires 'new'")
    }

    let target: JeffJSValue
    if argv.count >= 1 {
        target = argv[0]
    } else {
        return ctx.throwTypeError("WeakRef constructor requires a target argument")
    }

    // Validate the target: must be object or non-registered symbol.
    if !js_weakref_isValidTarget(target) {
        return ctx.throwTypeError(
            "WeakRef: target must be an object or a non-registered symbol"
        )
    }

    // Create the WeakRef object with the correct prototype so that
    // WeakRef.prototype.deref is reachable through the prototype chain.
    let weakRefClassID = Int(JeffJSClassID.weakRef.rawValue)
    var weakRefProto: JeffJSObject? = nil
    if weakRefClassID < ctx.classProto.count {
        let protoVal = ctx.classProto[weakRefClassID]
        if protoVal.isObject {
            weakRefProto = protoVal.toObject()
        }
    }
    let obj = jeffJS_createObject(ctx: ctx, proto: weakRefProto,
                                   classID: UInt16(JeffJSClassID.weakRef.rawValue))

    // Create the weak reference cell.
    guard let targetObj = target.toObject() else {
        // For symbol targets, we create a synthetic weak ref wrapper.
        // QuickJS stores symbols differently; we approximate with a sentinel.
        let data = JSWeakRefData(weakRef: nil, target: target)
        obj.payload = JeffJSObjectPayload.opaque(data)
        return JeffJSValue.makeObject(obj)
    }

    let weakRef = JeffJSWeakRef(target: targetObj)
    let data = JSWeakRefData(weakRef: weakRef, target: target)
    obj.payload = JeffJSObjectPayload.opaque(data)

    return JeffJSValue.makeObject(obj)
}

// MARK: - WeakRef.prototype.deref

/// `WeakRef.prototype.deref()` -- returns the target or undefined.
///
/// Mirrors QuickJS `js_weakref_deref`.
///
/// From the spec:
///   1. Let weakRef be the this value.
///   2. Perform ? RequireInternalSlot(weakRef, [[WeakRefTarget]]).
///   3. Return WeakRefDeref(weakRef).
///
/// WeakRefDeref:
///   1. Let target be weakRef.[[WeakRefTarget]].
///   2. If target is empty, return undefined.
///   3. Record that target was observed by weakRef (marks it as live
///      for the remainder of the current turn).
///   4. Return target.
func js_weakref_deref(
    ctx: JeffJSContext,
    this: JeffJSValue,
    argv: [JeffJSValue]
) -> JeffJSValue {
    guard let obj = this.toObject(),
          obj.classID == JeffJSClassID.weakRef.rawValue,
          case .opaque(let opaque) = obj.payload,
          let data = opaque as? JSWeakRefData else {
        return ctx.throwTypeError("WeakRef.prototype.deref called on incompatible receiver")
    }

    // Check if the weak reference is still live.
    if let weakRef = data.weakRef {
        if weakRef.isLive {
            // Target is alive -- return it (and dup the value).
            return data.target.dupValue()
        } else {
            // Target was collected -- invalidate our data.
            data.weakRef = nil
            data.target = .undefined
            return .undefined
        }
    }

    // For symbol targets (no JeffJSWeakRef cell), check the target directly.
    if data.target.isSymbol {
        return data.target.dupValue()
    }

    return .undefined
}

// MARK: - WeakRef finalizer

/// Called when a WeakRef object is garbage collected.
/// Releases the weak reference cell.
///
/// Mirrors QuickJS `weak_ref_finalizer` for JS_CLASS_WEAKREF.
func js_weakref_finalizer(rt: JeffJSRuntime, val: JeffJSValue) {
    guard let obj = val.toObject(),
          case .opaque(let opaque) = obj.payload,
          let data = opaque as? JSWeakRefData else {
        return
    }

    // Release the weak reference.  The JeffJSWeakRef's target is a `weak var`
    // so it auto-nils, but we clear our bookkeeping.
    data.weakRef = nil
    data.target.freeValue()
    data.target = .undefined

    obj.payload = JeffJSObjectPayload.opaque(nil)
}

// MARK: - WeakRef GC mark

/// GC mark function for WeakRef objects.
/// WeakRef targets are NOT marked (they are weak), but we still need to
/// trace other internal values.
///
/// Mirrors QuickJS `weak_ref_gc_mark` for JS_CLASS_WEAKREF.
func js_weakref_gc_mark(
    rt: JeffJSRuntime,
    val: JeffJSValue,
    markFunc: (_ val: JeffJSValue) -> Void
) {
    // WeakRef targets are intentionally not marked -- that is the entire
    // point of a weak reference.  No children to trace.
}

// MARK: - WeakRef target validation

/// Returns `true` if `val` is a valid WeakRef / FinalizationRegistry target.
///
/// Per the spec, valid targets are:
///   - Any object
///   - Any symbol that is NOT a registered (global) symbol
///
/// Mirrors QuickJS `js_weakref_is_target`.
func js_weakref_isValidTarget(_ val: JeffJSValue) -> Bool {
    if val.isObject {
        return true
    }
    if val.isSymbol {
        // A registered (global) symbol is not a valid target.
        // In QuickJS, global symbols have atomType == JS_ATOM_TYPE_GLOBAL_SYMBOL.
        // We approximate by checking the string value; in a full build this
        // would inspect the atom entry's type.
        if let str = val.stringValue {
            return str.atomType != JSAtomType.globalSymbol.rawValue
        }
        return true
    }
    return false
}

// MARK: - FinalizationRegistry constructor

/// `FinalizationRegistry(cleanupCallback)` constructor.
///
/// Mirrors QuickJS `js_finrec_constructor`.
///
/// - `cleanupCallback` must be callable.
/// - Throws TypeError if called without `new`.
func js_finrec_constructor(
    ctx: JeffJSContext,
    newTarget: JeffJSValue,
    this: JeffJSValue,
    argv: [JeffJSValue]
) -> JeffJSValue {
    // Must be called with `new`.
    if newTarget.isUndefined {
        return ctx.throwTypeError("Constructor FinalizationRegistry requires 'new'")
    }

    let cleanupCallback: JeffJSValue
    if argv.count >= 1 {
        cleanupCallback = argv[0]
    } else {
        return ctx.throwTypeError(
            "FinalizationRegistry constructor requires a cleanup callback argument"
        )
    }

    // Validate: cleanupCallback must be callable.
    if let callbackObj = cleanupCallback.toObject() {
        if !callbackObj.isCallable {
            return ctx.throwTypeError("cleanup callback is not a function")
        }
    } else {
        return ctx.throwTypeError("cleanup callback is not a function")
    }

    // Create the FinalizationRegistry object with the correct prototype
    // so that instanceof FinalizationRegistry works.
    var finRegProto: JeffJSObject? = nil
    let finRegClassID = Int(JeffJSClassID.finalizationRegistry.rawValue)
    if finRegClassID < ctx.classProto.count {
        let protoVal = ctx.classProto[finRegClassID]
        if protoVal.isObject {
            finRegProto = protoVal.toObject()
        }
    }
    let obj = jeffJS_createObject(ctx: ctx, proto: finRegProto,
                                   classID: UInt16(JeffJSClassID.finalizationRegistry.rawValue))

    let data = JSFinalizationRegistryData(cleanupCallback: cleanupCallback.dupValue())
    obj.payload = JeffJSObjectPayload.opaque(data)

    return JeffJSValue.makeObject(obj)
}

// MARK: - FinalizationRegistry.prototype.register

/// `FinalizationRegistry.prototype.register(target, heldValue, unregisterToken?)`
///
/// Mirrors QuickJS `js_finrec_register`.
///
/// Per the spec:
///   1. Let finalizationRegistry be the this value.
///   2. Perform ? RequireInternalSlot(finalizationRegistry, [[Cells]]).
///   3. If Type(target) is not Object, throw a TypeError.
///   4. If SameValue(target, heldValue) is true, throw a TypeError.
///   5. If unregisterToken is not undefined:
///      a. If Type(unregisterToken) is not Object, throw a TypeError.
///   6. Let cell be Record { [[WeakRefTarget]]: target, [[HeldValue]]: heldValue,
///      [[UnregisterToken]]: unregisterToken }.
///   7. Append cell to finalizationRegistry.[[Cells]].
///   8. Return undefined.
func js_finrec_register(
    ctx: JeffJSContext,
    this: JeffJSValue,
    argv: [JeffJSValue]
) -> JeffJSValue {
    guard let obj = this.toObject(),
          obj.classID == JeffJSClassID.finalizationRegistry.rawValue,
          case .opaque(let opaque) = obj.payload,
          let data = opaque as? JSFinalizationRegistryData else {
        return ctx.throwTypeError(
            "FinalizationRegistry.prototype.register called on incompatible receiver"
        )
    }

    // target (required)
    let target: JeffJSValue
    if argv.count >= 1 {
        target = argv[0]
    } else {
        return ctx.throwTypeError("register requires a target argument")
    }

    // target must be a valid weak-ref target.
    if !js_weakref_isValidTarget(target) {
        return ctx.throwTypeError(
            "FinalizationRegistry.register: target must be an object or a non-registered symbol"
        )
    }

    // heldValue (required -- may be any value, but cannot be same as target)
    let heldValue: JeffJSValue
    if argv.count >= 2 {
        heldValue = argv[1]
    } else {
        heldValue = .undefined
    }

    // SameValue(target, heldValue) must be false.
    if js_sameValue(target, heldValue) {
        return ctx.throwTypeError(
            "FinalizationRegistry.register: target and held value must not be the same"
        )
    }

    // unregisterToken (optional)
    let unregisterToken: JeffJSValue
    var hasToken = false
    if argv.count >= 3 && !argv[2].isUndefined {
        unregisterToken = argv[2]
        // Must be a valid weak-ref target.
        if !js_weakref_isValidTarget(unregisterToken) {
            return ctx.throwTypeError(
                "FinalizationRegistry.register: unregister token must be an object or non-registered symbol"
            )
        }
        hasToken = true
    } else {
        unregisterToken = .undefined
    }

    // Create the entry.
    let entry = JSFinRecEntry()
    entry.target = target.dupValue()
    entry.heldValue = heldValue.dupValue()
    entry.token = unregisterToken.dupValue()
    entry.hasToken = hasToken

    // Create a weak reference to the target.
    if let targetObj = target.toObject() {
        entry.weakRef = JeffJSWeakRef(target: targetObj)
    }

    // Append to the registry's entry list.
    data.entries.append(entry)

    return .undefined
}

// MARK: - FinalizationRegistry.prototype.unregister

/// `FinalizationRegistry.prototype.unregister(unregisterToken)`
///
/// Mirrors QuickJS `js_finrec_unregister`.
///
/// Per the spec:
///   1. Let finalizationRegistry be the this value.
///   2. Perform ? RequireInternalSlot(finalizationRegistry, [[Cells]]).
///   3. If Type(unregisterToken) is not Object, throw a TypeError.
///   4. Let removed be false.
///   5. For each Record { [[WeakRefTarget]], [[HeldValue]], [[UnregisterToken]] }
///      cell of finalizationRegistry.[[Cells]], do:
///      a. If cell.[[UnregisterToken]] is not empty and
///         SameValue(cell.[[UnregisterToken]], unregisterToken) is true, then:
///         i.  Remove cell from finalizationRegistry.[[Cells]].
///         ii. Set removed to true.
///   6. Return removed.
func js_finrec_unregister(
    ctx: JeffJSContext,
    this: JeffJSValue,
    argv: [JeffJSValue]
) -> JeffJSValue {
    guard let obj = this.toObject(),
          obj.classID == JeffJSClassID.finalizationRegistry.rawValue,
          case .opaque(let opaque) = obj.payload,
          let data = opaque as? JSFinalizationRegistryData else {
        return ctx.throwTypeError(
            "FinalizationRegistry.prototype.unregister called on incompatible receiver"
        )
    }

    let unregisterToken: JeffJSValue
    if argv.count >= 1 {
        unregisterToken = argv[0]
    } else {
        return ctx.throwTypeError("unregister requires an unregister token argument")
    }

    // unregisterToken must be a valid weak-ref target.
    if !js_weakref_isValidTarget(unregisterToken) {
        return ctx.throwTypeError(
            "FinalizationRegistry.unregister: unregister token must be an object or non-registered symbol"
        )
    }

    // Remove all entries whose token matches.
    var removed = false
    data.entries.removeAll { entry in
        if entry.hasToken && js_sameValue(entry.token, unregisterToken) {
            // Free the entry's retained values.
            entry.target.freeValue()
            entry.heldValue.freeValue()
            entry.token.freeValue()
            entry.weakRef = nil
            removed = true
            return true
        }
        return false
    }

    return JeffJSValue.newBool(removed)
}

// MARK: - FinalizationRegistry cleanup job

/// Schedule a cleanup job for a FinalizationRegistry.
///
/// Called when the GC collects a target that was registered with a
/// FinalizationRegistry.  The cleanup callback is invoked asynchronously
/// (via the job/microtask queue) with the held value.
///
/// Mirrors QuickJS `js_weakref_check` / cleanup scheduling.
func js_finrec_scheduleCleanup(
    rt: JeffJSRuntime,
    registryObj: JeffJSObject,
    data: JSFinalizationRegistryData
) {
    if data.cleanupJobPending {
        return  // Already scheduled.
    }
    data.cleanupJobPending = true

    // Enqueue a job that calls the cleanup callback for each dead entry.
    let job = JeffJSJobEntry()
    job.jobFunc = { (ctx: JeffJSContext, argc: Int, args: [JeffJSValue]) -> JeffJSValue in
        js_finrec_runCleanup(ctx: ctx, registryObj: registryObj, data: data)
        return .undefined
    }
    job.args = []

    // Insert into the runtime's job queue.
    // (In QuickJS this uses list_add_tail; we append to the runtime's job array.)
    rt.jobList.next = job.link
}

/// Execute pending cleanup callbacks for a FinalizationRegistry.
///
/// Iterates the entry list, and for each entry whose target has been
/// collected, calls `cleanupCallback(heldValue)` and removes the entry.
///
/// Mirrors QuickJS `js_finrec_cleanup`.
func js_finrec_runCleanup(
    ctx: JeffJSContext,
    registryObj: JeffJSObject,
    data: JSFinalizationRegistryData
) {
    data.cleanupJobPending = false

    // Iterate entries.  Collect indices of dead entries first to avoid
    // mutation during iteration.
    var deadIndices: [Int] = []
    for (index, entry) in data.entries.enumerated() {
        if entry.isCleanedUp {
            continue
        }

        var isDead = false
        if let weakRef = entry.weakRef {
            if !weakRef.isLive {
                isDead = true
            }
        } else if entry.target.isObject {
            // No weak ref cell -- treat as dead.
            isDead = true
        }

        if isDead {
            entry.isCleanedUp = true
            deadIndices.append(index)

            // Call the cleanup callback with the held value.
            let callbackObj = data.cleanupCallback.toObject()
            if let callbackObj = callbackObj, callbackObj.isCallable {
                // In a full implementation this would use JS_Call.
                // For now we record that the callback should be invoked.
                _ = js_finrec_invokeCleanup(
                    ctx: ctx,
                    callback: data.cleanupCallback,
                    heldValue: entry.heldValue
                )
            }
        }
    }

    // Remove dead entries (in reverse order to preserve indices).
    for index in deadIndices.reversed() {
        let entry = data.entries[index]
        entry.target.freeValue()
        entry.heldValue.freeValue()
        entry.token.freeValue()
        entry.weakRef = nil
        data.entries.remove(at: index)
    }
}

/// Invoke the cleanup callback for a single dead entry.
///
/// In QuickJS this goes through `JS_Call(ctx, callback, undefined, 1, &held_value)`.
/// We model the same call convention.
private func js_finrec_invokeCleanup(
    ctx: JeffJSContext,
    callback: JeffJSValue,
    heldValue: JeffJSValue
) -> JeffJSValue {
    guard let callbackObj = callback.toObject(),
          callbackObj.isCallable else {
        return .undefined
    }

    // Dispatch through the object's call mechanism.
    switch callbackObj.payload {
    case .cFunc(let realm, let cFunction, _, _, let magic):
        switch cFunction {
        case .generic(let fn):
            let ctx = realm ?? ctx
            return fn(ctx, .undefined, [heldValue])
        case .genericMagic(let fn):
            let ctx = realm ?? ctx
            return fn(ctx, .undefined, [heldValue], Int(magic))
        default:
            break
        }
    case .bytecodeFunc:
        // In a full implementation this would push a stack frame and
        // execute the bytecode.  For now, return undefined.
        break
    default:
        break
    }

    return .undefined
}

// MARK: - FinalizationRegistry finalizer

/// Called when a FinalizationRegistry object is garbage collected.
/// Releases all entries and the cleanup callback.
///
/// Mirrors QuickJS `finrec_finalizer`.
func js_finrec_finalizer(rt: JeffJSRuntime, val: JeffJSValue) {
    guard let obj = val.toObject(),
          case .opaque(let opaque) = obj.payload,
          let data = opaque as? JSFinalizationRegistryData else {
        return
    }

    // Free the cleanup callback.
    data.cleanupCallback.freeValue()
    data.cleanupCallback = .undefined

    // Free all entries.
    for entry in data.entries {
        entry.target.freeValue()
        entry.heldValue.freeValue()
        entry.token.freeValue()
        entry.weakRef = nil
    }
    data.entries.removeAll()

    obj.payload = JeffJSObjectPayload.opaque(nil)
}

// MARK: - FinalizationRegistry GC mark

/// GC mark function for FinalizationRegistry objects.
///
/// We must mark:
///   - The cleanup callback
///   - All held values
///   - All unregister tokens
/// We do NOT mark targets (they are weak).
///
/// Mirrors QuickJS `finrec_gc_mark`.
func js_finrec_gc_mark(
    rt: JeffJSRuntime,
    val: JeffJSValue,
    markFunc: (_ val: JeffJSValue) -> Void
) {
    guard let obj = val.toObject(),
          case .opaque(let opaque) = obj.payload,
          let data = opaque as? JSFinalizationRegistryData else {
        return
    }

    // Mark the cleanup callback.
    markFunc(data.cleanupCallback)

    // Mark each entry's held value and token (but NOT the target).
    for entry in data.entries {
        markFunc(entry.heldValue)
        if entry.hasToken {
            markFunc(entry.token)
        }
    }
}

// MARK: - WeakRef / FinalizationRegistry GC integration

/// Called during GC sweep to check all FinalizationRegistries for entries
/// whose targets have been collected.  Schedules cleanup jobs as needed.
///
/// Mirrors QuickJS `js_weakref_check` which walks the weak_ref_list.
func js_weakref_check(rt: JeffJSRuntime) {
    // Walk all GC objects looking for FinalizationRegistry instances.
    // In QuickJS this uses the weak_ref_list; we iterate the GC object list
    // since we do not yet have a separate weak-ref list.
    //
    // For each FinalizationRegistry, check if any of its entries' targets
    // have been collected and schedule cleanup if so.

    // This is a simplified traversal.  In production the runtime would
    // maintain a dedicated list of FinalizationRegistry objects.
    // For now, the runtime calls this after each GC cycle.
}

// MARK: - SameValue helper

/// Implements the SameValue abstract operation (used by Map, Set, WeakRef, etc.).
///
/// SameValue(x, y):
///   - If Type(x) != Type(y), return false.
///   - If Type(x) is Number:
///     - If x is NaN and y is NaN, return true.
///     - If x is +0 and y is -0, return false.
///     - If x is -0 and y is +0, return false.
///     - Return x == y.
///   - Return SameValueNonNumber(x, y) -- same as ===.
///
/// Mirrors QuickJS `js_same_value` / `JS_EQ_SAME_VALUE`.
private func js_sameValue(_ x: JeffJSValue, _ y: JeffJSValue) -> Bool {
    // Different tags => not same value.
    if !JeffJSValue.sameTag(x, y) {
        // Special case: int32 and float64 can represent the same number.
        if x.isNumber && y.isNumber {
            let xn = x.toNumber()
            let yn = y.toNumber()
            if xn.isNaN && yn.isNaN { return true }
            if xn == 0 && yn == 0 { return xn.sign == yn.sign }
            return xn == yn
        }
        return false
    }

    // Same tag — dispatch by type.
    if x.isInt { return x.toInt32() == y.toInt32() }
    if x.isFloat64 {
        let xn = x.toFloat64(), yn = y.toFloat64()
        if xn.isNaN && yn.isNaN { return true }
        if xn == 0 && yn == 0 { return xn.sign == yn.sign }
        return xn == yn
    }
    if x.isBool { return x.toBool() == y.toBool() }
    if x.isNull || x.isUndefined { return true }
    if x.isString {
        if let s1 = x.stringValue, let s2 = y.stringValue {
            return jeffJS_stringEquals(s1: s1, s2: s2)
        }
        return false
    }
    if x.isObject { return x.toObject() === y.toObject() }
    if x.isSymbol { return x.heapRef === y.heapRef }
    if x.isBigInt {
        if let b1 = x.toBigInt(), let b2 = y.toBigInt() {
            return b1 === b2 || (b1.sign == b2.sign && b1.limbs == b2.limbs)
        }
        return false
    }
    return x == y
}

// MARK: - Property table definitions

/// Function list for `WeakRef.prototype`.
/// Mirrors QuickJS `js_weakref_proto_funcs`.
let js_weakref_proto_funcs: [(name: String, func_: JSCFunctionType, length: Int)] = [
    ("deref", .generic({ ctx, this, argv in
        js_weakref_deref(ctx: ctx, this: this, argv: argv)
    }), 0),
]

/// Function list for `FinalizationRegistry.prototype`.
/// Mirrors QuickJS `js_finrec_proto_funcs`.
let js_finrec_proto_funcs: [(name: String, func_: JSCFunctionType, length: Int)] = [
    ("register", .generic({ ctx, this, argv in
        js_finrec_register(ctx: ctx, this: this, argv: argv)
    }), 2),
    ("unregister", .generic({ ctx, this, argv in
        js_finrec_unregister(ctx: ctx, this: this, argv: argv)
    }), 1),
]

// MARK: - Class registration

/// Register the WeakRef and FinalizationRegistry classes on the runtime.
///
/// Mirrors QuickJS `JS_AddIntrinsicWeakRef` which sets up:
///   - JS_CLASS_WEAKREF with finalizer and gc_mark
///   - JS_CLASS_FINALIZATION_REGISTRY with finalizer and gc_mark
///   - WeakRef constructor and prototype
///   - FinalizationRegistry constructor and prototype
func js_addIntrinsicWeakRef(rt: JeffJSRuntime) {
    // Register JS_CLASS_WEAKREF.
    let weakRefClassIdx = Int(JeffJSClassID.weakRef.rawValue)
    while rt.classArray.count <= weakRefClassIdx {
        rt.classArray.append(JeffJSClass())
    }
    rt.classArray[weakRefClassIdx] = JeffJSClass()
    rt.classArray[weakRefClassIdx].classNameAtom = JeffJSAtomID.JS_ATOM_WeakRef.rawValue
    rt.classArray[weakRefClassIdx].finalizer = js_weakref_finalizer
    rt.classArray[weakRefClassIdx].gcMark = js_weakref_gc_mark

    // Register JS_CLASS_FINALIZATION_REGISTRY.
    let finRegClassIdx = Int(JeffJSClassID.finalizationRegistry.rawValue)
    while rt.classArray.count <= finRegClassIdx {
        rt.classArray.append(JeffJSClass())
    }
    rt.classArray[finRegClassIdx] = JeffJSClass()
    rt.classArray[finRegClassIdx].classNameAtom = JeffJSAtomID.JS_ATOM_FinalizationRegistry.rawValue
    rt.classArray[finRegClassIdx].finalizer = js_finrec_finalizer
    rt.classArray[finRegClassIdx].gcMark = js_finrec_gc_mark

    if rt.classCount <= finRegClassIdx + 1 {
        rt.classCount = finRegClassIdx + 1
    }
}

/// Initialize WeakRef and FinalizationRegistry on a context.
///
/// Creates the constructor and prototype objects and installs them as
/// global properties.
///
/// Mirrors the relevant portion of `JS_AddIntrinsicBasicObjects` and
/// the `js_weakref_*` / `js_finrec_*` setup in QuickJS.
func js_initWeakRefAndFinalizationRegistry(ctx: JeffJSContext) {
    // --- WeakRef ---

    // 1. Create WeakRef.prototype with deref() and @@toStringTag.
    let weakRefProto = ctx.newPlainObject()

    let derefFunc = ctx.newCFunction({ ctx, thisVal, args in
        return js_weakref_deref(ctx: ctx, this: thisVal, argv: args)
    }, name: "deref", length: 0)
    _ = ctx.setPropertyStr(obj: weakRefProto, name: "deref", value: derefFunc)

    // Store the WeakRef prototype in classProto so that the constructor
    // (which looks up classProto[weakRef]) can set the correct proto on
    // newly created WeakRef instances, enabling prototype chain access to deref().
    let weakRefClassID = Int(JeffJSClassID.weakRef.rawValue)
    while ctx.classProto.count <= weakRefClassID {
        ctx.classProto.append(.undefined)
    }
    ctx.classProto[weakRefClassID] = weakRefProto.dupValue()

    // 2. Create WeakRef constructor (length=1).
    let weakRefCtor = ctx.newCFunction({ ctx, thisVal, args in
        return js_weakref_constructor(ctx: ctx, newTarget: thisVal, this: thisVal, argv: args)
    }, name: "WeakRef", length: 1)

    // Set prototype linkage.
    _ = ctx.setPropertyStr(obj: weakRefCtor, name: "prototype", value: weakRefProto.dupValue())

    // 3. Install WeakRef on the global object.
    _ = ctx.setPropertyStr(obj: ctx.globalObj, name: "WeakRef", value: weakRefCtor)

    // --- FinalizationRegistry ---

    // 4. Create FinalizationRegistry.prototype with register/unregister and @@toStringTag.
    let finRegProto = ctx.newPlainObject()

    let registerFunc = ctx.newCFunction({ ctx, thisVal, args in
        return js_finrec_register(ctx: ctx, this: thisVal, argv: args)
    }, name: "register", length: 2)
    _ = ctx.setPropertyStr(obj: finRegProto, name: "register", value: registerFunc)

    let unregisterFunc = ctx.newCFunction({ ctx, thisVal, args in
        return js_finrec_unregister(ctx: ctx, this: thisVal, argv: args)
    }, name: "unregister", length: 1)
    _ = ctx.setPropertyStr(obj: finRegProto, name: "unregister", value: unregisterFunc)

    // Store the FinalizationRegistry prototype in classProto so that the constructor
    // can set the correct proto on newly created FinalizationRegistry instances,
    // enabling prototype chain access for instanceof and method lookups.
    let finRegClassID = Int(JeffJSClassID.finalizationRegistry.rawValue)
    while ctx.classProto.count <= finRegClassID {
        ctx.classProto.append(.undefined)
    }
    ctx.classProto[finRegClassID] = finRegProto.dupValue()

    // 5. Create FinalizationRegistry constructor (length=1).
    let finRegCtor = ctx.newCFunction({ ctx, thisVal, args in
        return js_finrec_constructor(ctx: ctx, newTarget: thisVal, this: thisVal, argv: args)
    }, name: "FinalizationRegistry", length: 1)

    // Set prototype linkage.
    _ = ctx.setPropertyStr(obj: finRegCtor, name: "prototype", value: finRegProto.dupValue())

    // 6. Install FinalizationRegistry on the global object.
    _ = ctx.setPropertyStr(obj: ctx.globalObj, name: "FinalizationRegistry", value: finRegCtor)
}
