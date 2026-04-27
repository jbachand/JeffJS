// JeffJSRuntime.swift
// JeffJS - 1:1 Swift port of QuickJS JavaScript engine
//
// Port of JSRuntime from QuickJS. This is the top-level runtime that owns
// the atom table, GC state, class table, shape hash, and job queue.
//
// QuickJS source reference: quickjs.c — struct JSRuntime and all JS_*Runtime* functions.

import Foundation

// NOTE: ListHead is now defined in JeffJSList.swift and ListNode in JeffJSObject.swift.
// The duplicate definitions that were here have been removed.

// MARK: - JSMallocState

/// Mirrors QuickJS `JSMallocState`. Tracks memory allocation statistics.
struct JSMallocState {
    /// Current number of allocated bytes (malloc_size sum).
    var mallocCount: Int
    /// Total bytes allocated over lifetime.
    var mallocSize: Int
    /// Peak malloc_size ever reached.
    var mallocLimit: Int
    /// Number of outstanding allocations.
    var objectCount: Int

    init() {
        self.mallocCount = 0
        self.mallocSize = 0
        self.mallocLimit = -1 // -1 means no limit
        self.objectCount = 0
    }
}

// MARK: - JSMemoryUsage

/// Mirrors QuickJS `JSMemoryUsage` — snapshot of current memory usage.
/// Returned by `JS_ComputeMemoryUsage`.
struct JSMemoryUsage {
    var mallocSize: Int64
    var mallocLimit: Int64
    var memoryUsedSize: Int64
    var mallocCount: Int64

    var atomCount: Int64
    var atomSize: Int64
    var strCount: Int64
    var strSize: Int64

    var objCount: Int64
    var objSize: Int64

    var propCount: Int64
    var propSize: Int64

    var shapeCount: Int64
    var shapeSize: Int64

    var jsFuncCount: Int64
    var jsFuncSize: Int64
    var jsFuncCodeSize: Int64
    var jsFuncPCToLineCount: Int64
    var jsFuncPCToLineSize: Int64

    var cFuncCount: Int64
    var arrayCount: Int64

    var fastArrayCount: Int64
    var fastArrayElements: Int64

    var binaryObjectCount: Int64
    var binaryObjectSize: Int64

    init() {
        mallocSize = 0; mallocLimit = 0; memoryUsedSize = 0; mallocCount = 0
        atomCount = 0; atomSize = 0; strCount = 0; strSize = 0
        objCount = 0; objSize = 0; propCount = 0; propSize = 0
        shapeCount = 0; shapeSize = 0
        jsFuncCount = 0; jsFuncSize = 0; jsFuncCodeSize = 0
        jsFuncPCToLineCount = 0; jsFuncPCToLineSize = 0
        cFuncCount = 0; arrayCount = 0
        fastArrayCount = 0; fastArrayElements = 0
        binaryObjectCount = 0; binaryObjectSize = 0
    }
}

// NOTE: JeffJSGCObjectHeader is now defined in JeffJSObject.swift.
// The duplicate definition that was here has been removed.

// MARK: - JeffJSAtomStruct

/// Mirrors QuickJS `JSAtomStruct`. Each entry in the atom table.
/// Atoms are interned strings used as property keys, variable names, etc.
class JeffJSAtomStruct {
    /// Hash value of this atom (JS_ATOM_HASH_MASK bits).
    var hash: UInt32 = 0
    /// Next atom index in the hash chain (0 = end of chain).
    var hashNext: UInt32 = 0
    /// Atom type: string, symbol, global symbol, or private.
    var atomType: JSAtomTypeEnum = .JS_ATOM_TYPE_STRING
    /// Reference count. Predefined atoms start at a high refcount.
    var refCount: Int32 = 1
    /// The interned string data. For integer atoms, this may be empty
    /// (the integer is encoded in the atom ID itself).
    var str: String = ""
    /// Length of the string in UTF-16 code units (for compatibility with QuickJS).
    var len: Int = 0
    /// True if this atom is a small integer index (array index optimization).
    var isIntegerIndex: Bool = false

    init() {}

    init(str: String, hash: UInt32, atomType: JSAtomTypeEnum) {
        self.str = str
        self.hash = hash
        self.atomType = atomType
        self.len = str.utf16.count
    }
}

// MARK: - JeffJSClass

/// Mirrors QuickJS `JSClass`. Defines a class with its name, finalizer,
/// GC mark function, exotic methods, etc.
struct JeffJSClass {
    /// Atom index for the class name (e.g., "Object", "Array").
    var classNameAtom: UInt32 = 0
    /// Finalizer called when an object of this class is freed.
    var finalizer: ((JeffJSRuntime, JeffJSValue) -> Void)?
    /// GC mark function for tracing references.
    var gcMark: ((JeffJSRuntime, JeffJSValue, (_ val: JeffJSValue) -> Void) -> Void)?
    /// Call handler — makes instances of this class callable.
    var call: ((JeffJSContext, JeffJSValue, JeffJSValue, [JeffJSValue], Int) -> JeffJSValue)?
    /// Exotic behavior (proxy-like traps for property access).
    var exotic: JeffJSExoticMethods?

    init() {}
}

// MARK: - JeffJSExoticMethods

/// Mirrors QuickJS `JSExoticMethods` — custom property access behavior.
/// Used for Array, String, Proxy, TypedArray, etc.
struct JeffJSExoticMethods {
    var getOwnProperty: ((JeffJSContext, JeffJSValue, UInt32) -> Int)?
    var getOwnPropertyNames: ((JeffJSContext, JeffJSValue, Int) -> [UInt32]?)?
    var deleteProperty: ((JeffJSContext, JeffJSValue, UInt32) -> Int)?
    var defineOwnProperty: ((JeffJSContext, JeffJSValue, UInt32, JeffJSValue, Int) -> Int)?
    var hasProperty: ((JeffJSContext, JeffJSValue, UInt32) -> Int)?
    var getProperty: ((JeffJSContext, JeffJSValue, UInt32, JeffJSValue) -> JeffJSValue)?
    var setProperty: ((JeffJSContext, JeffJSValue, UInt32, JeffJSValue, JeffJSValue, Int) -> Int)?

    init() {}
}

// MARK: - JeffJSJobEntry

/// Mirrors QuickJS `JSJobEntry`. Represents a pending microtask/job in the queue.
/// Jobs include promise reactions, async function continuations, etc.
class JeffJSJobEntry {
    var link: ListHead = ListHead()
    var ctx: JeffJSContext?
    /// The job function to execute.
    var jobFunc: ((JeffJSContext, Int, [JeffJSValue]) -> JeffJSValue)?
    /// Arguments to pass to the job function.
    var args: [JeffJSValue] = []

    init() {}
}

// NOTE: JeffJSStackFrame is now defined in JeffJSObject.swift.
// The duplicate definition that was here has been removed.

// NOTE: JeffJSShape is now defined in JeffJSShape.swift.
// The forward declaration stub that was here has been removed.

// MARK: - Predefined Atom IDs

/// Predefined atom IDs matching JSPredefinedAtom in JeffJSAtom.swift.
/// Only includes atoms that are actively referenced by JeffJS code.
/// Raw values MUST match JSPredefinedAtom exactly.
enum JeffJSAtomID: UInt32 {
    case JS_ATOM_NULL = 0

    // Well-known property names
    case JS_ATOM_length              = 48   // JSPredefinedAtom.length
    case JS_ATOM_message             = 52   // JSPredefinedAtom.message
    case JS_ATOM_name                = 53   // JSPredefinedAtom.name
    case JS_ATOM_errors              = 54   // JSPredefinedAtom.errors
    case JS_ATOM_stack               = 55   // JSPredefinedAtom.stack
    case JS_ATOM_cause               = 56   // JSPredefinedAtom.cause
    case JS_ATOM_toString            = 57   // JSPredefinedAtom.toStringAtom
    case JS_ATOM_prototype           = 61   // JSPredefinedAtom.prototype
    case JS_ATOM_constructor         = 62   // JSPredefinedAtom.constructor_
    case JS_ATOM_value               = 66   // JSPredefinedAtom.value
    case JS_ATOM_arguments           = 80   // JSPredefinedAtom.arguments_
    case JS_ATOM_callee              = 81   // JSPredefinedAtom.callee

    // Well-known symbols
    case JS_ATOM_Symbol_toPrimitive          = 85   // JSPredefinedAtom.Symbol_toPrimitive
    case JS_ATOM_Symbol_iterator             = 86   // JSPredefinedAtom.Symbol_iterator
    case JS_ATOM_Symbol_match                = 87   // JSPredefinedAtom.Symbol_match
    case JS_ATOM_Symbol_matchAll             = 88   // JSPredefinedAtom.Symbol_matchAll
    case JS_ATOM_Symbol_replace              = 89   // JSPredefinedAtom.Symbol_replace
    case JS_ATOM_Symbol_search               = 90   // JSPredefinedAtom.Symbol_search
    case JS_ATOM_Symbol_split                = 91   // JSPredefinedAtom.Symbol_split
    case JS_ATOM_Symbol_toStringTag          = 92   // JSPredefinedAtom.Symbol_toStringTag
    case JS_ATOM_Symbol_isConcatSpreadable   = 93   // JSPredefinedAtom.Symbol_isConcatSpreadable
    case JS_ATOM_Symbol_hasInstance          = 94   // JSPredefinedAtom.Symbol_hasInstance
    case JS_ATOM_Symbol_species              = 95   // JSPredefinedAtom.Symbol_species
    case JS_ATOM_Symbol_unscopables          = 96   // JSPredefinedAtom.Symbol_unscopables
    case JS_ATOM_Symbol_asyncIterator        = 97   // JSPredefinedAtom.Symbol_asyncIterator

    // Built-in property names (continued)
    case JS_ATOM_then                = 99   // JSPredefinedAtom.then
    case JS_ATOM_flags               = 104  // JSPredefinedAtom.flags
    case JS_ATOM_source              = 105  // JSPredefinedAtom.source
    case JS_ATOM_global              = 106  // JSPredefinedAtom.global_
    case JS_ATOM_unicode             = 107  // JSPredefinedAtom.unicode
    case JS_ATOM_done                = 110  // JSPredefinedAtom.done

    // Math constants
    case JS_ATOM_E                   = 231  // JSPredefinedAtom.E
    case JS_ATOM_LN10                = 232  // JSPredefinedAtom.LN10
    case JS_ATOM_LN2                 = 233  // JSPredefinedAtom.LN2
    case JS_ATOM_LOG10E              = 234  // JSPredefinedAtom.LOG10E
    case JS_ATOM_LOG2E               = 235  // JSPredefinedAtom.LOG2E
    case JS_ATOM_PI                  = 236  // JSPredefinedAtom.PI
    case JS_ATOM_SQRT1_2             = 237  // JSPredefinedAtom.SQRT1_2
    case JS_ATOM_SQRT2               = 238  // JSPredefinedAtom.SQRT2

    // RegExp
    case JS_ATOM_exec                = 320  // JSPredefinedAtom.exec
    case JS_ATOM_dotAll              = 323  // JSPredefinedAtom.dotAll
    case JS_ATOM_hasIndices          = 324  // JSPredefinedAtom.hasIndices
    case JS_ATOM_ignoreCase          = 325  // JSPredefinedAtom.ignoreCase
    case JS_ATOM_multiline           = 326  // JSPredefinedAtom.multiline
    case JS_ATOM_sticky              = 327  // JSPredefinedAtom.sticky
    case JS_ATOM_input               = 328  // JSPredefinedAtom.input
    case JS_ATOM_index               = 329  // JSPredefinedAtom.index
    case JS_ATOM_groups              = 330  // JSPredefinedAtom.groups
    case JS_ATOM_indices             = 331  // JSPredefinedAtom.indices
    case JS_ATOM_lastIndex           = 332  // JSPredefinedAtom.lastIndex

    // TypedArray / ArrayBuffer
    case JS_ATOM_maxByteLength       = 381  // JSPredefinedAtom.maxByteLength

    // Error constructors
    case JS_ATOM_Error               = 396  // JSPredefinedAtom.Error
    case JS_ATOM_EvalError           = 397  // JSPredefinedAtom.EvalError
    case JS_ATOM_RangeError          = 398  // JSPredefinedAtom.RangeError
    case JS_ATOM_ReferenceError      = 399  // JSPredefinedAtom.ReferenceError
    case JS_ATOM_SyntaxError         = 400  // JSPredefinedAtom.SyntaxError
    case JS_ATOM_TypeError           = 401  // JSPredefinedAtom.TypeError
    case JS_ATOM_URIError            = 402  // JSPredefinedAtom.URIError
    case JS_ATOM_AggregateError      = 403  // JSPredefinedAtom.AggregateError
    case JS_ATOM_InternalError       = 404  // JSPredefinedAtom.InternalError

    // Global constructors and objects
    case JS_ATOM_Object              = 405  // JSPredefinedAtom.Object
    case JS_ATOM_Array               = 406  // JSPredefinedAtom.Array_
    case JS_ATOM_Function            = 407  // JSPredefinedAtom.Function_
    case JS_ATOM_Boolean             = 408  // JSPredefinedAtom.Boolean_
    case JS_ATOM_Number              = 409  // JSPredefinedAtom.Number_
    case JS_ATOM_String_             = 410  // JSPredefinedAtom.String_
    case JS_ATOM_Symbol              = 411  // JSPredefinedAtom.Symbol_
    case JS_ATOM_BigInt              = 412  // JSPredefinedAtom.BigInt_
    case JS_ATOM_RegExp              = 413  // JSPredefinedAtom.RegExp
    case JS_ATOM_Date                = 414  // JSPredefinedAtom.Date
    case JS_ATOM_Map                 = 415  // JSPredefinedAtom.Map_
    case JS_ATOM_Set                 = 416  // JSPredefinedAtom.Set_
    case JS_ATOM_WeakMap             = 417  // JSPredefinedAtom.WeakMap
    case JS_ATOM_WeakSet             = 418  // JSPredefinedAtom.WeakSet
    case JS_ATOM_WeakRef             = 419  // JSPredefinedAtom.WeakRef
    case JS_ATOM_FinalizationRegistry = 420  // JSPredefinedAtom.FinalizationRegistry
    case JS_ATOM_ArrayBuffer         = 421  // JSPredefinedAtom.ArrayBuffer
    case JS_ATOM_SharedArrayBuffer   = 422  // JSPredefinedAtom.SharedArrayBuffer
    case JS_ATOM_DataView            = 423  // JSPredefinedAtom.DataView
    case JS_ATOM_Promise             = 424  // JSPredefinedAtom.Promise_
    case JS_ATOM_Proxy               = 425  // JSPredefinedAtom.Proxy
    case JS_ATOM_Math                = 429  // JSPredefinedAtom.Math
    case JS_ATOM_Int8Array           = 430  // JSPredefinedAtom.Int8Array
    case JS_ATOM_Uint8Array          = 431  // JSPredefinedAtom.Uint8Array
    case JS_ATOM_Uint8ClampedArray   = 432  // JSPredefinedAtom.Uint8ClampedArray
    case JS_ATOM_Int16Array          = 433  // JSPredefinedAtom.Int16Array
    case JS_ATOM_Uint16Array         = 434  // JSPredefinedAtom.Uint16Array
    case JS_ATOM_Int32Array          = 435  // JSPredefinedAtom.Int32Array
    case JS_ATOM_Uint32Array         = 436  // JSPredefinedAtom.Uint32Array_
    case JS_ATOM_BigInt64Array       = 437  // JSPredefinedAtom.BigInt64Array
    case JS_ATOM_BigUint64Array      = 438  // JSPredefinedAtom.BigUint64Array
    case JS_ATOM_Float32Array        = 439  // JSPredefinedAtom.Float32Array
    case JS_ATOM_Float64Array        = 440  // JSPredefinedAtom.Float64Array
    case JS_ATOM_Iterator            = 441  // JSPredefinedAtom.Iterator
    case JS_ATOM_GeneratorFunction   = 442  // JSPredefinedAtom.GeneratorFunction
    case JS_ATOM_AsyncFunction       = 443  // JSPredefinedAtom.AsyncFunction
    case JS_ATOM_AsyncGeneratorFunction = 444  // JSPredefinedAtom.AsyncGeneratorFunction
    case JS_ATOM_Generator           = 445  // JSPredefinedAtom.Generator
    case JS_ATOM_AsyncGenerator      = 446  // JSPredefinedAtom.AsyncGenerator

    // Additional atoms (added to JSPredefinedAtom)
    case JS_ATOM_Module              = 504  // JSPredefinedAtom.Module
    case JS_ATOM_AsyncIterator       = 505  // JSPredefinedAtom.AsyncIterator_
    case JS_ATOM_unicodeSets         = 506  // JSPredefinedAtom.unicodeSets

    /// Sentinel — total number of predefined atoms.
    case JS_ATOM_END                 = 507  // JSPredefinedAtom.END
}

// MARK: - JeffJSRuntime

/// The top-level JS runtime. Owns the atom table, GC, class table,
/// shape hash, job queue, and all associated state.
///
/// Mirrors QuickJS `JSRuntime` from quickjs.c exactly.
///
/// Usage:
/// ```swift
/// let rt = JeffJSRuntime()
/// let ctx = rt.newContext()
/// let result = ctx.eval(input: "1 + 2", filename: "<input>", evalFlags: JS_EVAL_TYPE_GLOBAL)
/// // ... use result ...
/// ctx.free()
/// rt.free()
/// ```
final class JeffJSRuntime {

    // MARK: - Memory Management

    /// Tracks malloc statistics (allocated bytes, count, limit).
    var mallocState: JSMallocState

    // MARK: - Atom Table

    /// Size of the atom hash table (always a power of two).
    var atomHashSize: Int
    /// Number of atoms currently in the table (including predefined).
    var atomCount: Int
    /// Allocated capacity of atomArray.
    var atomSize: Int
    /// Resize threshold — when atomCount reaches this, double the hash table.
    var atomCountResize: Int
    /// Hash table buckets. Each bucket stores the index of the first atom in its chain.
    /// 0 means empty bucket (since atom index 0 is JS_ATOM_NULL).
    var atomHash: [UInt32]
    /// Flat array of atom structs. Index 0 is reserved (JS_ATOM_NULL).
    /// Freed atoms have their slot added to the free list.
    var atomArray: [JeffJSAtomStruct?]
    /// Head of the atom free list (index of first free slot, 0 = none free).
    var atomFreeIndex: Int

    // MARK: - Class System

    /// Number of registered classes.
    var classCount: Int
    /// Array of class definitions, indexed by JSClassID.
    var classArray: [JeffJSClass]

    // MARK: - GC Lists

    /// Linked list of all JeffJSContext objects owned by this runtime.
    var contextList: ListHead
    /// Main GC object list — all GC-tracked objects.
    var gcObjList: ListHead
    /// Objects with zero reference count, pending release.
    var gcZeroRefCountList: ListHead
    /// Temporary list used during GC cycle detection.
    var tmpObjList: ListHead
    /// Current GC phase.
    var gcPhase: JSGCPhaseEnum
    /// Re-entrancy guard for freeGCObject recursive child freeing.
    var inFreeChain: Bool = false
    /// Set to true after context init completes. Enables object freeing in freeValue().
    /// During init, objects are context-scoped and freed by context.free().
    var initComplete: Bool = false
    /// Byte threshold for triggering a GC cycle.
    var mallocGCThreshold: Int
    /// Linked list of weak references for cleanup during GC.
    var weakrefList: ListHead

    // MARK: - Per-Runtime GC Tracking (replaces module-level globals)

    /// All GC-tracked object headers for this runtime.
    var gcObjects: [JeffJSGCObjectHeader] = []
    /// Objects whose refcount hit zero during a GC cycle (deferred free).
    var gcZeroRefCountObjects: [JeffJSGCObjectHeader] = []
    /// Temporary list used during GC cycle detection (phase 3).
    var gcTmpObjects: [JeffJSGCObjectHeader] = []
    /// Map from ObjectIdentifier to JeffJSWeakRef for quick lookup.
    var gcWeakRefMap: [ObjectIdentifier: JeffJSWeakRef] = [:]

    /// Per-runtime bytecode cache. Atom IDs in bytecode are runtime-specific,
    /// so the cache must be scoped to the runtime that compiled them.
    let bytecodeCache = JeffJSBytecodeCache()

    // MARK: - Stack Checking

    /// Maximum stack size in bytes.
    var stackSize: UInt
    /// Address of the top of the stack (set at runtime startup).
    var stackTop: UInt
    /// Computed stack limit (stackTop - stackSize).
    var stackLimit: UInt

    // MARK: - Exception State

    /// The current pending exception value.
    var currentException: JeffJSValue
    /// If true, the current exception cannot be caught by try/catch.
    var currentExceptionIsUncatchable: Bool
    /// True if we are in an out-of-memory error handler (prevents recursion).
    var inOutOfMemory: Bool
    /// Current call stack frame (for stack traces).
    var currentStackFrame: JeffJSStackFrame?

    // MARK: - Interrupt Handler

    /// Optional interrupt handler. Called periodically during execution.
    /// Returns true to abort execution, false to continue.
    var interruptHandler: ((JeffJSRuntime) -> Bool)?
    /// Opaque data passed to the interrupt handler.
    var interruptOpaque: Any?

    // MARK: - Promise Rejection Tracker

    /// Called when a promise is rejected without a handler, or when a handler is added.
    /// Parameters: (context, isHandled, promise, reason, opaque)
    var hostPromiseRejectionTracker: ((JeffJSContext, Bool, JeffJSValue, JeffJSValue, Any?) -> Void)?
    /// Opaque data for the promise rejection tracker.
    var hostPromiseRejectionTrackerOpaque: Any?

    // MARK: - Job Queue (Microtask Queue)

    /// Linked list of pending jobs (promise reactions, etc.).
    var jobList: ListHead

    // MARK: - Module Loader

    /// Module name normalizer. Takes (context, base_name, module_name) -> resolved name.
    var moduleNormalizeFunc: ((JeffJSContext, String, String) -> String?)?
    /// Module loader. Takes (context, module_name) -> module object or exception.
    var moduleLoaderFunc: ((JeffJSContext, String) -> JeffJSValue)?
    /// Opaque data for the module loader.
    var moduleLoaderOpaque: Any?
    /// Monotonic timestamp for ordering async module evaluations.
    var moduleAsyncEvaluationNextTimestamp: Int64

    // MARK: - Miscellaneous

    /// True if the runtime can block (e.g., for Atomics.wait).
    var canBlock: Bool
    /// Strip flags for bytecode serialization (JS_STRIP_SOURCE, JS_STRIP_DEBUG).
    var stripFlags: UInt8

    // MARK: - Shape Hash Table

    /// Log2 of the shape hash table size.
    var shapeHashBits: Int
    /// Current size of the shape hash table (1 << shapeHashBits).
    var shapeHashSize: Int
    /// Number of shapes currently in the hash table.
    var shapeHashCount: Int
    /// Shape hash table buckets (chained via JeffJSShape.shapeHashNext).
    var shapeHash: [JeffJSShape?]

    // MARK: - User Data

    /// User-defined opaque data attached to the runtime.
    var userOpaque: Any?

    // MARK: - Global Symbol Registry

    /// Maps description string -> symbol JeffJSValue for Symbol.for() / Symbol.keyFor().
    /// In QuickJS this is implemented through the atom table with JS_ATOM_TYPE_GLOBAL_SYMBOL.
    /// We use a dictionary on the runtime for the same effect.
    var globalSymbolRegistry: [String: JeffJSValue] = [:]

    // MARK: - Class ID Counter

    /// Next auto-assigned class ID for user-defined classes.
    /// Built-in classes use 1..JS_CLASS_INIT_COUNT-1.
    private var nextClassID: Int

    // MARK: - Initialization

    /// Creates a new JS runtime with default settings.
    /// Mirrors `JS_NewRuntime()` / `JS_NewRuntime2()` from QuickJS.
    ///
    /// This initializes:
    /// - The atom table with all ~504 predefined atoms
    /// - The class table with all built-in JS classes
    /// - GC state, job queue, and shape hash
    /// - Default stack size (1 MB)
    init() {
        // Memory state
        mallocState = JSMallocState()

        // Atom table — start with a reasonable hash size
        let initialAtomHashSize = JeffJSConfig.atomsInitialHashSize  // must be power of 2, >= 2 * JS_ATOM_END
        atomHashSize = initialAtomHashSize
        atomCount = 0
        atomSize = Int(JeffJSAtomID.JS_ATOM_END.rawValue)  // exact size, grows dynamically as needed
        atomCountResize = initialAtomHashSize * 3 / 4  // 75% load factor
        atomHash = [UInt32](repeating: 0, count: initialAtomHashSize)
        atomArray = [JeffJSAtomStruct?](repeating: nil, count: atomSize)
        atomFreeIndex = 0

        // Class table
        classCount = 0
        classArray = []
        nextClassID = JSClassID.JS_CLASS_INIT_COUNT.rawValue

        // GC lists
        contextList = ListHead()
        gcObjList = ListHead()
        gcZeroRefCountList = ListHead()
        tmpObjList = ListHead()
        gcPhase = .JS_GC_PHASE_NONE
        mallocGCThreshold = JeffJSConfig.gcMallocThreshold
        weakrefList = ListHead()

        // Stack
        stackSize = UInt(JS_DEFAULT_STACK_SIZE)
        stackTop = 0
        stackLimit = 0

        // Exception state
        currentException = .null
        currentExceptionIsUncatchable = false
        inOutOfMemory = false
        currentStackFrame = nil

        // Interrupt handler
        interruptHandler = nil
        interruptOpaque = nil

        // Promise rejection tracker
        hostPromiseRejectionTracker = nil
        hostPromiseRejectionTrackerOpaque = nil

        // Job queue
        jobList = ListHead()

        // Module loader
        moduleNormalizeFunc = nil
        moduleLoaderFunc = nil
        moduleLoaderOpaque = nil
        moduleAsyncEvaluationNextTimestamp = 0

        // Misc
        canBlock = true
        stripFlags = 0

        // Shape hash table
        shapeHashBits = JeffJSConfig.shapesHashBits
        shapeHashSize = 1 << shapeHashBits
        shapeHashCount = 0
        shapeHash = [JeffJSShape?](repeating: nil, count: shapeHashSize)

        // User data
        userOpaque = nil

        // Post-init setup (must come after all stored properties are set)
        // Approximate the stack position
        var stackVar: UInt = 0
        Swift.withUnsafePointer(to: &stackVar) { ptr in
            self.stackTop = UInt(bitPattern: ptr)
        }
        self.stackLimit = stackTop > stackSize ? stackTop - stackSize : 0

        // Initialize predefined atoms and built-in classes
        initAtoms()
        initBuiltinClasses()

        // Wire bytecode cache to this runtime for atom remapping
        bytecodeCache.rt = self
    }

    // MARK: - Runtime Lifecycle

    /// Frees the runtime and all associated resources.
    /// Mirrors `JS_FreeRuntime()` from QuickJS.
    ///
    /// This must be called after all contexts have been freed.
    /// After calling free(), the runtime must not be used.
    func free() {
        // Clear bytecode cache
        bytecodeCache.clear()

        // Free all pending jobs (including their duped arg values)
        freeJobQueue()

        // Free global symbol registry values
        for (_, val) in globalSymbolRegistry {
            freeValue(self, val)
        }
        globalSymbolRegistry.removeAll()

        // Free all atoms (decrement refcounts, release strings)
        if atomCount > 1 {
            for i in 1..<atomCount {
                atomArray[i] = nil
            }
        }
        atomArray = []
        atomHash = []
        atomCount = 0
        atomHashSize = 0

        // Free class array
        classArray = []
        classCount = 0

        // Free shapes
        shapeHash = []
        shapeHashCount = 0

        // Clear exception
        currentException = .null

        // Clear GC tracking state
        clearGCState(self)
        gcObjList = ListHead()
        gcZeroRefCountList = ListHead()
        tmpObjList = ListHead()
        weakrefList = ListHead()
    }

    // MARK: - Stack Management

    /// Sets the maximum stack size for this runtime.
    /// Mirrors `JS_SetMaxStackSize()` from QuickJS.
    ///
    /// - Parameter size: Maximum stack size in bytes. Pass 0 to disable stack checking.
    func setStackSize(_ size: UInt) {
        stackSize = size
        if size == 0 {
            stackLimit = 0
        } else {
            stackLimit = stackTop > size ? stackTop - size : 0
        }
    }

    /// Checks if the current stack usage exceeds the limit.
    /// Mirrors `js_check_stack_overflow()` from QuickJS.
    ///
    /// - Parameter margin: Additional bytes required beyond current usage.
    /// - Returns: True if stack overflow would occur.
    func checkStackOverflow(margin: UInt = 0) -> Bool {
        if stackLimit == 0 { return false }
        var localVar: UInt = 0
        var currentSP: UInt = 0
        withUnsafePointer(to: &localVar) { ptr in
            currentSP = UInt(bitPattern: ptr)
        }
        // Stack grows downward on most architectures
        return currentSP < stackLimit + margin
    }

    // MARK: - Interrupt Handler

    /// Sets the interrupt handler, called periodically during execution.
    /// Mirrors `JS_SetInterruptHandler()` from QuickJS.
    ///
    /// - Parameters:
    ///   - handler: Closure returning true to abort execution. Pass nil to clear.
    ///   - opaque: User data passed to the handler.
    func setInterruptHandler(_ handler: ((JeffJSRuntime) -> Bool)?, opaque: Any? = nil) {
        interruptHandler = handler
        interruptOpaque = opaque
    }

    // MARK: - Module Loader

    /// Sets the module name normalizer and loader functions.
    /// Mirrors `JS_SetModuleLoaderFunc()` from QuickJS.
    ///
    /// - Parameters:
    ///   - normalize: Resolves a module specifier relative to a base name. Pass nil for default behavior.
    ///   - loader: Loads and returns a module given its resolved name.
    ///   - opaque: User data passed to both functions.
    func setModuleLoader(
        normalize: ((JeffJSContext, String, String) -> String?)?,
        loader: ((JeffJSContext, String) -> JeffJSValue)?,
        opaque: Any? = nil
    ) {
        moduleNormalizeFunc = normalize
        moduleLoaderFunc = loader
        moduleLoaderOpaque = opaque
    }

    // MARK: - Context Management

    /// Creates a new JS context within this runtime.
    /// Mirrors `JS_NewContext()` from QuickJS.
    ///
    /// The context is initialized with all standard intrinsics (Object, Array,
    /// Function, Error, Number, String, Boolean, Symbol, BigInt, RegExp, JSON,
    /// Map, Set, Promise, Proxy, Reflect, TypedArrays, eval, generators, etc.).
    ///
    /// - Returns: A new JeffJSContext ready for script evaluation.
    func newContext() -> JeffJSContext {
        let ctx = JeffJSContext(rt: self)
        return ctx
    }

    /// Creates a new raw context without any intrinsics.
    /// Mirrors `JS_NewContextRaw()` from QuickJS.
    ///
    /// You must manually call `addIntrinsic*()` methods to add built-ins.
    ///
    /// - Returns: A bare JeffJSContext with only global object.
    func newContextRaw() -> JeffJSContext {
        let ctx = JeffJSContext(rt: self, addIntrinsics: false)
        return ctx
    }

    // MARK: - Job Queue (Microtask Queue)

    /// Executes all pending jobs in the microtask queue.
    /// Mirrors `JS_ExecutePendingJob()` from QuickJS.
    ///
    /// In QuickJS, this runs one job at a time and returns 1 if a job was run,
    /// 0 if the queue is empty, or -1 on error. This Swift version runs ALL
    /// pending jobs in a loop (matching the common usage pattern) and returns
    /// the total number of jobs executed.
    ///
    /// Per the ECMAScript specification, a failing microtask must not prevent
    /// other queued microtasks from executing (e.g., an unhandled rejection
    /// must not block a fetch().then() handler). Exceptions are cleared and
    /// execution continues with the next job in the queue.
    ///
    /// - Returns: Number of jobs executed (always >= 0).
    func executePendingJobs() -> Int {
        var jobsExecuted = 0
        let maxJobs = JeffJSConfig.maxJobsPerDrain

        while !listEmpty(jobList) && jobsExecuted < maxJobs {
            guard let firstNode = jobList.next else { break }

            // Find the job entry that owns this node
            guard let jobEntry = findJobEntry(for: firstNode) else {
                // Remove orphan node
                removeFromList(firstNode)
                break
            }

            // Remove from queue before execution
            removeFromList(firstNode)

            // Remove from jobEntries array to prevent unbounded growth.
            // Without this, every job ever enqueued stays in the array,
            // making the O(n) findJobEntry lookup progressively slower.
            if let idx = jobEntries.firstIndex(where: { $0 === jobEntry }) {
                jobEntries.remove(at: idx)
            }

            if let ctx = jobEntry.ctx, let jobFunc = jobEntry.jobFunc {
                let result = jobFunc(ctx, jobEntry.args.count, jobEntry.args)

                // Free argument values
                for arg in jobEntry.args {
                    arg.freeValue()
                }

                if result.isException {
                    // Clear the exception so subsequent jobs are not affected.
                    // Per spec, microtask failures must not block other microtasks.
                    let exc = ctx.getException()
                    exc.freeValue()
                    jobsExecuted += 1
                } else {
                    result.freeValue()
                    jobsExecuted += 1
                }
            }
        }

        return jobsExecuted
    }

    /// Returns true if there are pending jobs in the microtask queue.
    /// Mirrors `JS_IsJobPending()` from QuickJS.
    func isJobPending() -> Bool {
        return !listEmpty(jobList)
    }

    /// Enqueues a job (microtask) for later execution.
    /// Mirrors `JS_EnqueueJob()` from QuickJS.
    ///
    /// - Parameters:
    ///   - ctx: The context that enqueued this job.
    ///   - jobFunc: The function to execute.
    ///   - args: Arguments to pass (values are duped).
    func enqueueJob(
        ctx: JeffJSContext,
        jobFunc: @escaping (JeffJSContext, Int, [JeffJSValue]) -> JeffJSValue,
        args: [JeffJSValue]
    ) {
        let entry = JeffJSJobEntry()
        entry.ctx = ctx
        entry.jobFunc = jobFunc
        // Dup all argument values to prevent premature release
        entry.args = args.map { $0.dupValue() }
        appendToList(&jobList, node: entry.link)
        jobEntries.append(entry)
    }

    // MARK: - Memory Management

    /// Sets the memory limit for this runtime.
    /// Mirrors `JS_SetMemoryLimit()` from QuickJS.
    ///
    /// - Parameter limit: Maximum bytes that can be allocated. Pass -1 for no limit.
    func setMemoryLimit(_ limit: Int) {
        mallocState.mallocLimit = limit
    }

    /// Returns a snapshot of the current memory usage.
    /// Mirrors `JS_ComputeMemoryUsage()` from QuickJS.
    func getMemoryUsage() -> JSMemoryUsage {
        var usage = JSMemoryUsage()
        usage.mallocSize = Int64(mallocState.mallocSize)
        usage.mallocLimit = Int64(mallocState.mallocLimit)
        usage.mallocCount = Int64(mallocState.mallocCount)
        usage.atomCount = Int64(atomCount)
        usage.shapeCount = Int64(shapeHashCount)
        return usage
    }

    /// Triggers a garbage collection cycle.
    /// Mirrors `JS_RunGC()` from QuickJS.
    ///
    /// ## Memory Management Strategy
    ///
    /// JeffJS relies on Swift's Automatic Reference Counting (ARC) for primary
    /// memory management. ARC handles the vast majority of object lifetimes
    /// automatically — when an object's last strong reference is released, it
    /// is deallocated immediately.
    ///
    /// The main limitation of ARC is reference cycles (A -> B -> A). In a JS
    /// engine, cycles can arise from closures capturing their enclosing scope,
    /// prototype chains, or circular object references.
    ///
    /// QuickJS uses a trial-deletion cycle collector (Lins' algorithm) on
    /// objects tracked in `gcObjList`. JeffJS objects are not currently
    /// inserted into `gcObjList`, so the QuickJS-style cycle collector cannot
    /// run. Instead, we:
    ///
    ///   1. Drain the microtask (job) queue — pending jobs hold strong
    ///      references to closures and contexts that may prevent deallocation.
    ///   2. Clear the zero-ref-count list — objects that reached zero but
    ///      were not yet released (deferred release scenario).
    ///   3. Transition through GC phases for API compatibility.
    ///
    /// Most reference cycles in practice are broken by:
    ///   - `[weak self]` captures in native (C) function closures
    ///   - Context `free()` which nils out prototype and global references
    ///   - Explicit cycle-breaking in `WeakRef` / `FinalizationRegistry`
    ///
    /// A full trial-deletion cycle collector can be added in the future by
    /// inserting newly created GC objects into `gcObjList` via their
    /// `header.link` node and implementing Lins' algorithm here.
    func runGC() {
        // Delegate to the real Bacon-Rajan cycle collector in JeffJSGC.swift.
        _runGCImpl(self)
    }

    // MARK: - Class Registration

    /// Allocates a new class ID for a user-defined class.
    /// Mirrors `JS_NewClassID()` from QuickJS.
    ///
    /// Thread-safe in QuickJS via atomic increment; here we just increment.
    ///
    /// - Returns: A unique class ID.
    func newClassID() -> Int {
        let id = nextClassID
        nextClassID += 1
        return id
    }

    /// Registers a new class with the given ID and definition.
    /// Mirrors `JS_NewClass()` / `JS_NewClass1()` from QuickJS.
    ///
    /// - Parameters:
    ///   - classID: The class ID (from `newClassID()` or a built-in JSClassID).
    ///   - classDef: The class definition (name atom, finalizer, GC mark, call, exotic).
    /// - Returns: True on success, false if the class ID is already registered.
    @discardableResult
    func newClass(classID: Int, classDef: JeffJSClass) -> Bool {
        // Extend class array if needed
        while classArray.count <= classID {
            classArray.append(JeffJSClass())
        }

        // Check if already registered (non-zero name atom)
        if classArray[classID].classNameAtom != 0 {
            return false  // already registered
        }

        classArray[classID] = classDef
        if classID >= classCount {
            classCount = classID + 1
        }
        return true
    }

    // MARK: - Atom Operations

    /// Finds or creates an atom for the given string.
    /// Mirrors `JS_NewAtomLen()` / `__JS_NewAtom()` from QuickJS.
    ///
    /// - Parameter str: The string to intern.
    /// - Returns: The atom index. The atom's refcount is incremented.
    func findAtom(_ str: String) -> UInt32 {
        guard atomHashSize > 0, !atomHash.isEmpty else { return 0 }
        let hash = atomHashString(str)
        let bucketIndex = Int(hash) & (atomHashSize - 1)

        // Search the chain
        var atomIdx = atomHash[bucketIndex]
        while atomIdx != 0 {
            if let atom = atomArray[Int(atomIdx)] {
                if atom.hash == (hash & JS_ATOM_HASH_MASK) && atom.str == str {
                    atom.refCount += 1
                    return atomIdx
                }
                atomIdx = atom.hashNext
            } else {
                break
            }
        }

        // Not found — create a new atom
        return addAtom(str: str, hash: hash, atomType: .JS_ATOM_TYPE_STRING)
    }

    /// Duplicates an atom (increments its refcount).
    /// Mirrors `JS_DupAtom()` from QuickJS.
    func dupAtom(_ atom: UInt32) -> UInt32 {
        if atom != JS_ATOM_NULL && Int(atom) < atomCount {
            atomArray[Int(atom)]?.refCount += 1
        }
        return atom
    }

    /// Frees an atom (decrements its refcount; removes if zero).
    /// Mirrors `JS_FreeAtom()` / `JS_FreeAtomRT()` from QuickJS.
    func freeAtom(_ atom: UInt32) {
        guard atom != JS_ATOM_NULL && Int(atom) < atomCount else { return }
        guard let entry = atomArray[Int(atom)] else { return }

        entry.refCount -= 1
        if entry.refCount <= 0 {
            // Predefined atoms (< JS_ATOM_END) are never freed
            if atom >= JeffJSAtomID.JS_ATOM_END.rawValue {
                removeAtomFromHash(atom)
                atomArray[Int(atom)] = nil
                // Add to free list by storing free list head in hashNext
                let freeEntry = JeffJSAtomStruct()
                freeEntry.hashNext = UInt32(atomFreeIndex)
                atomArray[Int(atom)] = freeEntry
                atomFreeIndex = Int(atom)
            } else {
                // Predefined atom — reset refcount to 1 (never truly freed)
                entry.refCount = 1
            }
        }
    }

    /// Returns the string for an atom.
    /// Mirrors `JS_AtomToCString()` from QuickJS.
    func atomToString(_ atom: UInt32) -> String? {
        guard atom != JS_ATOM_NULL && Int(atom) < atomCount else { return nil }
        return atomArray[Int(atom)]?.str
    }

    /// Checks if an atom is an array index (tagged integer or a string
    /// representation of a valid array index in the range 0..2^32-2).
    /// Mirrors `JS_AtomIsArrayIndex()` from QuickJS.
    func atomIsArrayIndex(_ atom: UInt32) -> Bool {
        if (atom & JS_ATOM_TAG_INT) != 0 {
            return true
        }
        // Also check string atoms that represent valid array indices (e.g. "1", "2").
        // Per ES spec §6.1.7, integer-indexed property keys must be enumerated
        // in ascending numeric order before other string keys.
        guard let str = atomToString(atom), !str.isEmpty else { return false }
        guard let val = UInt32(str) else { return false }
        return val <= 0xFFFFFFFE && String(val) == str
    }

    /// Creates an atom from an integer array index.
    /// Mirrors `JS_NewAtomUInt32()` from QuickJS.
    func newAtomUInt32(_ index: UInt32) -> UInt32 {
        if index <= JS_ATOM_MAX_INT {
            return index | JS_ATOM_TAG_INT
        }
        // Fall back to string representation for large indices
        return findAtom(String(index))
    }

    /// Extracts the array index from an integer atom.
    /// Mirrors `JS_AtomToUInt32()` from QuickJS.
    func atomToUInt32(_ atom: UInt32) -> UInt32? {
        if (atom & JS_ATOM_TAG_INT) != 0 {
            return atom & ~JS_ATOM_TAG_INT
        }
        // Also handle string atoms that represent valid array indices.
        guard let str = atomToString(atom), !str.isEmpty else { return nil }
        guard let val = UInt32(str) else { return nil }
        if val <= 0xFFFFFFFE && String(val) == str {
            return val
        }
        return nil
    }

    // MARK: - Private Atom Helpers

    /// Computes the hash for a string, matching QuickJS hash_string().
    private func atomHashString(_ str: String) -> UInt32 {
        var h: UInt32 = 0
        for ch in str.utf8 {
            h = h &* 31 &+ UInt32(ch)
        }
        return h & JS_ATOM_HASH_MASK
    }

    /// Adds a new atom to the table.
    /// Mirrors `__JS_NewAtom()` from QuickJS.
    private func addAtom(str: String, hash: UInt32, atomType: JSAtomTypeEnum) -> UInt32 {
        guard atomHashSize > 0, !atomHash.isEmpty else { return 0 }
        let newIndex: Int

        // Check free list first
        if atomFreeIndex != 0 {
            newIndex = atomFreeIndex
            if let freeEntry = atomArray[newIndex] {
                atomFreeIndex = Int(freeEntry.hashNext)
            } else {
                atomFreeIndex = 0
            }
        } else {
            newIndex = atomCount
            atomCount += 1
            // Grow atom array if needed
            if atomCount > atomSize {
                let newSize = atomSize * 2
                atomArray.append(contentsOf: [JeffJSAtomStruct?](repeating: nil, count: newSize - atomSize))
                atomSize = newSize
            }
        }

        // Create the atom entry
        let entry = JeffJSAtomStruct(str: str, hash: hash & JS_ATOM_HASH_MASK, atomType: atomType)
        atomArray[newIndex] = entry

        // Insert into hash chain
        let bucketIndex = Int(hash) & (atomHashSize - 1)
        entry.hashNext = atomHash[bucketIndex]
        atomHash[bucketIndex] = UInt32(newIndex)

        // Check if we need to resize the hash table
        if atomCount >= atomCountResize {
            resizeAtomHash()
        }

        return UInt32(newIndex)
    }

    /// Removes an atom from the hash chain.
    private func removeAtomFromHash(_ atom: UInt32) {
        guard let entry = atomArray[Int(atom)] else { return }
        let bucketIndex = Int(entry.hash) & (atomHashSize - 1)

        var prevIdx: UInt32 = 0
        var curIdx = atomHash[bucketIndex]

        while curIdx != 0 {
            if curIdx == atom {
                if prevIdx == 0 {
                    atomHash[bucketIndex] = entry.hashNext
                } else {
                    atomArray[Int(prevIdx)]?.hashNext = entry.hashNext
                }
                return
            }
            prevIdx = curIdx
            curIdx = atomArray[Int(curIdx)]?.hashNext ?? 0
        }
    }

    /// Resizes the atom hash table (doubles it).
    /// Mirrors `JS_ResizeAtomHash()` from QuickJS.
    private func resizeAtomHash() {
        let newSize = atomHashSize * 2
        var newHash = [UInt32](repeating: 0, count: newSize)

        // Rehash all existing atoms
        for i in 1..<atomCount {
            guard let entry = atomArray[i] else { continue }
            let bucketIndex = Int(entry.hash) & (newSize - 1)
            entry.hashNext = newHash[bucketIndex]
            newHash[bucketIndex] = UInt32(i)
        }

        atomHash = newHash
        atomHashSize = newSize
        atomCountResize = newSize * 3 / 4
    }

    /// Initializes all predefined atoms.
    /// Mirrors the `JS_InitAtoms()` function in QuickJS which processes
    /// the `js_atom_init[]` table generated from `quickjs-atom.h`.
    private func initAtoms() {
        // Slot 0 is reserved as JS_ATOM_NULL (empty)
        atomArray[0] = nil
        atomCount = 1

        // Insert all predefined atoms using JSPredefinedAtom as the single source of truth.
        // JSPredefinedAtom.allAtomStrings returns strings for atoms 1..(END-1) in order.
        let predefined = JSPredefinedAtom.allAtomStrings
        for (i, str) in predefined.enumerated() {
            let expectedID = UInt32(i + 1)  // atom IDs are 1-based
            let hash = atomHashString(str)
            let atomType: JSAtomTypeEnum
            // Well-known Symbols have string values starting with "Symbol."
            if str.hasPrefix("Symbol.") {
                atomType = .JS_ATOM_TYPE_SYMBOL
            } else {
                atomType = .JS_ATOM_TYPE_STRING
            }

            let actualID = addAtom(str: str, hash: hash, atomType: atomType)

            // The atom IDs must match the predefined enum values.
            assert(actualID == expectedID,
                   "Predefined atom ID mismatch: expected \(expectedID), got \(actualID) for '\(str)'")

            // Predefined atoms get a permanent refcount so they're never freed
            atomArray[Int(actualID)]?.refCount = Int32.max / 2
        }
    }

    /// Initializes the built-in class table with all standard JS classes.
    /// Mirrors the class registration in `JS_NewRuntime()` from QuickJS.
    private func initBuiltinClasses() {
        // Pre-allocate the class array for all built-in classes
        let initCount = JSClassID.JS_CLASS_INIT_COUNT.rawValue
        classArray = [JeffJSClass](repeating: JeffJSClass(), count: initCount)
        classCount = initCount

        // Register each built-in class with its name atom.
        // Full finalizers/GC-mark/exotic methods will be set up per-class
        // in their respective intrinsic initialization functions.

        registerBuiltinClass(.JS_CLASS_OBJECT, name: JeffJSAtomID.JS_ATOM_Object.rawValue)
        registerBuiltinClass(.JS_CLASS_ARRAY, name: JeffJSAtomID.JS_ATOM_Array.rawValue)
        registerBuiltinClass(.JS_CLASS_ERROR, name: JeffJSAtomID.JS_ATOM_Error.rawValue)
        registerBuiltinClass(.JS_CLASS_NUMBER, name: JeffJSAtomID.JS_ATOM_Number.rawValue)
        registerBuiltinClass(.JS_CLASS_STRING, name: JeffJSAtomID.JS_ATOM_String_.rawValue)
        registerBuiltinClass(.JS_CLASS_BOOLEAN, name: JeffJSAtomID.JS_ATOM_Boolean.rawValue)
        registerBuiltinClass(.JS_CLASS_SYMBOL, name: JeffJSAtomID.JS_ATOM_Symbol.rawValue)
        registerBuiltinClass(.JS_CLASS_ARGUMENTS, name: JeffJSAtomID.JS_ATOM_arguments.rawValue)
        registerBuiltinClass(.JS_CLASS_MAPPED_ARGUMENTS, name: JeffJSAtomID.JS_ATOM_arguments.rawValue)
        registerBuiltinClass(.JS_CLASS_DATE, name: JeffJSAtomID.JS_ATOM_Date.rawValue)
        registerBuiltinClass(.JS_CLASS_MODULE_NS, name: JeffJSAtomID.JS_ATOM_Module.rawValue)
        registerBuiltinClass(.JS_CLASS_C_FUNCTION, name: JeffJSAtomID.JS_ATOM_Function.rawValue)
        registerBuiltinClass(.JS_CLASS_BYTECODE_FUNCTION, name: JeffJSAtomID.JS_ATOM_Function.rawValue)
        registerBuiltinClass(.JS_CLASS_BOUND_FUNCTION, name: JeffJSAtomID.JS_ATOM_Function.rawValue)
        registerBuiltinClass(.JS_CLASS_C_FUNCTION_DATA, name: JeffJSAtomID.JS_ATOM_Function.rawValue)
        registerBuiltinClass(.JS_CLASS_GENERATOR_FUNCTION, name: JeffJSAtomID.JS_ATOM_GeneratorFunction.rawValue)
        registerBuiltinClass(.JS_CLASS_FOR_IN_ITERATOR, name: JeffJSAtomID.JS_ATOM_Iterator.rawValue)
        registerBuiltinClass(.JS_CLASS_REGEXP, name: JeffJSAtomID.JS_ATOM_RegExp.rawValue)
        registerBuiltinClass(.JS_CLASS_ARRAY_BUFFER, name: JeffJSAtomID.JS_ATOM_ArrayBuffer.rawValue)
        registerBuiltinClass(.JS_CLASS_SHARED_ARRAY_BUFFER, name: JeffJSAtomID.JS_ATOM_SharedArrayBuffer.rawValue)
        registerBuiltinClass(.JS_CLASS_UINT8C_ARRAY, name: JeffJSAtomID.JS_ATOM_Uint8ClampedArray.rawValue)
        registerBuiltinClass(.JS_CLASS_INT8_ARRAY, name: JeffJSAtomID.JS_ATOM_Int8Array.rawValue)
        registerBuiltinClass(.JS_CLASS_UINT8_ARRAY, name: JeffJSAtomID.JS_ATOM_Uint8Array.rawValue)
        registerBuiltinClass(.JS_CLASS_INT16_ARRAY, name: JeffJSAtomID.JS_ATOM_Int16Array.rawValue)
        registerBuiltinClass(.JS_CLASS_UINT16_ARRAY, name: JeffJSAtomID.JS_ATOM_Uint16Array.rawValue)
        registerBuiltinClass(.JS_CLASS_INT32_ARRAY, name: JeffJSAtomID.JS_ATOM_Int32Array.rawValue)
        registerBuiltinClass(.JS_CLASS_UINT32_ARRAY, name: JeffJSAtomID.JS_ATOM_Uint32Array.rawValue)
        registerBuiltinClass(.JS_CLASS_BIG_INT64_ARRAY, name: JeffJSAtomID.JS_ATOM_BigInt64Array.rawValue)
        registerBuiltinClass(.JS_CLASS_BIG_UINT64_ARRAY, name: JeffJSAtomID.JS_ATOM_BigUint64Array.rawValue)
        registerBuiltinClass(.JS_CLASS_FLOAT32_ARRAY, name: JeffJSAtomID.JS_ATOM_Float32Array.rawValue)
        registerBuiltinClass(.JS_CLASS_FLOAT64_ARRAY, name: JeffJSAtomID.JS_ATOM_Float64Array.rawValue)
        registerBuiltinClass(.JS_CLASS_DATAVIEW, name: JeffJSAtomID.JS_ATOM_DataView.rawValue)
        registerBuiltinClass(.JS_CLASS_BIG_INT, name: JeffJSAtomID.JS_ATOM_BigInt.rawValue)
        registerBuiltinClass(.JS_CLASS_MAP, name: JeffJSAtomID.JS_ATOM_Map.rawValue)
        registerBuiltinClass(.JS_CLASS_SET, name: JeffJSAtomID.JS_ATOM_Set.rawValue)
        registerBuiltinClass(.JS_CLASS_WEAKMAP, name: JeffJSAtomID.JS_ATOM_WeakMap.rawValue)
        registerBuiltinClass(.JS_CLASS_WEAKSET, name: JeffJSAtomID.JS_ATOM_WeakSet.rawValue)
        registerBuiltinClass(.JS_CLASS_MAP_ITERATOR, name: JeffJSAtomID.JS_ATOM_Map.rawValue)
        registerBuiltinClass(.JS_CLASS_SET_ITERATOR, name: JeffJSAtomID.JS_ATOM_Set.rawValue)
        registerBuiltinClass(.JS_CLASS_ARRAY_ITERATOR, name: JeffJSAtomID.JS_ATOM_Array.rawValue)
        registerBuiltinClass(.JS_CLASS_STRING_ITERATOR, name: JeffJSAtomID.JS_ATOM_String_.rawValue)
        registerBuiltinClass(.JS_CLASS_REGEXP_STRING_ITERATOR, name: JeffJSAtomID.JS_ATOM_RegExp.rawValue)
        registerBuiltinClass(.JS_CLASS_GENERATOR, name: JeffJSAtomID.JS_ATOM_Generator.rawValue)
        registerBuiltinClass(.JS_CLASS_PROXY, name: JeffJSAtomID.JS_ATOM_Proxy.rawValue)
        registerBuiltinClass(.JS_CLASS_PROMISE, name: JeffJSAtomID.JS_ATOM_Promise.rawValue)
        registerBuiltinClass(.JS_CLASS_PROMISE_RESOLVE_FUNCTION, name: JeffJSAtomID.JS_ATOM_Function.rawValue)
        registerBuiltinClass(.JS_CLASS_PROMISE_REJECT_FUNCTION, name: JeffJSAtomID.JS_ATOM_Function.rawValue)
        registerBuiltinClass(.JS_CLASS_ASYNC_FUNCTION, name: JeffJSAtomID.JS_ATOM_AsyncFunction.rawValue)
        registerBuiltinClass(.JS_CLASS_ASYNC_FUNCTION_RESOLVE, name: JeffJSAtomID.JS_ATOM_Function.rawValue)
        registerBuiltinClass(.JS_CLASS_ASYNC_FUNCTION_REJECT, name: JeffJSAtomID.JS_ATOM_Function.rawValue)
        registerBuiltinClass(.JS_CLASS_ASYNC_GENERATOR_FUNCTION, name: JeffJSAtomID.JS_ATOM_AsyncGeneratorFunction.rawValue)
        registerBuiltinClass(.JS_CLASS_ASYNC_GENERATOR, name: JeffJSAtomID.JS_ATOM_AsyncGenerator.rawValue)
        registerBuiltinClass(.JS_CLASS_ASYNC_FROM_SYNC_ITERATOR, name: JeffJSAtomID.JS_ATOM_AsyncIterator.rawValue)
        registerBuiltinClass(.JS_CLASS_WEAKREF, name: JeffJSAtomID.JS_ATOM_WeakRef.rawValue)
        registerBuiltinClass(.JS_CLASS_FINALIZATION_REGISTRY, name: JeffJSAtomID.JS_ATOM_FinalizationRegistry.rawValue)
        registerBuiltinClass(.JS_CLASS_CALL_SITE, name: JeffJSAtomID.JS_ATOM_Object.rawValue)
    }

    /// Registers a single built-in class with its name atom.
    private func registerBuiltinClass(_ classID: JSClassID, name: UInt32) {
        var classDef = JeffJSClass()
        classDef.classNameAtom = name
        classArray[classID.rawValue] = classDef
    }

    // MARK: - Private Job Queue Helpers

    /// Storage for job entries (prevents ARC release before execution).
    private var jobEntries: [JeffJSJobEntry] = []

    /// Frees all pending jobs in the queue.
    private func freeJobQueue() {
        // Free duped argument values from any remaining jobs (#5)
        for entry in jobEntries {
            for arg in entry.args {
                arg.freeValue()
            }
            entry.args.removeAll()
        }
        jobEntries.removeAll()
        jobList = ListHead()
    }

    /// Finds the JeffJSJobEntry that owns the given ListNode.
    private func findJobEntry(for node: ListHead) -> JeffJSJobEntry? {
        return jobEntries.first { $0.link === node }
    }

    // MARK: - Private List Helpers

    /// Appends a node to the end of a list (uses ListHead circular sentinel).
    private func appendToList(_ list: inout ListHead, node: ListHead) {
        listAddTail(node, list)
    }

    /// Removes a node from its list.
    private func removeFromList(_ node: ListHead) {
        listDel(node)
    }
}
