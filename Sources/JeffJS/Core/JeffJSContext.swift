// JeffJSContext.swift
// JeffJS - 1:1 Swift port of QuickJS JavaScript engine
//
// Port of JSContext from QuickJS. A context represents an isolated JS execution
// environment with its own global object, prototypes, and intrinsics, but sharing
// the atom table, GC, and class system with its parent runtime.
//
// QuickJS source reference: quickjs.c — struct JSContext and all JS_* context functions.

import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif

// MARK: - JeffJSContext

/// A JavaScript execution context. Owns the global object, class prototypes,
/// intrinsic constructors, and loaded modules.
///
/// Multiple contexts can share a single JeffJSRuntime (e.g., for iframe isolation),
/// but each context has independent global scope and prototype chains.
///
/// Mirrors QuickJS `JSContext` from quickjs.c exactly.
///
/// Usage:
/// ```swift
/// let rt = JeffJSRuntime()
/// let ctx = rt.newContext()
/// let result = ctx.eval(input: "2 + 3", filename: "<eval>", evalFlags: JS_EVAL_TYPE_GLOBAL)
/// if result.isException {
///     let err = ctx.getException()
///     // handle error...
/// }
/// ctx.free()
/// ```
public final class JeffJSContext: JeffJSTokenizerContext {

    /// Conforms to JeffJSTokenizerContext so the parser can intern atoms
    /// directly into the runtime's atom table (instead of a separate namespace).
    func findAtom(_ name: String) -> UInt32 {
        return rt.findAtom(name)
    }


    // MARK: - GC Header

    /// GC object header so the context itself can be tracked by the GC.
    /// In QuickJS, JSContext embeds a JSGCObjectHeader as its first field.
    var header: JeffJSGCObjectHeader

    /// The runtime that owns this context.
    /// Strong reference ensures the runtime stays alive while any background thread
    /// holds a reference to this context (e.g. polyfill loading on DispatchQueue.global).
    /// The retain cycle (runtime → contextList → ... and context → rt) is broken
    /// explicitly by free() and teardown().
    var rt: JeffJSRuntime

    /// Link node for insertion into the runtime's contextList.
    var link: ListNode

    // MARK: - Pre-allocated Shapes

    /// Shape for newly created plain arrays (class Array).
    var arrayShape: JeffJSShape?
    /// Shape for the `arguments` object (non-strict).
    var argumentsShape: JeffJSShape?
    /// Shape for the `arguments` object (strict / mapped).
    var mappedArgumentsShape: JeffJSShape?
    /// Shape for RegExp result objects.
    var regexpShape: JeffJSShape?
    /// Shape for RegExp result objects with indices.
    var regexpResultShape: JeffJSShape?

    // MARK: - Class Prototypes

    /// Prototype objects for each class, indexed by JSClassID.rawValue.
    /// classProto[JS_CLASS_OBJECT] is Object.prototype, etc.
    var classProto: [JeffJSValue]

    /// Function.prototype — cached for fast access.
    var functionProto: JeffJSValue
    /// Function constructor.
    var functionCtor: JeffJSValue
    /// Array constructor.
    var arrayCtor: JeffJSValue
    /// RegExp constructor.
    var regexpCtor: JeffJSValue
    /// Promise constructor.
    var promiseCtor: JeffJSValue
    /// Native error prototypes (EvalError, RangeError, ReferenceError, SyntaxError,
    /// TypeError, URIError, InternalError, AggregateError).
    /// Indexed by JSErrorEnum.rawValue.
    var nativeErrorProto: [JeffJSValue]
    /// Iterator constructor.
    var iteratorCtor: JeffJSValue
    /// AsyncIterator.prototype.
    var asyncIteratorProto: JeffJSValue
    /// Array.prototype.values — cached because it's also used as %ArrayIteratorPrototype%[@@iterator].
    var arrayProtoValues: JeffJSValue
    /// Array.prototype.push — cached object pointer for interpreter fast-path identity check.
    /// Set during JeffJSBuiltinArray.addIntrinsic(). Used by call_method to skip the full
    /// callFunction dispatch when pushing a single element onto a dense array.
    var arrayProtoPushObj: JeffJSObject?
    /// %ThrowTypeError% — a frozen function that always throws TypeError.
    /// Used for arguments.callee in strict mode, etc.
    var throwTypeError: JeffJSValue
    /// The eval function object.
    var evalObj: JeffJSValue

    // MARK: - Global Objects

    /// The global object (what `globalThis` refers to).
    var globalObj: JeffJSValue
    /// The global variable object. In browsers, this is the same as globalObj.
    /// In QuickJS, it can differ when using scoped globals.
    var globalVarObj: JeffJSValue

    // MARK: - Random State

    /// xorshift64* state for Math.random().
    /// Seeded from the system clock at context creation.
    var randomState: UInt64

    // MARK: - Interrupt Counter

    /// Counts down from JS_INTERRUPT_COUNTER_INIT. When it hits zero,
    /// the interrupt handler is called (if set) and the counter resets.
    var interruptCounter: Int

    // MARK: - Loaded Modules

    /// Linked list of loaded ES modules for this context.
    var loadedModules: ListHead

    // MARK: - Compiler / Evaluator Hooks

    /// RegExp compiler. Takes (ctx, pattern, flags) -> compiled regexp or exception.
    var compileRegexp: ((JeffJSContext, JeffJSValue, JeffJSValue) -> JeffJSValue)?
    /// Internal eval function. Takes (ctx, thisObj, input, filename, line, evalFlags) -> result.
    var evalInternalHook: ((JeffJSContext, JeffJSValue, String, String, Int, Int) -> JeffJSValue)?

    // MARK: - User Data

    /// User-defined opaque data attached to the context.
    var userOpaque: Any?

    // MARK: - Async Function Suspension

    /// When an async function's `await` encounters a pending Promise, the
    /// interpreter saves its state here and exits. A `.then()` callback on
    /// the awaited Promise will later resume execution via `resumeAsyncFunction`.
    struct AsyncSavedEntry {
        var saved: GeneratorSavedState
        var resolve: JeffJSValue   // the async function's Promise resolve
        var reject: JeffJSValue    // the async function's Promise reject
    }
    var asyncSavedStates: [Int: AsyncSavedEntry] = [:]
    private var nextAsyncStateID: Int = 1

    /// The async function's resolve/reject, threaded through callFunction → callInternal → await_.
    var _asyncResolve: JeffJSValue = .undefined
    var _asyncReject: JeffJSValue = .undefined
    /// Set to true by the await_ opcode when it suspends.
    var _asyncSuspended: Bool = false

    func storeAsyncState(_ entry: AsyncSavedEntry) -> Int {
        let id = nextAsyncStateID
        nextAsyncStateID += 1
        asyncSavedStates[id] = entry
        return id
    }

    /// Resume an async function from a saved await suspension.
    /// Called by the `.then()` callback registered on the awaited Promise.
    func resumeAsyncFunction(stateID: Int, value: JeffJSValue, isRejection: Bool) {
        guard let entry = asyncSavedStates.removeValue(forKey: stateID) else { return }

        // Set up context for potential nested await
        _asyncResolve = entry.resolve
        _asyncReject = entry.reject
        _asyncSuspended = false

        let result = JeffJSInterpreter.callInternal(
            ctx: self,
            funcObj: entry.saved.funcObj,
            thisVal: entry.saved.thisVal,
            args: [],
            flags: JS_CALL_FLAG_GENERATOR,
            resumeState: entry.saved,
            resumeValue: isRejection ? .undefined : value,
            resumeCompletionType: isRejection ? 2 : 0)

        if _asyncSuspended {
            // Hit another await — new callbacks already registered, nothing to do
            return
        }
        // Async function completed — resolve or reject its Promise
        if result.isException {
            let exc = getException()
            _ = call(entry.reject, this: .undefined, args: [exc])
        } else {
            _ = call(entry.resolve, this: .undefined, args: [result])
        }
        _ = rt.executePendingJobs()
    }

    /// Diagnostic: bytecode size from last eval (for debugging pipeline)
    var lastBytecodeSize: Int = 0
    /// Cumulative bytecode bytes compiled across all evals in this context.
    var totalBytecodeSize: Int = 0
    /// Number of bytecode cache hits (evals that reused compiled bytecode).
    var bytecodeCacheHits: Int = 0

    /// Clear this context's runtime bytecode cache.
    func clearBytecodeCache() {
        rt.bytecodeCache.clear()
    }

    // MARK: - Internal State

    /// True if the standard intrinsics have been added.
    private var intrinsicsAdded: Bool = false

    /// Current call stack frame. Used by the interpreter to save/restore frames.
    /// Stored directly on the context for O(1) access (previously used a global
    /// dictionary keyed by ObjectIdentifier, which added dictionary-lookup overhead
    /// on every frame access in the hot interpreter loop).
    var currentFrame: JeffJSStackFrame? = nil

    /// Whether the one-time Math builtin fixup has been applied for this context.
    var mathFixupApplied: Bool = false

    // MARK: - Initialization

    /// Creates a new JS context owned by the given runtime.
    /// Mirrors `JS_NewContext()` from QuickJS.
    ///
    /// When `addIntrinsics` is true (the default), all standard built-in objects
    /// are initialized (Object, Function, Array, Error, Number, String, Boolean,
    /// Symbol, BigInt, RegExp, JSON, Map, Set, Promise, Proxy, Reflect,
    /// TypedArrays, generators, async functions, eval, etc.).
    ///
    /// When `addIntrinsics` is false, only a bare global object is created.
    /// You must manually call `addIntrinsic*()` methods.
    ///
    /// - Parameters:
    ///   - rt: The parent runtime.
    ///   - addIntrinsics: Whether to add standard intrinsics (default: true).
    init(rt: JeffJSRuntime, addIntrinsics: Bool = true) {
        // Set the active runtime so all objects created during init get the back-pointer
        JeffJSGCObjectHeader.activeRuntime = rt
        self.rt = rt
        self.header = JeffJSGCObjectHeader()
        self.header.gcObjType = .jsObject
        self.link = ListNode()

        // Initialize prototype arrays
        let classCount = rt.classCount
        self.classProto = [JeffJSValue](repeating: .null, count: classCount)

        // Initialize cached values to undefined/null
        self.functionProto = .JS_UNDEFINED
        self.functionCtor = .JS_UNDEFINED
        self.arrayCtor = .JS_UNDEFINED
        self.regexpCtor = .JS_UNDEFINED
        self.promiseCtor = .JS_UNDEFINED
        self.nativeErrorProto = [JeffJSValue](repeating: .null,
                                              count: JSErrorEnum.JS_NATIVE_ERROR_COUNT.rawValue)
        self.iteratorCtor = .JS_UNDEFINED
        self.asyncIteratorProto = .JS_UNDEFINED
        self.arrayProtoValues = .JS_UNDEFINED
        self.throwTypeError = .JS_UNDEFINED
        self.evalObj = .JS_UNDEFINED

        // Create the global object
        self.globalObj = .JS_UNDEFINED
        self.globalVarObj = .JS_UNDEFINED

        // Pre-allocated shapes
        self.arrayShape = nil
        self.argumentsShape = nil
        self.mappedArgumentsShape = nil
        self.regexpShape = nil
        self.regexpResultShape = nil

        // Random state — seed from current time
        self.randomState = UInt64(bitPattern: Int64(Date().timeIntervalSince1970 * 1_000_000))
        if self.randomState == 0 { self.randomState = 1 }  // xorshift requires non-zero

        // Interrupt counter
        self.interruptCounter = JS_INTERRUPT_COUNTER_INIT

        // Modules
        self.loadedModules = ListHead()

        // Hooks
        self.compileRegexp = nil
        self.evalInternalHook = nil
        self.userOpaque = nil

        // Create the global object
        initGlobalObject()

        // Add standard intrinsics if requested
        if addIntrinsics {
            // Phase 1: Core inline intrinsics (creates global object, prototypes,
            // and placeholder constructors in the correct dependency order).
            addIntrinsicBaseObjects()
            addIntrinsicRegExp()
            addIntrinsicJSON()
            addIntrinsicProxy()
            addIntrinsicMapSet()
            addIntrinsicTypedArrays()
            addIntrinsicPromise()
            addIntrinsicEval()

            // Phase 2: Wire the detailed Builtin file implementations.
            // These overlay richer, spec-compliant methods on top of the
            // placeholder prototypes created above.
            //
            // Order follows QuickJS init sequence:
            //   1. Object (base of all objects)
            //   2. Function (needed for constructors)
            //   3. Error types (needed for throwing)
            //   4. Array
            //   5. Number, Boolean (wrappers)
            //   6. String
            //   7. Symbol
            //   8. Iterator helpers
            //   9. Date
            //  10. Global functions (parseInt, eval, URI encoding, etc.)
            JeffJSBuiltinObject.addIntrinsic(ctx: self)
            JeffJSBuiltinFunction.addIntrinsic(ctx: self)
            JeffJSBuiltinError.addIntrinsic(ctx: self)
            JeffJSBuiltinArray.addIntrinsic(ctx: self)
            JeffJSBuiltinNumber.addIntrinsic(ctx: self)
            JeffJSBuiltinBoolean.addIntrinsic(ctx: self)
            JeffJSBuiltinString.addIntrinsic(ctx: self)
            JeffJSBuiltinIterator.addIntrinsic(ctx: self)
            JeffJSBuiltinMap.addIntrinsic(ctx: self)
            JeffJSBuiltinJSON.addIntrinsic(ctx: self)
            JeffJSBuiltinPromise.addIntrinsic(ctx: self)
            JeffJSBuiltinGlobal.addIntrinsic(ctx: self)

            // Phase 3: Builtins that were entirely missing from the init sequence.
            // Math
            if let globalJSObj = globalObj.toObject() {
                jeffJS_initMath(ctx: self, globalObj: globalJSObj)
            }
            // Date
            if let globalJSObj = globalObj.toObject() {
                jeffJS_initDate(ctx: self, globalObj: globalJSObj)
            }

            // WeakRef and FinalizationRegistry
            js_initWeakRefAndFinalizationRegistry(ctx: self)

            // Ensure FinalizationRegistry's prototype is stored in classProto
            // so that jeffJS_createObject can set it on new instances (for instanceof).
            // js_initWeakRefAndFinalizationRegistry stores WeakRef's but not FinalizationRegistry's.
            let finRegClassID = Int(JeffJSClassID.finalizationRegistry.rawValue)
            while classProto.count <= finRegClassID {
                classProto.append(.undefined)
            }
            if classProto[finRegClassID].isUndefined || classProto[finRegClassID].isNull {
                let finRegCtor = getPropertyStr(obj: globalObj, name: "FinalizationRegistry")
                if finRegCtor.isObject {
                    let finRegProtoVal = getProperty(obj: finRegCtor, atom: JeffJSAtomID.JS_ATOM_prototype.rawValue)
                    if finRegProtoVal.isObject {
                        classProto[finRegClassID] = finRegProtoVal.dupValue()
                    }
                }
            }

            // Atomics
            js_addIntrinsicAtomics(ctx: self)

            // Phase 4: Ensure keyword-named and late-bound methods are on
            // their prototypes. Some methods whose names are JS keywords
            // (delete, for, finally) may not survive earlier registration
            // passes. Re-register them here as the final authority.
            fixUpKeywordNamedMethods()

            // Phase 5: One-time Math fixup (clz32, random).
            // Previously called on every callInternal entry — moved here so
            // it runs once during init instead of on every function call.
            ensureMathFixup()

            intrinsicsAdded = true
            rt.initComplete = true
        }
    }

    // MARK: - Context Lifecycle

    /// Frees the context and all associated resources.
    /// Mirrors `JS_FreeContext()` from QuickJS.
    ///
    /// After calling free(), the context must not be used.
    func free() {
        // Disable cascading frees during teardown. Individual refcount decrements
        // happen below; bulk deallocation is handled by runtime.free() → clearGCState().
        rt.initComplete = false

        // Free loaded modules
        loadedModules = ListHead()

        // Decrement refcounts for context-owned values.
        // Actual deallocation is handled by runtime.free() → clearGCState()
        // which nils out all strong references and lets ARC reclaim objects.
        for i in 0..<classProto.count {
            classProto[i].freeValue()
            classProto[i] = .null
        }

        // Free cached values
        functionProto.freeValue()
        functionCtor.freeValue()
        arrayCtor.freeValue()
        regexpCtor.freeValue()
        promiseCtor.freeValue()
        iteratorCtor.freeValue()
        asyncIteratorProto.freeValue()
        arrayProtoValues.freeValue()
        throwTypeError.freeValue()
        evalObj.freeValue()

        for i in 0..<nativeErrorProto.count {
            nativeErrorProto[i].freeValue()
        }

        // Free global objects
        globalObj.freeValue()
        globalVarObj.freeValue()

        // Reset all to undefined
        functionProto = .JS_UNDEFINED
        functionCtor = .JS_UNDEFINED
        arrayCtor = .JS_UNDEFINED
        regexpCtor = .JS_UNDEFINED
        promiseCtor = .JS_UNDEFINED
        iteratorCtor = .JS_UNDEFINED
        asyncIteratorProto = .JS_UNDEFINED
        arrayProtoValues = .JS_UNDEFINED
        throwTypeError = .JS_UNDEFINED
        evalObj = .JS_UNDEFINED
        globalObj = .JS_UNDEFINED
        globalVarObj = .JS_UNDEFINED

        // Free shapes
        arrayShape = nil
        argumentsShape = nil
        mappedArgumentsShape = nil
        regexpShape = nil
        regexpResultShape = nil
    }

    // MARK: - Eval

    /// Evaluates JavaScript source code.
    /// Mirrors `JS_Eval()` from QuickJS.
    ///
    /// - Parameters:
    ///   - input: The JavaScript source code string.
    ///   - filename: The filename for error messages and source maps.
    ///   - evalFlags: Eval flags (JS_EVAL_TYPE_GLOBAL, JS_EVAL_TYPE_MODULE, etc.).
    /// - Returns: The result value, or JS_EXCEPTION on error.
    func eval(input: String, filename: String, evalFlags: Int) -> JeffJSValue {
        let result = evalInternal(input: input, filename: filename, line: 0, evalFlags: evalFlags)
        // Safe point for GC — parsing and compilation are complete
        if rt.mallocState.mallocSize >= rt.mallocGCThreshold {
            runGC(rt)
        }
        return result
    }

    /// Executes pre-serialized JFBC bytecode directly, skipping parse and compile.
    /// Used for loading disk-cached polyfill bytecode.
    ///
    /// - Parameter data: Serialized JFBC bytecode bytes.
    /// - Returns: The result value, or JS_EXCEPTION on error. Returns JS_UNDEFINED if deserialization fails.
    func evalBytecode(_ data: [UInt8]) -> JeffJSValue {
        guard let fb = JeffJSBytecodeDeserializer.deserialize(data, rt: rt) else {
            return .JS_UNDEFINED
        }
        lastBytecodeSize = Self.totalBytecodeLen(fb)
        return executeBytecode(fb)
    }

    /// Evaluates a compiled function object.
    /// Mirrors `JS_EvalFunction()` from QuickJS.
    ///
    /// The function object is consumed (freed) by this call.
    ///
    /// - Parameter funcObj: A compiled function bytecode object.
    /// - Returns: The result value, or JS_EXCEPTION on error.
    func evalFunction(funcObj: JeffJSValue) -> JeffJSValue {
        let result = callFunction(funcObj, thisVal: globalObj, args: [])
        funcObj.freeValue()
        return result
    }

    // MARK: - Global Object

    /// Returns the global object, with its reference count incremented.
    /// Mirrors `JS_GetGlobalObject()` from QuickJS.
    ///
    /// - Returns: The global object (caller must free).
    func getGlobalObject() -> JeffJSValue {
        return globalObj.dupValue()
    }

    // MARK: - Object Creation

    /// Creates a new empty plain object.
    /// Mirrors `JS_NewObject()` from QuickJS.
    ///
    /// Equivalent to `new Object()` or `{}` in JavaScript.
    ///
    /// - Returns: A new JS object value, or JS_EXCEPTION on out-of-memory.
    func newObject() -> JeffJSValue {
        return newObjectClass(classID: JSClassID.JS_CLASS_OBJECT.rawValue)
    }

    /// Creates a new empty array.
    /// Mirrors `JS_NewArray()` from QuickJS.
    ///
    /// Equivalent to `new Array()` or `[]` in JavaScript.
    ///
    /// - Returns: A new JS array value, or JS_EXCEPTION on out-of-memory.
    func newArray() -> JeffJSValue {
        let obj = newObjectClass(classID: JSClassID.JS_CLASS_ARRAY.rawValue)
        if obj.isException { return obj }

        // Initialize the fast-array payload so setArrayElement works
        if let jsObj = obj.toObject() {
            jsObj.payload = .array(size: 0, values: [], count: 0)
            jsObj.fastArray = true
        }

        // Set initial length to 0
        let lengthAtom = JeffJSAtomID.JS_ATOM_length.rawValue
        _ = setPropertyInternal(
            obj: obj, atom: lengthAtom,
            value: .newInt32(0),
            flags: JS_PROP_WRITABLE
        )
        return obj
    }


    /// Creates a new JS object with the given class ID.
    /// Mirrors `JS_NewObjectClass()` from QuickJS.
    ///
    /// The object's prototype is set to `classProto[classID]`.
    ///
    /// - Parameter classID: The class ID for the new object.
    /// - Returns: A new JS object value, or JS_EXCEPTION on out-of-memory.
    func newObjectClass(classID: Int) -> JeffJSValue {
        let obj = JeffJSObject()
        obj.classID = classID

        // Set the prototype from classProto
        var protoObj: JeffJSObject? = nil
        if classID < classProto.count {
            let proto = classProto[classID]
            if proto.isObject {
                protoObj = proto.toObject()
            }
        }

        // Set shape (use arrayShape for arrays, cached empty shape for others)
        if classID == JSClassID.JS_CLASS_ARRAY.rawValue {
            obj.shape = arrayShape
        }

        // Ensure shape exists — use zero-alloc initial shape (no pre-allocated arrays)
        if obj.shape == nil {
            obj.shape = createShape(self, proto: protoObj, hashSize: 0, propSize: 0)
        }

        // Set the object's prototype (single source of truth, also syncs shape.proto)
        obj.proto = protoObj

        obj.extensible = true
        return JeffJSValue.makeObject(obj)
    }

    /// Creates a new JS object with a specific prototype.
    /// Mirrors `JS_NewObjectProto()` from QuickJS.
    ///
    /// - Parameter proto: The prototype object (null for no prototype).
    /// - Returns: A new JS object value, or JS_EXCEPTION on out-of-memory.
    func newObjectProto(proto: JeffJSValue) -> JeffJSValue {
        let obj = JeffJSObject()
        obj.classID = JSClassID.JS_CLASS_OBJECT.rawValue
        let protoObj = proto.isObject ? proto.toObject() : nil
        obj.shape = createShape(self, proto: protoObj, hashSize: 0, propSize: 0)
        obj.proto = protoObj
        obj.extensible = true
        return JeffJSValue.makeObject(obj)
    }

    // MARK: - C Function Binding

    /// Creates a new JS function wrapping a Swift closure.
    /// Mirrors `JS_NewCFunction2()` from QuickJS.
    ///
    /// - Parameters:
    ///   - function: The Swift closure to wrap. Takes (ctx, thisVal, args) -> result.
    ///   - name: The function's `.name` property.
    ///   - length: The function's `.length` property (number of expected arguments).
    /// - Returns: A JS function value, or JS_EXCEPTION on error.
    func newCFunction(
        _ function: @escaping (JeffJSContext, JeffJSValue, [JeffJSValue]) -> JeffJSValue,
        name: String,
        length: Int
    ) -> JeffJSValue {
        let obj = JeffJSObject()
        obj.classID = JSClassID.JS_CLASS_C_FUNCTION.rawValue
        obj.extensible = true
        obj.payload = .cFunc(
            realm: self,
            cFunction: .generic(function),
            length: UInt8(min(length, Int(UInt8.max))),
            cproto: UInt8(JS_CFUNC_GENERIC),
            magic: 0
        )

        // Set prototype to Function.prototype
        let protoObj = functionProto.isObject ? functionProto.toObject() : nil
        obj.shape = createShape(self, proto: protoObj, hashSize: 0, propSize: 0)
        obj.proto = protoObj

        let funcVal = JeffJSValue.makeObject(obj)

        // Set the name property
        let nameAtom = rt.findAtom(name)
        let nameStr = newStringValue(name)
        _ = setPropertyInternal(
            obj: funcVal, atom: nameAtom,
            value: nameStr,
            flags: JS_PROP_CONFIGURABLE
        )
        rt.freeAtom(nameAtom)

        // Set the length property
        let lengthAtom = JeffJSAtomID.JS_ATOM_length.rawValue
        _ = setPropertyInternal(
            obj: funcVal, atom: lengthAtom,
            value: .newInt32(Int32(length)),
            flags: JS_PROP_CONFIGURABLE
        )

        return funcVal
    }

    // MARK: - String Values

    /// Creates a new JS string value from a Swift String.
    /// Mirrors `JS_NewString()` from QuickJS.
    ///
    /// - Parameter str: The Swift string.
    /// - Returns: A JS string value.
    func newStringValue(_ str: String) -> JeffJSValue {
        let jsStr = JeffJSString(swiftString: str)
        return JeffJSValue.makeString(jsStr)
    }

    // MARK: - Property Operations (String-keyed)

    /// Sets a property on an object using a string key.
    /// Mirrors `JS_SetPropertyStr()` from QuickJS.
    ///
    /// The value is consumed (its ownership transfers to the object).
    ///
    /// - Parameters:
    ///   - obj: The target object.
    ///   - name: The property name string.
    ///   - value: The value to set (consumed).
    /// - Returns: True on success, false on error.
    @discardableResult
    func setPropertyStr(obj: JeffJSValue, name: String, value: JeffJSValue) -> Bool {
        let atom = rt.findAtom(name)
        let result = setPropertyInternal(obj: obj, atom: atom, value: value, flags: JS_PROP_THROW)
        rt.freeAtom(atom) // safe: addShapeProperty dups the atom for the shape's own ref
        return result >= 0
    }

    /// Gets a property from an object using a string key.
    /// Mirrors `JS_GetPropertyStr()` from QuickJS.
    ///
    /// - Parameters:
    ///   - obj: The target object.
    ///   - name: The property name string.
    /// - Returns: The property value (caller must free), or JS_EXCEPTION on error.
    func getPropertyStr(obj: JeffJSValue, name: String) -> JeffJSValue {
        let atom = rt.findAtom(name)
        let result = getPropertyInternal(obj: obj, atom: atom, receiver: obj)
        rt.freeAtom(atom)
        return result
    }

    // MARK: - Property Operations (Atom-keyed)

    /// Gets a property from an object using an atom key.
    /// Mirrors `JS_GetProperty()` from QuickJS.
    ///
    /// - Parameters:
    ///   - obj: The target object.
    ///   - atom: The property atom.
    /// - Returns: The property value (caller must free), or JS_EXCEPTION.
    func getProperty(obj: JeffJSValue, atom: UInt32) -> JeffJSValue {
        return getPropertyInternal(obj: obj, atom: atom, receiver: obj)
    }

    /// Sets a property on an object using an atom key.
    /// Mirrors `JS_SetProperty()` from QuickJS.
    ///
    /// - Parameters:
    ///   - obj: The target object.
    ///   - atom: The property atom.
    ///   - value: The value to set (consumed).
    /// - Returns: 0 or 1 on success, -1 on error.
    @discardableResult
    func setProperty(obj: JeffJSValue, atom: UInt32, value: JeffJSValue) -> Int {
        return setPropertyInternal(obj: obj, atom: atom, value: value, flags: JS_PROP_THROW)
    }

    /// Gets a property from an object using an integer index.
    /// Mirrors `JS_GetPropertyUint32()` from QuickJS.
    ///
    /// - Parameters:
    ///   - obj: The target object.
    ///   - index: The integer index.
    /// - Returns: The property value (caller must free), or JS_EXCEPTION.
    func getPropertyUint32(obj: JeffJSValue, index: UInt32) -> JeffJSValue {
        let atom = rt.newAtomUInt32(index)
        let result = getPropertyInternal(obj: obj, atom: atom, receiver: obj)
        rt.freeAtom(atom)
        return result
    }

    /// Sets a property on an object using an integer index.
    /// Mirrors `JS_SetPropertyUint32()` from QuickJS.
    ///
    /// - Parameters:
    ///   - obj: The target object.
    ///   - index: The integer index.
    ///   - value: The value to set (consumed).
    /// - Returns: 0 or 1 on success, -1 on error.
    @discardableResult
    func setPropertyUint32(obj: JeffJSValue, index: UInt32, value: JeffJSValue) -> Int {
        let atom = rt.newAtomUInt32(index)
        let result = setPropertyInternal(obj: obj, atom: atom, value: value, flags: JS_PROP_THROW)
        rt.freeAtom(atom)
        return result
    }

    /// Defines a property with full descriptor control.
    /// Mirrors `JS_DefineProperty()` from QuickJS.
    ///
    /// This implements the [[DefineOwnProperty]] internal method per ES spec.
    ///
    /// - Parameters:
    ///   - obj: The target object.
    ///   - atom: The property atom.
    ///   - value: The property value (for data descriptors).
    ///   - getter: The getter function (for accessor descriptors).
    ///   - setter: The setter function (for accessor descriptors).
    ///   - flags: Property descriptor flags (JS_PROP_*).
    /// - Returns: 0 or 1 on success, -1 on error.
    @discardableResult
    func defineProperty(
        obj: JeffJSValue,
        atom: UInt32,
        value: JeffJSValue,
        getter: JeffJSValue = .JS_UNDEFINED,
        setter: JeffJSValue = .JS_UNDEFINED,
        flags: Int
    ) -> Int {
        guard obj.isObject else {
            _ = throwTypeErrorAtom(atom: JeffJSAtomID.JS_ATOM_Object.rawValue,
                                   message: "not an object")
            return -1
        }

        guard let jsObj = obj.toObject() else { return -1 }

        // Check extensibility
        if !jsObj.extensible {
            if (flags & JS_PROP_THROW) != 0 {
                _ = throwTypeError(message: "object is not extensible")
            }
            return -1
        }

        // Determine property type flags for the shape
        let typeFlags: JeffJSPropertyFlags
        if (flags & JS_PROP_TMASK) == JS_PROP_GETSET {
            typeFlags = .getset
        } else {
            typeFlags = .normal
        }

        // Build combined flags for addProperty
        var propFlags = typeFlags
        if (flags & JS_PROP_CONFIGURABLE) != 0 { propFlags.insert(.configurable) }
        if (flags & JS_PROP_WRITABLE) != 0     { propFlags.insert(.writable) }
        if (flags & JS_PROP_ENUMERABLE) != 0    { propFlags.insert(.enumerable) }

        // Check if property already exists — if so, update it in place
        if let shape = jsObj.shape, let idx = findShapeProperty(shape, atom) ?? shape.prop.firstIndex(where: { $0.atom == atom && $0.atom != 0 }) {
            // Update the value slot
            if idx < jsObj.prop.count {
                if (flags & JS_PROP_TMASK) == JS_PROP_GETSET {
                    // Merge getter/setter: when defining only the getter or only the
                    // setter on an existing accessor, keep the other half intact.
                    var existingGetter: JeffJSObject? = nil
                    var existingSetter: JeffJSObject? = nil
                    if case .getset(let eg, let es) = jsObj.prop[idx] {
                        existingGetter = eg
                        existingSetter = es
                    }
                    let newGetter: JeffJSObject?
                    let newSetter: JeffJSObject?
                    if (flags & JS_PROP_HAS_GET) != 0 {
                        if !getter.isUndefined { _ = getter.dupValue() }
                        newGetter = getter.toObject()
                    } else {
                        newGetter = existingGetter
                    }
                    if (flags & JS_PROP_HAS_SET) != 0 {
                        if !setter.isUndefined { _ = setter.dupValue() }
                        newSetter = setter.toObject()
                    } else {
                        newSetter = existingSetter
                    }
                    jsObj.prop[idx] = .getset(getter: newGetter, setter: newSetter)
                } else {
                    jsObj.prop[idx] = .value(value.dupValue())
                }
                // Update shape flags
                shape.prop[idx].flags = propFlags
            }
            return 1
        }

        // Add new property atomically via jeffJS_addProperty (keeps shape.prop and obj.prop in sync)
        jeffJS_addProperty(ctx: self, obj: jsObj, atom: atom, flags: propFlags)

        // Set the correct value in the just-appended slot
        let lastIdx = jsObj.prop.count - 1
        if lastIdx >= 0 {
            if (flags & JS_PROP_TMASK) == JS_PROP_GETSET {
                if !getter.isUndefined { _ = getter.dupValue() }
                if !setter.isUndefined { _ = setter.dupValue() }
                jsObj.prop[lastIdx] = .getset(getter: getter.toObject(), setter: setter.toObject())
            } else {
                jsObj.prop[lastIdx] = .value(value.dupValue())
            }
        }
        return 1
    }

    /// Defines a property with just a value and flags.
    /// Convenience wrapper over defineProperty.
    /// Mirrors `JS_DefinePropertyValue()` from QuickJS.
    @discardableResult
    func definePropertyValue(
        obj: JeffJSValue,
        atom: UInt32,
        value: JeffJSValue,
        flags: Int
    ) -> Int {
        return defineProperty(obj: obj, atom: atom, value: value, flags: flags | JS_PROP_HAS_VALUE)
    }

    /// Deletes a property from an object.
    /// Mirrors `JS_DeleteProperty()` from QuickJS.
    ///
    /// - Parameters:
    ///   - obj: The target object.
    ///   - atom: The property atom.
    ///   - flags: Flags (JS_PROP_THROW to throw on non-configurable).
    /// - Returns: True on success, false on error or non-configurable.
    func deleteProperty(obj: JeffJSValue, atom: UInt32, flags: Int = 0) -> Bool {
        guard let jsObj = obj.toObject() else { return false }
        guard let shape = jsObj.shape else { return true }

        // Use hash-based lookup first, fall back to linear scan
        let index: Int?
        if let hashIdx = findShapeProperty(shape, atom) {
            index = hashIdx
        } else {
            index = shape.prop.firstIndex(where: { $0.atom == atom })
        }

        guard let index = index else {
            return true  // property didn't exist, which counts as success
        }

        let shapeProp = shape.prop[index]
        if !shapeProp.flags.contains(.configurable) {
            if (flags & JS_PROP_THROW) != 0 {
                _ = throwTypeError(message: "property is not configurable")
            }
            return false
        }

        // Free the property value
        if index < jsObj.prop.count {
            switch jsObj.prop[index] {
            case .value(let val):
                val.freeValue()
            case .getset(let getter, let setter):
                if let g = getter { JeffJSValue.makeObject(g).freeValue() }
                if let s = setter { JeffJSValue.makeObject(s).freeValue() }
            default:
                break
            }
            // Mark as deleted: set to empty value (don't remove to keep indices stable)
            jsObj.prop[index] = .value(.undefined)
        }

        // Mark the shape property as deleted by zeroing the atom (keeps indices stable
        // so hash table entries remain valid for other properties)
        shape.prop[index].atom = 0
        shape.prop[index].flags = []
        return true
    }

    /// Checks if an object has a property.
    /// Mirrors `JS_HasProperty()` from QuickJS.
    ///
    /// This checks the entire prototype chain (like the `in` operator).
    ///
    /// - Parameters:
    ///   - obj: The target object.
    ///   - atom: The property atom.
    /// - Returns: True if the property exists, false otherwise.
    func hasProperty(obj: JeffJSValue, atom: UInt32) -> Bool {
        guard let jsObj = obj.toObject() else { return false }

        // Proxy intercept: if this object is a proxy, dispatch to handler.has trap
        if jsObj.classID == JeffJSClassID.proxy.rawValue || jsObj.classID == JSClassID.JS_CLASS_PROXY.rawValue {
            if case .proxyData(let pd) = jsObj.payload {
                if pd.isRevoked {
                    _ = throwTypeError(message: "Cannot perform 'has' on a proxy that has been revoked")
                    return false
                }
                // Look for handler.has trap
                if let handlerObj = pd.handler.toObject() {
                    let hasTrapAtom = rt.findAtom("has")
                    let trap = getPropertyInternal(obj: pd.handler, atom: hasTrapAtom, receiver: pd.handler)
                    rt.freeAtom(hasTrapAtom)
                    if trap.isObject, let trapObj = trap.toObject(), trapObj.isCallable {
                        // Call trap(target, property)
                        let propName: JeffJSValue
                        if let name = rt.atomToString(atom) {
                            propName = newStringValue(name)
                        } else {
                            propName = .JS_UNDEFINED
                        }
                        let result = callFunction(trap, thisVal: pd.handler, args: [pd.target, propName])
                        return result.toBool()
                    }
                    _ = handlerObj // suppress warning
                }
                // No trap: fall through to target
                return hasProperty(obj: pd.target, atom: atom)
            }
        }

        // Fast path: check fast-array payload for integer-indexed access
        if jsObj.fastArray || jsObj.classID == JeffJSClassID.array.rawValue {
            if rt.atomIsArrayIndex(atom), let idx = rt.atomToUInt32(atom) {
                if let storage = jsObj._fastArrayValues {
                    if idx < storage.count && Int(idx) < storage.values.count {
                        return true
                    }
                } else if case .array(_, let vals, let count) = jsObj.payload {
                    if idx < count && Int(idx) < vals.count {
                        return true
                    }
                }
            }
        }

        // Check own properties via shape
        if jsObj.shape?.prop.contains(where: { $0.atom == atom }) == true {
            return true
        }

        // Walk the prototype chain (check both shape.proto and obj.proto
        // to match getPropertyInternal's fallback behavior)
        var proto = jsObj.proto
        while let p = proto {
            if p.shape?.prop.contains(where: { $0.atom == atom }) == true {
                return true
            }
            proto = p.proto
        }

        return false
    }

    /// Gets the own property descriptor for a property.
    /// Mirrors `JS_GetOwnProperty()` from QuickJS.
    ///
    /// Unlike `getProperty`, this does NOT walk the prototype chain.
    ///
    /// - Parameters:
    ///   - obj: The target object.
    ///   - atom: The property atom.
    /// - Returns: The property descriptor, or nil if not found.
    func getOwnProperty(obj: JeffJSValue, atom: UInt32) -> JeffJSProperty? {
        guard let jsObj = obj.toObject() else { return nil }
        let (_, prop) = jeffJS_findOwnProperty(obj: jsObj, atom: atom)
        return prop
    }

    // MARK: - Exception Handling

    /// Throws a JS value as an exception.
    /// Mirrors `JS_Throw()` from QuickJS.
    ///
    /// Always returns JS_EXCEPTION so callers can write `return ctx.throw(val)`.
    ///
    /// - Parameter value: The value to throw (consumed).
    /// - Returns: JS_EXCEPTION sentinel.
    @discardableResult
    func throwValue(_ value: JeffJSValue) -> JeffJSValue {
        // Free any existing pending exception
        rt.currentException.freeValue()
        rt.currentException = value
        return .exception
    }

    /// Gets and clears the current pending exception.
    /// Mirrors `JS_GetException()` from QuickJS.
    ///
    /// - Returns: The exception value (caller owns it), or JS_NULL if none.
    func getException() -> JeffJSValue {
        let exc = rt.currentException
        rt.currentException = .null
        return exc
    }

    /// Checks if a value is an Error object.
    /// Mirrors `JS_IsError()` from QuickJS.
    ///
    /// - Parameter val: The value to check.
    /// - Returns: True if val is an Error or any NativeError instance.
    func isError(_ val: JeffJSValue) -> Bool {
        guard let obj = val.toObject() else { return false }
        return obj.classID == JSClassID.JS_CLASS_ERROR.rawValue
    }

    /// Throws a TypeError with the given message.
    /// Mirrors `JS_ThrowTypeError()` from QuickJS.
    ///
    /// - Parameter message: The error message.
    /// - Returns: JS_EXCEPTION.
    @discardableResult
    func throwTypeError(message: String) -> JeffJSValue {
        return throwErrorInternal(errorType: .JS_TYPE_ERROR, message: message)
    }

    /// Throws a RangeError with the given message.
    /// Mirrors `JS_ThrowRangeError()` from QuickJS.
    @discardableResult
    func throwRangeError(message: String) -> JeffJSValue {
        return throwErrorInternal(errorType: .JS_RANGE_ERROR, message: message)
    }

    /// Throws a ReferenceError with the given message.
    /// Mirrors `JS_ThrowReferenceError()` from QuickJS.
    @discardableResult
    func throwReferenceError(message: String) -> JeffJSValue {
        return throwErrorInternal(errorType: .JS_REFERENCE_ERROR, message: message)
    }

    /// Throws a SyntaxError with the given message.
    /// Mirrors `JS_ThrowSyntaxError()` from QuickJS.
    @discardableResult
    func throwSyntaxError(message: String) -> JeffJSValue {
        return throwErrorInternal(errorType: .JS_SYNTAX_ERROR, message: message)
    }

    /// Throws a URIError with the given message.
    @discardableResult
    func throwURIError(message: String) -> JeffJSValue {
        return throwErrorInternal(errorType: .JS_URI_ERROR, message: message)
    }

    /// Throws an InternalError with the given message.
    @discardableResult
    func throwInternalError(message: String) -> JeffJSValue {
        return throwErrorInternal(errorType: .JS_INTERNAL_ERROR, message: message)
    }

    /// Throws an out-of-memory error.
    /// Mirrors `JS_ThrowOutOfMemory()` from QuickJS.
    @discardableResult
    func throwOutOfMemory() -> JeffJSValue {
        if !rt.inOutOfMemory {
            rt.inOutOfMemory = true
            let result = throwInternalError(message: "out of memory")
            rt.inOutOfMemory = false
            return result
        }
        return .exception
    }

    /// Throws a stack overflow error.
    @discardableResult
    func throwStackOverflow() -> JeffJSValue {
        return throwInternalError(message: "stack overflow")
    }

    // MARK: - Type Conversions

    /// Converts a JS value to Int32.
    /// Mirrors `JS_ToInt32()` from QuickJS.
    ///
    /// Follows the ToInt32 abstract operation from the ES spec:
    /// 1. If int32 tag, return directly.
    /// 2. If float64, truncate to 32-bit signed integer (mod 2^32).
    /// 3. If bool, return 0 or 1.
    /// 4. If null/undefined, return 0.
    /// 5. Otherwise, attempt ToPrimitive(number) then convert.
    ///
    /// - Parameter val: The value to convert.
    /// - Returns: The Int32 result, or nil on exception.
    func toInt32(_ val: JeffJSValue) -> Int32? {
        if val.isInt {
            return val.toInt32()
        }
        if val.isFloat64 {
            let d = val.toFloat64()
            return doubleToInt32(d)
        }
        if val.isBool {
            return val.toBool() ? 1 : 0
        }
        if val.isNull || val.isUndefined {
            return 0
        }
        // For objects/strings, would need ToPrimitive + ToNumber first
        // Placeholder: attempt numeric conversion
        if let n = toFloat64(val) {
            return doubleToInt32(n)
        }
        return nil
    }

    /// Implements the ES spec ToInt32 abstract operation on a Double.
    /// Handles all edge cases including values outside Int64 range.
    ///
    /// ES spec 7.1.6:
    /// 1. If d is NaN, +0, -0, +Inf, -Inf → return 0
    /// 2. int = sign(d) * floor(abs(d))
    /// 3. int32bit = int modulo 2^32
    /// 4. If int32bit >= 2^31, return int32bit - 2^32; else return int32bit
    private func doubleToInt32(_ d: Double) -> Int32 {
        if d.isNaN || d.isInfinite || d == 0 { return 0 }
        // Step 2: truncate toward zero (same as sign * floor(abs))
        let posInt = d < 0 ? -floor(-d) : floor(d)
        // Step 3: modulo 2^32 using fmod to avoid Int64 overflow
        let twoTo32: Double = 4294967296.0  // 2^32
        var int32bit = posInt.truncatingRemainder(dividingBy: twoTo32)
        // truncatingRemainder can return negative values; normalize to [0, 2^32)
        if int32bit < 0 { int32bit += twoTo32 }
        // Step 4: wrap to signed range
        if int32bit >= 2147483648.0 {  // 2^31
            return Int32(int32bit - twoTo32)
        }
        return Int32(int32bit)
    }

    /// Converts a JS value to Int64.
    /// Mirrors `JS_ToInt64()` from QuickJS.
    ///
    /// - Parameter val: The value to convert.
    /// - Returns: The Int64 result, or nil on exception.
    func toInt64(_ val: JeffJSValue) -> Int64? {
        if val.isInt {
            return Int64(val.toInt32())
        }
        if val.isFloat64 {
            let d = val.toFloat64()
            return doubleToInt64(d)
        }
        if val.isBool {
            return val.toBool() ? 1 : 0
        }
        if val.isNull || val.isUndefined {
            return 0
        }
        if let n = toFloat64(val) {
            return doubleToInt64(n)
        }
        return nil
    }

    /// Implements the ES spec ToInt64-like operation on a Double.
    /// Handles values outside Int64 range safely using fmod.
    private func doubleToInt64(_ d: Double) -> Int64 {
        if d.isNaN || d.isInfinite || d == 0 { return 0 }
        let posInt = d < 0 ? -floor(-d) : floor(d)
        // Clamp to Int64 range since fmod with 2^64 loses precision
        let int64Max = Double(Int64.max)
        let int64Min = Double(Int64.min)
        if posInt >= int64Max { return Int64.max }
        if posInt <= int64Min { return Int64.min }
        return Int64(posInt)
    }

    /// Converts a JS value to Float64.
    /// Mirrors `JS_ToFloat64()` from QuickJS.
    ///
    /// Follows the ToNumber abstract operation from the ES spec.
    ///
    /// - Parameter val: The value to convert.
    /// - Returns: The Double result, or nil on exception.
    func toFloat64(_ val: JeffJSValue) -> Double? {
        if val.isFloat64 {
            return val.toFloat64()
        }
        if val.isInt {
            return Double(val.toInt32())
        }
        if val.isBool {
            return val.toBool() ? 1.0 : 0.0
        }
        if val.isNull {
            return 0.0
        }
        if val.isUndefined {
            return Double.nan
        }
        if val.isString {
            // Convert string to number
            if let str = val.stringValue?.toSwiftString() {
                let trimmed = str.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                if trimmed.isEmpty { return 0.0 }
                if let d = Double(trimmed) { return d }
                if trimmed == "Infinity" || trimmed == "+Infinity" { return .infinity }
                if trimmed == "-Infinity" { return -.infinity }
                return Double.nan
            }
        }
        // For objects, call ToPrimitive(number) then convert
        if val.isObject {
            let prim = toPrimitive(val, preferredType: "number")
            if prim.isException { return nil }
            let result = toFloat64(prim)
            prim.freeValue()
            return result
        }
        return nil
    }

    /// Converts a JS value to Bool.
    /// Mirrors `JS_ToBool()` from QuickJS.
    ///
    /// Follows the ToBoolean abstract operation from the ES spec:
    /// - undefined, null, false, +0, -0, NaN, "" -> false
    /// - Everything else -> true (including all objects)
    ///
    /// - Parameter val: The value to convert.
    /// - Returns: The boolean result.
    func toBool(_ val: JeffJSValue) -> Bool {
        if val.isBool {
            return val.toBool()
        }
        if val.isNull || val.isUndefined {
            return false
        }
        if val.isInt {
            return val.toInt32() != 0
        }
        if val.isFloat64 {
            let d = val.toFloat64()
            return !d.isNaN && d != 0.0
        }
        if val.isString {
            if let str = val.stringValue {
                return !str.toSwiftString().isEmpty
            }
            return false
        }
        if val.isObject {
            return true  // all objects are truthy
        }
        return false
    }

    /// Converts a JS value to a JS string value.
    /// Mirrors `JS_ToString()` from QuickJS.
    ///
    /// This returns a JS string value (tag = STRING), not a Swift String.
    /// Follows the ToString abstract operation from the ES spec.
    ///
    /// - Parameter val: The value to convert.
    /// - Returns: A JS string value (caller must free), or JS_EXCEPTION.
    func toString(_ val: JeffJSValue) -> JeffJSValue {
        // Propagate exceptions — mirrors QuickJS JS_ToStringFree behavior.
        if val.isException {
            return .exception
        }
        if val.isString {
            return val.dupValue()
        }
        if val.isInt {
            return newStringValue(String(val.toInt32()))
        }
        if val.isFloat64 {
            let d = val.toFloat64()
            if d.isNaN { return newStringValue("NaN") }
            if d.isInfinite { return newStringValue(d > 0 ? "Infinity" : "-Infinity") }
            // Use Swift's default formatting which handles -0, etc.
            if d == 0 && d.sign == .minus {
                return newStringValue("0")
            }
            return newStringValue(formatDouble(d))
        }
        if val.isBool {
            return newStringValue(val.toBool() ? "true" : "false")
        }
        if val.isNull {
            return newStringValue("null")
        }
        if val.isUndefined {
            return newStringValue("undefined")
        }
        if val.isObject {
            // ES spec 7.1.12 step 1: ToPrimitive(val, "string")
            let prim = toPrimitive(val, preferredType: "string")
            if prim.isException { return prim }
            // Recursively call ToString on the resulting primitive
            let result = toString(prim)
            prim.freeValue()
            return result
        }
        if val.isSymbol {
            return throwTypeError(message: "Cannot convert a Symbol value to a string")
        }
        if val.isBigInt {
            // Would format the BigInt digits
            return newStringValue("0n")
        }
        return newStringValue("undefined")
    }

    /// Implements the ToPrimitive abstract operation (ES spec 7.1.1).
    ///
    /// When `val` is already a primitive, returns it unchanged.
    /// When `val` is an object:
    ///   1. If `[Symbol.toPrimitive]` exists, call it with the given hint.
    ///   2. Otherwise, if hint == "string", try toString() then valueOf().
    ///   3. Otherwise (hint == "number" / "default"), try valueOf() then toString().
    ///   4. If neither returns a primitive, throw TypeError.
    ///
    /// - Parameters:
    ///   - val: The value to convert.
    ///   - preferredType: "string", "number", or "default".
    /// - Returns: A primitive JS value, or JS_EXCEPTION.
    func toPrimitive(_ val: JeffJSValue, preferredType: String = "default") -> JeffJSValue {
        // Primitives pass through unchanged
        if !val.isObject { return val.dupValue() }

        // 1. Check for [Symbol.toPrimitive]
        let toPrimAtom = JeffJSAtomID.JS_ATOM_Symbol_toPrimitive.rawValue
        let exoticPrim = getPropertyInternal(obj: val, atom: toPrimAtom, receiver: val)
        if !exoticPrim.isUndefined && !exoticPrim.isNull {
            if exoticPrim.isFunction {
                let hintVal = newStringValue(preferredType)
                let result = callFunction(exoticPrim, thisVal: val, args: [hintVal])
                if result.isException { return result }
                if !result.isObject { return result }
                return throwTypeError(message: "Cannot convert object to primitive value")
            }
        }

        // 2. OrdinaryToPrimitive: try two methods depending on the hint
        let methodNames: [String]
        if preferredType == "string" {
            methodNames = ["toString", "valueOf"]
        } else {
            // "number" or "default"
            methodNames = ["valueOf", "toString"]
        }

        for name in methodNames {
            let method = getPropertyStr(obj: val, name: name)
            if method.isFunction {
                let result = callFunction(method, thisVal: val, args: [])
                if result.isException { return result }
                if !result.isObject { return result }
                // Result was an object — try the next method
            }
        }

        return throwTypeError(message: "Cannot convert object to primitive value")
    }

    /// Converts a JS value to an object.
    /// Mirrors `JS_ToObject()` from QuickJS.
    ///
    /// Follows the ToObject abstract operation from the ES spec:
    /// - Objects pass through unchanged.
    /// - Primitives are wrapped in their corresponding wrapper objects.
    /// - null/undefined throw a TypeError.
    ///
    /// - Parameter val: The value to convert.
    /// - Returns: An object value (caller must free), or JS_EXCEPTION.
    func toObject(_ val: JeffJSValue) -> JeffJSValue {
        if val.isObject {
            return val.dupValue()
        }
        if val.isNull || val.isUndefined {
            return throwTypeError(message: "cannot convert null or undefined to object")
        }
        // Wrap primitive in corresponding wrapper class
        var classID: Int
        if val.isString {
            classID = JSClassID.JS_CLASS_STRING.rawValue
        } else if val.isNumber {
            classID = JSClassID.JS_CLASS_NUMBER.rawValue
        } else if val.isBool {
            classID = JSClassID.JS_CLASS_BOOLEAN.rawValue
        } else if val.isSymbol {
            classID = JSClassID.JS_CLASS_SYMBOL.rawValue
        } else if val.isBigInt {
            classID = JSClassID.JS_CLASS_BIG_INT.rawValue
        } else {
            return throwTypeError(message: "cannot convert to object")
        }

        let obj = JeffJSObject()
        obj.classID = classID
        obj.extensible = true
        obj.primitiveValue = val.dupValue()

        // Ensure shape exists so proto setter can sync shape.proto
        if obj.shape == nil {
            obj.shape = createShape(self, proto: nil, hashSize: JS_PROP_INITIAL_HASH_SIZE, propSize: JS_PROP_INITIAL_SIZE)
        }

        if classID < classProto.count {
            let proto = classProto[classID]
            if proto.isObject {
                obj.proto = proto.toObject()
                _ = proto.dupValue()
            }
        }

        return JeffJSValue.makeObject(obj)
    }

    /// Converts a JS value to a Swift String.
    /// Not a QuickJS API — convenience for Swift callers.
    ///
    /// - Parameter val: The value to convert.
    /// - Returns: The Swift string, or nil on error.
    func toSwiftString(_ val: JeffJSValue) -> String? {
        let jsStr = toString(val)
        if jsStr.isException { return nil }
        let result = jsStr.stringValue?.toSwiftString()
        jsStr.freeValue()
        return result
    }

    // MARK: - Intrinsic Registration

    /// Adds Object, Function, Error, Array, Number, String, Boolean, Symbol,
    /// and other base objects.
    /// Mirrors `JS_AddIntrinsicBaseObjects()` from QuickJS.
    func addIntrinsicBaseObjects() {
        // --- Object.prototype (the root of all prototype chains) ---
        let objectProto = JeffJSObject()
        objectProto.classID = JSClassID.JS_CLASS_OBJECT.rawValue
        objectProto.extensible = true
        objectProto.shape = createShape(self, proto: nil, hashSize: JS_PROP_INITIAL_HASH_SIZE, propSize: JS_PROP_INITIAL_SIZE)
        objectProto.prop = []
        objectProto.proto = nil  // Object.prototype has no prototype ([[Prototype]] is null)
        let objectProtoVal = JeffJSValue.makeObject(objectProto)
        classProto[JSClassID.JS_CLASS_OBJECT.rawValue] = objectProtoVal

        // --- Function.prototype ---
        let funcProto = JeffJSObject()
        funcProto.classID = JSClassID.JS_CLASS_OBJECT.rawValue
        funcProto.extensible = true
        funcProto.shape = createShape(self, proto: objectProto, hashSize: JS_PROP_INITIAL_HASH_SIZE, propSize: JS_PROP_INITIAL_SIZE)
        funcProto.prop = []
        funcProto.proto = objectProto  // set after shape so setter syncs shape.proto
        let funcProtoVal = JeffJSValue.makeObject(funcProto)
        classProto[JSClassID.JS_CLASS_BYTECODE_FUNCTION.rawValue] = funcProtoVal.dupValue()
        classProto[JSClassID.JS_CLASS_C_FUNCTION.rawValue] = funcProtoVal.dupValue()
        classProto[JSClassID.JS_CLASS_BOUND_FUNCTION.rawValue] = funcProtoVal.dupValue()
        classProto[JSClassID.JS_CLASS_C_FUNCTION_DATA.rawValue] = funcProtoVal.dupValue()
        functionProto = funcProtoVal.dupValue()

        // Add Object.prototype methods: toString, valueOf, hasOwnProperty, etc.
        addObjectProtoMethods(objectProtoVal)

        // Add Function.prototype methods: call, apply, bind, toString
        addFunctionProtoMethods(funcProtoVal)
        funcProtoVal.freeValue()  // Release the local variable's reference (5 dupValue'd copies own theirs)

        // --- Object constructor ---
        let objectCtor = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .exception }
            if args.isEmpty || args[0].isNullOrUndefined {
                return self.newObject()
            }
            return self.toObject(args[0])
        }, name: "Object", length: 1)
        _ = setPropertyStr(obj: globalObj, name: "Object", value: objectCtor.dupValue())

        // --- Function constructor ---
        functionCtor = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .exception }
            // ES spec: new Function(p1, p2, ..., pN, body)
            // Last argument is the body, all preceding are parameter names.
            // With zero args: new Function() => empty function.
            let body: String
            var params: [String] = []

            if args.isEmpty {
                body = ""
            } else if args.count == 1 {
                // Single argument is the body
                guard let bodyStr = self.toSwiftString(args[0]) else {
                    return self.throwTypeError(message: "Function body must be a string")
                }
                body = bodyStr
            } else {
                // Last arg is body, rest are parameter names
                for i in 0..<(args.count - 1) {
                    guard let paramStr = self.toSwiftString(args[i]) else {
                        return self.throwTypeError(message: "Function parameter name must be a string")
                    }
                    params.append(paramStr)
                }
                guard let bodyStr = self.toSwiftString(args[args.count - 1]) else {
                    return self.throwTypeError(message: "Function body must be a string")
                }
                body = bodyStr
            }

            let paramList = params.joined(separator: ",")
            let source = "(function anonymous(\(paramList)) { \(body) })"
            let result = self.eval(input: source, filename: "<Function>", evalFlags: JS_EVAL_TYPE_GLOBAL)
            return result
        }, name: "Function", length: 1)
        if let funcCtorObj = functionCtor.toObject() {
            funcCtorObj.isConstructor = true
        }
        // Set Function.prototype so that `Function.prototype.apply.call(...)` works.
        // React DOM's printWarning uses this pattern extensively.
        _ = setPropertyStr(obj: functionCtor, name: "prototype", value: functionProto.dupValue())
        _ = setPropertyStr(obj: globalObj, name: "Function", value: functionCtor.dupValue())

        // --- Error and NativeError constructors ---
        addErrorConstructors()

        // --- Array ---
        addArrayIntrinsic()

        // --- Number ---
        addNumberIntrinsic()

        // --- String ---
        addStringIntrinsic()

        // --- Boolean ---
        addBooleanIntrinsic()

        // --- Symbol ---
        addSymbolIntrinsic()

        // --- BigInt ---
        addBigIntIntrinsic()

        // --- ThrowTypeError function (used in strict arguments, etc.) ---
        throwTypeError = newCFunction({ [weak self] ctx, thisVal, args in
            return self?.throwTypeError(message: "'caller', 'callee', and 'arguments' properties "
                + "may not be accessed on strict mode functions") ?? .exception
        }, name: "", length: 0)

        // --- Wire the global object's [[Prototype]] to Object.prototype ---
        // Per the ES spec, the global object's [[Prototype]] is implementation-defined
        // but typically Object.prototype so that globalThis.toString(), etc. work.
        if let globalJSObj = globalObj.toObject() {
            globalJSObj.proto = objectProto
        }

        // --- globalThis ---
        _ = setPropertyStr(obj: globalObj, name: "globalThis", value: globalObj.dupValue())

        // --- undefined, NaN, Infinity ---
        _ = setPropertyStr(obj: globalObj, name: "undefined", value: .JS_UNDEFINED)
        _ = setPropertyStr(obj: globalObj, name: "NaN", value: .newFloat64(Double.nan))
        _ = setPropertyStr(obj: globalObj, name: "Infinity", value: .newFloat64(Double.infinity))

        // --- Global functions: parseInt, parseFloat, isNaN, isFinite ---
        addGlobalFunctions()
    }

    /// Adds the RegExp constructor and prototype.
    /// Mirrors `JS_AddIntrinsicRegExp()` from QuickJS.
    func addIntrinsicRegExp() {
        let regexpProto = newObjectClass(classID: JSClassID.JS_CLASS_OBJECT.rawValue)
        classProto[JSClassID.JS_CLASS_REGEXP.rawValue] = regexpProto

        // Wire up the compileRegexp closure so that the `regexp` opcode
        // (and `new RegExp(...)` from JS) can create real RegExp objects.
        compileRegexp = { [weak self] (ctx: JeffJSContext, patternVal: JeffJSValue, flagsVal: JeffJSValue) -> JeffJSValue in
            guard let self = self else { return .exception }
            return js_regexp_constructor(ctx: self,
                                         newTarget: self.regexpCtor,
                                         this: .JS_UNDEFINED,
                                         argv: [patternVal, flagsVal])
        }

        regexpCtor = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .exception }
            let pattern = args.count >= 1 ? args[0] : .JS_UNDEFINED
            let flags = args.count >= 2 ? args[1] : .JS_UNDEFINED
            return js_regexp_constructor(ctx: self,
                                         newTarget: self.regexpCtor,
                                         this: thisVal,
                                         argv: [pattern, flags])
        }, name: "RegExp", length: 2)

        // Wire RegExp.prototype <-> RegExp constructor
        _ = setPropertyStr(obj: regexpCtor, name: "prototype", value: regexpProto)
        _ = setPropertyStr(obj: regexpProto, name: "constructor", value: regexpCtor)

        _ = setPropertyStr(obj: globalObj, name: "RegExp", value: regexpCtor.dupValue())

        // RegExp.prototype methods: exec, test, toString, compile
        addRegExpProtoMethods(regexpProto)
    }

    /// Adds the JSON object with parse() and stringify().
    /// Mirrors `JS_AddIntrinsicJSON()` from QuickJS.
    func addIntrinsicJSON() {
        let jsonObj = newObject()

        // JSON.parse
        let parseFunc = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self, !args.isEmpty else { return .JS_UNDEFINED }
            guard let text = self.toSwiftString(args[0]) else { return .exception }
            return self.jsonParse(text: text)
        }, name: "parse", length: 2)
        _ = setPropertyStr(obj: jsonObj, name: "parse", value: parseFunc)

        // JSON.stringify
        let stringifyFunc = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self, !args.isEmpty else { return .JS_UNDEFINED }
            return self.jsonStringify(value: args[0],
                                      replacer: args.count > 1 ? args[1] : .JS_UNDEFINED,
                                      space: args.count > 2 ? args[2] : .JS_UNDEFINED)
        }, name: "stringify", length: 3)
        _ = setPropertyStr(obj: jsonObj, name: "stringify", value: stringifyFunc)

        // JSON[Symbol.toStringTag] = "JSON"
        _ = setPropertyStr(obj: globalObj, name: "JSON", value: jsonObj)
    }

    /// Adds the Proxy and Reflect constructors.
    /// Mirrors `JS_AddIntrinsicProxy()` from QuickJS.
    func addIntrinsicProxy() {
        let proxyProto = newObjectClass(classID: JSClassID.JS_CLASS_OBJECT.rawValue)
        classProto[JSClassID.JS_CLASS_PROXY.rawValue] = proxyProto

        // Proxy constructor -- must be called with `new`
        let proxyCtorObj = JeffJSObject()
        proxyCtorObj.classID = JSClassID.JS_CLASS_C_FUNCTION.rawValue
        proxyCtorObj.extensible = true
        proxyCtorObj.isConstructor = true
        proxyCtorObj.payload = .cFunc(
            realm: self,
            cFunction: .constructorOrFunc({ [weak self] ctx, thisVal, args, isNew in
                guard let self = self else { return .exception }
                guard isNew else {
                    return self.throwTypeError(message: "Constructor Proxy requires 'new'")
                }
                guard args.count >= 2 else {
                    return self.throwTypeError(message: "Cannot create proxy with a non-object as target or handler")
                }
                let target = args[0]
                let handler = args[1]
                guard target.isObject else {
                    return self.throwTypeError(message: "Cannot create proxy with a non-object as target or handler")
                }
                guard handler.isObject else {
                    return self.throwTypeError(message: "Cannot create proxy with a non-object as target or handler")
                }
                return self.createProxyObject(target: target, handler: handler)
            }),
            length: 2,
            cproto: UInt8(JS_CFUNC_CONSTRUCTOR_OR_FUNC),
            magic: 0
        )
        // Set prototype to Function.prototype
        let proxyCtorProtoObj = functionProto.isObject ? functionProto.toObject() : nil
        proxyCtorObj.shape = createShape(self, proto: proxyCtorProtoObj, hashSize: JS_PROP_INITIAL_HASH_SIZE, propSize: JS_PROP_INITIAL_SIZE)
        proxyCtorObj.proto = proxyCtorProtoObj
        let proxyCtor = JeffJSValue.makeObject(proxyCtorObj)

        // Set name and length on the Proxy constructor
        let proxyNameAtom = rt.findAtom("Proxy")
        _ = setPropertyInternal(obj: proxyCtor, atom: proxyNameAtom, value: newStringValue("Proxy"), flags: JS_PROP_CONFIGURABLE)
        rt.freeAtom(proxyNameAtom)
        let proxyLenAtom = JeffJSAtomID.JS_ATOM_length.rawValue
        _ = setPropertyInternal(obj: proxyCtor, atom: proxyLenAtom, value: .newInt32(2), flags: JS_PROP_CONFIGURABLE)

        // Proxy.revocable(target, handler) -- static method
        let revocableFunc = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .exception }
            guard args.count >= 2 else {
                return self.throwTypeError(message: "Proxy.revocable requires target and handler")
            }
            let target = args[0]
            let handler = args[1]
            guard target.isObject else {
                return self.throwTypeError(message: "Cannot create proxy with a non-object as target or handler")
            }
            guard handler.isObject else {
                return self.throwTypeError(message: "Cannot create proxy with a non-object as target or handler")
            }
            let proxyVal = self.createProxyObject(target: target, handler: handler)
            if proxyVal.isException { return proxyVal }

            // Create revoke function that captures the proxy
            let revokeFunc = self.newCFunction({ [weak self] ctx, thisVal, revokeArgs in
                guard let self = self else { return .JS_UNDEFINED }
                // The proxy reference is stored as an internal property on the revoke function
                let proxyRefAtom = self.rt.findAtom("__proxyRef__")
                let proxyRef = self.getPropertyInternal(obj: thisVal, atom: proxyRefAtom, receiver: thisVal)
                self.rt.freeAtom(proxyRefAtom)
                guard let proxyObj = proxyRef.toObject(),
                      proxyObj.classID == JeffJSClassID.proxy.rawValue || proxyObj.classID == JSClassID.JS_CLASS_PROXY.rawValue,
                      case .proxyData(var pd) = proxyObj.payload else {
                    return .JS_UNDEFINED
                }
                if !pd.isRevoked {
                    pd.target = .undefined
                    pd.handler = .undefined
                    pd.isRevoked = true
                    proxyObj.payload = .proxyData(pd)
                }
                return .JS_UNDEFINED
            }, name: "revoke", length: 0)

            // Store the proxy reference on the revoke function
            let proxyRefAtom = self.rt.findAtom("__proxyRef__")
            _ = self.setPropertyInternal(obj: revokeFunc, atom: proxyRefAtom, value: proxyVal.dupValue(), flags: 0)
            self.rt.freeAtom(proxyRefAtom)

            // Build result: { proxy, revoke }
            let resultObj = self.newObject()
            _ = self.setPropertyStr(obj: resultObj, name: "proxy", value: proxyVal)
            _ = self.setPropertyStr(obj: resultObj, name: "revoke", value: revokeFunc)
            return resultObj
        }, name: "revocable", length: 2)
        _ = setPropertyStr(obj: proxyCtor, name: "revocable", value: revocableFunc)

        _ = setPropertyStr(obj: globalObj, name: "Proxy", value: proxyCtor)

        // Reflect object
        let reflectObj = newObject()
        _ = setPropertyStr(obj: globalObj, name: "Reflect", value: reflectObj)

        addReflectMethods(reflectObj)
    }

    /// Creates a proxy object with the given target and handler.
    /// Stores JeffJSProxyData as the payload.
    func createProxyObject(target: JeffJSValue, handler: JeffJSValue) -> JeffJSValue {
        guard let targetObj = target.toObject() else {
            return throwTypeError(message: "Proxy target must be an object")
        }
        let isFunc = targetObj.isCallable
        let isCtor = targetObj.isConstructor

        let proxyObj = JeffJSObject()
        proxyObj.classID = JSClassID.JS_CLASS_PROXY.rawValue
        proxyObj.extensible = true
        proxyObj.isExotic = true
        if isFunc {
            proxyObj.isConstructor = isCtor
        }

        let pd = JeffJSProxyData(
            target: target.dupValue(),
            handler: handler.dupValue(),
            isFunc: isFunc,
            isRevoked: false
        )
        proxyObj.payload = .proxyData(pd)

        // Set a shape so property lookup infrastructure works
        proxyObj.shape = createShape(self, proto: nil, hashSize: JS_PROP_INITIAL_HASH_SIZE, propSize: JS_PROP_INITIAL_SIZE)
        proxyObj.prop = []

        return JeffJSValue.makeObject(proxyObj)
    }

    /// Adds Map, Set, WeakMap, and WeakSet.
    /// Mirrors `JS_AddIntrinsicMapSet()` from QuickJS.
    func addIntrinsicMapSet() {
        // Map
        let mapProto = newObjectClass(classID: JSClassID.JS_CLASS_OBJECT.rawValue)
        classProto[JSClassID.JS_CLASS_MAP.rawValue] = mapProto
        let mapCtor = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .exception }
            return self.newMapOrSetObject(classID: JSClassID.JS_CLASS_MAP.rawValue, isWeak: false)
        }, name: "Map", length: 0)
        // Wire Map.prototype <-> Map constructor
        _ = setPropertyStr(obj: mapCtor, name: "prototype", value: mapProto)
        _ = setPropertyStr(obj: mapProto, name: "constructor", value: mapCtor)
        _ = setPropertyStr(obj: globalObj, name: "Map", value: mapCtor)

        // Set
        let setProto = newObjectClass(classID: JSClassID.JS_CLASS_OBJECT.rawValue)
        classProto[JSClassID.JS_CLASS_SET.rawValue] = setProto
        let setCtor = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .exception }
            return self.newMapOrSetObject(classID: JSClassID.JS_CLASS_SET.rawValue, isWeak: false)
        }, name: "Set", length: 0)
        // Wire Set.prototype <-> Set constructor
        _ = setPropertyStr(obj: setCtor, name: "prototype", value: setProto)
        _ = setPropertyStr(obj: setProto, name: "constructor", value: setCtor)
        _ = setPropertyStr(obj: globalObj, name: "Set", value: setCtor)

        // WeakMap
        let weakMapProto = newObjectClass(classID: JSClassID.JS_CLASS_OBJECT.rawValue)
        classProto[JSClassID.JS_CLASS_WEAKMAP.rawValue] = weakMapProto
        let weakMapCtor = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .exception }
            return self.newMapOrSetObject(classID: JSClassID.JS_CLASS_WEAKMAP.rawValue, isWeak: true)
        }, name: "WeakMap", length: 0)
        // Wire WeakMap.prototype <-> WeakMap constructor
        _ = setPropertyStr(obj: weakMapCtor, name: "prototype", value: weakMapProto)
        _ = setPropertyStr(obj: weakMapProto, name: "constructor", value: weakMapCtor)
        _ = setPropertyStr(obj: globalObj, name: "WeakMap", value: weakMapCtor)

        // WeakSet
        let weakSetProto = newObjectClass(classID: JSClassID.JS_CLASS_OBJECT.rawValue)
        classProto[JSClassID.JS_CLASS_WEAKSET.rawValue] = weakSetProto
        let weakSetCtor = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .exception }
            return self.newMapOrSetObject(classID: JSClassID.JS_CLASS_WEAKSET.rawValue, isWeak: true)
        }, name: "WeakSet", length: 0)
        // Wire WeakSet.prototype <-> WeakSet constructor
        _ = setPropertyStr(obj: weakSetCtor, name: "prototype", value: weakSetProto)
        _ = setPropertyStr(obj: weakSetProto, name: "constructor", value: weakSetCtor)
        _ = setPropertyStr(obj: globalObj, name: "WeakSet", value: weakSetCtor)

        // Iterator helpers
        let mapIterProto = newObjectClass(classID: JSClassID.JS_CLASS_OBJECT.rawValue)
        classProto[JSClassID.JS_CLASS_MAP_ITERATOR.rawValue] = mapIterProto

        let setIterProto = newObjectClass(classID: JSClassID.JS_CLASS_OBJECT.rawValue)
        classProto[JSClassID.JS_CLASS_SET_ITERATOR.rawValue] = setIterProto
    }

    /// Creates a Map/Set/WeakMap/WeakSet object with a properly initialized
    /// JeffJSMapState payload so prototype methods can find internal storage.
    func newMapOrSetObject(classID: Int, isWeak: Bool) -> JeffJSValue {
        let result = newObjectClass(classID: classID)
        if result.isException { return result }
        if let jsObj = result.toObject() {
            let s = JeffJSMapState(isWeak: isWeak)
            s.hashSize = 4
            s.hashTable = [Int](repeating: -1, count: 4)
            s.count = 0
            s.records = []
            jsObj.payload = .mapState(s)
        }
        return result
    }

    /// Adds ArrayBuffer, SharedArrayBuffer, DataView, and all TypedArray types.
    /// Mirrors `JS_AddIntrinsicTypedArrays()` from QuickJS.
    func addIntrinsicTypedArrays() {
        // ArrayBuffer — constructor now allocates bytes
        let abProto = newObjectClass(classID: JSClassID.JS_CLASS_OBJECT.rawValue)
        classProto[JSClassID.JS_CLASS_ARRAY_BUFFER.rawValue] = abProto

        let abCtor = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .exception }
            return jsArrayBuffer_constructor(self, thisVal, args)
        }, name: "ArrayBuffer", length: 1)

        // ArrayBuffer.isView(arg) — static method
        let abIsViewFn = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .exception }
            return jsArrayBuffer_isView(self, thisVal, args)
        }, name: "isView", length: 1)
        _ = setPropertyStr(obj: abCtor, name: "isView", value: abIsViewFn)

        // ArrayBuffer.prototype.byteLength — getter
        if let abProtoObj = abProto.toObject() {
            jeffJS_addGetterProperty(ctx: self, proto: abProtoObj, name: "byteLength") { ctx, this in
                return jsArrayBuffer_byteLength(ctx, this)
            }
            // ArrayBuffer.prototype.slice(begin, end)
            jeffJS_defineBuiltinFunc(ctx: self, obj: abProtoObj, name: "slice", length: 2) { ctx, this, args in
                return jsArrayBuffer_slice(ctx, this, args)
            }
            // ArrayBuffer.prototype.resize(newLength)
            jeffJS_defineBuiltinFunc(ctx: self, obj: abProtoObj, name: "resize", length: 1) { ctx, this, args in
                return jsArrayBuffer_resize(ctx, this, args)
            }
            // ArrayBuffer.prototype.transfer()
            jeffJS_defineBuiltinFunc(ctx: self, obj: abProtoObj, name: "transfer", length: 0) { ctx, this, args in
                return jsArrayBuffer_transfer(ctx, this, args)
            }
            // ArrayBuffer.prototype.transferToFixedLength()
            jeffJS_defineBuiltinFunc(ctx: self, obj: abProtoObj, name: "transferToFixedLength", length: 0) { ctx, this, args in
                return jsArrayBuffer_transfer(ctx, this, args)
            }
            // ArrayBuffer.prototype.maxByteLength — getter
            jeffJS_addGetterProperty(ctx: self, proto: abProtoObj, name: "maxByteLength") { ctx, this in
                return jsArrayBuffer_maxByteLength(ctx, this)
            }
            // ArrayBuffer.prototype.resizable — getter
            jeffJS_addGetterProperty(ctx: self, proto: abProtoObj, name: "resizable") { ctx, this in
                return jsArrayBuffer_resizable(ctx, this)
            }
            // ArrayBuffer.prototype.detached — getter
            jeffJS_addGetterProperty(ctx: self, proto: abProtoObj, name: "detached") { ctx, this in
                return jsArrayBuffer_detached(ctx, this)
            }
        }

        _ = setPropertyStr(obj: globalObj, name: "ArrayBuffer", value: abCtor)

        // SharedArrayBuffer
        let sabProto = newObjectClass(classID: JSClassID.JS_CLASS_OBJECT.rawValue)
        classProto[JSClassID.JS_CLASS_SHARED_ARRAY_BUFFER.rawValue] = sabProto

        let sabCtor = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .exception }
            return jsSharedArrayBuffer_constructor(self, thisVal, args)
        }, name: "SharedArrayBuffer", length: 1)

        if let sabProtoObj = sabProto.toObject() {
            jeffJS_addGetterProperty(ctx: self, proto: sabProtoObj, name: "byteLength") { ctx, this in
                return jsArrayBuffer_byteLength(ctx, this)
            }
            jeffJS_defineBuiltinFunc(ctx: self, obj: sabProtoObj, name: "grow", length: 1) { ctx, this, args in
                return jsSharedArrayBuffer_grow(ctx, this, args)
            }
            jeffJS_addGetterProperty(ctx: self, proto: sabProtoObj, name: "growable") { ctx, this in
                return jsSharedArrayBuffer_growable(ctx, this)
            }
            jeffJS_addGetterProperty(ctx: self, proto: sabProtoObj, name: "maxByteLength") { ctx, this in
                return jsArrayBuffer_maxByteLength(ctx, this)
            }
            jeffJS_defineBuiltinFunc(ctx: self, obj: sabProtoObj, name: "slice", length: 2) { ctx, this, args in
                return jsArrayBuffer_slice(ctx, this, args)
            }
        }

        _ = setPropertyStr(obj: globalObj, name: "SharedArrayBuffer", value: sabCtor)

        // DataView
        let dvProto = newObjectClass(classID: JSClassID.JS_CLASS_OBJECT.rawValue)
        classProto[JSClassID.JS_CLASS_DATAVIEW.rawValue] = dvProto

        let dvCtor = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .exception }
            return jsDataView_constructor(self, thisVal, args)
        }, name: "DataView", length: 1)

        if let dvProtoObj = dvProto.toObject() {
            // DataView getters
            jeffJS_addGetterProperty(ctx: self, proto: dvProtoObj, name: "buffer") { ctx, this in
                return jsDataView_buffer(ctx, this)
            }
            jeffJS_addGetterProperty(ctx: self, proto: dvProtoObj, name: "byteLength") { ctx, this in
                return jsDataView_byteLength(ctx, this)
            }
            jeffJS_addGetterProperty(ctx: self, proto: dvProtoObj, name: "byteOffset") { ctx, this in
                return jsDataView_byteOffset(ctx, this)
            }
            // DataView get methods
            jeffJS_defineBuiltinFunc(ctx: self, obj: dvProtoObj, name: "getInt8", length: 1, func: jsDataView_getInt8)
            jeffJS_defineBuiltinFunc(ctx: self, obj: dvProtoObj, name: "getUint8", length: 1, func: jsDataView_getUint8)
            jeffJS_defineBuiltinFunc(ctx: self, obj: dvProtoObj, name: "getInt16", length: 1, func: jsDataView_getInt16)
            jeffJS_defineBuiltinFunc(ctx: self, obj: dvProtoObj, name: "getUint16", length: 1, func: jsDataView_getUint16)
            jeffJS_defineBuiltinFunc(ctx: self, obj: dvProtoObj, name: "getInt32", length: 1, func: jsDataView_getInt32)
            jeffJS_defineBuiltinFunc(ctx: self, obj: dvProtoObj, name: "getUint32", length: 1, func: jsDataView_getUint32)
            jeffJS_defineBuiltinFunc(ctx: self, obj: dvProtoObj, name: "getFloat32", length: 1, func: jsDataView_getFloat32)
            jeffJS_defineBuiltinFunc(ctx: self, obj: dvProtoObj, name: "getFloat64", length: 1, func: jsDataView_getFloat64)
            jeffJS_defineBuiltinFunc(ctx: self, obj: dvProtoObj, name: "getBigInt64", length: 1, func: jsDataView_getBigInt64)
            jeffJS_defineBuiltinFunc(ctx: self, obj: dvProtoObj, name: "getBigUint64", length: 1, func: jsDataView_getBigUint64)
            jeffJS_defineBuiltinFunc(ctx: self, obj: dvProtoObj, name: "getFloat16", length: 1, func: jsDataView_getFloat16)
            // DataView set methods
            jeffJS_defineBuiltinFunc(ctx: self, obj: dvProtoObj, name: "setInt8", length: 2, func: jsDataView_setInt8)
            jeffJS_defineBuiltinFunc(ctx: self, obj: dvProtoObj, name: "setUint8", length: 2, func: jsDataView_setUint8)
            jeffJS_defineBuiltinFunc(ctx: self, obj: dvProtoObj, name: "setInt16", length: 2, func: jsDataView_setInt16)
            jeffJS_defineBuiltinFunc(ctx: self, obj: dvProtoObj, name: "setUint16", length: 2, func: jsDataView_setUint16)
            jeffJS_defineBuiltinFunc(ctx: self, obj: dvProtoObj, name: "setInt32", length: 2, func: jsDataView_setInt32)
            jeffJS_defineBuiltinFunc(ctx: self, obj: dvProtoObj, name: "setUint32", length: 2, func: jsDataView_setUint32)
            jeffJS_defineBuiltinFunc(ctx: self, obj: dvProtoObj, name: "setFloat32", length: 2, func: jsDataView_setFloat32)
            jeffJS_defineBuiltinFunc(ctx: self, obj: dvProtoObj, name: "setFloat64", length: 2, func: jsDataView_setFloat64)
            jeffJS_defineBuiltinFunc(ctx: self, obj: dvProtoObj, name: "setBigInt64", length: 2, func: jsDataView_setBigInt64)
            jeffJS_defineBuiltinFunc(ctx: self, obj: dvProtoObj, name: "setBigUint64", length: 2, func: jsDataView_setBigUint64)
            jeffJS_defineBuiltinFunc(ctx: self, obj: dvProtoObj, name: "setFloat16", length: 2, func: jsDataView_setFloat16)
        }

        _ = setPropertyStr(obj: globalObj, name: "DataView", value: dvCtor)

        // Mapping from JSClassID to JeffJSClassID for typed array types.
        // The functions in JeffJSBuiltinTypedArray.swift use JeffJSClassID values.
        let typedArrayNames: [(JSClassID, String, Int)] = [
            (.JS_CLASS_UINT8C_ARRAY,     "Uint8ClampedArray", JeffJSClassID.uint8cArray.rawValue),
            (.JS_CLASS_INT8_ARRAY,       "Int8Array",         JeffJSClassID.int8Array.rawValue),
            (.JS_CLASS_UINT8_ARRAY,      "Uint8Array",        JeffJSClassID.uint8Array.rawValue),
            (.JS_CLASS_INT16_ARRAY,      "Int16Array",        JeffJSClassID.int16Array.rawValue),
            (.JS_CLASS_UINT16_ARRAY,     "Uint16Array",       JeffJSClassID.uint16Array.rawValue),
            (.JS_CLASS_INT32_ARRAY,      "Int32Array",        JeffJSClassID.int32Array.rawValue),
            (.JS_CLASS_UINT32_ARRAY,     "Uint32Array",       JeffJSClassID.uint32Array.rawValue),
            (.JS_CLASS_BIG_INT64_ARRAY,  "BigInt64Array",     JeffJSClassID.bigInt64Array.rawValue),
            (.JS_CLASS_BIG_UINT64_ARRAY, "BigUint64Array",    JeffJSClassID.bigUint64Array.rawValue),
            (.JS_CLASS_FLOAT32_ARRAY,    "Float32Array",      JeffJSClassID.float32Array.rawValue),
            (.JS_CLASS_FLOAT64_ARRAY,    "Float64Array",      JeffJSClassID.float64Array.rawValue),
        ]

        for (jsClassID, name, jeffClassID) in typedArrayNames {
            let proto = newObjectClass(classID: JSClassID.JS_CLASS_OBJECT.rawValue)
            classProto[jsClassID.rawValue] = proto

            let capturedJeffClassID = jeffClassID
            let ctor = newCFunction({ [weak self] ctx, thisVal, args in
                guard let self = self else { return .exception }
                return jsTypedArray_constructor(self, thisVal, args, classID: capturedJeffClassID)
            }, name: name, length: 3)

            // TypedArray.from(source, mapFn?, thisArg?) — static method
            let fromFn = newCFunction({ [weak self] ctx, thisVal, args in
                guard let self = self else { return .exception }
                return jsTypedArray_from(self, thisVal, args, classID: capturedJeffClassID)
            }, name: "from", length: 1)
            _ = setPropertyStr(obj: ctor, name: "from", value: fromFn)

            // TypedArray.of(...items) — static method
            let ofFn = newCFunction({ [weak self] ctx, thisVal, args in
                guard let self = self else { return .exception }
                return jsTypedArray_of(self, thisVal, args, classID: capturedJeffClassID)
            }, name: "of", length: 0)
            _ = setPropertyStr(obj: ctor, name: "of", value: ofFn)

            // BYTES_PER_ELEMENT static property
            if let info = typedArrayInfo(forClassID: capturedJeffClassID) {
                _ = setPropertyStr(obj: ctor, name: "BYTES_PER_ELEMENT",
                                   value: .newInt32(Int32(info.bytesPerElement)))
            }

            // Prototype methods
            if let protoObj = proto.toObject() {
                // Getters
                jeffJS_addGetterProperty(ctx: self, proto: protoObj, name: "buffer") { ctx, this in
                    return jsTypedArray_buffer(ctx, this)
                }
                jeffJS_addGetterProperty(ctx: self, proto: protoObj, name: "byteLength") { ctx, this in
                    return jsTypedArray_byteLength(ctx, this)
                }
                jeffJS_addGetterProperty(ctx: self, proto: protoObj, name: "byteOffset") { ctx, this in
                    return jsTypedArray_byteOffset(ctx, this)
                }
                jeffJS_addGetterProperty(ctx: self, proto: protoObj, name: "length") { ctx, this in
                    return jsTypedArray_length(ctx, this)
                }

                // BYTES_PER_ELEMENT on prototype
                if let info = typedArrayInfo(forClassID: capturedJeffClassID) {
                    jeffJS_setPropertyStr(ctx: self, obj: protoObj, name: "BYTES_PER_ELEMENT",
                                          value: .newInt32(Int32(info.bytesPerElement)))
                }

                // Instance methods
                jeffJS_defineBuiltinFunc(ctx: self, obj: protoObj, name: "at", length: 1, func: jsTypedArray_at)
                jeffJS_defineBuiltinFunc(ctx: self, obj: protoObj, name: "set", length: 1, func: jsTypedArray_set)
                jeffJS_defineBuiltinFunc(ctx: self, obj: protoObj, name: "slice", length: 2, func: jsTypedArray_slice)
                jeffJS_defineBuiltinFunc(ctx: self, obj: protoObj, name: "subarray", length: 2, func: jsTypedArray_subarray)
                jeffJS_defineBuiltinFunc(ctx: self, obj: protoObj, name: "fill", length: 1, func: jsTypedArray_fill)
                jeffJS_defineBuiltinFunc(ctx: self, obj: protoObj, name: "copyWithin", length: 2, func: jsTypedArray_copyWithin)
                jeffJS_defineBuiltinFunc(ctx: self, obj: protoObj, name: "reverse", length: 0, func: jsTypedArray_reverse)
                jeffJS_defineBuiltinFunc(ctx: self, obj: protoObj, name: "indexOf", length: 1, func: jsTypedArray_indexOf)
                jeffJS_defineBuiltinFunc(ctx: self, obj: protoObj, name: "lastIndexOf", length: 1, func: jsTypedArray_lastIndexOf)
                jeffJS_defineBuiltinFunc(ctx: self, obj: protoObj, name: "includes", length: 1, func: jsTypedArray_includes)
                jeffJS_defineBuiltinFunc(ctx: self, obj: protoObj, name: "join", length: 1, func: jsTypedArray_join)
                jeffJS_defineBuiltinFunc(ctx: self, obj: protoObj, name: "toString", length: 0, func: jsTypedArray_toString)
                jeffJS_defineBuiltinFunc(ctx: self, obj: protoObj, name: "toLocaleString", length: 0, func: jsTypedArray_toLocaleString)
            }

            _ = setPropertyStr(obj: globalObj, name: name, value: ctor)
        }
    }

    /// Adds Promise, async function support, generators, and async generators.
    /// Mirrors `JS_AddIntrinsicPromise()` from QuickJS.
    func addIntrinsicPromise() {
        // Promise
        let promiseProto = newObjectClass(classID: JSClassID.JS_CLASS_OBJECT.rawValue)
        classProto[JSClassID.JS_CLASS_PROMISE.rawValue] = promiseProto

        promiseCtor = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .exception }
            guard !args.isEmpty && args[0].isObject else {
                return self.throwTypeError(message: "Promise resolver is not a function")
            }
            let promiseObj = self.newObjectClass(classID: JSClassID.JS_CLASS_PROMISE.rawValue)
            // In a full implementation, would set up resolve/reject callbacks
            // and call the executor
            return promiseObj
        }, name: "Promise", length: 1)
        _ = setPropertyStr(obj: globalObj, name: "Promise", value: promiseCtor.dupValue())

        // Promise.prototype.then
        let thenFunc = newCFunction({ ctx, thisVal, args in
            // Would register onFulfilled and onRejected handlers
            return .JS_UNDEFINED
        }, name: "then", length: 2)
        _ = setPropertyStr(obj: promiseProto, name: "then", value: thenFunc)

        // Promise.prototype.catch
        let catchFunc = newCFunction({ ctx, thisVal, args in
            return .JS_UNDEFINED
        }, name: "catch", length: 1)
        _ = setPropertyStr(obj: promiseProto, name: "catch", value: catchFunc)

        // Promise.prototype.finally
        let finallyFunc = newCFunction({ ctx, thisVal, args in
            return .JS_UNDEFINED
        }, name: "finally", length: 1)
        _ = setPropertyStr(obj: promiseProto, name: "finally", value: finallyFunc)

        // Promise.resolve, Promise.reject, Promise.all, Promise.race, etc.
        let resolveFunc = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .exception }
            let promise = self.newObjectClass(classID: JSClassID.JS_CLASS_PROMISE.rawValue)
            return promise
        }, name: "resolve", length: 1)
        _ = setPropertyStr(obj: promiseCtor, name: "resolve", value: resolveFunc)

        let rejectFunc = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .exception }
            let promise = self.newObjectClass(classID: JSClassID.JS_CLASS_PROMISE.rawValue)
            return promise
        }, name: "reject", length: 1)
        _ = setPropertyStr(obj: promiseCtor, name: "reject", value: rejectFunc)

        let allFunc = newCFunction({ ctx, thisVal, args in
            return .JS_UNDEFINED
        }, name: "all", length: 1)
        _ = setPropertyStr(obj: promiseCtor, name: "all", value: allFunc)

        let raceFunc = newCFunction({ ctx, thisVal, args in
            return .JS_UNDEFINED
        }, name: "race", length: 1)
        _ = setPropertyStr(obj: promiseCtor, name: "race", value: raceFunc)

        let allSettledFunc = newCFunction({ ctx, thisVal, args in
            return .JS_UNDEFINED
        }, name: "allSettled", length: 1)
        _ = setPropertyStr(obj: promiseCtor, name: "allSettled", value: allSettledFunc)

        let anyFunc = newCFunction({ ctx, thisVal, args in
            return .JS_UNDEFINED
        }, name: "any", length: 1)
        _ = setPropertyStr(obj: promiseCtor, name: "any", value: anyFunc)

        // Generator function prototypes
        let generatorProto = newObjectClass(classID: JSClassID.JS_CLASS_OBJECT.rawValue)
        classProto[JSClassID.JS_CLASS_GENERATOR.rawValue] = generatorProto
        classProto[JSClassID.JS_CLASS_GENERATOR_FUNCTION.rawValue] =
            newObjectClass(classID: JSClassID.JS_CLASS_OBJECT.rawValue)

        // Async function prototypes
        classProto[JSClassID.JS_CLASS_ASYNC_FUNCTION.rawValue] =
            newObjectClass(classID: JSClassID.JS_CLASS_OBJECT.rawValue)
        classProto[JSClassID.JS_CLASS_ASYNC_GENERATOR_FUNCTION.rawValue] =
            newObjectClass(classID: JSClassID.JS_CLASS_OBJECT.rawValue)
        classProto[JSClassID.JS_CLASS_ASYNC_GENERATOR.rawValue] =
            newObjectClass(classID: JSClassID.JS_CLASS_OBJECT.rawValue)

        asyncIteratorProto = newObjectClass(classID: JSClassID.JS_CLASS_OBJECT.rawValue)
    }

    /// Adds the eval() function.
    /// Mirrors `JS_AddIntrinsicEval()` from QuickJS.
    func addIntrinsicEval() {
        evalObj = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self, !args.isEmpty else { return .JS_UNDEFINED }
            guard args[0].isString else {
                // If the argument is not a string, return it unchanged (per spec)
                return args[0].dupValue()
            }
            guard let code = args[0].stringValue?.toSwiftString() else { return .JS_UNDEFINED }
            return self.eval(input: code, filename: "<eval>", evalFlags: JS_EVAL_TYPE_GLOBAL)
        }, name: "eval", length: 1)
        _ = setPropertyStr(obj: globalObj, name: "eval", value: evalObj.dupValue())

        // The native eval pipeline is now wired in evalInternal(input:filename:line:evalFlags:).
        // Do NOT set the evalInternal closure — that would short-circuit the native pipeline.
    }

    // MARK: - Internal Eval

    /// Internal eval implementation.
    /// Mirrors `__JS_EvalInternal()` from QuickJS.
    private func evalInternal(
        input: String,
        filename: String,
        line: Int,
        evalFlags: Int
    ) -> JeffJSValue {
        // Ensure objects created during eval know their owning runtime
        JeffJSGCObjectHeader.activeRuntime = rt

        // Check stack overflow
        if rt.checkStackOverflow() {
            return throwStackOverflow()
        }

        // If we have an eval hook, use it (self.evalInternal is the closure
        // PROPERTY, not this method — must use explicit `self.` to disambiguate)
        if let hook = self.evalInternalHook {
            return hook(self, globalObj, input, filename, line, evalFlags)
        }

        // ---- JeffJS Native Pipeline: Tokenize → Parse → Compile → Execute ----
        return nativeEvalPipeline(input: input, filename: filename, evalFlags: evalFlags)
    }

    /// The actual native evaluation pipeline, separated for crash isolation.
    /// Checks the bytecode cache first — if the same source was compiled before,
    /// reuses the compiled bytecode (skipping tokenize + parse + compile entirely).
    private func nativeEvalPipeline(input: String, filename: String, evalFlags: Int) -> JeffJSValue {
        let isModule = (evalFlags & JS_EVAL_TYPE_MASK) == JS_EVAL_TYPE_MODULE

        // ---- Bytecode cache lookup ----
        // Cache stores SERIALIZED bytecode (not live objects). On cache hit,
        // deserialization creates fresh cpool values in the current context.
        let cacheEnabled: Bool = {
            guard JeffJSConfig.bytecodeEnabled && !isModule else { return false }
            // Exclude small dynamic scripts (eval, onclick, diagnostics)
            if JeffJSConfig.bytecodeExcludePrefixes.contains(where: { filename.hasPrefix($0) }) { return false }
            // If legacy include-prefixes are set, require a match
            if !JeffJSConfig.bytecodePrefixes.isEmpty {
                return JeffJSConfig.bytecodePrefixes.contains(where: { filename.hasPrefix($0) })
            }
            return true  // cache everything not excluded
        }()
        let cacheKey = cacheEnabled ? JeffJSBytecodeCache.hashSource(input) : 0
        if cacheEnabled, let cached = rt.bytecodeCache.lookup(cacheKey) {
            bytecodeCacheHits += 1
            lastBytecodeSize = cached.bytecodeLen
            return executeBytecode(cached)
        }

        // ---- Cache MISS — full pipeline: Tokenize → Parse → Compile ----
        let isStrict = (evalFlags & JS_EVAL_FLAG_STRICT) != 0

        // Step 1+2: Tokenize and parse
        let parseState = JeffJSParseState(
            source: input,
            filename: filename,
            ctx: self
        )
        parseState.isModule = isModule
        parseState.allowHTMLComments = !isModule

        let fd = JeffJSFunctionDefCompiler()
        fd.filename = rt.findAtom(filename)
        fd.source = input
        if isStrict || isModule {
            fd.jsMode = JS_MODE_STRICT
        }

        let parser = JeffJSParser(s: parseState, fd: fd)
        parser.parseProgram()

        if parser.hasError || fd.byteCode.error {
            let detail = parseState.lastErrorMessage ?? "Parse error in \(filename)"
            return throwSyntaxError(message: detail)
        }

        let bcSize = fd.byteCode.len
        if bcSize == 0 {
            return .JS_UNDEFINED
        }
        if bcSize > JeffJSConfig.bytecodeMaxSize {
            return throwInternalError(message: "Bytecode too large (\(bcSize) bytes) for \(filename)")
        }

        // Step 3: Compile (recursively compiles child functions, resolves
        // variables/labels, and produces final bytecode).
        guard let fb = JeffJSCompiler.createFunction(ctx: self, fd: fd) else {
            return throwInternalError(message: "Compilation failed for \(filename)")
        }

        let compiledSize = Self.totalBytecodeLen(fb)
        lastBytecodeSize = compiledSize
        totalBytecodeSize += compiledSize

        // Store serialized bytecode in cache for future evals of the same source
        if cacheEnabled {
            rt.bytecodeCache.store(cacheKey, bytecode: fb)
        }

        return executeBytecode(fb)
    }

    /// Execute a compiled function bytecode on the global object.
    /// Recursively sums bytecodeLen across a function and all nested functions in its cpool.
    static func totalBytecodeLen(_ fb: JeffJSFunctionBytecode) -> Int {
        var total = fb.bytecodeLen
        for val in fb.cpool {
            if let nested = val.toFunctionBytecode() {
                total += totalBytecodeLen(nested)
            }
        }
        return total
    }

    /// Execute precompiled bytecode loaded from a .jfbc file.
    /// Deserializes with atom remapping and runs on the global object.
    func evalPrecompiled(_ bytes: [UInt8]) -> JeffJSValue {
        guard let fb = JeffJSBytecodeDeserializer.deserialize(bytes, rt: rt) else {
            return throwInternalError(message: "Failed to deserialize precompiled bytecode")
        }
        let size = Self.totalBytecodeLen(fb)
        lastBytecodeSize = size
        totalBytecodeSize += size
        return executeBytecode(fb)
    }

    private func executeBytecode(_ fb: JeffJSFunctionBytecode) -> JeffJSValue {
        let funcObj = JeffJSObject()
        funcObj.classID = JeffJSClassID.bytecodeFunction.rawValue
        funcObj.payload = .bytecodeFunc(
            functionBytecode: fb,
            varRefs: [],
            homeObject: nil
        )
        let funcVal = JeffJSValue.makeObject(funcObj)
        let result = JeffJSInterpreter.callInternal(
            ctx: self,
            funcObj: funcVal,
            thisVal: globalObj,
            args: []
        )

        // Drop the extra reference to the temporary wrapper. The funcObj was
        // created solely for this call — closures defined during eval hold their
        // own references to the bytecode through varRefs, independent of this wrapper.
        // Without this freeValue, each eval leaks ~200B of bytecode + cpool.
        funcVal.freeValue()

        // Drain microtask queue (promise reactions) after eval,
        // matching browser/QuickJS behavior.
        _ = rt.executePendingJobs()

        return result
    }

    // MARK: - Private Initialization Helpers

    /// Creates and configures the global object.
    private func initGlobalObject() {
        let obj = JeffJSObject()
        obj.classID = JSClassID.JS_CLASS_OBJECT.rawValue
        obj.extensible = true
        obj.shape = createShape(self, proto: nil, hashSize: JS_PROP_INITIAL_HASH_SIZE, propSize: JS_PROP_INITIAL_SIZE)
        obj.prop = []
        globalObj = JeffJSValue.makeObject(obj)
        globalVarObj = globalObj.dupValue()
    }

    /// Adds methods to Object.prototype.
    /// Sets a non-enumerable, writable, configurable property on an object.
    /// Used for prototype methods which must not appear in for-in iteration
    /// (ES spec requires built-in prototype methods to be non-enumerable).
    private func setNonEnumerableProperty(obj: JeffJSValue, name: String, value: JeffJSValue) {
        let atom = rt.findAtom(name)
        _ = definePropertyValue(obj: obj, atom: atom, value: value,
                                flags: JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE)
        rt.freeAtom(atom)
    }

    private func addObjectProtoMethods(_ proto: JeffJSValue) {
        // Object.prototype.toString
        let toStringFunc = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .exception }
            if thisVal.isNull {
                return self.newStringValue("[object Null]")
            }
            if thisVal.isUndefined {
                return self.newStringValue("[object Undefined]")
            }
            // For objects, get the class name
            if let obj = thisVal.toObject() {
                let classID = obj.classID
                if classID < self.rt.classCount {
                    let nameAtom = self.rt.classArray[classID].classNameAtom
                    if let name = self.rt.atomToString(nameAtom) {
                        return self.newStringValue("[object \(name)]")
                    }
                }
            }
            return self.newStringValue("[object Object]")
        }, name: "toString", length: 0)
        setNonEnumerableProperty(obj: proto, name: "toString", value: toStringFunc)

        // Object.prototype.valueOf
        let valueOfFunc = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .exception }
            return self.toObject(thisVal)
        }, name: "valueOf", length: 0)
        setNonEnumerableProperty(obj: proto, name: "valueOf", value: valueOfFunc)

        // Object.prototype.hasOwnProperty
        let hasOwnFunc = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self, !args.isEmpty else { return .JS_FALSE }
            guard let propName = self.toSwiftString(args[0]) else { return .exception }
            let atom = self.rt.findAtom(propName)
            let obj = self.toObject(thisVal)
            if obj.isException {
                self.rt.freeAtom(atom)
                return .exception
            }
            let has = self.getOwnProperty(obj: obj, atom: atom) != nil
            self.rt.freeAtom(atom)
            obj.freeValue()
            return .newBool(has)
        }, name: "hasOwnProperty", length: 1)
        setNonEnumerableProperty(obj: proto, name: "hasOwnProperty", value: hasOwnFunc)

        // Object.prototype.isPrototypeOf
        let isProtoOfFunc = newCFunction({ ctx, thisVal, args in
            return .JS_FALSE  // placeholder
        }, name: "isPrototypeOf", length: 1)
        setNonEnumerableProperty(obj: proto, name: "isPrototypeOf", value: isProtoOfFunc)

        // Object.prototype.propertyIsEnumerable
        let propIsEnumFunc = newCFunction({ ctx, thisVal, args in
            return .JS_FALSE  // placeholder
        }, name: "propertyIsEnumerable", length: 1)
        setNonEnumerableProperty(obj: proto, name: "propertyIsEnumerable", value: propIsEnumFunc)

        // Object.prototype.toLocaleString
        let toLocaleStringFunc = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .exception }
            // Default: call toString()
            return self.toString(thisVal)
        }, name: "toLocaleString", length: 0)
        setNonEnumerableProperty(obj: proto, name: "toLocaleString", value: toLocaleStringFunc)
    }

    /// Adds methods to Function.prototype.
    private func addFunctionProtoMethods(_ proto: JeffJSValue) {
        // Function.prototype.call
        let callFunc = newCFunction({ ctx, thisVal, args in
            // Would call the function with args[0] as this and remaining as args
            return .JS_UNDEFINED
        }, name: "call", length: 1)
        _ = setPropertyStr(obj: proto, name: "call", value: callFunc)

        // Function.prototype.apply
        let applyFunc = newCFunction({ ctx, thisVal, args in
            return .JS_UNDEFINED
        }, name: "apply", length: 2)
        _ = setPropertyStr(obj: proto, name: "apply", value: applyFunc)

        // Function.prototype.bind
        let bindFunc = newCFunction({ ctx, thisVal, args in
            return .JS_UNDEFINED
        }, name: "bind", length: 1)
        _ = setPropertyStr(obj: proto, name: "bind", value: bindFunc)

        // Function.prototype.toString
        let toStringFunc = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .exception }
            return self.newStringValue("function () { [native code] }")
        }, name: "toString", length: 0)
        _ = setPropertyStr(obj: proto, name: "toString", value: toStringFunc)

        // Function.prototype[Symbol.hasInstance]
        let hasInstanceFunc = newCFunction({ ctx, thisVal, args in
            return .JS_FALSE  // placeholder
        }, name: "[Symbol.hasInstance]", length: 1)
        _ = setPropertyStr(obj: proto, name: "@@hasInstance", value: hasInstanceFunc)
    }

    /// Adds Error and NativeError constructors.
    private func addErrorConstructors() {
        // Error prototype
        let errorProto = newObjectClass(classID: JSClassID.JS_CLASS_ERROR.rawValue)
        classProto[JSClassID.JS_CLASS_ERROR.rawValue] = errorProto

        // Error.prototype.__proto__ = Object.prototype
        let objProto = classProto[JSClassID.JS_CLASS_OBJECT.rawValue]
        if let errorProtoObj = errorProto.toObject(), let objProtoObj = objProto.toObject() {
            errorProtoObj.proto = objProtoObj
        }

        // Error.prototype.name = "Error"
        _ = setPropertyStr(obj: errorProto, name: "name", value: newStringValue("Error"))
        // Error.prototype.message = ""
        _ = setPropertyStr(obj: errorProto, name: "message", value: newStringValue(""))

        // Error.prototype.toString
        let errToStringFunc = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .exception }
            let name = self.getPropertyStr(obj: thisVal, name: "name")
            let msg = self.getPropertyStr(obj: thisVal, name: "message")
            let nameStr = self.toSwiftString(name) ?? "Error"
            let msgStr = self.toSwiftString(msg) ?? ""
            name.freeValue()
            msg.freeValue()
            if msgStr.isEmpty {
                return self.newStringValue(nameStr)
            }
            return self.newStringValue("\(nameStr): \(msgStr)")
        }, name: "toString", length: 0)
        _ = setPropertyStr(obj: errorProto, name: "toString", value: errToStringFunc)

        // Error constructor
        let errorCtor = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .exception }
            let errObj = self.newObjectClass(classID: JSClassID.JS_CLASS_ERROR.rawValue)
            var msgStr = ""
            if !args.isEmpty && !args[0].isUndefined {
                msgStr = self.toSwiftString(args[0]) ?? ""
                _ = self.setPropertyStr(obj: errObj, name: "message", value: self.newStringValue(msgStr))
            }
            // Set stack property
            let stackStr = msgStr.isEmpty ? "Error" : "Error: \(msgStr)"
            _ = self.setPropertyStr(obj: errObj, name: "stack", value: self.newStringValue(stackStr))
            return errObj
        }, name: "Error", length: 1)
        // Set Error.prototype on constructor and Error.prototype.constructor = Error
        _ = setPropertyStr(obj: errorCtor, name: "prototype", value: errorProto.dupValue())
        _ = setPropertyStr(obj: errorProto, name: "constructor", value: errorCtor.dupValue())
        _ = setPropertyStr(obj: globalObj, name: "Error", value: errorCtor)

        // Native error types
        let nativeErrorNames: [(JSErrorEnum, String)] = [
            (.JS_EVAL_ERROR, "EvalError"),
            (.JS_RANGE_ERROR, "RangeError"),
            (.JS_REFERENCE_ERROR, "ReferenceError"),
            (.JS_SYNTAX_ERROR, "SyntaxError"),
            (.JS_TYPE_ERROR, "TypeError"),
            (.JS_URI_ERROR, "URIError"),
            (.JS_INTERNAL_ERROR, "InternalError"),
            (.JS_AGGREGATE_ERROR, "AggregateError"),
        ]

        for (errorEnum, name) in nativeErrorNames {
            let nativeProto = newObjectClass(classID: JSClassID.JS_CLASS_ERROR.rawValue)
            // NativeError.prototype.__proto__ = Error.prototype
            if let errorProtoObj = errorProto.toObject(), let nativeProtoObj = nativeProto.toObject() {
                nativeProtoObj.proto = errorProtoObj
            }
            _ = setPropertyStr(obj: nativeProto, name: "name", value: newStringValue(name))
            _ = setPropertyStr(obj: nativeProto, name: "message", value: newStringValue(""))
            nativeErrorProto[errorEnum.rawValue] = nativeProto

            let capturedName = name
            let capturedProto = nativeProto
            let ctor = newCFunction({ [weak self] ctx, thisVal, args in
                guard let self = self else { return .exception }
                let errObj = self.newObjectClass(classID: JSClassID.JS_CLASS_ERROR.rawValue)
                // Set the instance's prototype to the NativeError.prototype
                // so that instanceof NativeError and instanceof Error both work
                if let errJSObj = errObj.toObject(), let nativeProtoObj = capturedProto.toObject() {
                    errJSObj.proto = nativeProtoObj
                }
                var msgStr = ""
                if !args.isEmpty && !args[0].isUndefined {
                    msgStr = self.toSwiftString(args[0]) ?? ""
                    _ = self.setPropertyStr(obj: errObj, name: "message", value: self.newStringValue(msgStr))
                }
                // Set stack property
                let stackStr = msgStr.isEmpty ? capturedName : "\(capturedName): \(msgStr)"
                _ = self.setPropertyStr(obj: errObj, name: "stack", value: self.newStringValue(stackStr))
                return errObj
            }, name: name, length: 1)
            // Set NativeError.prototype on constructor and NativeError.prototype.constructor = NativeError
            _ = setPropertyStr(obj: ctor, name: "prototype", value: nativeProto.dupValue())
            _ = setPropertyStr(obj: nativeProto, name: "constructor", value: ctor.dupValue())
            _ = setPropertyStr(obj: globalObj, name: name, value: ctor)
        }
    }

    /// Adds Array constructor and prototype methods.
    private func addArrayIntrinsic() {
        let arrayProto = newObjectClass(classID: JSClassID.JS_CLASS_ARRAY.rawValue)
        classProto[JSClassID.JS_CLASS_ARRAY.rawValue] = arrayProto

        // Array.prototype.__proto__ = Object.prototype
        // This is required so that `[] instanceof Object` returns true
        // (the prototype chain must be: array -> Array.prototype -> Object.prototype).
        let objProto = classProto[JSClassID.JS_CLASS_OBJECT.rawValue]
        if let arrayProtoObj = arrayProto.toObject(), let objProtoObj = objProto.toObject() {
            arrayProtoObj.proto = objProtoObj
        }

        arrayCtor = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .exception }
            return self.newArray()
        }, name: "Array", length: 1)
        _ = setPropertyStr(obj: globalObj, name: "Array", value: arrayCtor.dupValue())

        // Array.isArray
        let isArrayFunc = newCFunction({ ctx, thisVal, args in
            guard !args.isEmpty else { return .JS_FALSE }
            guard let obj = args[0].toObject() else { return .JS_FALSE }
            return .newBool(obj.classID == JSClassID.JS_CLASS_ARRAY.rawValue)
        }, name: "isArray", length: 1)
        _ = setPropertyStr(obj: arrayCtor, name: "isArray", value: isArrayFunc)

        // Array.prototype.push, pop, shift, unshift, etc.
        // These are placeholders — full implementations would manipulate the fast array.
        let pushFunc = newCFunction({ ctx, thisVal, args in
            return .newInt32(0)
        }, name: "push", length: 1)
        _ = setPropertyStr(obj: arrayProto, name: "push", value: pushFunc)

        let popFunc = newCFunction({ ctx, thisVal, args in
            return .JS_UNDEFINED
        }, name: "pop", length: 0)
        _ = setPropertyStr(obj: arrayProto, name: "pop", value: popFunc)

        // Array.prototype.values (also cached for iterator protocol)
        arrayProtoValues = newCFunction({ ctx, thisVal, args in
            return .JS_UNDEFINED
        }, name: "values", length: 0)
        _ = setPropertyStr(obj: arrayProto, name: "values", value: arrayProtoValues.dupValue())

        // Array prototype: forEach, map, filter, reduce, etc. (placeholders)
        let arrayMethods: [(String, Int)] = [
            ("forEach", 1), ("map", 1), ("filter", 1), ("reduce", 1),
            ("reduceRight", 1), ("find", 1), ("findIndex", 1),
            ("findLast", 1), ("findLastIndex", 1), ("every", 1),
            ("some", 1), ("indexOf", 1), ("lastIndexOf", 1),
            ("includes", 1), ("join", 1), ("reverse", 0),
            ("sort", 1), ("splice", 2), ("slice", 2),
            ("concat", 1), ("fill", 1), ("copyWithin", 2),
            ("flat", 0), ("flatMap", 1), ("at", 1),
            ("shift", 0), ("unshift", 1),
            ("toReversed", 0), ("toSorted", 1), ("toSpliced", 2),
            ("with", 2), ("entries", 0), ("keys", 0),
        ]
        for (name, len) in arrayMethods {
            let fn = newCFunction({ ctx, thisVal, args in
                return .JS_UNDEFINED
            }, name: name, length: len)
            _ = setPropertyStr(obj: arrayProto, name: name, value: fn)
        }

        // Array iterator prototype
        let arrayIterProto = newObjectClass(classID: JSClassID.JS_CLASS_OBJECT.rawValue)
        classProto[JSClassID.JS_CLASS_ARRAY_ITERATOR.rawValue] = arrayIterProto
    }

    /// Adds Number constructor, prototype, and Math object.
    private func addNumberIntrinsic() {
        let numberProto = newObjectClass(classID: JSClassID.JS_CLASS_NUMBER.rawValue)
        classProto[JSClassID.JS_CLASS_NUMBER.rawValue] = numberProto

        let numberCtor = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .exception }
            if args.isEmpty {
                return .newInt32(0)
            }
            if let d = self.toFloat64(args[0]) {
                if d == Double(Int32(d)) && !d.isNaN {
                    return .newInt32(Int32(d))
                }
                return .newFloat64(d)
            }
            return .newInt32(0)
        }, name: "Number", length: 1)
        _ = setPropertyStr(obj: globalObj, name: "Number", value: numberCtor)

        // Number constants
        _ = setPropertyStr(obj: numberCtor, name: "MAX_VALUE",
                           value: .newFloat64(Double.greatestFiniteMagnitude))
        _ = setPropertyStr(obj: numberCtor, name: "MIN_VALUE",
                           value: .newFloat64(Double.leastNonzeroMagnitude))
        _ = setPropertyStr(obj: numberCtor, name: "NaN", value: .newFloat64(Double.nan))
        _ = setPropertyStr(obj: numberCtor, name: "POSITIVE_INFINITY",
                           value: .newFloat64(Double.infinity))
        _ = setPropertyStr(obj: numberCtor, name: "NEGATIVE_INFINITY",
                           value: .newFloat64(-Double.infinity))
        _ = setPropertyStr(obj: numberCtor, name: "EPSILON",
                           value: .newFloat64(Double.ulpOfOne))
        _ = setPropertyStr(obj: numberCtor, name: "MAX_SAFE_INTEGER",
                           value: .newFloat64(Double(JS_MAX_SAFE_INTEGER)))
        _ = setPropertyStr(obj: numberCtor, name: "MIN_SAFE_INTEGER",
                           value: .newFloat64(Double(JS_MIN_SAFE_INTEGER)))

        // Number.isFinite, isNaN, isInteger, isSafeInteger, parseFloat, parseInt
        let isFiniteFunc = newCFunction({ ctx, thisVal, args in
            guard !args.isEmpty else { return .JS_FALSE }
            if args[0].isInt { return .JS_TRUE }
            if args[0].isFloat64 {
                let d = args[0].toFloat64()
                return .newBool(d.isFinite)
            }
            return .JS_FALSE
        }, name: "isFinite", length: 1)
        _ = setPropertyStr(obj: numberCtor, name: "isFinite", value: isFiniteFunc)

        let isNaNFunc = newCFunction({ ctx, thisVal, args in
            guard !args.isEmpty else { return .JS_FALSE }
            if args[0].isFloat64 {
                return .newBool(args[0].toFloat64().isNaN)
            }
            return .JS_FALSE
        }, name: "isNaN", length: 1)
        _ = setPropertyStr(obj: numberCtor, name: "isNaN", value: isNaNFunc)

        // Math object
        let mathObj = newObject()
        _ = setPropertyStr(obj: globalObj, name: "Math", value: mathObj)

        // Math constants
        _ = setPropertyStr(obj: mathObj, name: "E", value: .newFloat64(exp(1.0)))
        _ = setPropertyStr(obj: mathObj, name: "LN10", value: .newFloat64(log(10.0)))
        _ = setPropertyStr(obj: mathObj, name: "LN2", value: .newFloat64(log(2.0)))
        _ = setPropertyStr(obj: mathObj, name: "LOG10E", value: .newFloat64(1.0 / log(10.0)))
        _ = setPropertyStr(obj: mathObj, name: "LOG2E", value: .newFloat64(1.0 / log(2.0)))
        _ = setPropertyStr(obj: mathObj, name: "PI", value: .newFloat64(Double.pi))
        _ = setPropertyStr(obj: mathObj, name: "SQRT1_2", value: .newFloat64(sqrt(0.5)))
        _ = setPropertyStr(obj: mathObj, name: "SQRT2", value: .newFloat64(sqrt(2.0)))

        // Math functions
        let mathAbs = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self, !args.isEmpty, let d = self.toFloat64(args[0]) else {
                return .newFloat64(Double.nan)
            }
            return .newFloat64(abs(d))
        }, name: "abs", length: 1)
        _ = setPropertyStr(obj: mathObj, name: "abs", value: mathAbs)

        let mathFloor = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self, !args.isEmpty, let d = self.toFloat64(args[0]) else {
                return .newFloat64(Double.nan)
            }
            return .newFloat64(floor(d))
        }, name: "floor", length: 1)
        _ = setPropertyStr(obj: mathObj, name: "floor", value: mathFloor)

        let mathCeil = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self, !args.isEmpty, let d = self.toFloat64(args[0]) else {
                return .newFloat64(Double.nan)
            }
            return .newFloat64(ceil(d))
        }, name: "ceil", length: 1)
        _ = setPropertyStr(obj: mathObj, name: "ceil", value: mathCeil)

        let mathRound = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self, !args.isEmpty, let d = self.toFloat64(args[0]) else {
                return .newFloat64(Double.nan)
            }
            return .newFloat64(Foundation.round(d))
        }, name: "round", length: 1)
        _ = setPropertyStr(obj: mathObj, name: "round", value: mathRound)

        let mathRandom = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .newFloat64(0) }
            // xorshift64*
            var x = self.randomState
            x ^= x >> 12
            x ^= x << 25
            x ^= x >> 27
            self.randomState = x
            let result = Double(x &* 0x2545F4914F6CDD1D >> 11) / Double(1 << 53)
            return .newFloat64(result)
        }, name: "random", length: 0)
        _ = setPropertyStr(obj: mathObj, name: "random", value: mathRandom)

        // Math.max, Math.min
        let mathMax = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .newFloat64(-Double.infinity) }
            if args.isEmpty { return .newFloat64(-Double.infinity) }
            var result = -Double.infinity
            for arg in args {
                if let d = self.toFloat64(arg) {
                    if d.isNaN { return .newFloat64(Double.nan) }
                    if d > result { result = d }
                }
            }
            return .newFloat64(result)
        }, name: "max", length: 2)
        _ = setPropertyStr(obj: mathObj, name: "max", value: mathMax)

        let mathMin = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .newFloat64(Double.infinity) }
            if args.isEmpty { return .newFloat64(Double.infinity) }
            var result = Double.infinity
            for arg in args {
                if let d = self.toFloat64(arg) {
                    if d.isNaN { return .newFloat64(Double.nan) }
                    if d < result { result = d }
                }
            }
            return .newFloat64(result)
        }, name: "min", length: 2)
        _ = setPropertyStr(obj: mathObj, name: "min", value: mathMin)

        // Remaining Math functions (sin, cos, sqrt, pow, log, exp, etc.)
        let mathUnaryFuncs: [(String, (Double) -> Double)] = [
            ("sin", sin), ("cos", cos), ("tan", tan),
            ("asin", asin), ("acos", acos), ("atan", atan),
            ("sinh", sinh), ("cosh", cosh), ("tanh", tanh),
            ("asinh", asinh), ("acosh", acosh), ("atanh", atanh),
            ("sqrt", sqrt), ("cbrt", cbrt),
            ("exp", exp), ("expm1", expm1),
            ("log", log), ("log2", log2), ("log10", log10), ("log1p", log1p),
            ("trunc", trunc), ("sign", { $0 > 0 ? 1 : ($0 < 0 ? -1 : $0) }),
            ("fround", { Double(Float($0)) }),
        ]
        for (name, mathFn) in mathUnaryFuncs {
            let capturedFn = mathFn
            let fn = newCFunction({ [weak self] ctx, thisVal, args in
                guard let self = self, !args.isEmpty, let d = self.toFloat64(args[0]) else {
                    return .newFloat64(Double.nan)
                }
                return .newFloat64(capturedFn(d))
            }, name: name, length: 1)
            _ = setPropertyStr(obj: mathObj, name: name, value: fn)
        }

        // Math.pow, Math.atan2, Math.hypot, Math.imul, Math.clz32
        let mathPow = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self, args.count >= 2,
                  let b = self.toFloat64(args[0]), let e = self.toFloat64(args[1]) else {
                return .newFloat64(Double.nan)
            }
            return .newFloat64(Foundation.pow(b, e))
        }, name: "pow", length: 2)
        _ = setPropertyStr(obj: mathObj, name: "pow", value: mathPow)

        let mathAtan2 = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self, args.count >= 2,
                  let y = self.toFloat64(args[0]), let x = self.toFloat64(args[1]) else {
                return .newFloat64(Double.nan)
            }
            return .newFloat64(atan2(y, x))
        }, name: "atan2", length: 2)
        _ = setPropertyStr(obj: mathObj, name: "atan2", value: mathAtan2)

        // Math.hypot(...values)
        let mathHypot = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .newFloat64(0.0) }
            if args.isEmpty { return .newFloat64(0.0) }
            var hasNaN = false
            var values = [Double]()
            values.reserveCapacity(args.count)
            for arg in args {
                if let d = self.toFloat64(arg) {
                    if d.isInfinite { return .newFloat64(Double.infinity) }
                    if d.isNaN { hasNaN = true }
                    values.append(d)
                } else {
                    hasNaN = true
                    values.append(Double.nan)
                }
            }
            if hasNaN { return .newFloat64(Double.nan) }
            var maxVal = 0.0
            for v in values {
                let a = Swift.abs(v)
                if a > maxVal { maxVal = a }
            }
            if maxVal == 0 { return .newFloat64(0.0) }
            var sum = 0.0
            for v in values {
                let normalized = v / maxVal
                sum += normalized * normalized
            }
            return .newFloat64(maxVal * sqrt(sum))
        }, name: "hypot", length: 2)
        _ = setPropertyStr(obj: mathObj, name: "hypot", value: mathHypot)

        // Math.imul(a, b)
        let mathImul = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .newInt32(0) }
            let a: Int32
            let b: Int32
            if args.count >= 1, let d = self.toFloat64(args[0]) {
                a = JeffJSTypeConvert.doubleToInt32(d)
            } else { a = 0 }
            if args.count >= 2, let d = self.toFloat64(args[1]) {
                b = JeffJSTypeConvert.doubleToInt32(d)
            } else { b = 0 }
            return .newInt32(a &* b)
        }, name: "imul", length: 2)
        _ = setPropertyStr(obj: mathObj, name: "imul", value: mathImul)

        // Math.clz32(x)
        let mathClz32 = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .newInt32(32) }
            let n: Int32
            if args.count >= 1, let d = self.toFloat64(args[0]) {
                n = JeffJSTypeConvert.doubleToInt32(d)
            } else { n = 0 }
            let u = UInt32(bitPattern: n)
            return .newInt32(Int32(u == 0 ? 32 : u.leadingZeroBitCount))
        }, name: "clz32", length: 1)
        _ = setPropertyStr(obj: mathObj, name: "clz32", value: mathClz32)
    }

    /// Adds String constructor and prototype methods.
    private func addStringIntrinsic() {
        let stringProto = newObjectClass(classID: JSClassID.JS_CLASS_STRING.rawValue)
        classProto[JSClassID.JS_CLASS_STRING.rawValue] = stringProto

        let stringCtor = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .exception }
            if args.isEmpty {
                return self.newStringValue("")
            }
            return self.toString(args[0])
        }, name: "String", length: 1)
        _ = setPropertyStr(obj: globalObj, name: "String", value: stringCtor)

        // String.fromCharCode
        let fromCharCodeFunc = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .exception }
            var result = ""
            for arg in args {
                if let n = self.toInt32(arg) {
                    let codeUnit = UInt16(truncatingIfNeeded: n)
                    result += String(UnicodeScalar(UInt32(codeUnit)) ?? UnicodeScalar(0xFFFD)!)
                }
            }
            return self.newStringValue(result)
        }, name: "fromCharCode", length: 1)
        _ = setPropertyStr(obj: stringCtor, name: "fromCharCode", value: fromCharCodeFunc)

        // String iterator prototype
        let stringIterProto = newObjectClass(classID: JSClassID.JS_CLASS_OBJECT.rawValue)
        classProto[JSClassID.JS_CLASS_STRING_ITERATOR.rawValue] = stringIterProto
    }

    /// Adds Boolean constructor.
    private func addBooleanIntrinsic() {
        let boolProto = newObjectClass(classID: JSClassID.JS_CLASS_BOOLEAN.rawValue)
        classProto[JSClassID.JS_CLASS_BOOLEAN.rawValue] = boolProto

        let boolCtor = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .exception }
            let val = args.isEmpty ? false : self.toBool(args[0])
            return .newBool(val)
        }, name: "Boolean", length: 1)
        _ = setPropertyStr(obj: globalObj, name: "Boolean", value: boolCtor)
    }

    /// Adds Symbol constructor with prototype methods and well-known symbols.
    private func addSymbolIntrinsic() {
        let symbolProto = newObjectClass(classID: JSClassID.JS_CLASS_OBJECT.rawValue)
        classProto[JSClassID.JS_CLASS_SYMBOL.rawValue] = symbolProto

        // Symbol.prototype.toString()
        let symToString = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .exception }
            let desc: String
            if thisVal.isSymbol {
                desc = getSymbolDescription(thisVal)
            } else if let obj = thisVal.toObject(),
                      obj.classID == JeffJSClassID.symbol.rawValue,
                      case .objectData(let inner) = obj.payload {
                desc = getSymbolDescription(inner)
            } else {
                return self.throwTypeError(message: "Symbol.prototype.toString requires a Symbol value")
            }
            return self.newStringValue("Symbol(\(desc))")
        }, name: "toString", length: 0)
        _ = setPropertyStr(obj: symbolProto, name: "toString", value: symToString)

        // Symbol.prototype.valueOf()
        let symValueOf = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .exception }
            if thisVal.isSymbol {
                return thisVal.dupValue()
            }
            if let obj = thisVal.toObject(),
               obj.classID == JeffJSClassID.symbol.rawValue,
               case .objectData(let inner) = obj.payload {
                return inner.dupValue()
            }
            return self.throwTypeError(message: "Symbol.prototype.valueOf requires a Symbol value")
        }, name: "valueOf", length: 0)
        _ = setPropertyStr(obj: symbolProto, name: "valueOf", value: symValueOf)

        // Symbol.prototype.description getter
        let symDescGetter = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .exception }
            let desc: String
            if thisVal.isSymbol {
                desc = getSymbolDescription(thisVal)
            } else if let obj = thisVal.toObject(),
                      obj.classID == JeffJSClassID.symbol.rawValue,
                      case .objectData(let inner) = obj.payload {
                desc = getSymbolDescription(inner)
            } else {
                return self.throwTypeError(message: "Symbol.prototype.description getter requires a Symbol value")
            }
            if desc.isEmpty { return .JS_UNDEFINED }
            return self.newStringValue(desc)
        }, name: "get description", length: 0)
        setPropertyGetSet(obj: symbolProto, name: "description", getter: symDescGetter, setter: nil)

        // Symbol constructor -- constructorOrFunc so we can reject `new Symbol()`
        let symCtorObj = JeffJSObject()
        symCtorObj.classID = JSClassID.JS_CLASS_C_FUNCTION.rawValue
        symCtorObj.extensible = true
        symCtorObj.isConstructor = false  // Symbol cannot be used with `new`
        symCtorObj.payload = .cFunc(
            realm: self,
            cFunction: .constructorOrFunc({ [weak self] ctx, thisVal, args, isNew in
                guard let self = self else { return .exception }
                if isNew {
                    return self.throwTypeError(message: "Symbol is not a constructor")
                }
                let desc = (!args.isEmpty && !args[0].isUndefined) ? (self.toSwiftString(args[0]) ?? "") : ""
                let symStr = JeffJSString(swiftString: desc)
                symStr.atomType = JSAtomType.symbol.rawValue
                return JeffJSValue.mkPtr(tag: .symbol, ptr: symStr)
            }),
            length: 0,
            cproto: UInt8(JS_CFUNC_CONSTRUCTOR_OR_FUNC),
            magic: 0
        )
        // Set prototype to Function.prototype
        let symCtorProtoObj = functionProto.isObject ? functionProto.toObject() : nil
        if functionProto.isObject {
            _ = functionProto.dupValue()
        }
        symCtorObj.shape = createShape(self, proto: symCtorProtoObj, hashSize: JS_PROP_INITIAL_HASH_SIZE, propSize: JS_PROP_INITIAL_SIZE)
        symCtorObj.proto = symCtorProtoObj
        let symbolCtor = JeffJSValue.makeObject(symCtorObj)

        // Set name and length on the Symbol constructor
        let symNameAtom = rt.findAtom("Symbol")
        _ = setPropertyInternal(obj: symbolCtor, atom: symNameAtom, value: newStringValue("Symbol"), flags: JS_PROP_CONFIGURABLE)
        rt.freeAtom(symNameAtom)
        let symLenAtom = JeffJSAtomID.JS_ATOM_length.rawValue
        _ = setPropertyInternal(obj: symbolCtor, atom: symLenAtom, value: .newInt32(0), flags: JS_PROP_CONFIGURABLE)

        // Symbol.for(key) -- global symbol registry lookup/create
        let symbolFor = newCFunction({ ctx, thisVal, args in
            return js_symbol_for(ctx, thisVal, args)
        }, name: "for", length: 1)
        _ = setPropertyStr(obj: symbolCtor, name: "for", value: symbolFor)

        // Symbol.keyFor(sym) -- reverse lookup in global symbol registry
        let symbolKeyFor = newCFunction({ ctx, thisVal, args in
            return js_symbol_keyFor(ctx, thisVal, args)
        }, name: "keyFor", length: 1)
        _ = setPropertyStr(obj: symbolCtor, name: "keyFor", value: symbolKeyFor)

        // Install well-known symbols as static properties on Symbol
        let wellKnownSymbols: [(String, String)] = [
            ("asyncIterator",      "Symbol.asyncIterator"),
            ("hasInstance",        "Symbol.hasInstance"),
            ("isConcatSpreadable", "Symbol.isConcatSpreadable"),
            ("iterator",          "Symbol.iterator"),
            ("match",             "Symbol.match"),
            ("matchAll",          "Symbol.matchAll"),
            ("replace",           "Symbol.replace"),
            ("search",            "Symbol.search"),
            ("split",             "Symbol.split"),
            ("species",           "Symbol.species"),
            ("toPrimitive",       "Symbol.toPrimitive"),
            ("toStringTag",       "Symbol.toStringTag"),
            ("unscopables",       "Symbol.unscopables"),
        ]
        for (name, desc) in wellKnownSymbols {
            let symStr = JeffJSString(swiftString: desc)
            symStr.atomType = JSAtomType.symbol.rawValue
            let symVal = JeffJSValue.mkPtr(tag: .symbol, ptr: symStr)
            _ = setPropertyStr(obj: symbolCtor, name: name, value: symVal)
        }

        _ = setPropertyStr(obj: globalObj, name: "Symbol", value: symbolCtor)
    }

    /// Ensures keyword-named and late-bound builtin methods are registered
    /// on their prototypes / constructors. Earlier registration passes may
    /// silently fail for property names that collide with JS keywords
    /// ("delete", "for", "finally") or that depend on objects not yet fully
    /// wired at the time of first registration. This runs after ALL phases
    /// and serves as the single authoritative fix-up.
    private func fixUpKeywordNamedMethods() {
        // --- Symbol.for / Symbol.keyFor (static methods on Symbol constructor) ---
        let symbolCtor = getPropertyStr(obj: globalObj, name: "Symbol")
        if symbolCtor.isObject {
            let existingFor = getPropertyStr(obj: symbolCtor, name: "for")
            if existingFor.isUndefined {
                let symbolForFunc = newCFunction({ ctx, thisVal, args in
                    return js_symbol_for(ctx, thisVal, args)
                }, name: "for", length: 1)
                _ = setPropertyStr(obj: symbolCtor, name: "for", value: symbolForFunc)
            }

            let existingKeyFor = getPropertyStr(obj: symbolCtor, name: "keyFor")
            if existingKeyFor.isUndefined {
                let symbolKeyForFunc = newCFunction({ ctx, thisVal, args in
                    return js_symbol_keyFor(ctx, thisVal, args)
                }, name: "keyFor", length: 1)
                _ = setPropertyStr(obj: symbolCtor, name: "keyFor", value: symbolKeyForFunc)
            }
        }

        // --- Promise.prototype.finally ---
        let promiseCtor = getPropertyStr(obj: globalObj, name: "Promise")
        if promiseCtor.isObject {
            let promiseProto = getPropertyStr(obj: promiseCtor, name: "prototype")
            if promiseProto.isObject {
                let existingFinally = getPropertyStr(obj: promiseProto, name: "finally")
                if existingFinally.isUndefined {
                    let finallyFunc = newCFunction({ ctx, thisVal, args in
                        return JeffJSBuiltinPromise.finally_(ctx: ctx, this: thisVal, args: args)
                    }, name: "finally", length: 1)
                    _ = setPropertyStr(obj: promiseProto, name: "finally", value: finallyFunc)
                }
            }
        }
    }

    /// Adds BigInt constructor, prototype methods, and static methods.
    private func addBigIntIntrinsic() {
        let bigIntProto = newObjectClass(classID: JSClassID.JS_CLASS_OBJECT.rawValue)
        classProto[JSClassID.JS_CLASS_BIG_INT.rawValue] = bigIntProto

        // BigInt(value) constructor — converts argument to BigInt
        let bigIntCtor = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .exception }
            if args.isEmpty {
                return JeffJSValue.mkShortBigInt(0)
            }
            let arg = args[0]
            // Already a BigInt: return as-is
            if arg.isBigInt || arg.isShortBigInt {
                return arg
            }
            // Number -> BigInt (must be an integer)
            if arg.isInt {
                return JeffJSValue.mkShortBigInt(Int64(arg.toInt32()))
            }
            if arg.isFloat64 {
                let d = arg.toFloat64()
                if d.isNaN || d.isInfinite || d != Foundation.floor(d) {
                    return self.throwRangeError("Cannot convert non-integer to BigInt")
                }
                if d > Double(Int64.max) || d < Double(Int64.min) {
                    return self.throwRangeError("BigInt value out of Int64 range")
                }
                return JeffJSValue.mkShortBigInt(Int64(d))
            }
            // Boolean -> BigInt
            if arg.isBool {
                return JeffJSValue.mkShortBigInt(arg.toBool() ? 1 : 0)
            }
            // String -> BigInt
            if arg.isString, let s = arg.stringValue {
                let str = s.toSwiftString().trimmingCharacters(in: .whitespaces)
                if str.isEmpty {
                    return self.throwSyntaxError("Cannot convert empty string to BigInt")
                }
                // Handle hex (0x), octal (0o), binary (0b) prefixes
                var parseStr = str
                var radix = 10
                if str.hasPrefix("0x") || str.hasPrefix("0X") {
                    parseStr = String(str.dropFirst(2))
                    radix = 16
                } else if str.hasPrefix("0o") || str.hasPrefix("0O") {
                    parseStr = String(str.dropFirst(2))
                    radix = 8
                } else if str.hasPrefix("0b") || str.hasPrefix("0B") {
                    parseStr = String(str.dropFirst(2))
                    radix = 2
                }
                var negative = false
                if parseStr.hasPrefix("-") {
                    negative = true
                    parseStr = String(parseStr.dropFirst())
                } else if parseStr.hasPrefix("+") {
                    parseStr = String(parseStr.dropFirst())
                }
                if let value = UInt64(parseStr, radix: radix) {
                    let result = negative ? -Int64(bitPattern: value) : Int64(bitPattern: value)
                    return JeffJSValue.mkShortBigInt(result)
                }
                return self.throwSyntaxError("Cannot convert \(str) to BigInt")
            }
            return self.throwTypeError("Cannot convert to BigInt")
        }, name: "BigInt", length: 1)

        // BigInt.prototype.toString(radix?)
        if let protoObj = bigIntProto.toObject() {
            jeffJS_defineBuiltinFunc(ctx: self, obj: protoObj, name: "toString", length: 1) { ctx, this, args in
                return JeffJSBuiltinBigInt.toString(ctx: ctx, this: this, args: args)
            }
            // BigInt.prototype.valueOf()
            jeffJS_defineBuiltinFunc(ctx: self, obj: protoObj, name: "valueOf", length: 0) { ctx, this, args in
                return JeffJSBuiltinBigInt.valueOf(ctx: ctx, this: this, args: args)
            }
            // BigInt.prototype.toLocaleString()
            jeffJS_defineBuiltinFunc(ctx: self, obj: protoObj, name: "toLocaleString", length: 0) { ctx, this, args in
                return JeffJSBuiltinBigInt.toLocaleString(ctx: ctx, this: this, args: args)
            }
        }

        // BigInt.asIntN(bits, bigint) — static method
        let asIntNFn = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .exception }
            return JeffJSBuiltinBigInt.asIntN(ctx: self, this: thisVal, args: args)
        }, name: "asIntN", length: 2)
        _ = setPropertyStr(obj: bigIntCtor, name: "asIntN", value: asIntNFn)

        // BigInt.asUintN(bits, bigint) — static method
        let asUintNFn = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .exception }
            return JeffJSBuiltinBigInt.asUintN(ctx: self, this: thisVal, args: args)
        }, name: "asUintN", length: 2)
        _ = setPropertyStr(obj: bigIntCtor, name: "asUintN", value: asUintNFn)

        _ = setPropertyStr(obj: globalObj, name: "BigInt", value: bigIntCtor)
    }

    /// Adds RegExp.prototype methods.
    /// Wires each method to its implementation in JeffJSBuiltinRegExp.swift.
    private func addRegExpProtoMethods(_ proto: JeffJSValue) {
        // exec
        let execFn = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .exception }
            return js_regexp_exec(ctx: self, this: thisVal, argv: Array(args))
        }, name: "exec", length: 1)
        _ = setPropertyStr(obj: proto, name: "exec", value: execFn)

        // test
        let testFn = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .exception }
            return js_regexp_test(ctx: self, this: thisVal, argv: Array(args))
        }, name: "test", length: 1)
        _ = setPropertyStr(obj: proto, name: "test", value: testFn)

        // toString
        let toStringFn = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .exception }
            return js_regexp_toString(ctx: self, this: thisVal, argv: Array(args))
        }, name: "toString", length: 0)
        _ = setPropertyStr(obj: proto, name: "toString", value: toStringFn)

        // compile (legacy Annex B)
        let compileFn = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .exception }
            return js_regexp_compile(ctx: self, this: thisVal, argv: Array(args))
        }, name: "compile", length: 2)
        _ = setPropertyStr(obj: proto, name: "compile", value: compileFn)

        // Symbol.match
        let matchFn = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .exception }
            return js_regexp_Symbol_match(ctx: self, this: thisVal, argv: Array(args))
        }, name: "[Symbol.match]", length: 1)
        _ = setProperty(obj: proto, atom: JSPredefinedAtom.Symbol_match.rawValue, value: matchFn)

        // Symbol.matchAll
        let matchAllFn = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .exception }
            return js_regexp_Symbol_matchAll(ctx: self, this: thisVal, argv: Array(args))
        }, name: "[Symbol.matchAll]", length: 1)
        _ = setProperty(obj: proto, atom: JSPredefinedAtom.Symbol_matchAll.rawValue, value: matchAllFn)

        // Symbol.replace
        let replaceFn = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .exception }
            return js_regexp_Symbol_replace(ctx: self, this: thisVal, argv: Array(args))
        }, name: "[Symbol.replace]", length: 2)
        _ = setProperty(obj: proto, atom: JSPredefinedAtom.Symbol_replace.rawValue, value: replaceFn)

        // Symbol.search
        let searchFn = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .exception }
            return js_regexp_Symbol_search(ctx: self, this: thisVal, argv: Array(args))
        }, name: "[Symbol.search]", length: 1)
        _ = setProperty(obj: proto, atom: JSPredefinedAtom.Symbol_search.rawValue, value: searchFn)

        // Symbol.split
        let splitFn = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .exception }
            return js_regexp_Symbol_split(ctx: self, this: thisVal, argv: Array(args))
        }, name: "[Symbol.split]", length: 2)
        _ = setProperty(obj: proto, atom: JSPredefinedAtom.Symbol_split.rawValue, value: splitFn)

        // Flag getters: source, flags, global, ignoreCase, multiline, dotAll,
        // unicode, unicodeSets, sticky, hasIndices.
        let flagGetters: [(String, (JeffJSContext, JeffJSValue) -> JeffJSValue)] = [
            ("source", js_regexp_get_source),
            ("flags", { c, t in js_regexp_get_flags(ctx: c, this: t) }),
            ("global", js_regexp_get_global),
            ("ignoreCase", js_regexp_get_ignoreCase),
            ("multiline", js_regexp_get_multiline),
            ("dotAll", js_regexp_get_dotAll),
            ("unicode", js_regexp_get_unicode),
            ("unicodeSets", js_regexp_get_unicodeSets),
            ("sticky", js_regexp_get_sticky),
            ("hasIndices", js_regexp_get_hasIndices),
        ]

        for (name, getterImpl) in flagGetters {
            let getterFn = newCFunction({ [weak self] ctx, thisVal, args in
                guard let self = self else { return .exception }
                return getterImpl(self, thisVal)
            }, name: "get \(name)", length: 0)
            setPropertyGetSet(obj: proto, name: name, getter: getterFn, setter: nil)
        }
    }

    /// Adds Reflect object methods.
    private func addReflectMethods(_ reflectObj: JeffJSValue) {
        // Reflect.apply(target, thisArg, argumentsList)
        let reflApply = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .exception }
            guard args.count >= 3 else {
                return self.throwTypeError(message: "Reflect.apply requires 3 arguments")
            }
            let target = args[0]
            let thisArg = args[1]
            let argList = args[2]
            guard let targetObj = target.toObject(), targetObj.isCallable else {
                return self.throwTypeError(message: "Reflect.apply: target is not callable")
            }
            var callArgs: [JeffJSValue] = []
            if let arrObj = argList.toObject() {
                let lenVal = self.getProperty(obj: argList, atom: JeffJSAtomID.JS_ATOM_length.rawValue)
                let len = max(0, lenVal.isInt ? Int(lenVal.toInt32()) : 0)
                for i in 0..<len {
                    let elem = self.getPropertyByIndex(obj: argList, index: UInt32(i))
                    callArgs.append(elem)
                }
                _ = arrObj // suppress warning
            }
            return self.callFunction(target, thisVal: thisArg, args: callArgs)
        }, name: "apply", length: 3)
        _ = setPropertyStr(obj: reflectObj, name: "apply", value: reflApply)

        // Reflect.construct(target, argumentsList [, newTarget])
        let reflConstruct = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .exception }
            guard args.count >= 2 else {
                return self.throwTypeError(message: "Reflect.construct requires at least 2 arguments")
            }
            let target = args[0]
            guard let targetObj = target.toObject(), targetObj.isConstructor else {
                return self.throwTypeError(message: "Reflect.construct: target is not a constructor")
            }
            let argList = args[1]
            var callArgs: [JeffJSValue] = []
            let lenVal = self.getProperty(obj: argList, atom: JeffJSAtomID.JS_ATOM_length.rawValue)
            let len = max(0, lenVal.isInt ? Int(lenVal.toInt32()) : 0)
            for i in 0..<len {
                callArgs.append(self.getPropertyByIndex(obj: argList, index: UInt32(i)))
            }
            return self.callConstructor(target, args: callArgs)
        }, name: "construct", length: 2)
        _ = setPropertyStr(obj: reflectObj, name: "construct", value: reflConstruct)

        // Reflect.defineProperty(target, propertyKey, attributes)
        let reflDefineProperty = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .exception }
            guard args.count >= 3 else {
                return self.throwTypeError(message: "Reflect.defineProperty requires 3 arguments")
            }
            guard args[0].isObject else {
                return self.throwTypeError(message: "Reflect.defineProperty: target must be an object")
            }
            let target = args[0]
            let key = args[1]
            let desc = args[2]
            if let keyStr = self.toSwiftString(key) {
                let atom = self.rt.findAtom(keyStr)
                // Extract value from descriptor
                let value = desc.isObject ? self.getPropertyStr(obj: desc, name: "value") : .JS_UNDEFINED
                // Extract flags from descriptor
                var flags = JS_PROP_HAS_VALUE | JS_PROP_CONFIGURABLE | JS_PROP_WRITABLE | JS_PROP_ENUMERABLE
                if desc.isObject {
                    let writableVal = self.getPropertyStr(obj: desc, name: "writable")
                    if !writableVal.isUndefined && !writableVal.toBool() {
                        flags &= ~JS_PROP_WRITABLE
                    }
                    let enumVal = self.getPropertyStr(obj: desc, name: "enumerable")
                    if !enumVal.isUndefined && !enumVal.toBool() {
                        flags &= ~JS_PROP_ENUMERABLE
                    }
                    let configVal = self.getPropertyStr(obj: desc, name: "configurable")
                    if !configVal.isUndefined && !configVal.toBool() {
                        flags &= ~JS_PROP_CONFIGURABLE
                    }
                }
                let result = self.defineProperty(obj: target, atom: atom, value: value, flags: flags)
                self.rt.freeAtom(atom)
                return .newBool(result >= 0)
            }
            return .JS_FALSE
        }, name: "defineProperty", length: 3)
        _ = setPropertyStr(obj: reflectObj, name: "defineProperty", value: reflDefineProperty)

        // Reflect.deleteProperty(target, propertyKey)
        let reflDeleteProperty = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .exception }
            guard args.count >= 2 else {
                return self.throwTypeError(message: "Reflect.deleteProperty requires 2 arguments")
            }
            guard args[0].isObject else {
                return self.throwTypeError(message: "Reflect.deleteProperty: target must be an object")
            }
            if let keyStr = self.toSwiftString(args[1]) {
                let atom = self.rt.findAtom(keyStr)
                if let targetObj = args[0].toObject() {
                    _ = jeffJS_deleteProperty(ctx: self, obj: targetObj, atom: atom)
                }
                self.rt.freeAtom(atom)
            }
            return .JS_TRUE
        }, name: "deleteProperty", length: 2)
        _ = setPropertyStr(obj: reflectObj, name: "deleteProperty", value: reflDeleteProperty)

        // Reflect.get(target, propertyKey [, receiver])
        let reflGet = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .exception }
            guard args.count >= 2 else {
                return self.throwTypeError(message: "Reflect.get requires at least 2 arguments")
            }
            guard args[0].isObject else {
                return self.throwTypeError(message: "Reflect.get: target must be an object")
            }
            let receiver = args.count >= 3 ? args[2] : args[0]
            if let keyStr = self.toSwiftString(args[1]) {
                let atom = self.rt.findAtom(keyStr)
                let result = self.getPropertyInternal(obj: args[0], atom: atom, receiver: receiver)
                self.rt.freeAtom(atom)
                return result
            }
            return .JS_UNDEFINED
        }, name: "get", length: 2)
        _ = setPropertyStr(obj: reflectObj, name: "get", value: reflGet)

        // Reflect.getOwnPropertyDescriptor(target, propertyKey)
        let reflGetOwnPropertyDescriptor = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .exception }
            guard args.count >= 2 else {
                return self.throwTypeError(message: "Reflect.getOwnPropertyDescriptor requires 2 arguments")
            }
            guard args[0].isObject else {
                return self.throwTypeError(message: "Reflect.getOwnPropertyDescriptor: target must be an object")
            }
            return self.getOwnPropertyDescriptor(args[0], key: args[1])
        }, name: "getOwnPropertyDescriptor", length: 2)
        _ = setPropertyStr(obj: reflectObj, name: "getOwnPropertyDescriptor", value: reflGetOwnPropertyDescriptor)

        // Reflect.getPrototypeOf(target)
        let reflGetPrototypeOf = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .exception }
            guard !args.isEmpty, args[0].isObject else {
                return self.throwTypeError(message: "Reflect.getPrototypeOf: target must be an object")
            }
            guard let targetObj = args[0].toObject() else { return .null }
            if let p = targetObj.proto {
                return JeffJSValue.makeObject(p).dupValue()
            }
            return .null
        }, name: "getPrototypeOf", length: 1)
        _ = setPropertyStr(obj: reflectObj, name: "getPrototypeOf", value: reflGetPrototypeOf)

        // Reflect.has(target, propertyKey) -- equivalent to `key in target`
        let reflHas = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .exception }
            guard args.count >= 2 else {
                return self.throwTypeError(message: "Reflect.has requires 2 arguments")
            }
            guard args[0].isObject else {
                return self.throwTypeError(message: "Reflect.has: target must be an object")
            }
            if let keyStr = self.toSwiftString(args[1]) {
                let atom = self.rt.findAtom(keyStr)
                let result = self.hasProperty(obj: args[0], atom: atom)
                self.rt.freeAtom(atom)
                return .newBool(result)
            }
            return .JS_FALSE
        }, name: "has", length: 2)
        _ = setPropertyStr(obj: reflectObj, name: "has", value: reflHas)

        // Reflect.isExtensible(target)
        let reflIsExtensible = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .exception }
            guard !args.isEmpty, args[0].isObject else {
                return self.throwTypeError(message: "Reflect.isExtensible: target must be an object")
            }
            guard let targetObj = args[0].toObject() else { return .JS_TRUE }
            return .newBool(targetObj.extensible)
        }, name: "isExtensible", length: 1)
        _ = setPropertyStr(obj: reflectObj, name: "isExtensible", value: reflIsExtensible)

        // Reflect.ownKeys(target)
        // Per ES spec §9.1.12, own property keys are returned in this order:
        // 1. Integer indices in ascending numeric order
        // 2. String keys in insertion order
        // 3. Symbol keys in insertion order
        let reflOwnKeys = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .exception }
            guard !args.isEmpty, args[0].isObject else {
                return self.throwTypeError(message: "Reflect.ownKeys: target must be an object")
            }
            guard let targetObj = args[0].toObject() else { return .exception }
            var intKeys: [(UInt32, JeffJSValue)] = []
            var stringKeys: [JeffJSValue] = []
            var symbolKeys: [JeffJSValue] = []
            if let shape = targetObj.shape {
                for prop in shape.prop {
                    let atom = prop.atom
                    if atom == 0 { continue }
                    if self.rt.atomIsArrayIndex(atom) {
                        if let idx = self.rt.atomToUInt32(atom) {
                            intKeys.append((idx, self.newStringValue(String(idx))))
                        }
                    } else if let entry = self.rt.atomArray[Int(atom)] {
                        let isSymbol = entry.atomType == .JS_ATOM_TYPE_SYMBOL ||
                                       entry.atomType == .JS_ATOM_TYPE_GLOBAL_SYMBOL
                        if isSymbol {
                            symbolKeys.append(self.newStringValue(entry.str))
                        } else {
                            stringKeys.append(self.newStringValue(entry.str))
                        }
                    }
                }
            }
            intKeys.sort { $0.0 < $1.0 }
            var keys: [JeffJSValue] = []
            keys.reserveCapacity(intKeys.count + stringKeys.count + symbolKeys.count)
            for (_, val) in intKeys { keys.append(val) }
            keys.append(contentsOf: stringKeys)
            keys.append(contentsOf: symbolKeys)
            return self.newArrayFrom(keys)
        }, name: "ownKeys", length: 1)
        _ = setPropertyStr(obj: reflectObj, name: "ownKeys", value: reflOwnKeys)

        // Reflect.preventExtensions(target)
        let reflPreventExtensions = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .exception }
            guard !args.isEmpty, args[0].isObject else {
                return self.throwTypeError(message: "Reflect.preventExtensions: target must be an object")
            }
            guard let targetObj = args[0].toObject() else { return .JS_FALSE }
            targetObj.extensible = false
            return .JS_TRUE
        }, name: "preventExtensions", length: 1)
        _ = setPropertyStr(obj: reflectObj, name: "preventExtensions", value: reflPreventExtensions)

        // Reflect.set(target, propertyKey, value [, receiver])
        let reflSet = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .exception }
            guard args.count >= 3 else {
                return self.throwTypeError(message: "Reflect.set requires at least 3 arguments")
            }
            guard args[0].isObject else {
                return self.throwTypeError(message: "Reflect.set: target must be an object")
            }
            if let keyStr = self.toSwiftString(args[1]) {
                let atom = self.rt.findAtom(keyStr)
                let result = self.setPropertyInternal(obj: args[0], atom: atom, value: args[2].dupValue(), flags: 0)
                self.rt.freeAtom(atom)
                return .newBool(result >= 0)
            }
            return .JS_TRUE
        }, name: "set", length: 3)
        _ = setPropertyStr(obj: reflectObj, name: "set", value: reflSet)

        // Reflect.setPrototypeOf(target, proto)
        let reflSetPrototypeOf = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .exception }
            guard args.count >= 2 else {
                return self.throwTypeError(message: "Reflect.setPrototypeOf requires 2 arguments")
            }
            guard args[0].isObject else {
                return self.throwTypeError(message: "Reflect.setPrototypeOf: target must be an object")
            }
            let proto = args[1]
            if !proto.isObject && !proto.isNull {
                return self.throwTypeError(message: "prototype must be an object or null")
            }
            if let targetObj = args[0].toObject() {
                let protoObj = proto.isObject ? proto.toObject() : nil
                targetObj.proto = protoObj
            }
            return .JS_TRUE
        }, name: "setPrototypeOf", length: 2)
        _ = setPropertyStr(obj: reflectObj, name: "setPrototypeOf", value: reflSetPrototypeOf)
    }

    /// Adds global functions: parseInt, parseFloat, isNaN, isFinite, etc.
    private func addGlobalFunctions() {
        // parseInt
        let parseIntFunc = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self, !args.isEmpty else { return .newFloat64(Double.nan) }
            guard let str = self.toSwiftString(args[0]) else { return .newFloat64(Double.nan) }
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            let radix: Int
            if args.count > 1 {
                radix = Int(self.toInt32(args[1]) ?? 10)
            } else {
                radix = trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") ? 16 : 10
            }
            if radix < 2 || radix > 36 { return .newFloat64(Double.nan) }
            if let result = Int(trimmed, radix: radix) {
                return JeffJSValue.newInt64(Int64(result))
            }
            return .newFloat64(Double.nan)
        }, name: "parseInt", length: 2)
        _ = setPropertyStr(obj: globalObj, name: "parseInt", value: parseIntFunc)

        // parseFloat
        let parseFloatFunc = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self, !args.isEmpty else { return .newFloat64(Double.nan) }
            guard let str = self.toSwiftString(args[0]) else { return .newFloat64(Double.nan) }
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            if let d = Double(trimmed) {
                return .newFloat64(d)
            }
            return .newFloat64(Double.nan)
        }, name: "parseFloat", length: 1)
        _ = setPropertyStr(obj: globalObj, name: "parseFloat", value: parseFloatFunc)

        // isNaN
        let isNaNFunc = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self, !args.isEmpty else { return .JS_TRUE }
            if let d = self.toFloat64(args[0]) {
                return .newBool(d.isNaN)
            }
            return .JS_TRUE
        }, name: "isNaN", length: 1)
        _ = setPropertyStr(obj: globalObj, name: "isNaN", value: isNaNFunc)

        // isFinite
        let isFiniteFunc = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self, !args.isEmpty else { return .JS_FALSE }
            if let d = self.toFloat64(args[0]) {
                return .newBool(d.isFinite)
            }
            return .JS_FALSE
        }, name: "isFinite", length: 1)
        _ = setPropertyStr(obj: globalObj, name: "isFinite", value: isFiniteFunc)

        // encodeURI, decodeURI, encodeURIComponent, decodeURIComponent
        let encodeURIFunc = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self, !args.isEmpty, let str = self.toSwiftString(args[0]) else {
                return .JS_UNDEFINED
            }
            let encoded = str.addingPercentEncoding(withAllowedCharacters:
                .urlQueryAllowed.union(.urlPathAllowed).union(.urlHostAllowed)
                    .union(.urlFragmentAllowed)) ?? str
            return self.newStringValue(encoded)
        }, name: "encodeURI", length: 1)
        _ = setPropertyStr(obj: globalObj, name: "encodeURI", value: encodeURIFunc)

        let decodeURIFunc = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self, !args.isEmpty, let str = self.toSwiftString(args[0]) else {
                return .JS_UNDEFINED
            }
            return self.newStringValue(str.removingPercentEncoding ?? str)
        }, name: "decodeURI", length: 1)
        _ = setPropertyStr(obj: globalObj, name: "decodeURI", value: decodeURIFunc)

        let encodeURIComponentFunc = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self, !args.isEmpty, let str = self.toSwiftString(args[0]) else {
                return .JS_UNDEFINED
            }
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()"))
            let encoded = str.addingPercentEncoding(withAllowedCharacters: allowed) ?? str
            return self.newStringValue(encoded)
        }, name: "encodeURIComponent", length: 1)
        _ = setPropertyStr(obj: globalObj, name: "encodeURIComponent", value: encodeURIComponentFunc)

        let decodeURIComponentFunc = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self, !args.isEmpty, let str = self.toSwiftString(args[0]) else {
                return .JS_UNDEFINED
            }
            return self.newStringValue(str.removingPercentEncoding ?? str)
        }, name: "decodeURIComponent", length: 1)
        _ = setPropertyStr(obj: globalObj, name: "decodeURIComponent", value: decodeURIComponentFunc)
    }

    // MARK: - Private Property Helpers

    /// Internal property get implementation.
    /// Mirrors `JS_GetPropertyInternal()` from QuickJS.
    private func getPropertyInternal(
        obj: JeffJSValue,
        atom: UInt32,
        receiver: JeffJSValue
    ) -> JeffJSValue {
        guard let jsObj = obj.toObject() else {
            // Primitive value — auto-box and get from prototype
            if obj.isString {
                // String indexing
                if rt.atomIsArrayIndex(atom) {
                    if let idx = rt.atomToUInt32(atom), let str = obj.stringValue?.toSwiftString() {
                        let index = str.index(str.startIndex, offsetBy: Int(idx), limitedBy: str.endIndex)
                        if let index = index, index < str.endIndex {
                            return newStringValue(String(str[index]))
                        }
                    }
                    return .JS_UNDEFINED
                }
                // String.length
                if atom == JeffJSAtomID.JS_ATOM_length.rawValue {
                    if let str = obj.stringValue?.toSwiftString() {
                        return .newInt32(Int32(str.utf16.count))
                    }
                }
                // Fall through to String.prototype
                let proto = classProto[JSClassID.JS_CLASS_STRING.rawValue]
                if proto.isObject {
                    return getPropertyInternal(obj: proto, atom: atom, receiver: receiver)
                }
            }
            // Number auto-boxing: (42).toString() etc.
            if obj.isInt || obj.isFloat64 {
                let proto = classProto[JSClassID.JS_CLASS_NUMBER.rawValue]
                if proto.isObject {
                    return getPropertyInternal(obj: proto, atom: atom, receiver: receiver)
                }
            }
            // Boolean auto-boxing: true.toString() etc.
            if obj.isBool {
                let proto = classProto[JSClassID.JS_CLASS_BOOLEAN.rawValue]
                if proto.isObject {
                    return getPropertyInternal(obj: proto, atom: atom, receiver: receiver)
                }
            }
            // Symbol auto-boxing: Symbol('foo').description etc.
            if obj.isSymbol {
                let proto = classProto[JSClassID.JS_CLASS_SYMBOL.rawValue]
                if proto.isObject {
                    return getPropertyInternal(obj: proto, atom: atom, receiver: receiver)
                }
            }
            if obj.isNullOrUndefined {
                let atomStr = rt.atomToString(atom) ?? "?"
                // Include the last variable/field that produced the undefined value
                let prevAtom = JeffJSInterpreter.prevGetFieldAtom
                let varHint = prevAtom > 0 ? (rt.atomToString(prevAtom) ?? "") : ""
                let hint = varHint.isEmpty ? "" : " — '\(varHint).\(atomStr)' is undefined"
                return throwTypeError(message: "Cannot read properties of \(obj.isNull ? "null" : "undefined") (reading '\(atomStr)')\(hint)")
            }
            return .JS_UNDEFINED
        }

        // Proxy intercept: if this object is a proxy, dispatch to handler.get trap
        if jsObj.classID == JeffJSClassID.proxy.rawValue || jsObj.classID == JSClassID.JS_CLASS_PROXY.rawValue {
            if case .proxyData(let pd) = jsObj.payload {
                if pd.isRevoked {
                    return throwTypeError(message: "Cannot perform 'get' on a proxy that has been revoked")
                }
                // Look for handler.get trap
                if let handlerObj = pd.handler.toObject() {
                    let getTrapAtom = rt.findAtom("get")
                    let trap = getPropertyInternal(obj: pd.handler, atom: getTrapAtom, receiver: pd.handler)
                    rt.freeAtom(getTrapAtom)
                    if trap.isObject, let trapObj = trap.toObject(), trapObj.isCallable {
                        // Call trap(target, property, receiver)
                        let propName: JeffJSValue
                        if let name = rt.atomToString(atom) {
                            propName = newStringValue(name)
                        } else {
                            propName = .JS_UNDEFINED
                        }
                        let result = callFunction(trap, thisVal: pd.handler, args: [pd.target, propName, receiver])
                        return result
                    }
                    _ = handlerObj // suppress warning
                }
                // No trap: fall through to target
                return getPropertyInternal(obj: pd.target, atom: atom, receiver: receiver)
            }
        }

        // Fast path for array integer-indexed access
        if jsObj.fastArray || jsObj.classID == JeffJSClassID.array.rawValue {
            if rt.atomIsArrayIndex(atom), let idx = rt.atomToUInt32(atom) {
                // Check ref-type fast storage first (populated by push fast path)
                if let storage = jsObj._fastArrayValues {
                    if idx < storage.count, Int(idx) < storage.values.count {
                        return storage.values[Int(idx)].dupValue()
                    }
                    return .JS_UNDEFINED
                }
                if case .array(_, let vals, let count) = jsObj.payload {
                    if idx < count, Int(idx) < vals.count {
                        return vals[Int(idx)].dupValue()
                    }
                    return .JS_UNDEFINED
                }
            }
        }

        // TypedArray integer-indexed element access.
        // TypedArray objects use classIDs in the range [uint8cArray..float64Array].
        // Integer-indexed reads go directly to the underlying ArrayBuffer data.
        if jsObj.classID >= JeffJSClassID.uint8cArray.rawValue &&
           jsObj.classID <= JeffJSClassID.float64Array.rawValue {
            if case .typedArray(let ta) = jsObj.payload {
                if rt.atomIsArrayIndex(atom), let idx = rt.atomToUInt32(atom) {
                    guard let bufObj = ta.buffer,
                          case .arrayBuffer(let ab) = bufObj.payload,
                          !ab.detached else {
                        return .JS_UNDEFINED
                    }
                    if idx < ta.length, let info = typedArrayInfo(forClassID: ta.classID) {
                        return info.readElement(ab.data,
                                                offset: ta.byteOffset + Int(idx) * info.bytesPerElement)
                    }
                    return .JS_UNDEFINED
                }
            }
        }

        // String wrapper object: delegate indexed access and .length to the
        // underlying [[StringData]] primitive, mirroring the exotic String
        // object behavior from the ES spec (9.4.3).
        if jsObj.classID == JSClassID.JS_CLASS_STRING.rawValue {
            let pv = jsObj.primitiveValue
            if pv.isString {
                if rt.atomIsArrayIndex(atom) {
                    if let idx = rt.atomToUInt32(atom), let str = pv.stringValue?.toSwiftString() {
                        let index = str.index(str.startIndex, offsetBy: Int(idx), limitedBy: str.endIndex)
                        if let index = index, index < str.endIndex {
                            return newStringValue(String(str[index]))
                        }
                    }
                    return .JS_UNDEFINED
                }
                if atom == JeffJSAtomID.JS_ATOM_length.rawValue {
                    if let str = pv.stringValue?.toSwiftString() {
                        return .newInt32(Int32(str.utf16.count))
                    }
                }
            }
        }

        // Invariant: shape.prop and obj.prop must stay in sync.
        // Soft-recover shape/prop desync instead of crashing
        if let shape = jsObj.shape, shape.prop.count != jsObj.prop.count, !jsObj.prop.isEmpty {
            while jsObj.prop.count < shape.prop.count {
                jsObj.prop.append(.value(.undefined))
            }
        }

        // Check own properties via shape-based lookup
        let (ownShapeProp, ownProp) = jeffJS_findOwnProperty(obj: jsObj, atom: atom)
        if let ownShapeProp = ownShapeProp, let ownProp = ownProp {
            if ownShapeProp.flags.contains(.getset) {
                // Accessor property — call the getter
                if case .getset(let getter, _) = ownProp, let getterObj = getter {
                    let getterVal = JeffJSValue.makeObject(getterObj)
                    return callFunction(getterVal, thisVal: receiver, args: [])
                }
                return .JS_UNDEFINED
            }
            if case .value(let v) = ownProp {
                return v.dupValue()
            }
            return .JS_UNDEFINED
        }

        // For arrays: a property may have been stored under a tagged-int atom
        // (via setPropertyUint32) while the lookup used a string atom (from
        // getPropertyStr), or vice-versa.  Retry with the alternate form.
        // Use the raw tag-bit check (not atomIsArrayIndex) since we need to
        // distinguish string atoms from tagged-int atoms specifically.
        if jsObj.classID == JeffJSClassID.array.rawValue {
            if (atom & JS_ATOM_TAG_INT) == 0 {
                // String atom — try the tagged-int equivalent.
                if let str = rt.atomToString(atom), let idx = UInt32(str),
                   String(idx) == str, idx <= 0xFFFFFFFE {
                    let intAtom = rt.newAtomUInt32(idx)
                    defer { rt.freeAtom(intAtom) }
                    let (sp, pp) = jeffJS_findOwnProperty(obj: jsObj, atom: intAtom)
                    if let sp = sp, let pp = pp {
                        if case .value(let v) = pp {
                            return v.dupValue()
                        }
                    }
                }
            } else {
                // Tagged-int atom — try the string equivalent.
                if let idx = rt.atomToUInt32(atom) {
                    let strAtom = rt.findAtom(String(idx))
                    defer { rt.freeAtom(strAtom) }
                    let (sp, pp) = jeffJS_findOwnProperty(obj: jsObj, atom: strAtom)
                    if let sp = sp, let pp = pp {
                        if case .value(let v) = pp {
                            return v.dupValue()
                        }
                    }
                }
            }
        }

        // Walk prototype chain (prototype is stored on the shape)
        var proto = jsObj.proto
        while let p = proto {
            let (pShapeProp, pProp) = jeffJS_findOwnProperty(obj: p, atom: atom)
            if let pShapeProp = pShapeProp, let pProp = pProp {
                if pShapeProp.flags.contains(.getset) {
                    if case .getset(let getter, _) = pProp, let getterObj = getter {
                        let getterVal = JeffJSValue.makeObject(getterObj)
                        return callFunction(getterVal, thisVal: receiver, args: [])
                    }
                    return .JS_UNDEFINED
                }
                if case .value(let v) = pProp {
                    return v.dupValue()
                }
                return .JS_UNDEFINED
            }
            proto = p.proto
        }

        return .JS_UNDEFINED
    }

    /// Internal property set implementation.
    /// Mirrors `JS_SetPropertyInternal()` from QuickJS.
    private func setPropertyInternal(
        obj: JeffJSValue,
        atom: UInt32,
        value: JeffJSValue,
        flags: Int
    ) -> Int {
        guard let jsObj = obj.toObject() else {
            if (flags & JS_PROP_THROW) != 0 {
                let propName = rt.atomToString(atom) ?? "?"
                let desc: String
                if obj.isUndefined { desc = "undefined" }
                else if obj.isNull { desc = "null" }
                else if obj.isInt { desc = "int(\(obj.toInt32()))" }
                else if obj.isBool { desc = obj.toBool() ? "true" : "false" }
                else { desc = "tag(\(obj.tag))" }
                _ = throwTypeError(message: "cannot set property '\(propName)' of \(desc)")
            }
            return -1
        }

        // Proxy intercept: if this object is a proxy, dispatch to handler.set trap
        if jsObj.classID == JeffJSClassID.proxy.rawValue || jsObj.classID == JSClassID.JS_CLASS_PROXY.rawValue {
            if case .proxyData(let pd) = jsObj.payload {
                if pd.isRevoked {
                    if (flags & JS_PROP_THROW) != 0 {
                        _ = throwTypeError(message: "Cannot perform 'set' on a proxy that has been revoked")
                    }
                    return -1
                }
                // Look for handler.set trap
                if let handlerObj = pd.handler.toObject() {
                    let setTrapAtom = rt.findAtom("set")
                    let trap = getPropertyInternal(obj: pd.handler, atom: setTrapAtom, receiver: pd.handler)
                    rt.freeAtom(setTrapAtom)
                    if trap.isObject, let trapObj = trap.toObject(), trapObj.isCallable {
                        // Call trap(target, property, value, receiver)
                        let propName: JeffJSValue
                        if let name = rt.atomToString(atom) {
                            propName = newStringValue(name)
                        } else {
                            propName = .JS_UNDEFINED
                        }
                        let result = callFunction(trap, thisVal: pd.handler, args: [pd.target, propName, value, obj])
                        if result.isException { return -1 }
                        return result.toBool() ? 1 : 0
                    }
                    _ = handlerObj // suppress warning
                }
                // No trap: fall through to target
                return setPropertyInternal(obj: pd.target, atom: atom, value: value, flags: flags)
            }
        }

        // Fast path for array integer-indexed writes
        if jsObj.fastArray || jsObj.classID == JeffJSClassID.array.rawValue {
            if rt.atomIsArrayIndex(atom), let idx = rt.atomToUInt32(atom) {
                if jsObj.setArrayElement(idx, value: value) {
                    // Update length if needed
                    let arrCount = jsObj.arrayCount
                    if arrCount > 0 {
                        let lengthAtom = JeffJSAtomID.JS_ATOM_length.rawValue
                        let (lenShapeProp, _) = jeffJS_findOwnProperty(obj: jsObj, atom: lengthAtom)
                        if lenShapeProp != nil {
                            jsObj.setOwnPropertyValue(atom: lengthAtom, value: .newInt32(Int32(arrCount)))
                        }
                    }
                    return 1
                }
                // setArrayElement failed (no .array payload) — fall through
                // to the shape-based property creation below.
            }
        }

        // TypedArray integer-indexed element write.
        // TypedArray objects use classIDs in the range [uint8cArray..float64Array].
        // Integer-indexed writes go directly to the underlying ArrayBuffer data.
        if jsObj.classID >= JeffJSClassID.uint8cArray.rawValue &&
           jsObj.classID <= JeffJSClassID.float64Array.rawValue {
            if case .typedArray(let ta) = jsObj.payload {
                if rt.atomIsArrayIndex(atom), let idx = rt.atomToUInt32(atom) {
                    guard let bufObj = ta.buffer,
                          case .arrayBuffer(let ab) = bufObj.payload,
                          !ab.detached else {
                        // Detached buffer — silently ignore write per spec
                        return 0
                    }
                    if idx < ta.length, let info = typedArrayInfo(forClassID: ta.classID) {
                        info.writeElement(&ab.data,
                                          offset: ta.byteOffset + Int(idx) * info.bytesPerElement,
                                          value: value)
                        return 1
                    }
                    // Out of bounds — silently ignore per spec
                    return 0
                }
            }
        }

        // Invariant: shape.prop and obj.prop must stay in sync.
        // Soft-recover shape/prop desync instead of crashing
        if let shape = jsObj.shape, shape.prop.count != jsObj.prop.count, !jsObj.prop.isEmpty {
            while jsObj.prop.count < shape.prop.count {
                jsObj.prop.append(.value(.undefined))
            }
        }

        // Check if property already exists via shape-based lookup
        let (existingShapeProp, existingProp) = jeffJS_findOwnProperty(obj: jsObj, atom: atom)
        if let existingShapeProp = existingShapeProp, let existingPropVal = existingProp {
            if existingShapeProp.flags.contains(.getset) {
                // Accessor property — call the setter
                if case .getset(_, let setter) = existingPropVal, let setterObj = setter {
                    let setterVal = JeffJSValue.makeObject(setterObj)
                    let result = callFunction(setterVal, thisVal: obj, args: [value])
                    if result.isException { return -1 }
                    return 1
                }
                // No setter defined — silently fail in non-strict, throw in strict
                if (flags & JS_PROP_THROW) != 0 {
                    _ = throwTypeError(message: "Cannot set property which has only a getter")
                }
                value.freeValue()
                return -1
            }
            if !existingShapeProp.flags.contains(.writable) {
                if (flags & JS_PROP_THROW) != 0 {
                    _ = throwTypeError(message: "Cannot assign to read only property")
                }
                value.freeValue()
                return -1
            }
            // Update the value via shape index
            if let shape = jsObj.shape {
                // Try hash-based lookup first, fall back to linear scan
                var foundIdx: Int? = findShapeProperty(shape, atom)
                if foundIdx == nil {
                    for i in 0 ..< shape.prop.count {
                        if shape.prop[i].atom == atom {
                            foundIdx = i
                            break
                        }
                    }
                }
                if let idx = foundIdx, idx < jsObj.prop.count {
                    let oldProp = jsObj.prop[idx]
                    jsObj.prop[idx] = .value(value)
                    if case .value(let oldVal) = oldProp {
                        oldVal.freeValue()
                    }
                }
            }
            return 1
        }

        // Walk prototype chain for inherited accessor setters (ES spec 9.1.9 step 4)
        var setProto = jsObj.proto
        while let p = setProto {
            let (pShapeProp, pProp) = jeffJS_findOwnProperty(obj: p, atom: atom)
            if let pShapeProp = pShapeProp, let pPropVal = pProp {
                if pShapeProp.flags.contains(.getset) {
                    // Inherited accessor — call its setter
                    if case .getset(_, let setter) = pPropVal, let setterObj = setter {
                        let setterVal = JeffJSValue.makeObject(setterObj)
                        let result = callFunction(setterVal, thisVal: obj, args: [value])
                        if result.isException { return -1 }
                        return 1
                    }
                    // Inherited accessor with no setter
                    if (flags & JS_PROP_THROW) != 0 {
                        _ = throwTypeError(message: "Cannot set property which has only a getter")
                    }
                    value.freeValue()
                    return -1
                }
                // Found a data property on prototype — stop walking, create own property below
                break
            }
            setProto = p.proto
        }

        // Check extensibility
        if !jsObj.extensible {
            if (flags & JS_PROP_THROW) != 0 {
                _ = throwTypeError(message: "Cannot add property, object is not extensible")
            }
            value.freeValue()
            return -1
        }

        // Create new property via shape system
        let propFlags: JeffJSPropertyFlags = [.writable, .enumerable, .configurable]
        jeffJS_addProperty(ctx: self, obj: jsObj, atom: atom, flags: propFlags)
        // Set the value in the last slot (just added)
        if !jsObj.prop.isEmpty {
            jsObj.prop[jsObj.prop.count - 1] = .value(value)
        }

        // For arrays: keep the "length" property in sync after adding an
        // integer-indexed element via the shape-based fallback path.
        if jsObj.classID == JeffJSClassID.array.rawValue {
            if rt.atomIsArrayIndex(atom), let idx = rt.atomToUInt32(atom) {
                let newLen = Int32(idx) + 1
                let lengthAtom = JeffJSAtomID.JS_ATOM_length.rawValue
                let (lenProp, _) = jeffJS_findOwnProperty(obj: jsObj, atom: lengthAtom)
                if lenProp != nil {
                    let curLen = jsObj.getOwnPropertyValue(atom: lengthAtom)
                    let curLenVal = curLen.isInt ? curLen.toInt32() : Int32(0)
                    if newLen > curLenVal {
                        jsObj.setOwnPropertyValue(atom: lengthAtom, value: .newInt32(newLen))
                    }
                }
            }
        }

        return 1
    }

    // MARK: - Private Error Helpers

    /// Creates and throws an error of the given type.
    /// Build a stack trace string by walking the call frame chain.
    func buildStackTrace(errorName: String, message: String) -> String {
        var lines: [String] = []
        let header = message.isEmpty ? errorName : "\(errorName): \(message)"
        lines.append(header)

        var frame = currentFrame
        var depth = 0
        while let f = frame, depth < 16 {
            depth += 1
            if let obj = f.curFunc.toObject(),
               case .bytecodeFunc(let bytecodeOpt, _, _) = obj.payload,
               let fb = bytecodeOpt as? JeffJSFunctionBytecodeCompiled {
                let pc = fb.bytecodeLen > 0 ? max(0, min(f.curPC, fb.bytecodeLen - 1)) : 0
                let lineNum = fb.debugPc2lineBuf.isEmpty ? 0 : fb.lineForPC(pc)
                let colNum = fb.debugPc2colBuf.isEmpty ? 0 : fb.colForPC(pc)
                let filename = fb.debugFilenameAtom != 0
                    ? (rt.atomToString(fb.debugFilenameAtom) ?? "<unknown>")
                    : "<anonymous>"
                let funcName = fb.funcNameAtom != 0
                    ? (rt.atomToString(fb.funcNameAtom) ?? "")
                    : ""
                var location: String
                if lineNum > 0 && colNum > 0 {
                    location = "\(filename):\(lineNum):\(colNum)"
                } else if lineNum > 0 {
                    location = "\(filename):\(lineNum)"
                } else {
                    location = filename
                }
                if funcName.isEmpty {
                    lines.append("    at \(location)")
                } else {
                    lines.append("    at \(funcName) (\(location))")
                }
                // Add source snippet for the innermost frame
                if lines.count == 2, lineNum > 0, let (snippet, _) = fb.sourceSnippet(forLine: lineNum) {
                    lines.append("    > \(snippet)")
                }
            }
            frame = f.prevFrame
        }
        return lines.joined(separator: "\n")
    }

    private func throwErrorInternal(errorType: JSErrorEnum, message: String) -> JeffJSValue {
        let errObj = newObjectClass(classID: JSClassID.JS_CLASS_ERROR.rawValue)
        if errObj.isException { return errObj }

        // Set the name from the error type
        let errorNames = [
            "EvalError", "RangeError", "ReferenceError", "SyntaxError",
            "TypeError", "URIError", "InternalError", "AggregateError"
        ]
        let nameStr = errorType.rawValue < errorNames.count ? errorNames[errorType.rawValue] : "Error"
        _ = setPropertyStr(obj: errObj, name: "name", value: newStringValue(nameStr))

        // Set the message
        _ = setPropertyStr(obj: errObj, name: "message", value: newStringValue(message))

        // Set stack property with source location from call frames
        // Guard against re-entrant / deeply nested errors that may corrupt frame state
        let stackStr: String
        if let _ = currentFrame {
            stackStr = buildStackTrace(errorName: nameStr, message: message)
        } else {
            stackStr = message.isEmpty ? nameStr : "\(nameStr): \(message)"
        }
        _ = setPropertyStr(obj: errObj, name: "stack", value: newStringValue(stackStr))

        // Set prototype to the appropriate NativeError.prototype.
        // Look up the constructor from the global object and get its .prototype
        // property, so we always use the same prototype that instanceof checks.
        // This handles the case where JeffJSBuiltinError.addIntrinsic creates
        // new constructor/prototype pairs that differ from nativeErrorProto[].
        if let errJSObj = errObj.toObject() {
            let ctorVal = getPropertyStr(obj: globalObj, name: nameStr)
            if ctorVal.isObject {
                let protoVal = getProperty(obj: ctorVal, atom: JeffJSAtomID.JS_ATOM_prototype.rawValue)
                if protoVal.isObject {
                    errJSObj.proto = protoVal.toObject()
                } else if errorType.rawValue < nativeErrorProto.count {
                    // Fallback to nativeErrorProto if constructor lookup fails
                    let proto = nativeErrorProto[errorType.rawValue]
                    if proto.isObject {
                        errJSObj.proto = proto.toObject()
                    }
                }
            } else if errorType.rawValue < nativeErrorProto.count {
                // Fallback to nativeErrorProto if constructor not on global
                let proto = nativeErrorProto[errorType.rawValue]
                if proto.isObject {
                    errJSObj.proto = proto.toObject()
                }
            }
        }

        return throwValue(errObj)
    }

    /// Throws a TypeError with an atom-based message (for internal use).
    private func throwTypeErrorAtom(atom: UInt32, message: String) -> JeffJSValue {
        return throwTypeError(message: message)
    }

    // MARK: - Private JSON Helpers

    /// Parses a JSON string into a JS value.
    private func jsonParse(text: String) -> JeffJSValue {
        guard let data = text.data(using: .utf8) else {
            return throwSyntaxError(message: "Unexpected end of JSON input")
        }
        do {
            let obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            return swiftToJSValue(obj)
        } catch {
            return throwSyntaxError(message: "Unexpected token in JSON at position 0")
        }
    }

    /// Converts a Foundation JSON object to a JeffJSValue.
    private func swiftToJSValue(_ obj: Any) -> JeffJSValue {
        if let dict = obj as? [String: Any] {
            let jsObj = newObject()
            for (key, val) in dict {
                _ = setPropertyStr(obj: jsObj, name: key, value: swiftToJSValue(val))
            }
            return jsObj
        }
        if let arr = obj as? [Any] {
            let jsArr = newArray()
            for (i, val) in arr.enumerated() {
                _ = setPropertyUint32(obj: jsArr, index: UInt32(i), value: swiftToJSValue(val))
            }
            // Update length
            _ = setPropertyStr(obj: jsArr, name: "length",
                               value: .newInt32(Int32(arr.count)))
            return jsArr
        }
        if let str = obj as? String { return newStringValue(str) }
        if let num = obj as? NSNumber {
            #if canImport(CoreFoundation)
            if CFGetTypeID(num) == CFBooleanGetTypeID() {
                return .newBool(num.boolValue)
            }
            #endif
            let d = num.doubleValue
            if d == Double(Int32(d)) && !d.isNaN {
                return .newInt32(Int32(d))
            }
            return .newFloat64(d)
        }
        if obj is NSNull { return .null }
        return .JS_UNDEFINED
    }

    /// Converts a JeffJSValue to a JSON string.
    private func jsonStringify(
        value: JeffJSValue,
        replacer: JeffJSValue,
        space: JeffJSValue
    ) -> JeffJSValue {
        // Simplified JSON.stringify
        let indentStr: String
        if let n = toInt32(space) {
            indentStr = String(repeating: " ", count: max(0, min(Int(n), 10)))
        } else if let s = toSwiftString(space) {
            indentStr = String(s.prefix(10))
        } else {
            indentStr = ""
        }

        let result = jsonStringifyValue(value: value, indent: "", gap: indentStr)
        if let str = result {
            return newStringValue(str)
        }
        return .JS_UNDEFINED
    }

    /// Recursively serializes a value to JSON.
    private func jsonStringifyValue(value: JeffJSValue, indent: String, gap: String) -> String? {
        if value.isNull { return "null" }
        if value.isUndefined { return nil }
        if value.isBool { return value.toBool() ? "true" : "false" }
        if value.isInt { return String(value.toInt32()) }
        if value.isFloat64 {
            let d = value.toFloat64()
            if d.isNaN || d.isInfinite { return "null" }
            return formatDouble(d)
        }
        if value.isString {
            if let str = value.stringValue?.toSwiftString() {
                return jsonQuoteString(str)
            }
        }
        if value.isObject {
            guard let obj = value.toObject() else { return nil }
            if obj.classID == JSClassID.JS_CLASS_ARRAY.rawValue {
                return jsonStringifyArray(obj: value, indent: indent, gap: gap)
            }
            return jsonStringifyObject(obj: value, indent: indent, gap: gap)
        }
        return nil
    }

    /// JSON-quotes a string.
    private func jsonQuoteString(_ str: String) -> String {
        var result = "\""
        for ch in str {
            switch ch {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if ch.asciiValue != nil && ch.asciiValue! < 0x20 {
                    let hex = String(format: "\\u%04x", ch.asciiValue!)
                    result += hex
                } else {
                    result.append(ch)
                }
            }
        }
        result += "\""
        return result
    }

    /// Serializes an array to JSON.
    private func jsonStringifyArray(obj: JeffJSValue, indent: String, gap: String) -> String {
        let lengthVal = getPropertyStr(obj: obj, name: "length")
        let len = toInt32(lengthVal) ?? 0
        lengthVal.freeValue()

        if len <= 0 { return "[]" }

        let newIndent = indent + gap
        var items: [String] = []
        for i in 0..<len {
            let elem = getPropertyUint32(obj: obj, index: UInt32(i))
            if let str = jsonStringifyValue(value: elem, indent: newIndent, gap: gap) {
                items.append(str)
            } else {
                items.append("null")
            }
            elem.freeValue()
        }

        if gap.isEmpty {
            return "[" + items.joined(separator: ",") + "]"
        }
        let separator = ",\n" + newIndent
        return "[\n" + newIndent + items.joined(separator: separator) + "\n" + indent + "]"
    }

    /// Serializes an object to JSON.
    private func jsonStringifyObject(obj: JeffJSValue, indent: String, gap: String) -> String {
        guard let jsObj = obj.toObject() else { return "{}" }

        guard let shape = jsObj.shape else { return "{}" }
        if shape.prop.isEmpty { return "{}" }

        let newIndent = indent + gap
        var items: [String] = []

        for (i, shapeProp) in shape.prop.enumerated() {
            if !shapeProp.flags.contains(.enumerable) { continue }
            guard let key = rt.atomToString(shapeProp.atom) else { continue }
            guard i < jsObj.prop.count else { continue }
            let propVal: JeffJSValue
            if case .value(let v) = jsObj.prop[i] {
                propVal = v
            } else {
                continue
            }
            if let valStr = jsonStringifyValue(value: propVal, indent: newIndent, gap: gap) {
                let entry: String
                if gap.isEmpty {
                    entry = jsonQuoteString(key) + ":" + valStr
                } else {
                    entry = jsonQuoteString(key) + ": " + valStr
                }
                items.append(entry)
            }
        }

        if items.isEmpty { return "{}" }

        if gap.isEmpty {
            return "{" + items.joined(separator: ",") + "}"
        }
        let separator = ",\n" + newIndent
        return "{\n" + newIndent + items.joined(separator: separator) + "\n" + indent + "}"
    }

    // MARK: - Private Numeric Formatting

    /// Formats a Double in a way compatible with JavaScript's Number.toString().
    /// Formats a Double to a string matching JavaScript's Number.prototype.toString()
    /// behavior (ES spec 7.1.12.1 NumberToString).
    ///
    /// Key differences from Swift's String(d):
    /// - Integers up to 10^21 are printed without exponent: "100000000000000000000"
    /// - Exponents never have leading zeros: "1e+21" not "1e+21", "1e-7" not "1e-07"
    /// - Trailing zeros are stripped: "1.5" not "1.50"
    private func formatDouble(_ d: Double) -> String {
        if d == 0 { return "0" }

        let abs_d = Swift.abs(d)
        let sign = d < 0 ? "-" : ""

        // Integer values in range [1, 10^21) → print as integer without exponent
        if abs_d < 1e21 && abs_d >= 1 && abs_d == floor(abs_d) {
            // Format as integer (no decimal point, no exponent)
            // Use a format that avoids scientific notation
            return sign + String(format: "%.0f", abs_d)
        }

        // For other values, use Swift's default formatting and fix up
        let str = String(d)

        // Remove trailing ".0" for integers that slipped through
        if str.hasSuffix(".0") {
            return String(str.dropLast(2))
        }

        // Fix exponent formatting: Swift uses "e+07" or "e-07", JS uses "e+7" or "e-7"
        // Also Swift uses lowercase 'e' which matches JS
        if let eIdx = str.firstIndex(of: "e") {
            let mantissa = str[str.startIndex..<eIdx]
            var expPart = String(str[eIdx...])  // e.g. "e+07" or "e-07"

            // Remove leading zeros from exponent: "e+07" → "e+7", "e-07" → "e-7"
            if expPart.count > 2 {
                let signChar = expPart[expPart.index(after: expPart.startIndex)]  // '+' or '-'
                let digits = String(expPart.dropFirst(2))  // "07"
                let trimmed = String(digits.drop(while: { $0 == "0" }))
                let expDigits = trimmed.isEmpty ? "0" : trimmed
                expPart = "e\(signChar)\(expDigits)"
            }

            return String(mantissa) + expPart
        }

        return str
    }
}

// NOTE: JeffJSProperty is now defined as an enum in JeffJSObject.swift.
// The duplicate class definition that was here has been removed.

// MARK: - JeffJSObject Extensions

/// Extensions to JeffJSObject (forward-declared in JeffJSValue.swift)
/// to add the fields needed by JeffJSContext.
extension JeffJSObject {
    // NOTE: classID (UInt16), extensible (Bool), and shape (JeffJSShape?) are
    // stored properties defined directly on JeffJSObject in JeffJSObject.swift.
    // Do NOT redeclare them here.

    /// The prototype of this object.
    /// This is the single source of truth for the prototype. On write, it also
    /// updates `shape.proto` so the two never go out of sync.
    var proto: JeffJSObject? {
        get { return _proto }
        set {
            _proto = newValue
            // Keep shape.proto in sync (weak mirror of the canonical strong ref)
            shape?.proto = newValue
        }
    }

    /// The properties of this object.
    var properties: [JeffJSProperty] {
        get { return _properties }
        set { _properties = newValue }
    }

    /// For wrapper objects (Number, String, Boolean, Symbol, BigInt), the primitive value.
    var primitiveValue: JeffJSValue {
        get { return _primitiveValue }
        set { _primitiveValue = newValue }
    }

    /// For C function objects, the Swift closure.
    var cFunction: ((JeffJSContext, JeffJSValue, [JeffJSValue]) -> JeffJSValue)? {
        get { return _cFunction }
        set { _cFunction = newValue }
    }

    /// For C function objects, the expected argument count.
    var cFunctionLength: Int {
        get { return _cFunctionLength }
        set { _cFunctionLength = newValue }
    }

    private var _proto: JeffJSObject? {
        get { storedProto }
        set { storedProto = newValue }
    }

    private var _properties: [JeffJSProperty] {
        get { prop }
        set { prop = newValue }
    }

    private var _primitiveValue: JeffJSValue {
        get { storedPrimitiveValue }
        set { storedPrimitiveValue = newValue }
    }

    private var _cFunction: ((JeffJSContext, JeffJSValue, [JeffJSValue]) -> JeffJSValue)? {
        get { storedCFunction }
        set { storedCFunction = newValue }
    }

    private var _cFunctionLength: Int {
        get { storedCFunctionLength }
        set { storedCFunctionLength = newValue }
    }
}

// MARK: - Convenience Methods for Builtins

/// Type alias for native JS functions (matches the pattern used in newCFunction)
typealias JeffJSNativeFunc = (_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ args: [JeffJSValue]) -> JeffJSValue

extension JeffJSContext {

    // -- Property by index (for arrays) --

    func getPropertyByIndex(obj: JeffJSValue, index: UInt32) -> JeffJSValue {
        let atom = UInt32(index) | 0x80000000  // JS_ATOM_TAG_INT
        return getProperty(obj: obj, atom: atom)
    }

    func setPropertyByIndex(obj: JeffJSValue, index: UInt32, value: JeffJSValue) {
        let atom = UInt32(index) | 0x80000000
        _ = setProperty(obj: obj, atom: atom, value: value)
    }

    func hasPropertyByIndex(obj: JeffJSValue, index: UInt32) -> Bool {
        let atom = UInt32(index) | 0x80000000
        return hasProperty(obj: obj, atom: atom)
    }

    func deletePropertyByIndex(obj: JeffJSValue, index: UInt32) -> Bool {
        let atom = UInt32(index) | 0x80000000
        return deleteProperty(obj: obj, atom: atom)
    }

    // -- Function registration --

    func setPropertyFunc(obj: JeffJSValue, name: String, fn: @escaping JeffJSNativeFunc, length: Int) {
        let funcObj = newCFunction(fn, name: name, length: length)
        // Use non-enumerable so methods don't appear in for-in iteration.
        // DOM elements and prototype objects should not pollute property enumeration.
        setNonEnumerableProperty(obj: obj, name: name, value: funcObj)
    }

    // -- Value creation --

    func newInt64(_ val: Int64) -> JeffJSValue {
        if val >= Int64(Int32.min) && val <= Int64(Int32.max) {
            return .newInt32(Int32(val))
        }
        return .newFloat64(Double(val))
    }

    func newArrayWithLength(_ len: Int) -> JeffJSValue {
        let arr = newArray()
        setArrayLength(arr, Int64(len))
        return arr
    }

    // -- Array helpers --

    func setArrayLength(_ obj: JeffJSValue, _ len: Int64) {
        guard let p = obj.toObject() else { return }
        if let storage = p._fastArrayValues {
            storage.count = UInt32(min(Int64(storage.values.count), len))
        } else if case .array(_, let values, _) = p.payload {
            p.payload = .array(size: UInt32(len), values: values, count: UInt32(min(Int64(values.count), len)))
        }
        let lenAtom = rt.findAtom("length")
        _ = setProperty(obj: obj, atom: lenAtom, value: newInt64(len))
    }

    func getArrayLength(_ obj: JeffJSValue) -> Int64 {
        let lenAtom = rt.findAtom("length")
        let lenVal = getProperty(obj: obj, atom: lenAtom)
        if let v = toInt32(lenVal) { return Int64(v) }
        if let v = toFloat64(lenVal) { return Int64(v) }
        return 0
    }

    // -- Calling --

    func call(_ fn: JeffJSValue, this thisVal: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        // Dispatch to the full callFunction path which handles both
        // C functions and bytecode functions (arrow functions, closures, etc.)
        return callFunction(fn, thisVal: thisVal, args: args)
    }

    func callMethod(_ obj: JeffJSValue, name: String, args: [JeffJSValue]) -> JeffJSValue {
        let method = getPropertyStr(obj: obj, name: name)
        if method.isUndefined || !method.isFunction { return JeffJSValue.undefined }
        return call(method, this: obj, args: args)
    }

    func callConstructor(_ fn: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        // Delegate to the full callConstructor that handles both
        // C function and bytecode function constructors.
        return callConstructor(fn, newTarget: fn, args: args)
    }

    // -- Type checking --

    func isCallable(_ val: JeffJSValue) -> Bool {
        return isFunction(val)
    }

    func isConstructor(_ val: JeffJSValue) -> Bool {
        guard let obj = val.toObject() else { return false }
        return obj.isConstructor
    }

    // -- Type conversion --

    func extractFloat64(_ val: JeffJSValue) -> Double? {
        return toFloat64(val)
    }

    func extractUint32(_ val: JeffJSValue) -> UInt32? {
        guard let v = toInt32(val) else { return nil }
        return UInt32(bitPattern: v)
    }

    func toIntegerOrInfinity(_ val: JeffJSValue) -> Double {
        guard let d = toFloat64(val) else { return 0 }
        if d.isNaN { return 0 }
        if d.isInfinite { return d }
        return d >= 0 ? d.rounded(.down) : -((-d).rounded(.down))
    }

    func toLength(_ val: JeffJSValue) -> Int64 {
        let n = toIntegerOrInfinity(val)
        if n <= 0 { return 0 }
        let maxLength: Int64 = Int64(1) << 53 - 1  // 2^53 - 1
        if n.isInfinite || n >= Double(maxLength) { return maxLength }
        return Int64(n)
    }

    func toUint32(_ val: JeffJSValue) -> UInt32 {
        guard let d = toFloat64(val) else { return 0 }
        if d.isNaN || d.isInfinite || d == 0 { return 0 }
        // ES spec ToUint32: same as ToInt32 but interpret as unsigned
        let int32 = doubleToInt32(d)
        return UInt32(bitPattern: int32)
    }

    func toBoolFree(_ val: JeffJSValue) -> Bool {
        return toBool(val)
    }

    func jsValueToString(_ val: JeffJSValue) -> String? {
        let str = toString(val)
        if str.isException { return nil }
        return str.stringValue?.toSwiftString()
    }

    // -- Comparison --

    func sameValueZero(_ a: JeffJSValue, _ b: JeffJSValue) -> Bool {
        if let da = toFloat64(a), let db = toFloat64(b) {
            if da.isNaN && db.isNaN { return true }
            return da == db
        }
        if let ia = toInt32(a), let ib = toInt32(b) { return ia == ib }
        if let sa = a.stringValue?.toSwiftString(), let sb = b.stringValue?.toSwiftString() {
            return sa == sb
        }
        if let oa = a.toObject(), let ob = b.toObject() { return oa === ob }
        return toBool(a) == toBool(b)
    }

    // -- Constructor helpers --

    func newConstructorFunc(name: String, fn: @escaping JeffJSNativeFunc, length: Int, proto: JeffJSValue) -> JeffJSValue {
        let ctor = newCFunction(fn, name: name, length: length)
        if let obj = ctor.toObject() { obj.isConstructor = true }
        _ = setPropertyStr(obj: ctor, name: "prototype", value: proto)
        // Per ES spec, prototype.constructor is writable+configurable but NOT enumerable
        let atom = rt.findAtom("constructor")
        _ = definePropertyValue(obj: proto, atom: atom, value: ctor,
                                flags: JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE)
        rt.freeAtom(atom)
        return ctor
    }

    func setGlobalConstructor(name: String, ctor: JeffJSValue) {
        _ = setPropertyStr(obj: globalObj, name: name, value: ctor)
    }

    func setPropertyGetSet(obj: JeffJSValue, name: String, getter: JeffJSValue?, setter: JeffJSValue?) {
        let atom = rt.findAtom(name)
        defer { rt.freeAtom(atom) }
        if let p = obj.toObject(), let shape = p.shape {
            let idx = addShapeProperty(self, shape, atom: atom, flags: UInt32(JS_PROP_CONFIGURABLE | JS_PROP_ENUMERABLE | JS_PROP_GETSET))
            while p.prop.count <= idx {
                p.prop.append(.value(JeffJSValue.undefined))
            }
            p.prop[idx] = .getset(getter: getter?.toObject(), setter: setter?.toObject())
        }
    }

    // -- Iterator helpers --

    func createArrayIterator(obj: JeffJSValue, kind: Int) -> JeffJSValue {
        let iter = newObject()
        _ = setPropertyStr(obj: iter, name: "_target", value: obj)
        _ = setPropertyStr(obj: iter, name: "_index", value: .newInt32(0))
        _ = setPropertyStr(obj: iter, name: "_kind", value: .newInt32(Int32(kind)))

        // Add .next() so the iterator conforms to the iterator protocol.
        // Reads _target[_index], advances _index, returns {value, done}.
        let nextFn = newCFunction({ ctx, this_, args -> JeffJSValue in
            let target = ctx.getPropertyStr(obj: this_, name: "_target")
            let idxVal = ctx.getPropertyStr(obj: this_, name: "_index")
            let kindVal = ctx.getPropertyStr(obj: this_, name: "_kind")
            let idx = idxVal.isInt ? Int(idxVal.toInt32()) : 0
            let iterKind = kindVal.isInt ? Int(kindVal.toInt32()) : 1

            // Get length of the target array
            let lenVal = ctx.getPropertyStr(obj: target, name: "length")
            let len: Int
            if lenVal.isInt { len = Int(lenVal.toInt32()) }
            else if lenVal.isFloat64 { len = Int(lenVal.toFloat64()) }
            else { len = 0 }
            if JeffJSInterpreter.traceOpcodes {
                print("[ITER-NEXT] this.isObject=\(this_.isObject) target.isObject=\(target.isObject) idx=\(idx) len=\(len) kind=\(iterKind)")
            }

            if idx >= len {
                let result = ctx.newObject()
                ctx.setPropertyStr(obj: result, name: "value", value: .undefined)
                ctx.setPropertyStr(obj: result, name: "done", value: .newBool(true))
                return result
            }

            // Advance index
            ctx.setPropertyStr(obj: this_, name: "_index", value: .newInt32(Int32(idx + 1)))

            let result = ctx.newObject()
            switch iterKind {
            case 0: // key
                ctx.setPropertyStr(obj: result, name: "value", value: .newInt32(Int32(idx)))
            case 2: // key+value (entries)
                let val = ctx.getPropertyUint32(obj: target, index: UInt32(idx))
                let pair = ctx.newArray()
                _ = ctx.setPropertyUint32(obj: pair, index: 0, value: .newInt32(Int32(idx)))
                _ = ctx.setPropertyUint32(obj: pair, index: 1, value: val)
                ctx.setPropertyStr(obj: result, name: "value", value: pair)
            default: // 1 = value
                let val = ctx.getPropertyUint32(obj: target, index: UInt32(idx))
                ctx.setPropertyStr(obj: result, name: "value", value: val)
            }
            ctx.setPropertyStr(obj: result, name: "done", value: .newBool(false))
            return result
        }, name: "next", length: 0)
        _ = setPropertyStr(obj: iter, name: "next", value: nextFn)

        // Add [Symbol.iterator]() returning this, per the iterator protocol.
        let selfIterFn = newCFunction({ ctx, this, args -> JeffJSValue in
            return this.dupValue()
        }, name: "[Symbol.iterator]", length: 0)
        let symIterAtom = JeffJSAtomID.JS_ATOM_Symbol_iterator.rawValue
        _ = setProperty(obj: iter, atom: symIterAtom, value: selfIterFn)

        return iter
    }

    func createArrayFromConstructor(_ ctor: JeffJSValue, length: Int) -> JeffJSValue {
        if isConstructor(ctor) {
            return callConstructor(ctor, args: [.newInt32(Int32(length))])
        }
        return newArrayWithLength(length)
    }

    func getMethod(_ obj: JeffJSValue, name: String) -> JeffJSValue? {
        let val = getPropertyStr(obj: obj, name: name)
        if val.isUndefined || val.isNull { return nil }
        if !isCallable(val) { return nil }
        return val
    }

    // -- Global references --

    var arrayPrototype: JeffJSValue {
        let idx = Int(JeffJSClassID.array.rawValue)
        return classProto.count > idx ? classProto[idx] : JeffJSValue.undefined
    }
}
