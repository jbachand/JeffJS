// JeffJSConstants.swift
// JeffJS - 1:1 Swift port of QuickJS JavaScript engine
//
// Port of all constants, limits, flags, and enums from QuickJS.

import Foundation

// MARK: - Optimization Flags

let JEFFJS_OPTIMIZE = JeffJSConfig.optimizeEnabled
let JEFFJS_SHORT_OPCODES = JeffJSConfig.shortOpcodes

// MARK: - Limits

let JS_MAX_LOCAL_VARS: Int = JeffJSConfig.maxLocalVars
let JS_STACK_SIZE_MAX: Int = JeffJSConfig.maxStackSize
let JS_STRING_LEN_MAX: Int = (1 << 30) - 1
let JS_DEFAULT_STACK_SIZE: Int = JeffJSConfig.defaultStackSize

// MARK: - Rope Thresholds

let JS_STRING_ROPE_SHORT_LEN: Int = JeffJSConfig.ropeShortLen
let JS_STRING_ROPE_SHORT2_LEN: Int = JeffJSConfig.ropeShort2Len
let JS_STRING_ROPE_MAX_DEPTH: Int = JeffJSConfig.ropeMaxDepth
let ROPE_N_BUCKETS: Int = 44

// MARK: - JS Modes

let JS_MODE_STRICT: Int = 1 << 0
let JS_MODE_ASYNC: Int = 1 << 2
let JS_MODE_BACKTRACE_BARRIER: Int = 1 << 3

// MARK: - Property Flags

let JS_PROP_CONFIGURABLE: Int = 1 << 0
let JS_PROP_WRITABLE: Int = 1 << 1
let JS_PROP_ENUMERABLE: Int = 1 << 2
let JS_PROP_C_W_E: Int = (1 << 0) | (1 << 1) | (1 << 2)
let JS_PROP_LENGTH: Int = 1 << 3
let JS_PROP_TMASK: Int = 3 << 4
let JS_PROP_NORMAL: Int = 0 << 4
let JS_PROP_GETSET: Int = 1 << 4
let JS_PROP_VARREF: Int = 2 << 4
let JS_PROP_AUTOINIT: Int = 3 << 4
let JS_PROP_HAS_SHIFT: Int = 8
let JS_PROP_HAS_CONFIGURABLE: Int = 1 << 8
let JS_PROP_HAS_WRITABLE: Int = 1 << 9
let JS_PROP_HAS_ENUMERABLE: Int = 1 << 10
let JS_PROP_HAS_GET: Int = 1 << 11
let JS_PROP_HAS_SET: Int = 1 << 12
let JS_PROP_HAS_VALUE: Int = 1 << 13
let JS_PROP_THROW: Int = 1 << 14
let JS_PROP_THROW_STRICT: Int = 1 << 15
let JS_PROP_NO_EXOTIC: Int = 1 << 16
let JS_PROP_INITIAL_SIZE: Int = 2
let JS_PROP_INITIAL_HASH_SIZE: Int = 4
let JS_PROP_NO_ADD: Int = 1 << 17
let JS_PROP_DEFINE_PROPERTY: Int = 1 << 18

// MARK: - Atom Constants

let JS_ATOM_NULL: UInt32 = 0
let JS_ATOM_HASH_MASK: UInt32 = (1 << 30) - 1
let JS_ATOM_HASH_PRIVATE: UInt32 = (1 << 30) - 1
let JS_ATOM_TAG_INT: UInt32 = 1 << 31
let JS_ATOM_MAX_INT: UInt32 = (1 << 31) - 1
let JS_ATOM_MAX: UInt32 = (1 << 30) - 1

// MARK: - Eval Flags

let JS_EVAL_TYPE_GLOBAL: Int = 0 << 0
let JS_EVAL_TYPE_MODULE: Int = 1 << 0
let JS_EVAL_TYPE_DIRECT: Int = 2 << 0
let JS_EVAL_TYPE_INDIRECT: Int = 3 << 0
let JS_EVAL_TYPE_MASK: Int = 3 << 0
let JS_EVAL_FLAG_STRICT: Int = 1 << 3
let JS_EVAL_FLAG_COMPILE_ONLY: Int = 1 << 5
let JS_EVAL_FLAG_BACKTRACE_BARRIER: Int = 1 << 6
let JS_EVAL_FLAG_ASYNC: Int = 1 << 7

// MARK: - Type Conversion Hints

let HINT_STRING: Int = 0
let HINT_NUMBER: Int = 1
let HINT_NONE: Int = 2
let HINT_FORCE_ORDINARY: Int = 1 << 4

// MARK: - PC2Line Encoding

let PC2LINE_BASE: Int = -1
let PC2LINE_RANGE: Int = 5
let PC2LINE_OP_FIRST: Int = 1

// MARK: - Call Flags

let JS_CALL_FLAG_CONSTRUCTOR: Int = 1 << 0
let JS_CALL_FLAG_COPY_ARGV: Int = 1 << 1
let JS_CALL_FLAG_GENERATOR: Int = 1 << 2

// MARK: - GetPropertyNames (GPN) Flags

let JS_GPN_STRING_MASK: Int = 1 << 0
let JS_GPN_SYMBOL_MASK: Int = 1 << 1
let JS_GPN_PRIVATE_MASK: Int = 1 << 2
let JS_GPN_ENUM_ONLY: Int = 1 << 4
let JS_GPN_SET_ENUM: Int = 1 << 5

// MARK: - Interrupt Counter

let JS_INTERRUPT_COUNTER_INIT: Int = JeffJSConfig.interruptCounterInit

// MARK: - Backtrace Flags

let JS_BACKTRACE_FLAG_SKIP_FIRST_LEVEL: Int = 1 << 0

// MARK: - Strip Flags

let JS_STRIP_SOURCE: UInt8 = 1 << 0
let JS_STRIP_DEBUG: UInt8 = 1 << 1

// MARK: - BigInt / Limb (64-bit platform)

typealias JSLimb = UInt64
typealias JSSignedLimb = Int64
let JS_LIMB_BITS: Int = 64
let JS_LIMB_DIGITS: Int = 19
let JS_SHORT_BIG_INT_BITS: Int = 64

// MARK: - Miscellaneous Constants

let JS_MAX_SAFE_INTEGER: Int64 = (1 << 53) - 1
let JS_MIN_SAFE_INTEGER: Int64 = -((1 << 53) - 1)

let JS_WRITE_OBJ_BYTECODE: Int = 1 << 0
let JS_WRITE_OBJ_BSWAP: Int = 1 << 1
let JS_WRITE_OBJ_SAB: Int = 1 << 2
let JS_WRITE_OBJ_REFERENCE: Int = 1 << 3
let JS_WRITE_OBJ_STRIP_SOURCE: Int = 1 << 4
let JS_WRITE_OBJ_STRIP_DEBUG: Int = 1 << 5

let JS_READ_OBJ_BYTECODE: Int = 1 << 0
let JS_READ_OBJ_ROM_DATA: Int = 1 << 1
let JS_READ_OBJ_SAB: Int = 1 << 2
let JS_READ_OBJ_REFERENCE: Int = 1 << 3

let JS_DEF_CFUNC: Int = 0
let JS_DEF_CGETSET: Int = 1
let JS_DEF_CGETSET_MAGIC: Int = 2
let JS_DEF_PROP_STRING: Int = 3
let JS_DEF_PROP_INT32: Int = 4
let JS_DEF_PROP_INT64: Int = 5
let JS_DEF_PROP_DOUBLE: Int = 6
let JS_DEF_PROP_UNDEFINED: Int = 7
let JS_DEF_OBJECT: Int = 8
let JS_DEF_ALIAS: Int = 9

let JS_CFUNC_GENERIC: Int = 0
let JS_CFUNC_GENERIC_MAGIC: Int = 1
let JS_CFUNC_CONSTRUCTOR: Int = 2
let JS_CFUNC_CONSTRUCTOR_MAGIC: Int = 3
let JS_CFUNC_CONSTRUCTOR_OR_FUNC: Int = 4
let JS_CFUNC_CONSTRUCTOR_OR_FUNC_MAGIC: Int = 5
let JS_CFUNC_F_F: Int = 6
let JS_CFUNC_F_F_F: Int = 7
let JS_CFUNC_GETTER: Int = 8
let JS_CFUNC_SETTER: Int = 9
let JS_CFUNC_GETTER_MAGIC: Int = 10
let JS_CFUNC_SETTER_MAGIC: Int = 11
let JS_CFUNC_ITERATOR_NEXT: Int = 12

let JS_PARSE_JSON_EXT: Int = 1 << 0

// NOTE: JSValueTag is now defined in JeffJSValue.swift.
// The duplicate definition that was here has been removed.

// MARK: - JSClassID

/// Built-in class IDs matching QuickJS JS_CLASS_* values exactly.
enum JSClassID: Int {
    case JS_CLASS_OBJECT = 1
    case JS_CLASS_ARRAY = 2
    case JS_CLASS_ERROR = 3
    case JS_CLASS_NUMBER = 4
    case JS_CLASS_STRING = 5
    case JS_CLASS_BOOLEAN = 6
    case JS_CLASS_SYMBOL = 7
    case JS_CLASS_ARGUMENTS = 8
    case JS_CLASS_MAPPED_ARGUMENTS = 9
    case JS_CLASS_DATE = 10
    case JS_CLASS_MODULE_NS = 11
    case JS_CLASS_C_FUNCTION = 12
    case JS_CLASS_BYTECODE_FUNCTION = 13
    case JS_CLASS_BOUND_FUNCTION = 14
    case JS_CLASS_C_FUNCTION_DATA = 15
    case JS_CLASS_GENERATOR_FUNCTION = 16
    case JS_CLASS_FOR_IN_ITERATOR = 17
    case JS_CLASS_REGEXP = 18
    case JS_CLASS_ARRAY_BUFFER = 19
    case JS_CLASS_SHARED_ARRAY_BUFFER = 20
    case JS_CLASS_UINT8C_ARRAY = 21
    case JS_CLASS_INT8_ARRAY = 22
    case JS_CLASS_UINT8_ARRAY = 23
    case JS_CLASS_INT16_ARRAY = 24
    case JS_CLASS_UINT16_ARRAY = 25
    case JS_CLASS_INT32_ARRAY = 26
    case JS_CLASS_UINT32_ARRAY = 27
    case JS_CLASS_BIG_INT64_ARRAY = 28
    case JS_CLASS_BIG_UINT64_ARRAY = 29
    case JS_CLASS_FLOAT32_ARRAY = 30
    case JS_CLASS_FLOAT64_ARRAY = 31
    case JS_CLASS_DATAVIEW = 32
    case JS_CLASS_BIG_INT = 33
    case JS_CLASS_MAP = 34
    case JS_CLASS_SET = 35
    case JS_CLASS_WEAKMAP = 36
    case JS_CLASS_WEAKSET = 37
    case JS_CLASS_MAP_ITERATOR = 38
    case JS_CLASS_SET_ITERATOR = 39
    case JS_CLASS_ARRAY_ITERATOR = 40
    case JS_CLASS_STRING_ITERATOR = 41
    case JS_CLASS_REGEXP_STRING_ITERATOR = 42
    case JS_CLASS_GENERATOR = 43
    case JS_CLASS_PROXY = 44
    case JS_CLASS_PROMISE = 45
    case JS_CLASS_PROMISE_RESOLVE_FUNCTION = 46
    case JS_CLASS_PROMISE_REJECT_FUNCTION = 47
    case JS_CLASS_ASYNC_FUNCTION = 48
    case JS_CLASS_ASYNC_FUNCTION_RESOLVE = 49
    case JS_CLASS_ASYNC_FUNCTION_REJECT = 50
    case JS_CLASS_ASYNC_GENERATOR_FUNCTION = 51
    case JS_CLASS_ASYNC_GENERATOR = 52
    case JS_CLASS_ASYNC_FROM_SYNC_ITERATOR = 53
    case JS_CLASS_WEAKREF = 54
    case JS_CLASS_FINALIZATION_REGISTRY = 55
    case JS_CLASS_CALL_SITE = 56
    case JS_CLASS_INIT_COUNT = 57
}

/// First and last typed array class IDs for range checks.
let JS_CLASS_TYPED_ARRAY_FIRST = JSClassID.JS_CLASS_UINT8C_ARRAY.rawValue
let JS_CLASS_TYPED_ARRAY_LAST = JSClassID.JS_CLASS_FLOAT64_ARRAY.rawValue
let JS_TYPED_ARRAY_COUNT = JS_CLASS_TYPED_ARRAY_LAST - JS_CLASS_TYPED_ARRAY_FIRST + 1

// MARK: - JSErrorEnum

/// Matches QuickJS JS_*_ERROR enum for native error types.
enum JSErrorEnum: Int {
    case JS_EVAL_ERROR = 0
    case JS_RANGE_ERROR = 1
    case JS_REFERENCE_ERROR = 2
    case JS_SYNTAX_ERROR = 3
    case JS_TYPE_ERROR = 4
    case JS_URI_ERROR = 5
    case JS_INTERNAL_ERROR = 6
    case JS_AGGREGATE_ERROR = 7
    case JS_NATIVE_ERROR_COUNT = 8
}

// NOTE: JSGCPhaseEnum is now defined in JeffJSGC.swift.
// NOTE: JSGCObjectTypeEnum is now defined in JeffJSObject.swift.
// The duplicate definitions that were here have been removed.

// MARK: - JSWeakRefHeaderTypeEnum

/// Weak reference header type tags.
enum JSWeakRefHeaderTypeEnum: Int {
    case JS_WEAK_REF_HEADER_MAP = 0
    case JS_WEAK_REF_HEADER_WEAKREF = 1
    case JS_WEAK_REF_HEADER_WEAK_MAP_ENTRY = 2
    case JS_WEAK_REF_HEADER_FINREG_ENTRY = 3
}

// MARK: - JSAtomTypeEnum

/// Atom type classification matching QuickJS JS_ATOM_TYPE_*.
enum JSAtomTypeEnum: Int {
    case JS_ATOM_TYPE_STRING = 0
    case JS_ATOM_TYPE_GLOBAL_SYMBOL = 1
    case JS_ATOM_TYPE_SYMBOL = 2
    case JS_ATOM_TYPE_PRIVATE = 3
}

// MARK: - JSAtomKindEnum

/// Atom kind classification for parsing/internal use.
enum JSAtomKindEnum: Int {
    case JS_ATOM_KIND_STRING = 0
    case JS_ATOM_KIND_SYMBOL = 1
    case JS_ATOM_KIND_PRIVATE = 2
}

// MARK: - JSAutoInitIDEnum

/// Auto-init IDs for lazily initialized properties.
enum JSAutoInitIDEnum: Int {
    case JS_AUTOINIT_ID_PROTOTYPE = 0
    case JS_AUTOINIT_ID_MODULE_NS = 1
    case JS_AUTOINIT_ID_PROP = 2
}

// MARK: - JSClosureTypeEnum

/// Closure variable types matching QuickJS closure_var types.
enum JSClosureTypeEnum: Int {
    case JS_CLOSURE_VAR_LOCAL = 0
    case JS_CLOSURE_VAR_ARG = 1
    case JS_CLOSURE_VAR_VAR_REF = 2
    case JS_CLOSURE_VAR_PARENT_LOCAL = 3
}

// MARK: - JSVarKindEnum

/// Variable declaration kind matching QuickJS JSVarKindEnum.
enum JSVarKindEnum: Int {
    case JS_VAR_NORMAL = 0
    case JS_VAR_FUNCTION_DECL = 1
    case JS_VAR_NEW_FUNCTION_DECL = 2
    case JS_VAR_CATCH = 3
    case JS_VAR_FUNCTION_NAME = 4
    case JS_VAR_PRIVATE_FIELD = 5
    case JS_VAR_PRIVATE_METHOD = 6
    case JS_VAR_PRIVATE_GETTER = 7
    case JS_VAR_PRIVATE_SETTER = 8
    case JS_VAR_PRIVATE_GETTER_SETTER = 9
}

// MARK: - JSFunctionKindEnum

/// Function kind matching QuickJS JSFunctionKindEnum.
enum JSFunctionKindEnum: Int {
    case JS_FUNC_NORMAL = 0
    case JS_FUNC_GENERATOR = 1
    case JS_FUNC_ASYNC = 2
    case JS_FUNC_ASYNC_GENERATOR = 3
}

// MARK: - JSIteratorKindEnum

/// Iterator kind for Map/Set/Array iterators.
enum JSIteratorKindEnum: Int {
    case JS_ITERATOR_KIND_KEY = 0
    case JS_ITERATOR_KIND_VALUE = 1
    case JS_ITERATOR_KIND_KEY_AND_VALUE = 2
}

// MARK: - JSStrictEqModeEnum

/// Strict equality comparison modes.
enum JSStrictEqModeEnum: Int {
    case JS_EQ_STRICT = 0
    case JS_EQ_SAME_VALUE = 1
    case JS_EQ_SAME_VALUE_ZERO = 2
}

// MARK: - JSExportTypeEnum

/// Module export entry types.
enum JSExportTypeEnum: Int {
    case JS_EXPORT_TYPE_LOCAL = 0
    case JS_EXPORT_TYPE_INDIRECT = 1
}

// MARK: - JSModuleStatus

/// Module loading/evaluation state machine.
enum JSModuleStatus: Int {
    case JS_MODULE_STATUS_UNLINKED = 0
    case JS_MODULE_STATUS_LINKING = 1
    case JS_MODULE_STATUS_LINKED = 2
    case JS_MODULE_STATUS_EVALUATING = 3
    case JS_MODULE_STATUS_EVALUATING_ASYNC = 4
    case JS_MODULE_STATUS_EVALUATED = 5
}

// MARK: - JSFreeModuleEnum

/// Controls how module resources are freed.
enum JSFreeModuleEnum: Int {
    case JS_FREE_MODULE_ALL = 0
    case JS_FREE_MODULE_NOT_RESOLVED = 1
    case JS_FREE_MODULE_NOT_EVALUATED = 2
}

// MARK: - JSVarDefEnum

/// Variable definition types for bytecode.
enum JSVarDefEnum: Int {
    case JS_VAR_DEF_WITH = 0
    case JS_VAR_DEF_LET = 1
    case JS_VAR_DEF_CONST = 2
    case JS_VAR_DEF_FUNCTION_DECL = 3
    case JS_VAR_DEF_NEW_FUNCTION_DECL = 4
    case JS_VAR_DEF_CATCH = 5
    case JS_VAR_DEF_VAR = 6
}

// MARK: - JSPromiseStateEnum

/// Promise internal states matching the spec.
enum JSPromiseStateEnum: Int {
    case JS_PROMISE_PENDING = 0
    case JS_PROMISE_FULFILLED = 1
    case JS_PROMISE_REJECTED = 2
}

// MARK: - JSGeneratorStateEnum

/// Generator function internal states.
enum JSGeneratorStateEnum: Int {
    case JS_GENERATOR_STATE_SUSPENDED_START = 0
    case JS_GENERATOR_STATE_SUSPENDED_YIELD = 1
    case JS_GENERATOR_STATE_SUSPENDED_YIELD_STAR = 2
    case JS_GENERATOR_STATE_EXECUTING = 3
    case JS_GENERATOR_STATE_COMPLETED = 4
}

// MARK: - JSOverloadableOperatorEnum

/// Overloadable operator IDs for operator overloading support.
enum JSOverloadableOperatorEnum: Int {
    case JS_OVOP_ADD = 0
    case JS_OVOP_SUB = 1
    case JS_OVOP_MUL = 2
    case JS_OVOP_DIV = 3
    case JS_OVOP_MOD = 4
    case JS_OVOP_POW = 5
    case JS_OVOP_OR = 6
    case JS_OVOP_AND = 7
    case JS_OVOP_XOR = 8
    case JS_OVOP_SHL = 9
    case JS_OVOP_SAR = 10
    case JS_OVOP_SHR = 11
    case JS_OVOP_EQ = 12
    case JS_OVOP_LESS = 13
    case JS_OVOP_POS = 14
    case JS_OVOP_NEG = 15
    case JS_OVOP_INC = 16
    case JS_OVOP_DEC = 17
    case JS_OVOP_NOT = 18
    case JS_OVOP_COUNT = 19
}

// MARK: - JSRegExpFlags

/// RegExp flag bits matching QuickJS LRE_FLAG_*.
let LRE_FLAG_GLOBAL: Int = 1 << 0
let LRE_FLAG_IGNORECASE: Int = 1 << 1
let LRE_FLAG_MULTILINE: Int = 1 << 2
let LRE_FLAG_DOTALL: Int = 1 << 3
let LRE_FLAG_UNICODE: Int = 1 << 4
let LRE_FLAG_STICKY: Int = 1 << 5
let LRE_FLAG_INDICES: Int = 1 << 6
let LRE_FLAG_UNICODE_SETS: Int = 1 << 7
let LRE_FLAG_NAMED_GROUPS: Int = 1 << 8

// MARK: - JSTokenType (parser token IDs)

/// Token IDs for the JS parser, matching QuickJS TOK_* values.
enum JSTokenType: Int {
    case TOK_NUMBER = 128
    case TOK_STRING = 129
    case TOK_TEMPLATE = 130
    case TOK_IDENT = 131
    case TOK_REGEXP = 132
    case TOK_DIV_ASSIGN = 133
    case TOK_LINE_NUM = 134
    case TOK_PRIVATE_NAME = 135
    case TOK_EOF = 136

    // Single-char tokens use their ASCII value (<128).
    // Multi-char operators:
    case TOK_SHL_ASSIGN = 137    // <<=
    case TOK_SAR_ASSIGN = 138    // >>=
    case TOK_SHR_ASSIGN = 139    // >>>=
    case TOK_MUL_ASSIGN = 140    // *=
    case TOK_MOD_ASSIGN = 141    // %=
    case TOK_POW_ASSIGN = 142    // **=
    case TOK_ADD_ASSIGN = 143    // +=
    case TOK_SUB_ASSIGN = 144    // -=
    case TOK_AND_ASSIGN = 145    // &=
    case TOK_OR_ASSIGN = 146     // |=
    case TOK_XOR_ASSIGN = 147    // ^=
    case TOK_LAND_ASSIGN = 148   // &&=
    case TOK_LOR_ASSIGN = 149    // ||=
    case TOK_DOUBLE_QUESTION_MARK_ASSIGN = 150  // ??=
    case TOK_SHL = 151           // <<
    case TOK_SAR = 152           // >>
    case TOK_SHR = 153           // >>>
    case TOK_POW = 154           // **
    case TOK_LAND = 155          // &&
    case TOK_LOR = 156           // ||
    case TOK_INC = 157           // ++
    case TOK_DEC = 158           // --
    case TOK_EQ = 159            // ==
    case TOK_NEQ = 160           // !=
    case TOK_STRICT_EQ = 161     // ===
    case TOK_STRICT_NEQ = 162    // !==
    case TOK_LE = 163            // <=
    case TOK_GE = 164            // >=
    case TOK_ARROW = 165         // =>
    case TOK_ELLIPSIS = 166      // ...
    case TOK_DOUBLE_QUESTION_MARK = 167  // ??
    case TOK_OPTIONAL_CHAIN = 168        // ?.

    // Keywords (must be after operator tokens):
    case TOK_NULL = 169
    case TOK_FALSE = 170
    case TOK_TRUE = 171
    case TOK_IF = 172
    case TOK_ELSE = 173
    case TOK_RETURN = 174
    case TOK_VAR = 175
    case TOK_THIS = 176
    case TOK_DELETE = 177
    case TOK_VOID = 178
    case TOK_TYPEOF = 179
    case TOK_NEW = 180
    case TOK_IN = 181
    case TOK_INSTANCEOF = 182
    case TOK_DO = 183
    case TOK_WHILE = 184
    case TOK_FOR = 185
    case TOK_BREAK = 186
    case TOK_CONTINUE = 187
    case TOK_SWITCH = 188
    case TOK_CASE = 189
    case TOK_DEFAULT = 190
    case TOK_THROW = 191
    case TOK_TRY = 192
    case TOK_CATCH = 193
    case TOK_FINALLY = 194
    case TOK_FUNCTION = 195
    case TOK_DEBUGGER = 196
    case TOK_WITH = 197
    case TOK_CLASS = 198
    case TOK_CONST = 199
    case TOK_ENUM = 200
    case TOK_EXPORT = 201
    case TOK_EXTENDS = 202
    case TOK_IMPORT = 203
    case TOK_SUPER = 204
    case TOK_IMPLEMENTS = 205
    case TOK_INTERFACE = 206
    case TOK_LET = 207
    case TOK_PACKAGE = 208
    case TOK_PRIVATE = 209
    case TOK_PROTECTED = 210
    case TOK_PUBLIC = 211
    case TOK_STATIC = 212
    case TOK_YIELD = 213
    case TOK_AWAIT = 214
    case TOK_OF = 215
    case TOK_ACCESSOR = 216
}

// MARK: - JSDescriptionFlagEnum

/// Descriptor behavior flags for Object.defineProperty internals.
enum JSDescriptionFlagEnum: Int {
    case JS_DESC_FLAG_DATA = 0
    case JS_DESC_FLAG_ACCESSOR = 1
}

// MARK: - JSIteratorHelperKindEnum

/// Iterator helper method identifiers.
enum JSIteratorHelperKindEnum: Int {
    case JS_ITERATOR_HELPER_KIND_MAP = 0
    case JS_ITERATOR_HELPER_KIND_FILTER = 1
    case JS_ITERATOR_HELPER_KIND_TAKE = 2
    case JS_ITERATOR_HELPER_KIND_DROP = 3
    case JS_ITERATOR_HELPER_KIND_FLAT_MAP = 4
}

// MARK: - JSObjectHeaderFlags

/// Bit layout in JSObject header_flags, mirroring QuickJS.
let JS_OBJECT_CLASS_SHIFT: Int = 0
let JS_OBJECT_CLASS_MASK: Int = 0x3F
let JS_OBJECT_EXTENSIBLE_BIT: Int = 1 << 6
let JS_OBJECT_FREE_IN_GC_BIT: Int = 1 << 7
let JS_OBJECT_IS_EXOTIC_BIT: Int = 1 << 8
let JS_OBJECT_HAS_MAP_BIT: Int = 1 << 9
let JS_OBJECT_TMP_MARK_BIT: Int = 1 << 10
let JS_OBJECT_IS_UNCATCHABLE_ERROR_BIT: Int = 1 << 11

// MARK: - JSShapeFlags

/// Bit-field layout of JSShape flags.
let JS_SHAPE_HAS_SMALL_ARRAY_INDEX: Int = 1 << 0
let JS_SHAPE_HASH_RESIZE_THRESHOLD: Double = 0.7
let JS_SHAPE_INITIAL_HASH_LOG2_SIZE: Int = 4

// MARK: - JSArrayBufferFlags

let JS_ARRAY_BUFFER_DETACHED: Int = 1 << 0
let JS_ARRAY_BUFFER_SHARED: Int = 1 << 1

// MARK: - JSTypedArrayFlags

let JS_TYPED_ARRAY_BYTE_OFFSET_MASK: Int = 0x7FFFFFFF
let JS_TYPED_ARRAY_LENGTH_TRACKING: Int = 1 << 31

// MARK: - Helper Functions

/// Check if a class ID corresponds to a typed array.
func jsClassIsTypedArray(_ classID: Int) -> Bool {
    return classID >= JS_CLASS_TYPED_ARRAY_FIRST && classID <= JS_CLASS_TYPED_ARRAY_LAST
}

/// Check if a JSValueTag is a reference (heap-allocated) type.
func jsTagIsHeapAllocated(_ tag: JSValueTag) -> Bool {
    return tag.rawValue < 0
}

/// Size in bytes for each typed array element by class ID offset.
let JS_TYPED_ARRAY_ELEMENT_SIZES: [Int] = [
    1,  // Uint8ClampedArray
    1,  // Int8Array
    1,  // Uint8Array
    2,  // Int16Array
    2,  // Uint16Array
    4,  // Int32Array
    4,  // Uint32Array
    8,  // BigInt64Array
    8,  // BigUint64Array
    4,  // Float32Array
    8,  // Float64Array
]

/// Returns the byte size of a typed array element given the class ID.
func jsTypedArrayElementSize(_ classID: Int) -> Int {
    let index = classID - JS_CLASS_TYPED_ARRAY_FIRST
    guard index >= 0, index < JS_TYPED_ARRAY_ELEMENT_SIZES.count else { return 0 }
    return JS_TYPED_ARRAY_ELEMENT_SIZES[index]
}
