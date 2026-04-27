// JeffJSOpcodes.swift
// JeffJS - 1:1 Swift port of QuickJS JavaScript engine
//
// Port of ALL opcodes from QuickJS quickjs-opcode.h.
// Each opcode has: name, size (bytes), n_pop (stack items consumed),
// n_push (stack items produced), format.
//
// n_pop/n_push of -1 means variable (depends on runtime arguments).
// Size includes the opcode byte itself.

import Foundation

// MARK: - OpcodeFormat

/// Operand encoding format for each opcode, matching QuickJS OP_FMT_*.
enum OpcodeFormat: UInt8 {
    case none = 0          // no operand
    case none_int          // no operand, implicit int
    case none_loc          // no operand, implicit local
    case none_arg          // no operand, implicit arg
    case none_var_ref      // no operand, implicit var ref
    case u8                // unsigned 8-bit operand
    case i8                // signed 8-bit operand
    case loc8              // local index (8-bit)
    case const8            // constant pool index (8-bit)
    case label8            // relative label offset (8-bit)
    case u16               // unsigned 16-bit operand
    case i16               // signed 16-bit operand
    case label16           // relative label offset (16-bit)
    case npop              // n_pop encoded in operand
    case npopx             // extended n_pop
    case npop_u16          // n_pop + u16
    case loc               // local variable index (16-bit)
    case arg               // argument index (16-bit)
    case var_ref           // closure variable index (16-bit)
    case u32               // unsigned 32-bit operand
    case i32               // signed 32-bit operand
    case const_            // constant pool index (32-bit)
    case label             // relative label offset (32-bit)
    case atom              // atom operand (32-bit)
    case atom_u8           // atom + u8
    case atom_u16          // atom + u16
    case atom_label_u8     // atom + label + u8
    case atom_label_u16    // atom + label + u16
    case label_u16         // label + u16
}

// MARK: - OpcodeInfo

/// Metadata for a single bytecode instruction.
/// Used by the compiler, disassembler, and interpreter.
struct OpcodeInfo {
    let name: String       // human-readable opcode name
    let size: UInt8        // total instruction size in bytes (including opcode byte)
    let nPop: Int8         // stack items consumed (-1 = variable)
    let nPush: Int8        // stack items produced (-1 = variable)
    let format: OpcodeFormat
}

// MARK: - JeffJSOpcode

/// Every bytecode opcode in the JeffJS VM.
/// 1:1 port of QuickJS DEF/def() macros from quickjs-opcode.h.
///
/// Raw values are the opcode byte encoding. The enum ordering matches
/// QuickJS exactly so raw values are assigned automatically starting at 0.
///
/// Note: UInt16 raw type is used because temporary opcodes (enter_scope through
/// line_num) push the total count past 255. Only opcodes with rawValue < 256
/// appear in final bytecode; temporary opcodes are resolved during compilation.
enum JeffJSOpcode: UInt16, CaseIterable {

    // ---------------------------------------------------------------
    // Invalid opcode (trap for uninitialized bytecode)
    // ---------------------------------------------------------------
    case invalid = 0             // trap: should never be executed

    // ---------------------------------------------------------------
    // Push values
    // ---------------------------------------------------------------
    case push_i32                // push_i32(i32)
    case push_const              // push_const(u32) - from constant pool
    case fclosure                // fclosure(u32) - create closure from cpool
    case push_atom_value         // push_atom_value(atom)
    case private_symbol          // private_symbol(atom)
    case undefined               // push undefined
    case push_false              // push false
    case push_true               // push true
    case push_null               // push null
    case push_this               // push this
    case object                  // push empty object {}
    case special_object          // special_object(u8) - arguments, mapped_arguments, etc
    case rest                    // rest(u16) - create rest parameter array

    // ---------------------------------------------------------------
    // Stack manipulation
    // ---------------------------------------------------------------
    case drop                    // drop top of stack
    case nip                     // remove second-from-top
    case nip1                    // remove third-from-top
    case dup                     // duplicate top
    case dup1                    // duplicate top and second element
    case dup2                    // duplicate top 2
    case dup3                    // duplicate top 3
    case insert2                 // insert top value at position 2
    case insert3                 // insert top value at position 3
    case insert4                 // insert top value at position 4
    case perm3                   // rotate 3: a b c -> c a b
    case perm4                   // rotate 4
    case perm5                   // rotate 5
    case swap                    // swap top 2
    case swap2                   // swap top 2 pairs
    case rot3l                   // rotate 3 left:  a b c -> b c a
    case rot3r                   // rotate 3 right: a b c -> c a b (opposite of rot3l)
    case rot4l                   // rotate 4 left
    case rot5l                   // rotate 5 left

    // ---------------------------------------------------------------
    // Function calls
    // ---------------------------------------------------------------
    case call_constructor        // call_constructor(u16) - new F(args)
    case call                    // call(u16)
    case tail_call               // tail_call(u16)
    case call_method             // call_method(u16) - obj.f(args)
    case tail_call_method        // tail_call_method(u16)
    case array_from              // array_from(u16) - Array.from with n items
    case apply                   // apply(u16) - Function.prototype.apply
    case apply_constructor       // apply_constructor(u16) - new F(...args)
    case return_                 // return value on top of stack
    case return_undef            // return undefined
    case check_ctor_return       // check constructor return value
    case check_ctor              // check that function is called as constructor
    case init_ctor               // initialize constructor
    case check_brand             // check private brand
    case add_brand               // add private brand to object
    case return_async            // return from async function
    case throw_                  // throw exception
    case throw_error             // throw_error(atom, u8) - throw built-in error
    case eval                    // eval(u16, u16)
    case apply_eval              // apply_eval(u16)
    case regexp                  // create RegExp from pattern+flags on stack
    case get_super               // get super constructor reference
    case import_                 // import(u8)

    // ---------------------------------------------------------------
    // Global/scoped variable access
    // ---------------------------------------------------------------
    case check_var               // check_var(atom)
    case get_var_undef            // get_var_undef(atom) - returns undefined if missing
    case get_var                  // get_var(atom) - throws ReferenceError if missing
    case put_var                  // put_var(atom)
    case put_var_init             // put_var_init(atom) - initialize let/const/with binding
    case put_var_strict           // put_var_strict(atom) - strict mode assignment

    // ---------------------------------------------------------------
    // Reference value operations
    // ---------------------------------------------------------------
    case get_ref_value           // get reference value
    case put_ref_value           // put reference value

    // ---------------------------------------------------------------
    // Variable definitions
    // ---------------------------------------------------------------
    case define_var              // define_var(atom, u8)
    case check_define_var        // check_define_var(atom, u8)
    case define_func             // define_func(atom, u8)

    // ---------------------------------------------------------------
    // Property access
    // ---------------------------------------------------------------
    case get_field               // get_field(atom) - obj.prop
    case get_field2              // get_field2(atom) - obj.prop, keep obj on stack
    case put_field               // put_field(atom) - obj.prop = val
    case get_private_field       // get private field
    case put_private_field       // put private field
    case define_private_field    // define private field

    // ---------------------------------------------------------------
    // Array element access
    // ---------------------------------------------------------------
    case get_array_el            // obj[key]
    case get_array_el2           // obj[key], keep obj on stack
    case put_array_el            // obj[key] = val

    // ---------------------------------------------------------------
    // Super property access
    // ---------------------------------------------------------------
    case get_super_value         // super[key]
    case put_super_value         // super[key] = val

    // ---------------------------------------------------------------
    // Object/class definition helpers
    // ---------------------------------------------------------------
    case define_field            // define_field(atom)
    case set_name                // set_name(atom) - set function name
    case set_name_computed       // set function name from computed key
    case set_proto               // set __proto__
    case set_home_object         // set home object for super
    case define_array_el         // define array element (numeric)
    case append                  // append to array (spread)
    case copy_data_properties    // copy data properties (Object.assign semantics)
    case define_method           // define_method(atom, u8)
    case define_method_computed  // define method with computed key
    case define_class            // define_class(atom, u8)
    case define_class_computed   // define class with computed key

    // ---------------------------------------------------------------
    // Local variable access
    // ---------------------------------------------------------------
    case get_loc                 // get_loc(u16) - read local
    case put_loc                 // put_loc(u16) - write local
    case set_loc                 // set_loc(u16) - write local, keep value on stack

    // ---------------------------------------------------------------
    // Argument access
    // ---------------------------------------------------------------
    case get_arg                 // get_arg(u16)
    case put_arg                 // put_arg(u16)
    case set_arg                 // set_arg(u16)

    // ---------------------------------------------------------------
    // Closure variable access
    // ---------------------------------------------------------------
    case get_var_ref             // get_var_ref(u16)
    case put_var_ref             // put_var_ref(u16)
    case set_var_ref             // set_var_ref(u16)

    // ---------------------------------------------------------------
    // TDZ (Temporal Dead Zone) operations
    // ---------------------------------------------------------------
    case set_loc_uninitialized   // set_loc_uninitialized(u16) - mark local as TDZ
    case get_loc_check           // get_loc_check(u16) - get with TDZ check
    case put_loc_check           // put_loc_check(u16) - put with TDZ check
    case put_loc_check_init      // put_loc_check_init(u16) - init let/const
    case get_loc_checkthis       // get_loc_checkthis(u16) - get this with TDZ check
    case get_var_ref_check       // get_var_ref_check(u16)
    case put_var_ref_check       // put_var_ref_check(u16)
    case put_var_ref_check_init  // put_var_ref_check_init(u16)

    // ---------------------------------------------------------------
    // Closure operations
    // ---------------------------------------------------------------
    case close_loc               // close_loc(u16) - detach closure variable from stack

    // ---------------------------------------------------------------
    // Control flow
    // ---------------------------------------------------------------
    case if_false                // if_false(label) - conditional branch
    case if_true                 // if_true(label)
    case goto_                   // goto(label) - unconditional jump
    case catch_                  // catch(label) - push catch handler
    case gosub                   // gosub(label) - call finally block
    case ret                     // ret - return from gosub (finally)
    case nip_catch               // remove catch handler from stack

    // ---------------------------------------------------------------
    // Type conversions
    // ---------------------------------------------------------------
    case to_object               // ToObject()
    case to_propkey              // ToPropertyKey()
    case to_propkey2             // ToPropertyKey() keeping original value

    // ---------------------------------------------------------------
    // with statement variable access
    // ---------------------------------------------------------------
    case with_get_var            // with_get_var(atom, label, u8)
    case with_put_var            // with_put_var(atom, label, u8)
    case with_delete_var         // with_delete_var(atom, label, u8)
    case with_make_ref           // with_make_ref(atom, label, u8)
    case with_get_ref            // with_get_ref(atom, label, u8)
    case with_get_ref_undef      // with_get_ref_undef(atom, label, u8)

    // ---------------------------------------------------------------
    // Reference construction
    // ---------------------------------------------------------------
    case make_loc_ref            // make_loc_ref(atom, u16)
    case make_arg_ref            // make_arg_ref(atom, u16)
    case make_var_ref_ref        // make_var_ref_ref(atom, u16)
    case make_var_ref            // make_var_ref(atom)

    // ---------------------------------------------------------------
    // Iteration
    // ---------------------------------------------------------------
    case for_in_start            // for...in: push iterator state
    case for_of_start            // for...of: push iterator state
    case for_await_of_start      // for await...of: push iterator state
    case for_in_next             // for...in: get next key
    case for_of_next             // for_of_next(u8): get next value
    case for_await_of_next       // for await...of: async iteration next
    case iterator_check_object   // check iterator result is object
    case iterator_get_value_done // get {value, done} from iterator result
    case iterator_close          // close iterator (normal completion)
    case iterator_close_return   // close iterator (return completion)
    case iterator_next           // call iterator.next()
    case iterator_call           // iterator_call(u8) - call iterator method

    // ---------------------------------------------------------------
    // Generators / async
    // ---------------------------------------------------------------
    case initial_yield           // initial yield in generator
    case yield_                  // yield expression
    case yield_star              // yield* expression
    case async_yield_star        // async yield* expression
    case await_                  // await expression

    // ---------------------------------------------------------------
    // Unary operators
    // ---------------------------------------------------------------
    case neg                     // unary minus (-)
    case plus                    // unary plus (+)
    case dec                     // prefix decrement (--)
    case inc                     // prefix increment (++)
    case post_dec                // postfix decrement
    case post_inc                // postfix increment
    case inc_loc                 // inc_loc(u8) - increment local variable in-place
    case dec_loc                 // dec_loc(u8) - decrement local variable in-place
    case not                     // bitwise NOT (~)
    case lnot                    // logical NOT (!)
    case typeof_                 // typeof
    case delete_                 // delete
    case delete_var              // delete_var(atom) - delete global variable

    // ---------------------------------------------------------------
    // Binary operators
    // ---------------------------------------------------------------
    case mul                     // *
    case div                     // /
    case mod                     // %
    case add                     // +
    case sub                     // -
    case pow                     // **
    case shl                     // <<
    case sar                     // >> (arithmetic)
    case shr                     // >>> (logical)

    // ---------------------------------------------------------------
    // Comparison operators
    // ---------------------------------------------------------------
    case lt                      // <
    case lte                     // <=
    case gt                      // >
    case gte                     // >=
    case instanceof_             // instanceof
    case in_                     // in

    // ---------------------------------------------------------------
    // Equality operators
    // ---------------------------------------------------------------
    case eq                      // ==
    case neq                     // !=
    case strict_eq               // ===
    case strict_neq              // !==

    // ---------------------------------------------------------------
    // Bitwise operators
    // ---------------------------------------------------------------
    case and                     // &
    case xor                     // ^
    case or                      // |

    // ---------------------------------------------------------------
    // Optimization predicates
    // ---------------------------------------------------------------
    case is_undefined            // value === undefined
    case is_null                 // value === null (for internal use, not ===)
    case typeof_is_undefined     // typeof x === "undefined"
    case typeof_is_function      // typeof x === "function"

    // ---------------------------------------------------------------
    // Short opcodes (JEFFJS_SHORT_OPCODES)
    //
    // These are compact encodings for common operations.
    // They reduce bytecode size and improve dispatch speed.
    // ---------------------------------------------------------------
    case push_0                  // push 0
    case push_1                  // push 1
    case push_2                  // push 2
    case push_3                  // push 3
    case push_4                  // push 4
    case push_5                  // push 5
    case push_6                  // push 6
    case push_7                  // push 7
    case push_minus1             // push -1
    case push_i8                 // push_i8(i8) - small integer literal
    case push_i16                // push_i16(i16) - medium integer literal
    case push_const8             // push_const8(u8) - small constant pool index
    case fclosure8               // fclosure8(u8) - small closure index
    case push_empty_string       // push ""

    // Short local variable access
    case get_loc8                // get_loc8(u8) - 8-bit local index
    case put_loc8                // put_loc8(u8)
    case set_loc8                // set_loc8(u8)
    case get_loc0                // get local 0
    case get_loc1                // get local 1
    case get_loc2                // get local 2
    case get_loc3                // get local 3
    case put_loc0                // put local 0
    case put_loc1                // put local 1
    case put_loc2                // put local 2
    case put_loc3                // put local 3
    case set_loc0                // set local 0
    case set_loc1                // set local 1
    case set_loc2                // set local 2
    case set_loc3                // set local 3

    // Short argument access
    case get_arg0                // get argument 0
    case get_arg1                // get argument 1
    case get_arg2                // get argument 2
    case get_arg3                // get argument 3
    case put_arg0                // put argument 0
    case put_arg1                // put argument 1
    case put_arg2                // put argument 2
    case put_arg3                // put argument 3
    case set_arg0                // set argument 0
    case set_arg1                // set argument 1
    case set_arg2                // set argument 2
    case set_arg3                // set argument 3

    // Short closure variable access
    case get_var_ref0            // get closure var 0
    case get_var_ref1            // get closure var 1
    case get_var_ref2            // get closure var 2
    case get_var_ref3            // get closure var 3
    case put_var_ref0            // put closure var 0
    case put_var_ref1            // put closure var 1
    case put_var_ref2            // put closure var 2
    case put_var_ref3            // put closure var 3
    case set_var_ref0            // set closure var 0
    case set_var_ref1            // set closure var 1
    case set_var_ref2            // set closure var 2
    case set_var_ref3            // set closure var 3

    // Short miscellaneous
    case get_length              // get .length property (optimization)
    case if_false8               // if_false8(i8) - short conditional branch
    case if_true8                // if_true8(i8) - short conditional branch
    case goto8                   // goto8(i8) - short unconditional jump
    case goto16                  // goto16(i16) - medium unconditional jump
    case call0                   // call with 0 arguments
    case call1                   // call with 1 argument
    case call2                   // call with 2 arguments
    case call3                   // call with 3 arguments
    case is_undefined_or_null    // value === null || value === undefined
    case nop                     // no operation
    case add_loc                 // add_loc(u8, i32) - add constant to local

    // ---------------------------------------------------------------
    // Superinstructions (fused opcodes to reduce dispatch overhead)
    // rawValues 248-255: fit in 1 byte, appear in final bytecode
    // ---------------------------------------------------------------
    case get_loc8_get_field      // get_loc8(idx) + get_field(atom): loc8(1) + atom(4) = 6 bytes
    case get_arg0_get_field      // get_arg(0) + get_field(atom): atom(4) = 5 bytes
    case get_loc8_add            // get_loc8(idx) + add: loc8(1) = 2 bytes
    case put_loc8_return         // put_loc8(idx) + return: loc8(1) = 2 bytes
    case push_i32_put_loc8       // push_i32(val) + put_loc8(idx): i32(4) + loc8(1) = 6 bytes
    case get_loc8_get_loc8       // get_loc8(a) + get_loc8(b): loc8(1) + loc8(1) = 3 bytes
    case get_loc8_call           // get_loc8(idx) + call(argc): loc8(1) + u16(2) = 4 bytes
    case dup_put_loc8            // dup + put_loc8(idx): loc8(1) = 2 bytes

    // ---------------------------------------------------------------
    // Temporary opcodes (used during compilation, resolved before final bytecode)
    // ---------------------------------------------------------------
    case enter_scope             // enter lexical scope (u16)
    case leave_scope             // leave lexical scope (u16)
    case label_                  // label definition (u32)
    case scope_get_var           // scope_get_var(atom, u16)
    case scope_put_var           // scope_put_var(atom, u16)
    case scope_delete_var        // scope_delete_var(atom, u16)
    case scope_make_ref          // scope_make_ref(atom, label, u16)
    case scope_get_ref           // scope_get_ref(atom, u16)
    case scope_put_var_init      // scope_put_var_init(atom, u16)
    case scope_get_private_field // scope_get_private_field(atom, u16)
    case scope_put_private_field // scope_put_private_field(atom, u16)
    case scope_in_private_field  // scope_in_private_field(atom, u16)
    case get_field_opt_chain     // optional chaining get field (atom)
    case get_array_el_opt_chain  // optional chaining get element
    case line_num                // line_num(u32 line, u32 col) - source map info
}

// MARK: - Opcode Info Table

/// Complete metadata for every JeffJS bytecode opcode.
///
/// Columns: name, size, nPop, nPush, format
///
/// Size = total instruction bytes (opcode byte + operand bytes).
/// nPop/nPush = -1 means variable (depends on operand or runtime state).
///
/// This table is indexed by JeffJSOpcode.rawValue. The order must match
/// the enum case order exactly.
let jeffJSOpcodeInfo: [OpcodeInfo] = [

    // ---------------------------------------------------------------
    // Invalid opcode (trap for uninitialized bytecode)
    // ---------------------------------------------------------------

    OpcodeInfo(name: "invalid",          size: 1, nPop: 0,  nPush: 0,  format: .none),

    // ---------------------------------------------------------------
    // Push values
    // ---------------------------------------------------------------

    // push_i32: pushes a 32-bit signed integer
    // size=5: 1 opcode + 4 bytes i32
    OpcodeInfo(name: "push_i32",         size: 5, nPop: 0,  nPush: 1,  format: .i32),

    // push_const: pushes value from constant pool
    // size=5: 1 opcode + 4 bytes u32 index
    OpcodeInfo(name: "push_const",       size: 5, nPop: 0,  nPush: 1,  format: .const_),

    // fclosure: create function closure from constant pool
    // size=5: 1 opcode + 4 bytes u32 index
    OpcodeInfo(name: "fclosure",         size: 5, nPop: 0,  nPush: 1,  format: .const_),

    // push_atom_value: push an atom as a string value
    // size=5: 1 opcode + 4 bytes atom
    OpcodeInfo(name: "push_atom_value",  size: 5, nPop: 0,  nPush: 1,  format: .atom),

    // private_symbol: push a private symbol from atom
    // size=5: 1 opcode + 4 bytes atom
    OpcodeInfo(name: "private_symbol",   size: 5, nPop: 0,  nPush: 1,  format: .atom),

    // undefined: push undefined
    OpcodeInfo(name: "undefined",        size: 1, nPop: 0,  nPush: 1,  format: .none),

    // push_false: push false
    OpcodeInfo(name: "push_false",       size: 1, nPop: 0,  nPush: 1,  format: .none),

    // push_true: push true
    OpcodeInfo(name: "push_true",        size: 1, nPop: 0,  nPush: 1,  format: .none),

    // push_null: push null
    OpcodeInfo(name: "push_null",        size: 1, nPop: 0,  nPush: 1,  format: .none),

    // push_this: push this
    OpcodeInfo(name: "push_this",        size: 1, nPop: 0,  nPush: 1,  format: .none),

    // object: push empty object
    OpcodeInfo(name: "object",           size: 1, nPop: 0,  nPush: 1,  format: .none),

    // special_object: push special object (arguments, etc)
    // size=2: 1 opcode + 1 byte u8
    OpcodeInfo(name: "special_object",   size: 2, nPop: 0,  nPush: 1,  format: .u8),

    // rest: create rest parameter array
    // size=3: 1 opcode + 2 bytes u16
    OpcodeInfo(name: "rest",             size: 3, nPop: 0,  nPush: 1,  format: .u16),

    // ---------------------------------------------------------------
    // Stack manipulation
    // ---------------------------------------------------------------

    OpcodeInfo(name: "drop",             size: 1, nPop: 1,  nPush: 0,  format: .none),
    OpcodeInfo(name: "nip",              size: 1, nPop: 1,  nPush: 0,  format: .none),
    OpcodeInfo(name: "nip1",             size: 1, nPop: 1,  nPush: 0,  format: .none),
    OpcodeInfo(name: "dup",              size: 1, nPop: 1,  nPush: 2,  format: .none),
    OpcodeInfo(name: "dup1",             size: 1, nPop: 2,  nPush: 3,  format: .none),
    OpcodeInfo(name: "dup2",             size: 1, nPop: 2,  nPush: 4,  format: .none),
    OpcodeInfo(name: "dup3",             size: 1, nPop: 3,  nPush: 6,  format: .none),
    OpcodeInfo(name: "insert2",          size: 1, nPop: 2,  nPush: 3,  format: .none),
    OpcodeInfo(name: "insert3",          size: 1, nPop: 3,  nPush: 4,  format: .none),
    OpcodeInfo(name: "insert4",          size: 1, nPop: 4,  nPush: 5,  format: .none),
    OpcodeInfo(name: "perm3",            size: 1, nPop: 3,  nPush: 3,  format: .none),
    OpcodeInfo(name: "perm4",            size: 1, nPop: 4,  nPush: 4,  format: .none),
    OpcodeInfo(name: "perm5",            size: 1, nPop: 5,  nPush: 5,  format: .none),
    OpcodeInfo(name: "swap",             size: 1, nPop: 2,  nPush: 2,  format: .none),
    OpcodeInfo(name: "swap2",            size: 1, nPop: 4,  nPush: 4,  format: .none),
    OpcodeInfo(name: "rot3l",            size: 1, nPop: 3,  nPush: 3,  format: .none),
    OpcodeInfo(name: "rot3r",            size: 1, nPop: 3,  nPush: 3,  format: .none),
    OpcodeInfo(name: "rot4l",            size: 1, nPop: 4,  nPush: 4,  format: .none),
    OpcodeInfo(name: "rot5l",            size: 1, nPop: 5,  nPush: 5,  format: .none),

    // ---------------------------------------------------------------
    // Function calls
    // ---------------------------------------------------------------

    // call_constructor: new F(arg0..argN)
    // size=3: 1 opcode + 2 bytes u16 (argc)
    // pops: func + new.target + argc args = -1 (variable)
    OpcodeInfo(name: "call_constructor", size: 3, nPop: -1, nPush: 1,  format: .npop),

    // call: F(arg0..argN)
    // size=3: 1 opcode + 2 bytes u16 (argc)
    OpcodeInfo(name: "call",             size: 3, nPop: -1, nPush: 1,  format: .npop),

    // tail_call: tail call F(arg0..argN)
    // size=3: 1 opcode + 2 bytes u16 (argc)
    OpcodeInfo(name: "tail_call",        size: 3, nPop: -1, nPush: 1,  format: .npop),

    // call_method: obj.f(arg0..argN)
    // size=3: 1 opcode + 2 bytes u16 (argc)
    OpcodeInfo(name: "call_method",      size: 3, nPop: -1, nPush: 1,  format: .npop),

    // tail_call_method
    // size=3: 1 opcode + 2 bytes u16 (argc)
    OpcodeInfo(name: "tail_call_method", size: 3, nPop: -1, nPush: 1,  format: .npop),

    // array_from: create array from N stack items
    // size=3: 1 opcode + 2 bytes u16 (count)
    OpcodeInfo(name: "array_from",       size: 3, nPop: -1, nPush: 1,  format: .npop),

    // apply: Function.prototype.apply
    // size=3: 1 opcode + 2 bytes u16
    OpcodeInfo(name: "apply",            size: 3, nPop: -1, nPush: 1,  format: .npop),

    // apply_constructor: new F(...args)
    // size=3: 1 opcode + 2 bytes u16
    OpcodeInfo(name: "apply_constructor",size: 3, nPop: -1, nPush: 1,  format: .npop),

    // return: return TOS
    OpcodeInfo(name: "return",           size: 1, nPop: 1,  nPush: 0,  format: .none),

    // return_undef: return undefined
    OpcodeInfo(name: "return_undef",     size: 1, nPop: 0,  nPush: 0,  format: .none),

    // check_ctor_return: verify constructor return
    OpcodeInfo(name: "check_ctor_return",size: 1, nPop: 1,  nPush: 2,  format: .none),

    // check_ctor: verify called as constructor
    OpcodeInfo(name: "check_ctor",       size: 1, nPop: 0,  nPush: 0,  format: .none),

    // init_ctor: initialize constructor
    OpcodeInfo(name: "init_ctor",        size: 1, nPop: 0,  nPush: 1,  format: .none),

    // check_brand: check private brand
    OpcodeInfo(name: "check_brand",      size: 1, nPop: 2,  nPush: 2,  format: .none),

    // add_brand: add private brand
    OpcodeInfo(name: "add_brand",        size: 1, nPop: 2,  nPush: 0,  format: .none),

    // return_async: return from async function
    OpcodeInfo(name: "return_async",     size: 1, nPop: 1,  nPush: 0,  format: .none),

    // throw: throw TOS
    OpcodeInfo(name: "throw",            size: 1, nPop: 1,  nPush: 0,  format: .none),

    // throw_error: throw built-in error
    // size=6: 1 opcode + 4 bytes atom + 1 byte u8
    OpcodeInfo(name: "throw_error",      size: 6, nPop: 0,  nPush: 0,  format: .atom_u8),

    // eval: direct/indirect eval
    // size=5: 1 opcode + 2 bytes u16 + 2 bytes u16
    OpcodeInfo(name: "eval",             size: 5, nPop: -1, nPush: 1,  format: .npop_u16),

    // apply_eval
    // size=3: 1 opcode + 2 bytes u16
    OpcodeInfo(name: "apply_eval",       size: 3, nPop: -1, nPush: 1,  format: .npop),

    // regexp: create regex from pattern + flags on stack
    OpcodeInfo(name: "regexp",           size: 1, nPop: 2,  nPush: 1,  format: .none),

    // get_super: get super reference
    OpcodeInfo(name: "get_super",        size: 1, nPop: 1,  nPush: 1,  format: .none),

    // import
    OpcodeInfo(name: "import",           size: 2, nPop: 1,  nPush: 1,  format: .u8),

    // ---------------------------------------------------------------
    // Global/scoped variable access
    // ---------------------------------------------------------------

    // check_var: check if variable exists
    // size=5: 1 opcode + 4 bytes atom
    OpcodeInfo(name: "check_var",        size: 5, nPop: 0,  nPush: 1,  format: .atom),

    // get_var_undef: get variable, push undefined if not found
    OpcodeInfo(name: "get_var_undef",    size: 5, nPop: 0,  nPush: 1,  format: .atom),

    // get_var: get variable, throw ReferenceError if not found
    OpcodeInfo(name: "get_var",          size: 5, nPop: 0,  nPush: 1,  format: .atom),

    // put_var: set variable value
    OpcodeInfo(name: "put_var",          size: 5, nPop: 1,  nPush: 0,  format: .atom),

    // put_var_init: initialize let/const binding
    OpcodeInfo(name: "put_var_init",     size: 5, nPop: 1,  nPush: 0,  format: .atom),

    // put_var_strict: strict mode variable assignment
    OpcodeInfo(name: "put_var_strict",   size: 5, nPop: 2,  nPush: 0,  format: .atom),

    // get_ref_value
    OpcodeInfo(name: "get_ref_value",    size: 1, nPop: 2,  nPush: 3,  format: .none),

    // put_ref_value
    OpcodeInfo(name: "put_ref_value",    size: 1, nPop: 3,  nPush: 0,  format: .none),

    // ---------------------------------------------------------------
    // Variable definitions
    // ---------------------------------------------------------------

    // define_var: define variable
    // size=6: 1 opcode + 4 bytes atom + 1 byte u8 (flags)
    OpcodeInfo(name: "define_var",       size: 6, nPop: 0,  nPush: 0,  format: .atom_u8),

    // check_define_var
    OpcodeInfo(name: "check_define_var", size: 6, nPop: 0,  nPush: 0,  format: .atom_u8),

    // define_func: define function in scope
    OpcodeInfo(name: "define_func",      size: 6, nPop: 1,  nPush: 0,  format: .atom_u8),

    // ---------------------------------------------------------------
    // Property access
    // ---------------------------------------------------------------

    // get_field: obj.prop -> val (consumes obj)
    // size=5: 1 opcode + 4 bytes atom
    OpcodeInfo(name: "get_field",        size: 5, nPop: 1,  nPush: 1,  format: .atom),

    // get_field2: obj.prop -> obj val (keeps obj)
    OpcodeInfo(name: "get_field2",       size: 5, nPop: 1,  nPush: 2,  format: .atom),

    // put_field: obj val -> (obj.prop = val)
    OpcodeInfo(name: "put_field",        size: 5, nPop: 2,  nPush: 0,  format: .atom),

    // get_private_field: obj -> val
    OpcodeInfo(name: "get_private_field",size: 1, nPop: 2,  nPush: 1,  format: .none),

    // put_private_field: obj val -> ()
    OpcodeInfo(name: "put_private_field",size: 1, nPop: 3,  nPush: 0,  format: .none),

    // define_private_field: obj val -> ()
    OpcodeInfo(name: "define_private_field", size: 1, nPop: 3, nPush: 0, format: .none),

    // ---------------------------------------------------------------
    // Array element access
    // ---------------------------------------------------------------

    // get_array_el: obj key -> val
    OpcodeInfo(name: "get_array_el",     size: 1, nPop: 2,  nPush: 1,  format: .none),

    // get_array_el2: obj key -> obj val
    OpcodeInfo(name: "get_array_el2",    size: 1, nPop: 2,  nPush: 2,  format: .none),

    // put_array_el: obj key val -> ()
    OpcodeInfo(name: "put_array_el",     size: 1, nPop: 3,  nPush: 0,  format: .none),

    // ---------------------------------------------------------------
    // Super property access
    // ---------------------------------------------------------------

    // get_super_value: this obj key -> val
    OpcodeInfo(name: "get_super_value",  size: 1, nPop: 3,  nPush: 1,  format: .none),

    // put_super_value: this obj key val -> ()
    OpcodeInfo(name: "put_super_value",  size: 1, nPop: 4,  nPush: 0,  format: .none),

    // ---------------------------------------------------------------
    // Object/class definition helpers
    // ---------------------------------------------------------------

    // define_field: obj val -> obj
    OpcodeInfo(name: "define_field",     size: 5, nPop: 2,  nPush: 1,  format: .atom),

    // set_name: val -> val (sets .name property)
    OpcodeInfo(name: "set_name",         size: 5, nPop: 1,  nPush: 1,  format: .atom),

    // set_name_computed: val key -> val
    OpcodeInfo(name: "set_name_computed",size: 1, nPop: 2,  nPush: 1,  format: .none),

    // set_proto: obj proto -> obj
    OpcodeInfo(name: "set_proto",        size: 1, nPop: 2,  nPush: 1,  format: .none),

    // set_home_object: func obj -> func
    OpcodeInfo(name: "set_home_object",  size: 1, nPop: 2,  nPush: 2,  format: .none),

    // define_array_el: obj idx val -> obj (next_idx)
    OpcodeInfo(name: "define_array_el",  size: 1, nPop: 3,  nPush: 2,  format: .none),

    // append: obj val -> obj
    OpcodeInfo(name: "append",           size: 1, nPop: -1, nPush: 0,  format: .none),

    // copy_data_properties: target source excludeList -> target
    OpcodeInfo(name: "copy_data_properties", size: 2, nPop: -1, nPush: -1, format: .u8),

    // define_method: obj func -> obj
    // size=6: 1 opcode + 4 bytes atom + 1 byte u8 (flags)
    OpcodeInfo(name: "define_method",    size: 6, nPop: 2,  nPush: 1,  format: .atom_u8),

    // define_method_computed: obj key func -> obj
    OpcodeInfo(name: "define_method_computed", size: 2, nPop: 3, nPush: 1, format: .u8),

    // define_class: define class
    // size=6: 1 opcode + 4 bytes atom + 1 byte u8
    OpcodeInfo(name: "define_class",     size: 6, nPop: 2,  nPush: 2,  format: .atom_u8),

    // define_class_computed: define class with computed name
    OpcodeInfo(name: "define_class_computed", size: 2, nPop: 3, nPush: 3, format: .u8),

    // ---------------------------------------------------------------
    // Local variable access
    // ---------------------------------------------------------------

    // get_loc: get local variable
    // size=3: 1 opcode + 2 bytes u16
    OpcodeInfo(name: "get_loc",          size: 3, nPop: 0,  nPush: 1,  format: .loc),

    // put_loc: put local variable (consumes value)
    OpcodeInfo(name: "put_loc",          size: 3, nPop: 1,  nPush: 0,  format: .loc),

    // set_loc: set local variable (keeps value on stack)
    OpcodeInfo(name: "set_loc",          size: 3, nPop: 1,  nPush: 1,  format: .loc),

    // ---------------------------------------------------------------
    // Argument access
    // ---------------------------------------------------------------

    OpcodeInfo(name: "get_arg",          size: 3, nPop: 0,  nPush: 1,  format: .arg),
    OpcodeInfo(name: "put_arg",          size: 3, nPop: 1,  nPush: 0,  format: .arg),
    OpcodeInfo(name: "set_arg",          size: 3, nPop: 1,  nPush: 1,  format: .arg),

    // ---------------------------------------------------------------
    // Closure variable access
    // ---------------------------------------------------------------

    OpcodeInfo(name: "get_var_ref",      size: 3, nPop: 0,  nPush: 1,  format: .var_ref),
    OpcodeInfo(name: "put_var_ref",      size: 3, nPop: 1,  nPush: 0,  format: .var_ref),
    OpcodeInfo(name: "set_var_ref",      size: 3, nPop: 1,  nPush: 1,  format: .var_ref),

    // ---------------------------------------------------------------
    // TDZ operations
    // ---------------------------------------------------------------

    OpcodeInfo(name: "set_loc_uninitialized", size: 3, nPop: 0, nPush: 0, format: .loc),
    OpcodeInfo(name: "get_loc_check",    size: 3, nPop: 0,  nPush: 1,  format: .loc),
    OpcodeInfo(name: "put_loc_check",    size: 3, nPop: 1,  nPush: 0,  format: .loc),
    OpcodeInfo(name: "put_loc_check_init", size: 3, nPop: 1, nPush: 0, format: .loc),
    OpcodeInfo(name: "get_loc_checkthis",size: 3, nPop: 0,  nPush: 1,  format: .loc),
    OpcodeInfo(name: "get_var_ref_check",size: 3, nPop: 0,  nPush: 1,  format: .var_ref),
    OpcodeInfo(name: "put_var_ref_check",size: 3, nPop: 1,  nPush: 0,  format: .var_ref),
    OpcodeInfo(name: "put_var_ref_check_init", size: 3, nPop: 1, nPush: 0, format: .var_ref),

    // ---------------------------------------------------------------
    // Closure operations
    // ---------------------------------------------------------------

    // close_loc: detach closure variable from stack frame
    OpcodeInfo(name: "close_loc",        size: 3, nPop: 0,  nPush: 0,  format: .loc),

    // ---------------------------------------------------------------
    // Control flow
    // ---------------------------------------------------------------

    // if_false: conditional jump (branch if TOS is falsy)
    // size=5: 1 opcode + 4 bytes label
    OpcodeInfo(name: "if_false",         size: 5, nPop: 1,  nPush: 0,  format: .label),

    // if_true: conditional jump (branch if TOS is truthy)
    OpcodeInfo(name: "if_true",          size: 5, nPop: 1,  nPush: 0,  format: .label),

    // goto: unconditional jump
    OpcodeInfo(name: "goto",             size: 5, nPop: 0,  nPush: 0,  format: .label),

    // catch: push exception handler address onto stack
    OpcodeInfo(name: "catch",            size: 5, nPop: 0,  nPush: 1,  format: .label),

    // gosub: push return address then jump to finally block
    OpcodeInfo(name: "gosub",            size: 5, nPop: 0,  nPush: 1,  format: .label),

    // ret: return from gosub (pops return address)
    OpcodeInfo(name: "ret",              size: 1, nPop: 1,  nPush: 0,  format: .none),

    // nip_catch: remove catch handler from stack (net -1: pops 2, pushes 1)
    OpcodeInfo(name: "nip_catch",        size: 1, nPop: 2,  nPush: 1,  format: .none),

    // ---------------------------------------------------------------
    // Type conversions
    // ---------------------------------------------------------------

    OpcodeInfo(name: "to_object",        size: 1, nPop: 1,  nPush: 1,  format: .none),
    OpcodeInfo(name: "to_propkey",       size: 1, nPop: 1,  nPush: 1,  format: .none),
    OpcodeInfo(name: "to_propkey2",      size: 1, nPop: 2,  nPush: 2,  format: .none),

    // ---------------------------------------------------------------
    // with statement variable access
    // ---------------------------------------------------------------

    // with_get_var: get variable through with scope
    // size=10: 1 opcode + 4 bytes atom + 4 bytes label + 1 byte u8
    OpcodeInfo(name: "with_get_var",     size: 10, nPop: 1, nPush: 1,  format: .atom_label_u8),

    // with_put_var
    OpcodeInfo(name: "with_put_var",     size: 10, nPop: 2, nPush: 1,  format: .atom_label_u8),

    // with_delete_var
    OpcodeInfo(name: "with_delete_var",  size: 10, nPop: 1, nPush: 1,  format: .atom_label_u8),

    // with_make_ref
    OpcodeInfo(name: "with_make_ref",    size: 10, nPop: 1, nPush: 2,  format: .atom_label_u8),

    // with_get_ref
    OpcodeInfo(name: "with_get_ref",     size: 10, nPop: 1, nPush: 2,  format: .atom_label_u8),

    // with_get_ref_undef
    OpcodeInfo(name: "with_get_ref_undef", size: 10, nPop: 1, nPush: 2, format: .atom_label_u8),

    // ---------------------------------------------------------------
    // Reference construction
    // ---------------------------------------------------------------

    // make_loc_ref: create reference to local
    // size=7: 1 opcode + 4 bytes atom + 2 bytes u16
    OpcodeInfo(name: "make_loc_ref",     size: 7, nPop: 0,  nPush: 2,  format: .atom_u16),

    // make_arg_ref
    OpcodeInfo(name: "make_arg_ref",     size: 7, nPop: 0,  nPush: 2,  format: .atom_u16),

    // make_var_ref_ref
    OpcodeInfo(name: "make_var_ref_ref", size: 7, nPop: 0,  nPush: 2,  format: .atom_u16),

    // make_var_ref
    OpcodeInfo(name: "make_var_ref",     size: 5, nPop: 0,  nPush: 2,  format: .atom),

    // ---------------------------------------------------------------
    // Iteration
    // ---------------------------------------------------------------

    OpcodeInfo(name: "for_in_start",     size: 1, nPop: 1,  nPush: 1,  format: .none),
    OpcodeInfo(name: "for_of_start",     size: 1, nPop: 1,  nPush: 3,  format: .none),
    OpcodeInfo(name: "for_await_of_start", size: 1, nPop: 1, nPush: 3, format: .none),
    OpcodeInfo(name: "for_in_next",      size: 1, nPop: 1,  nPush: 3,  format: .none),

    // for_of_next: for...of next
    // size=2: 1 opcode + 1 byte u8
    OpcodeInfo(name: "for_of_next",      size: 2, nPop: 3,  nPush: 5,  format: .u8),

    // for_await_of_next: async iteration next
    OpcodeInfo(name: "for_await_of_next", size: 1, nPop: 3, nPush: 4,  format: .none),

    OpcodeInfo(name: "iterator_check_object", size: 1, nPop: 1, nPush: 1, format: .none),
    OpcodeInfo(name: "iterator_get_value_done", size: 1, nPop: 1, nPush: 2, format: .none),
    OpcodeInfo(name: "iterator_close",   size: 1, nPop: 3,  nPush: 0,  format: .none),
    OpcodeInfo(name: "iterator_close_return", size: 1, nPop: 4, nPush: 1, format: .none),
    OpcodeInfo(name: "iterator_next",    size: 1, nPop: 4,  nPush: 4,  format: .none),

    // iterator_call: call iterator method
    // size=2: 1 opcode + 1 byte u8
    OpcodeInfo(name: "iterator_call",    size: 2, nPop: 4,  nPush: 4,  format: .u8),

    // ---------------------------------------------------------------
    // Generators / async
    // ---------------------------------------------------------------

    OpcodeInfo(name: "initial_yield",    size: 1, nPop: 0,  nPush: 0,  format: .none),
    OpcodeInfo(name: "yield",            size: 1, nPop: 1,  nPush: 2,  format: .none),
    OpcodeInfo(name: "yield_star",       size: 1, nPop: 1,  nPush: 2,  format: .none),
    OpcodeInfo(name: "async_yield_star", size: 1, nPop: 1,  nPush: 2,  format: .none),
    OpcodeInfo(name: "await",            size: 1, nPop: 1,  nPush: 1,  format: .none),

    // ---------------------------------------------------------------
    // Unary operators
    // ---------------------------------------------------------------

    OpcodeInfo(name: "neg",              size: 1, nPop: 1,  nPush: 1,  format: .none),
    OpcodeInfo(name: "plus",             size: 1, nPop: 1,  nPush: 1,  format: .none),
    OpcodeInfo(name: "dec",              size: 1, nPop: 1,  nPush: 1,  format: .none),
    OpcodeInfo(name: "inc",              size: 1, nPop: 1,  nPush: 1,  format: .none),
    OpcodeInfo(name: "post_dec",         size: 1, nPop: 1,  nPush: 2,  format: .none),
    OpcodeInfo(name: "post_inc",         size: 1, nPop: 1,  nPush: 2,  format: .none),

    // inc_loc: increment local variable in place
    // size=2: 1 opcode + 1 byte u8 (local index)
    OpcodeInfo(name: "inc_loc",          size: 2, nPop: 0,  nPush: 0,  format: .loc8),

    // dec_loc: decrement local variable in place
    OpcodeInfo(name: "dec_loc",          size: 2, nPop: 0,  nPush: 0,  format: .loc8),

    OpcodeInfo(name: "not",              size: 1, nPop: 1,  nPush: 1,  format: .none),
    OpcodeInfo(name: "lnot",             size: 1, nPop: 1,  nPush: 1,  format: .none),
    OpcodeInfo(name: "typeof",           size: 1, nPop: 1,  nPush: 1,  format: .none),
    OpcodeInfo(name: "delete",           size: 1, nPop: 2,  nPush: 1,  format: .none),

    // delete_var: delete global variable
    // size=5: 1 opcode + 4 bytes atom
    OpcodeInfo(name: "delete_var",       size: 5, nPop: 0,  nPush: 1,  format: .atom),

    // ---------------------------------------------------------------
    // Binary operators
    // ---------------------------------------------------------------

    OpcodeInfo(name: "mul",              size: 1, nPop: 2,  nPush: 1,  format: .none),
    OpcodeInfo(name: "div",              size: 1, nPop: 2,  nPush: 1,  format: .none),
    OpcodeInfo(name: "mod",              size: 1, nPop: 2,  nPush: 1,  format: .none),
    OpcodeInfo(name: "add",              size: 1, nPop: 2,  nPush: 1,  format: .none),
    OpcodeInfo(name: "sub",              size: 1, nPop: 2,  nPush: 1,  format: .none),
    OpcodeInfo(name: "pow",              size: 1, nPop: 2,  nPush: 1,  format: .none),
    OpcodeInfo(name: "shl",              size: 1, nPop: 2,  nPush: 1,  format: .none),
    OpcodeInfo(name: "sar",              size: 1, nPop: 2,  nPush: 1,  format: .none),
    OpcodeInfo(name: "shr",              size: 1, nPop: 2,  nPush: 1,  format: .none),

    // ---------------------------------------------------------------
    // Comparison operators
    // ---------------------------------------------------------------

    OpcodeInfo(name: "lt",               size: 1, nPop: 2,  nPush: 1,  format: .none),
    OpcodeInfo(name: "lte",              size: 1, nPop: 2,  nPush: 1,  format: .none),
    OpcodeInfo(name: "gt",               size: 1, nPop: 2,  nPush: 1,  format: .none),
    OpcodeInfo(name: "gte",              size: 1, nPop: 2,  nPush: 1,  format: .none),
    OpcodeInfo(name: "instanceof",       size: 1, nPop: 2,  nPush: 1,  format: .none),
    OpcodeInfo(name: "in",               size: 1, nPop: 2,  nPush: 1,  format: .none),

    // ---------------------------------------------------------------
    // Equality operators
    // ---------------------------------------------------------------

    OpcodeInfo(name: "eq",               size: 1, nPop: 2,  nPush: 1,  format: .none),
    OpcodeInfo(name: "neq",              size: 1, nPop: 2,  nPush: 1,  format: .none),
    OpcodeInfo(name: "strict_eq",        size: 1, nPop: 2,  nPush: 1,  format: .none),
    OpcodeInfo(name: "strict_neq",       size: 1, nPop: 2,  nPush: 1,  format: .none),

    // ---------------------------------------------------------------
    // Bitwise operators
    // ---------------------------------------------------------------

    OpcodeInfo(name: "and",              size: 1, nPop: 2,  nPush: 1,  format: .none),
    OpcodeInfo(name: "xor",              size: 1, nPop: 2,  nPush: 1,  format: .none),
    OpcodeInfo(name: "or",               size: 1, nPop: 2,  nPush: 1,  format: .none),

    // ---------------------------------------------------------------
    // Optimization predicates
    // ---------------------------------------------------------------

    OpcodeInfo(name: "is_undefined",     size: 1, nPop: 1,  nPush: 1,  format: .none),
    OpcodeInfo(name: "is_null",          size: 1, nPop: 1,  nPush: 1,  format: .none),
    OpcodeInfo(name: "typeof_is_undefined", size: 1, nPop: 1, nPush: 1, format: .none),
    OpcodeInfo(name: "typeof_is_function",  size: 1, nPop: 1, nPush: 1, format: .none),

    // ---------------------------------------------------------------
    // Short opcodes
    // ---------------------------------------------------------------

    // Push constants (compact encoding)
    OpcodeInfo(name: "push_0",           size: 1, nPop: 0,  nPush: 1,  format: .none_int),
    OpcodeInfo(name: "push_1",           size: 1, nPop: 0,  nPush: 1,  format: .none_int),
    OpcodeInfo(name: "push_2",           size: 1, nPop: 0,  nPush: 1,  format: .none_int),
    OpcodeInfo(name: "push_3",           size: 1, nPop: 0,  nPush: 1,  format: .none_int),
    OpcodeInfo(name: "push_4",           size: 1, nPop: 0,  nPush: 1,  format: .none_int),
    OpcodeInfo(name: "push_5",           size: 1, nPop: 0,  nPush: 1,  format: .none_int),
    OpcodeInfo(name: "push_6",           size: 1, nPop: 0,  nPush: 1,  format: .none_int),
    OpcodeInfo(name: "push_7",           size: 1, nPop: 0,  nPush: 1,  format: .none_int),
    OpcodeInfo(name: "push_minus1",      size: 1, nPop: 0,  nPush: 1,  format: .none_int),

    // push_i8: small integer literal
    // size=2: 1 opcode + 1 byte i8
    OpcodeInfo(name: "push_i8",          size: 2, nPop: 0,  nPush: 1,  format: .i8),

    // push_i16: medium integer literal
    // size=3: 1 opcode + 2 bytes i16
    OpcodeInfo(name: "push_i16",         size: 3, nPop: 0,  nPush: 1,  format: .i16),

    // push_const8: small constant pool index
    // size=2: 1 opcode + 1 byte u8
    OpcodeInfo(name: "push_const8",      size: 2, nPop: 0,  nPush: 1,  format: .const8),

    // fclosure8: small closure index
    OpcodeInfo(name: "fclosure8",        size: 2, nPop: 0,  nPush: 1,  format: .const8),

    // push_empty_string: push ""
    OpcodeInfo(name: "push_empty_string",size: 1, nPop: 0,  nPush: 1,  format: .none),

    // Short local variable access (8-bit index)
    OpcodeInfo(name: "get_loc8",         size: 2, nPop: 0,  nPush: 1,  format: .loc8),
    OpcodeInfo(name: "put_loc8",         size: 2, nPop: 1,  nPush: 0,  format: .loc8),
    OpcodeInfo(name: "set_loc8",         size: 2, nPop: 1,  nPush: 1,  format: .loc8),

    // Short local variable access (implicit index 0-3)
    OpcodeInfo(name: "get_loc0",         size: 1, nPop: 0,  nPush: 1,  format: .none_loc),
    OpcodeInfo(name: "get_loc1",         size: 1, nPop: 0,  nPush: 1,  format: .none_loc),
    OpcodeInfo(name: "get_loc2",         size: 1, nPop: 0,  nPush: 1,  format: .none_loc),
    OpcodeInfo(name: "get_loc3",         size: 1, nPop: 0,  nPush: 1,  format: .none_loc),
    OpcodeInfo(name: "put_loc0",         size: 1, nPop: 1,  nPush: 0,  format: .none_loc),
    OpcodeInfo(name: "put_loc1",         size: 1, nPop: 1,  nPush: 0,  format: .none_loc),
    OpcodeInfo(name: "put_loc2",         size: 1, nPop: 1,  nPush: 0,  format: .none_loc),
    OpcodeInfo(name: "put_loc3",         size: 1, nPop: 1,  nPush: 0,  format: .none_loc),
    OpcodeInfo(name: "set_loc0",         size: 1, nPop: 1,  nPush: 1,  format: .none_loc),
    OpcodeInfo(name: "set_loc1",         size: 1, nPop: 1,  nPush: 1,  format: .none_loc),
    OpcodeInfo(name: "set_loc2",         size: 1, nPop: 1,  nPush: 1,  format: .none_loc),
    OpcodeInfo(name: "set_loc3",         size: 1, nPop: 1,  nPush: 1,  format: .none_loc),

    // Short argument access (implicit index 0-3)
    OpcodeInfo(name: "get_arg0",         size: 1, nPop: 0,  nPush: 1,  format: .none_arg),
    OpcodeInfo(name: "get_arg1",         size: 1, nPop: 0,  nPush: 1,  format: .none_arg),
    OpcodeInfo(name: "get_arg2",         size: 1, nPop: 0,  nPush: 1,  format: .none_arg),
    OpcodeInfo(name: "get_arg3",         size: 1, nPop: 0,  nPush: 1,  format: .none_arg),
    OpcodeInfo(name: "put_arg0",         size: 1, nPop: 1,  nPush: 0,  format: .none_arg),
    OpcodeInfo(name: "put_arg1",         size: 1, nPop: 1,  nPush: 0,  format: .none_arg),
    OpcodeInfo(name: "put_arg2",         size: 1, nPop: 1,  nPush: 0,  format: .none_arg),
    OpcodeInfo(name: "put_arg3",         size: 1, nPop: 1,  nPush: 0,  format: .none_arg),
    OpcodeInfo(name: "set_arg0",         size: 1, nPop: 1,  nPush: 1,  format: .none_arg),
    OpcodeInfo(name: "set_arg1",         size: 1, nPop: 1,  nPush: 1,  format: .none_arg),
    OpcodeInfo(name: "set_arg2",         size: 1, nPop: 1,  nPush: 1,  format: .none_arg),
    OpcodeInfo(name: "set_arg3",         size: 1, nPop: 1,  nPush: 1,  format: .none_arg),

    // Short closure variable access (implicit index 0-3)
    OpcodeInfo(name: "get_var_ref0",     size: 1, nPop: 0,  nPush: 1,  format: .none_var_ref),
    OpcodeInfo(name: "get_var_ref1",     size: 1, nPop: 0,  nPush: 1,  format: .none_var_ref),
    OpcodeInfo(name: "get_var_ref2",     size: 1, nPop: 0,  nPush: 1,  format: .none_var_ref),
    OpcodeInfo(name: "get_var_ref3",     size: 1, nPop: 0,  nPush: 1,  format: .none_var_ref),
    OpcodeInfo(name: "put_var_ref0",     size: 1, nPop: 1,  nPush: 0,  format: .none_var_ref),
    OpcodeInfo(name: "put_var_ref1",     size: 1, nPop: 1,  nPush: 0,  format: .none_var_ref),
    OpcodeInfo(name: "put_var_ref2",     size: 1, nPop: 1,  nPush: 0,  format: .none_var_ref),
    OpcodeInfo(name: "put_var_ref3",     size: 1, nPop: 1,  nPush: 0,  format: .none_var_ref),
    OpcodeInfo(name: "set_var_ref0",     size: 1, nPop: 1,  nPush: 1,  format: .none_var_ref),
    OpcodeInfo(name: "set_var_ref1",     size: 1, nPop: 1,  nPush: 1,  format: .none_var_ref),
    OpcodeInfo(name: "set_var_ref2",     size: 1, nPop: 1,  nPush: 1,  format: .none_var_ref),
    OpcodeInfo(name: "set_var_ref3",     size: 1, nPop: 1,  nPush: 1,  format: .none_var_ref),

    // Short miscellaneous
    OpcodeInfo(name: "get_length",       size: 1, nPop: 1,  nPush: 1,  format: .none),

    // if_false8: short conditional jump
    // size=2: 1 opcode + 1 byte i8
    OpcodeInfo(name: "if_false8",        size: 2, nPop: 1,  nPush: 0,  format: .label8),

    // if_true8: short conditional jump
    OpcodeInfo(name: "if_true8",         size: 2, nPop: 1,  nPush: 0,  format: .label8),

    // goto8: short unconditional jump
    OpcodeInfo(name: "goto8",            size: 2, nPop: 0,  nPush: 0,  format: .label8),

    // goto16: medium unconditional jump
    // size=3: 1 opcode + 2 bytes i16
    OpcodeInfo(name: "goto16",           size: 3, nPop: 0,  nPush: 0,  format: .label16),

    // Short calls (implicit argc)
    OpcodeInfo(name: "call0",            size: 1, nPop: 1,  nPush: 1,  format: .npopx),
    OpcodeInfo(name: "call1",            size: 1, nPop: 2,  nPush: 1,  format: .npopx),
    OpcodeInfo(name: "call2",            size: 1, nPop: 3,  nPush: 1,  format: .npopx),
    OpcodeInfo(name: "call3",            size: 1, nPop: 4,  nPush: 1,  format: .npopx),

    // is_undefined_or_null: nullish check
    OpcodeInfo(name: "is_undefined_or_null", size: 1, nPop: 1, nPush: 1, format: .none),

    // nop: no operation
    OpcodeInfo(name: "nop",              size: 1, nPop: 0,  nPush: 0,  format: .none),

    // add_loc: add constant to local variable
    // size=6: 1 opcode + 1 byte u8 (local index) + 4 bytes i32 (value)
    OpcodeInfo(name: "add_loc",          size: 6, nPop: 0,  nPush: 0,  format: .loc8),

    // ---------------------------------------------------------------
    // Superinstructions (fused opcodes, rawValues 248-255)
    // ---------------------------------------------------------------

    // get_loc8_get_field: get_loc8(idx) + get_field(atom)
    // size=6: 1 opcode + 1 byte loc8 + 4 bytes atom
    // Net effect: push property value (0 pop, 1 push)
    OpcodeInfo(name: "get_loc8_get_field", size: 6, nPop: 0, nPush: 1, format: .loc8),

    // get_arg0_get_field: get_arg(0) + get_field(atom)
    // size=5: 1 opcode + 4 bytes atom
    // Net effect: push property value (0 pop, 1 push)
    OpcodeInfo(name: "get_arg0_get_field", size: 5, nPop: 0, nPush: 1, format: .atom),

    // get_loc8_add: get_loc8(idx) + add
    // size=2: 1 opcode + 1 byte loc8
    // Net effect: pops 1 (rhs from stack), pushes 1 (result)
    OpcodeInfo(name: "get_loc8_add",     size: 2, nPop: 1, nPush: 1, format: .loc8),

    // put_loc8_return: put_loc8(idx) + return
    // size=2: 1 opcode + 1 byte loc8
    // Net effect: pops 1 (value), pushes 0
    OpcodeInfo(name: "put_loc8_return",  size: 2, nPop: 1, nPush: 0, format: .loc8),

    // push_i32_put_loc8: push_i32(val) + put_loc8(idx)
    // size=6: 1 opcode + 4 bytes i32 + 1 byte loc8
    // Net effect: 0 pop, 0 push (pushes then immediately stores)
    OpcodeInfo(name: "push_i32_put_loc8", size: 6, nPop: 0, nPush: 0, format: .loc8),

    // get_loc8_get_loc8: get_loc8(a) + get_loc8(b)
    // size=3: 1 opcode + 1 byte loc8(a) + 1 byte loc8(b)
    // Net effect: 0 pop, 2 push
    OpcodeInfo(name: "get_loc8_get_loc8", size: 3, nPop: 0, nPush: 2, format: .loc8),

    // get_loc8_call: get_loc8(idx) + call(argc)
    // size=4: 1 opcode + 1 byte loc8 + 2 bytes u16(argc)
    // Net effect: variable (pops argc args, pushes 1 result)
    OpcodeInfo(name: "get_loc8_call",    size: 4, nPop: -1, nPush: 1, format: .loc8),

    // dup_put_loc8: dup + put_loc8(idx)
    // size=2: 1 opcode + 1 byte loc8
    // Net effect: peek TOS, store copy to local (net: 0 extra pop, 0 extra push vs dup+put)
    // Combined: pops 0, pushes 0 on net (TOS stays, copy goes to local)
    OpcodeInfo(name: "dup_put_loc8",     size: 2, nPop: 0, nPush: 0, format: .loc8),

    // ---------------------------------------------------------------
    // Temporary opcodes (compilation only, not in final bytecode)
    // ---------------------------------------------------------------

    // enter_scope: enter lexical scope
    // size=3: 1 opcode + 2 bytes u16 (scope index)
    OpcodeInfo(name: "enter_scope",      size: 3, nPop: 0,  nPush: 0,  format: .u16),

    // leave_scope: leave lexical scope
    OpcodeInfo(name: "leave_scope",      size: 3, nPop: 0,  nPush: 0,  format: .u16),

    // label: label definition
    // size=5: 1 opcode + 4 bytes u32 (label id)
    OpcodeInfo(name: "label",            size: 5, nPop: 0,  nPush: 0,  format: .label),

    // scope_get_var: get variable in scope
    // size=7: 1 opcode + 4 bytes atom + 2 bytes u16 (scope)
    OpcodeInfo(name: "scope_get_var",    size: 7, nPop: 0,  nPush: 1,  format: .atom_u16),

    // scope_put_var: put variable in scope
    OpcodeInfo(name: "scope_put_var",    size: 7, nPop: 1,  nPush: 0,  format: .atom_u16),

    // scope_delete_var: delete variable in scope
    OpcodeInfo(name: "scope_delete_var", size: 7, nPop: 0,  nPush: 1,  format: .atom_u16),

    // scope_make_ref: make reference in scope
    // size=11: 1 opcode + 4 bytes atom + 4 bytes label + 2 bytes u16
    OpcodeInfo(name: "scope_make_ref",   size: 11, nPop: 0, nPush: 2,  format: .atom_label_u16),

    // scope_get_ref: get reference in scope
    // size=7: 1 opcode + 4 bytes atom + 2 bytes u16
    OpcodeInfo(name: "scope_get_ref",    size: 7, nPop: 0,  nPush: 2,  format: .atom_u16),

    // scope_put_var_init: initialize variable in scope
    OpcodeInfo(name: "scope_put_var_init", size: 7, nPop: 1, nPush: 0, format: .atom_u16),

    // scope_get_private_field
    OpcodeInfo(name: "scope_get_private_field", size: 7, nPop: 1, nPush: 1, format: .atom_u16),

    // scope_put_private_field
    OpcodeInfo(name: "scope_put_private_field", size: 7, nPop: 2, nPush: 0, format: .atom_u16),

    // scope_in_private_field
    OpcodeInfo(name: "scope_in_private_field", size: 7, nPop: 1, nPush: 1, format: .atom_u16),

    // get_field_opt_chain: optional chaining property access
    // size=5: 1 opcode + 4 bytes atom
    OpcodeInfo(name: "get_field_opt_chain", size: 5, nPop: 1, nPush: 1, format: .atom),

    // get_array_el_opt_chain: optional chaining element access
    OpcodeInfo(name: "get_array_el_opt_chain", size: 1, nPop: 2, nPush: 1, format: .none),

    // line_num: source line and column for debugging
    // size=9: 1 opcode + 4 bytes line (u32) + 4 bytes col (u32)
    OpcodeInfo(name: "line_num",         size: 9, nPop: 0,  nPush: 0,  format: .u32),
]

// MARK: - Opcode Lookup Helpers

/// Look up opcode info by raw opcode byte value.
/// Returns nil for out-of-range values.
@inline(__always)
func jeffJSGetOpcodeInfo(_ op: UInt8) -> OpcodeInfo? {
    guard Int(op) < jeffJSOpcodeInfo.count else { return nil }
    return jeffJSOpcodeInfo[Int(op)]
}

/// Look up opcode info by enum case.
@inline(__always)
func jeffJSGetOpcodeInfo(_ op: JeffJSOpcode) -> OpcodeInfo {
    return jeffJSOpcodeInfo[Int(op.rawValue)]
}

// MARK: - Opcode Classification Helpers

extension JeffJSOpcode {

    /// Human-readable opcode name for debug logging.
    var debugName: String { String(describing: self) }

    /// True if this opcode is a short (1-byte) opcode that encodes its operand implicitly.
    var isShortOpcode: Bool {
        return rawValue >= JeffJSOpcode.push_0.rawValue &&
               rawValue <= JeffJSOpcode.add_loc.rawValue
    }

    /// True if this opcode is a temporary compilation-only opcode.
    var isTemporaryOpcode: Bool {
        return rawValue >= JeffJSOpcode.enter_scope.rawValue &&
               rawValue <= JeffJSOpcode.line_num.rawValue
    }

    /// True if this opcode is a conditional or unconditional jump.
    var isJump: Bool {
        switch self {
        case .if_false, .if_true, .goto_, .catch_, .gosub,
             .if_false8, .if_true8, .goto8, .goto16:
            return true
        default:
            return false
        }
    }

    /// True if this opcode terminates a basic block (no fallthrough).
    var isTerminator: Bool {
        switch self {
        case .return_, .return_undef, .return_async, .throw_,
             .goto_, .goto8, .goto16, .ret, .tail_call, .tail_call_method,
             .put_loc8_return:
            return true
        default:
            return false
        }
    }

    /// True if this opcode reads a local variable.
    var readsLocal: Bool {
        switch self {
        case .get_loc, .set_loc, .get_loc_check, .get_loc_checkthis,
             .close_loc, .inc_loc, .dec_loc, .add_loc,
             .get_loc8, .set_loc8,
             .get_loc0, .get_loc1, .get_loc2, .get_loc3,
             .set_loc0, .set_loc1, .set_loc2, .set_loc3:
            return true
        default:
            return false
        }
    }

    /// True if this opcode writes a local variable.
    var writesLocal: Bool {
        switch self {
        case .put_loc, .set_loc, .put_loc_check, .put_loc_check_init,
             .set_loc_uninitialized, .inc_loc, .dec_loc, .add_loc,
             .put_loc8, .set_loc8,
             .put_loc0, .put_loc1, .put_loc2, .put_loc3,
             .set_loc0, .set_loc1, .set_loc2, .set_loc3:
            return true
        default:
            return false
        }
    }

    /// True if this opcode is a call instruction.
    var isCall: Bool {
        switch self {
        case .call, .call_constructor, .call_method,
             .tail_call, .tail_call_method,
             .call0, .call1, .call2, .call3,
             .eval, .apply, .apply_constructor, .apply_eval:
            return true
        default:
            return false
        }
    }

    /// True if this opcode accesses a global or scoped variable by atom name.
    var accessesGlobalVar: Bool {
        switch self {
        case .check_var, .get_var, .get_var_undef,
             .put_var, .put_var_init, .put_var_strict,
             .define_var, .check_define_var, .define_func, .delete_var:
            return true
        default:
            return false
        }
    }

    /// The size of this instruction in bytes.
    var instructionSize: UInt8 {
        return jeffJSOpcodeInfo[Int(rawValue)].size
    }

    /// The name of this opcode as a human-readable string.
    var opcodeName: String {
        return jeffJSOpcodeInfo[Int(rawValue)].name
    }
}

// MARK: - Special Object Types

/// Values for the special_object opcode's u8 operand.
/// Matches QuickJS OP_SPECIAL_OBJECT_* values.
enum SpecialObjectType: UInt8 {
    case arguments          = 0   // non-mapped arguments object
    case mappedArguments    = 1   // mapped arguments object
    case thisVal            = 2   // this value
    case newTarget          = 3   // new.target
    case homeObject         = 4   // home object for super
    case varObject          = 5   // variable environment object (with)
    case importMeta         = 6   // import.meta
}

// MARK: - Define Method Flags

/// Flags for the define_method and define_method_computed u8 operand.
/// Matches QuickJS JS_PROP_* method definition flags.
enum DefineMethodFlags: UInt8 {
    case method         = 0    // regular method
    case getter         = 1    // getter
    case setter         = 2    // setter
    case enumerable     = 4    // enumerable property
}

// MARK: - Define Class Flags

/// Flags for the define_class u8 operand.
enum DefineClassFlags: UInt8 {
    case hasHeritage    = 1    // class extends ...
}

// MARK: - Import Flags

/// Flags for the import opcode's u8 operand.
enum ImportFlags: UInt8 {
    case default_       = 0    // default import
    case star           = 1    // import * as ...
}

// MARK: - Throw Error Types

/// Error type encoding for the throw_error opcode's u8 operand.
/// Matches QuickJS JS_THROW_ERROR_* values.
enum ThrowErrorType: UInt8 {
    case deleteSuperProperty    = 0   // delete super.prop
    case setPropertyReadOnly    = 1   // assignment to const
    case varRedeclaration       = 2   // var redeclared in scope
    case invalidOrDestructuring = 3   // invalid destructuring target
    case notDefined             = 4   // variable not defined
    case constAssign            = 5   // assignment to const variable
}

// MARK: - Compile-time Assertions

/// Verify the opcode info table has exactly the right number of entries.
/// This runs at module initialization time.
private let _opcodeTableCheck: Void = {
    assert(jeffJSOpcodeInfo.count == JeffJSOpcode.allCases.count,
           "Opcode info table size (\(jeffJSOpcodeInfo.count)) does not match opcode count (\(JeffJSOpcode.allCases.count))")
}()
