// JeffJSAtom.swift
// JeffJS - 1:1 Swift port of QuickJS
//
// The atom table: a hash table of interned strings stored on the runtime.
// Atoms are 32-bit indices into the atom array. Predefined atoms are
// statically assigned at indices 1..JS_ATOM_END-1.
//
// From QuickJS:
//   - Atoms 0..JS_ATOM_END-1 are predefined (never freed)
//   - Atom 0 is reserved (JS_ATOM_NULL, used as "no atom")
//   - Tagged int atoms: if bit 31 is set, the lower 31 bits are a uint31 index
//   - Hash function: h = h * 263 + char
//
// NOTE: JS_ATOM_NULL, JS_ATOM_TAG_INT, JS_ATOM_MAX_INT are defined in
// JeffJSConstants.swift and are NOT redeclared here.

import Foundation

// MARK: - JSAtom type alias

/// A JSAtom is a 32-bit index into the runtime atom table.
/// Atom 0 (JS_ATOM_NULL) means "no atom" / invalid.
typealias JSAtom = UInt32

// MARK: - JSAtomType

/// Mirrors QuickJS JSAtomKindEnum.
/// Determines what kind of atom this is (for property key semantics).
enum JSAtomType: UInt8 {
    case string       = 0  // regular string atom
    case globalSymbol = 1  // Symbol.for("...") -- globally registered
    case symbol       = 2  // unique symbol (Symbol("..."))
    case privateKey   = 3  // private class field/method name
}

// MARK: - JSAtomEntry

/// One entry in the atom table. Mirrors QuickJS JSAtomStruct.
///
/// QuickJS layout:
/// ```c
/// typedef struct JSAtomStruct {
///     JSRefCountHeader header; /* must come first, 32-bit ref count */
///     uint8_t is_wide_char : 1;
///     uint8_t atom_type : 2;
///     uint32_t hash : 30;
///     uint32_t hash_next; /* index into atom_hash or free_list, 0 = end */
///     uint32_t len;
///     union { uint8_t str8[0]; uint16_t str16[0]; };
/// } JSAtomStruct;
/// ```
class JSAtomEntry {
    var refCount: Int32
    var isWideChar: Bool
    var atomType: JSAtomType
    var hash: UInt32
    var hashNext: UInt32   // next index in hash chain, 0 = end
    var value: String

    init(value: String, hash: UInt32, atomType: JSAtomType = .string) {
        self.refCount = 1
        self.isWideChar = false
        self.atomType = atomType
        self.hash = hash
        self.hashNext = 0
        self.value = value
    }
}

// MARK: - JSAtomTable

/// The atom table. Lives on JeffJSRuntime.
///
/// QuickJS stores atoms in a dynamic array (`atom_array`) indexed by atom id.
/// A separate hash table (`atom_hash`) maps hash values to atom ids for lookup.
/// Free slots form a linked list through `hash_next`.
class JSAtomTable {

    /// The atom array. Index 0 is unused (JS_ATOM_NULL).
    /// Indices 1..predefinedCount are the predefined atoms.
    var atoms: [JSAtomEntry?]

    /// Hash table: maps (hash % hashSize) -> first atom index in chain.
    /// Chain links through JSAtomEntry.hashNext. 0 = end of chain.
    var hashTable: [UInt32]

    /// Current size of the hash table (always a power of 2).
    var hashSize: Int

    /// Mask for hash table indexing (hashSize - 1).
    var hashMask: UInt32

    /// Head of free list (linked through JSAtomEntry.hashNext). 0 = empty.
    var freeListHead: UInt32

    /// Number of atoms currently in use (excluding free slots).
    var atomCount: Int

    /// Number of predefined atoms. These are never freed.
    let predefinedCount: Int

    // MARK: - Initialization

    init() {
        let predefined = JSPredefinedAtom.allAtomStrings
        let count = predefined.count
        self.predefinedCount = count

        // Allocate atom array: slot 0 is nil (JS_ATOM_NULL), then predefined atoms
        self.atoms = [JSAtomEntry?](repeating: nil, count: count + 1)

        // Hash table size: next power of 2 >= 2 * count
        var hs = 1
        while hs < count * 2 {
            hs <<= 1
        }
        self.hashSize = hs
        self.hashMask = UInt32(hs - 1)
        self.hashTable = [UInt32](repeating: 0, count: hs)
        self.freeListHead = 0
        self.atomCount = count

        // Insert all predefined atoms
        for i in 0..<count {
            let str = predefined[i]
            let h = JSAtomTable.hashString(str)
            let entry = JSAtomEntry(value: str, hash: h)
            entry.refCount = Int32.max / 2  // predefined atoms are immortal
            let atomIndex = UInt32(i + 1)

            // Insert into hash chain
            let bucket = Int(h & hashMask)
            entry.hashNext = hashTable[bucket]
            hashTable[bucket] = atomIndex

            atoms[Int(atomIndex)] = entry
        }
    }

    // MARK: - Hash Function

    /// QuickJS hash function: h = h * 263 + char
    /// Applied to each byte of the UTF-8 representation.
    ///
    /// From quickjs.c:
    /// ```c
    /// static uint32_t hash_string(const JSString *str, int h) {
    ///     if (str->is_wide_char) {
    ///         for (i = 0; i < len; i++) h = h * 263 + str->u.str16[i];
    ///     } else {
    ///         for (i = 0; i < len; i++) h = h * 263 + str->u.str8[i];
    ///     }
    ///     return h;
    /// }
    /// ```
    /// 4x unrolled polynomial hash using contiguous UTF-8 access (avoids per-byte iterator overhead).
    static func hashString(_ str: String) -> UInt32 {
        var h: UInt32 = 0
        var str = str
        str.withUTF8 { buf in
            let count = buf.count
            var i = 0
            let p1: UInt32 = 263
            let p2: UInt32 = p1 &* p1
            let p3: UInt32 = p2 &* p1
            let p4: UInt32 = p3 &* p1
            while i &+ 3 < count {
                h = h &* p4
                    &+ UInt32(buf[i])     &* p3
                    &+ UInt32(buf[i &+ 1]) &* p2
                    &+ UInt32(buf[i &+ 2]) &* p1
                    &+ UInt32(buf[i &+ 3])
                i &+= 4
            }
            while i < count {
                h = h &* 263 &+ UInt32(buf[i])
                i &+= 1
            }
        }
        return h
    }

    /// 4x unrolled seeded hash using contiguous UTF-8 access.
    static func hashStringSeeded(_ str: String, seed: UInt32) -> UInt32 {
        var h = seed
        var str = str
        str.withUTF8 { buf in
            let count = buf.count
            var i = 0
            let p1: UInt32 = 263
            let p2: UInt32 = p1 &* p1
            let p3: UInt32 = p2 &* p1
            let p4: UInt32 = p3 &* p1
            while i &+ 3 < count {
                h = h &* p4
                    &+ UInt32(buf[i])     &* p3
                    &+ UInt32(buf[i &+ 1]) &* p2
                    &+ UInt32(buf[i &+ 2]) &* p1
                    &+ UInt32(buf[i &+ 3])
                i &+= 4
            }
            while i < count {
                h = h &* 263 &+ UInt32(buf[i])
                i &+= 1
            }
        }
        return h
    }

    // MARK: - Lookup

    /// Find an existing atom for the given string. Returns JS_ATOM_NULL if not found.
    func findAtom(_ str: String) -> JSAtom {
        let h = JSAtomTable.hashString(str)
        let bucket = Int(h & hashMask)
        var idx = hashTable[bucket]
        while idx != 0 {
            if let entry = atoms[Int(idx)] {
                if entry.hash == h && entry.value == str && entry.atomType == .string {
                    return idx
                }
                idx = entry.hashNext
            } else {
                break
            }
        }
        return JS_ATOM_NULL
    }

    /// Find an existing atom by string and type. Returns JS_ATOM_NULL if not found.
    func findAtom(_ str: String, type: JSAtomType) -> JSAtom {
        let h = JSAtomTable.hashString(str)
        let bucket = Int(h & hashMask)
        var idx = hashTable[bucket]
        while idx != 0 {
            if let entry = atoms[Int(idx)] {
                if entry.hash == h && entry.value == str && entry.atomType == type {
                    return idx
                }
                idx = entry.hashNext
            } else {
                break
            }
        }
        return JS_ATOM_NULL
    }

    // MARK: - Insertion

    /// Intern a string: return an existing atom or create a new one.
    /// Increments ref count if the atom already exists.
    func newAtom(_ str: String) -> JSAtom {
        return newAtom(str, type: .string)
    }

    /// Intern a string with a given atom type.
    func newAtom(_ str: String, type: JSAtomType) -> JSAtom {
        // Check if it already exists
        let existing = findAtom(str, type: type)
        if existing != JS_ATOM_NULL {
            dupAtom(existing)
            return existing
        }

        // Allocate a new slot
        let h = JSAtomTable.hashString(str)
        let entry = JSAtomEntry(value: str, hash: h, atomType: type)
        let atomIndex: UInt32

        if freeListHead != 0 {
            // Reuse a slot from the free list
            atomIndex = freeListHead
            let freeEntry = atoms[Int(freeListHead)]
            freeListHead = freeEntry?.hashNext ?? 0
            atoms[Int(atomIndex)] = entry
        } else {
            // Append to the array
            atomIndex = UInt32(atoms.count)
            atoms.append(entry)
        }

        atomCount += 1

        // Rehash if load factor > 0.7
        if atomCount * 10 > hashSize * 7 {
            rehash()
        }

        // Insert into hash chain
        let bucket = Int(h & hashMask)
        entry.hashNext = hashTable[bucket]
        hashTable[bucket] = atomIndex

        return atomIndex
    }

    /// Rehash the hash table to a larger size.
    private func rehash() {
        let newSize = hashSize * 2
        hashSize = newSize
        hashMask = UInt32(newSize - 1)
        hashTable = [UInt32](repeating: 0, count: newSize)

        // Re-insert all atoms
        for i in 1..<atoms.count {
            if let entry = atoms[i] {
                let bucket = Int(entry.hash & hashMask)
                entry.hashNext = hashTable[bucket]
                hashTable[bucket] = UInt32(i)
            }
        }
    }

    // MARK: - Reference Counting

    /// Increment the reference count for an atom.
    @inline(__always)
    @discardableResult
    func dupAtom(_ atom: JSAtom) -> JSAtom {
        if atom != JS_ATOM_NULL && !atomIsTaggedInt(atom) {
            let idx = Int(atom)
            if idx < atoms.count, let entry = atoms[idx] {
                if entry.refCount < Int32.max / 2 {  // don't overflow immortal atoms
                    entry.refCount += 1
                }
            }
        }
        return atom
    }

    /// Decrement the reference count for an atom. If it reaches 0, free the slot.
    /// Predefined atoms (index <= predefinedCount) are never freed.
    func freeAtom(_ atom: JSAtom) {
        if atom == JS_ATOM_NULL || atomIsTaggedInt(atom) {
            return
        }
        let idx = Int(atom)
        if idx < atoms.count, let entry = atoms[idx] {
            // Predefined atoms are immortal
            if idx <= predefinedCount {
                return
            }
            entry.refCount -= 1
            if entry.refCount <= 0 {
                removeFromHashChain(atom)
                atoms[idx] = nil
                atomCount -= 1

                // Add to free list: reuse the slot with a sentinel entry
                let freeEntry = JSAtomEntry(value: "", hash: 0)
                freeEntry.hashNext = freeListHead
                freeEntry.refCount = 0
                atoms[idx] = freeEntry
                freeListHead = atom
            }
        }
    }

    /// Remove an atom from its hash chain.
    private func removeFromHashChain(_ atom: JSAtom) {
        guard let entry = atoms[Int(atom)] else { return }
        let bucket = Int(entry.hash & hashMask)
        var prevIdx: UInt32 = 0
        var curIdx = hashTable[bucket]
        while curIdx != 0 {
            if curIdx == atom {
                if prevIdx == 0 {
                    hashTable[bucket] = entry.hashNext
                } else if let prevEntry = atoms[Int(prevIdx)] {
                    prevEntry.hashNext = entry.hashNext
                }
                return
            }
            prevIdx = curIdx
            curIdx = atoms[Int(curIdx)]?.hashNext ?? 0
        }
    }

    // MARK: - Conversion

    /// Convert an atom to its string representation.
    func atomToString(_ atom: JSAtom) -> String {
        if atomIsTaggedInt(atom) {
            let n = atom & JS_ATOM_MAX_INT
            return String(n)
        }
        let idx = Int(atom)
        if idx > 0 && idx < atoms.count, let entry = atoms[idx] {
            return entry.value
        }
        return ""
    }

    /// Get the atom type.
    func atomGetType(_ atom: JSAtom) -> JSAtomType {
        if atomIsTaggedInt(atom) {
            return .string
        }
        let idx = Int(atom)
        if idx > 0 && idx < atoms.count, let entry = atoms[idx] {
            return entry.atomType
        }
        return .string
    }

    // MARK: - Tagged Integer Atoms

    /// Check if an atom is a tagged integer (bit 31 set).
    /// Tagged int atoms represent array indices directly without a table entry.
    @inline(__always)
    func atomIsTaggedInt(_ atom: JSAtom) -> Bool {
        return (atom & JS_ATOM_TAG_INT) != 0
    }

    /// Create a tagged-int atom from a UInt32 array index.
    /// The index must be < 2^31.
    @inline(__always)
    func atomFromUInt32(_ n: UInt32) -> JSAtom {
        return n | JS_ATOM_TAG_INT
    }

    /// Extract the UInt32 from a tagged-int atom.
    /// Returns nil if the atom is not a tagged int.
    @inline(__always)
    func atomToUInt32(_ atom: JSAtom) -> UInt32? {
        if atomIsTaggedInt(atom) {
            return atom & JS_ATOM_MAX_INT
        }
        return nil
    }

    /// Check if an atom is an array index (either tagged int or a numeric string
    /// in the range 0..2^32-2).
    func atomIsArrayIndex(_ atom: JSAtom) -> Bool {
        if atomIsTaggedInt(atom) {
            return true
        }
        let str = atomToString(atom)
        if str.isEmpty { return false }
        guard let val = UInt32(str) else { return false }
        return val <= 0xFFFFFFFE && String(val) == str
    }
}

// MARK: - Free-standing helper functions (match QuickJS API)

/// Check if an atom is a tagged integer (bit 31 set).
@inline(__always)
func js_atom_is_tagged_int(_ atom: JSAtom) -> Bool {
    return (atom & JS_ATOM_TAG_INT) != 0
}

/// Create a tagged-int atom from a UInt32.
@inline(__always)
func js_atom_from_uint32(_ n: UInt32) -> JSAtom {
    return n | JS_ATOM_TAG_INT
}

/// Extract the UInt32 from a tagged-int atom.
@inline(__always)
func js_atom_to_uint32(_ atom: JSAtom) -> UInt32 {
    return atom & JS_ATOM_MAX_INT
}

// MARK: - Predefined Atoms

/// All predefined atoms from quickjs-atom.h.
///
/// In QuickJS these are declared with DEF() macros that expand into an enum.
/// The enum values are 1-based indices into the atom table.
///
/// The ordering is critical: it must match exactly so that bytecode compiled
/// by QuickJS can be loaded directly.
///
/// Categories:
///   - Keywords and reserved words
///   - Well-known property names
///   - Well-known symbol names (Symbol.iterator, etc.)
///   - Internal names (prefixed with underscores)
///   - Built-in constructor/prototype names
enum JSPredefinedAtom: UInt32 {
    // -----------------------------------------------------------------------
    // MARK: Keywords and reserved words (must come first, order matters)
    // -----------------------------------------------------------------------
    case null_                  = 1    // "null"
    case false_                 = 2    // "false"
    case true_                  = 3    // "true"
    case if_                    = 4    // "if"
    case else_                  = 5    // "else"
    case return_                = 6    // "return"
    case var_                   = 7    // "var"
    case this_                  = 8    // "this"
    case delete_                = 9    // "delete"
    case void_                  = 10   // "void"
    case typeof_                = 11   // "typeof"
    case new_                   = 12   // "new"
    case in_                    = 13   // "in"
    case instanceof_            = 14   // "instanceof"
    case do_                    = 15   // "do"
    case while_                 = 16   // "while"
    case for_                   = 17   // "for"
    case break_                 = 18   // "break"
    case continue_              = 19   // "continue"
    case switch_                = 20   // "switch"
    case case_                  = 21   // "case"
    case default_               = 22   // "default"
    case throw_                 = 23   // "throw"
    case try_                   = 24   // "try"
    case catch_                 = 25   // "catch"
    case finally_               = 26   // "finally"
    case function_              = 27   // "function"
    case debugger_              = 28   // "debugger"
    case with_                  = 29   // "with"
    case class_                 = 30   // "class"
    case const_                 = 31   // "const"
    case enum_                  = 32   // "enum"
    case export_                = 33   // "export"
    case extends_               = 34   // "extends"
    case import_                = 35   // "import"
    case super_                 = 36   // "super"

    // Strict-mode reserved words
    case implements_            = 37   // "implements"
    case interface_             = 38   // "interface"
    case let_                   = 39   // "let"
    case package_               = 40   // "package"
    case private_               = 41   // "private"
    case protected_             = 42   // "protected"
    case public_                = 43   // "public"
    case static_                = 44   // "static"
    case yield_                 = 45   // "yield"
    case await_                 = 46   // "await"

    // -----------------------------------------------------------------------
    // MARK: Well-known property names
    // -----------------------------------------------------------------------
    case emptyString            = 47   // ""
    case length                 = 48   // "length"
    case fileName               = 49   // "fileName"
    case lineNumber             = 50   // "lineNumber"
    case columnNumber           = 51   // "columnNumber"
    case message                = 52   // "message"
    case name                   = 53   // "name"
    case errors                 = 54   // "errors"
    case stack                  = 55   // "stack"
    case cause                  = 56   // "cause"
    case toStringAtom           = 57   // "toString"
    case toLocaleString         = 58   // "toLocaleString"
    case valueOf                = 59   // "valueOf"
    case eval_                  = 60   // "eval"
    case prototype              = 61   // "prototype"
    case constructor_           = 62   // "constructor"
    case configurable           = 63   // "configurable"
    case writable               = 64   // "writable"
    case enumerable             = 65   // "enumerable"
    case value                  = 66   // "value"
    case get                    = 67   // "get"
    case set                    = 68   // "set"
    case of                     = 69   // "of"
    case __proto__              = 70   // "__proto__"
    case undefined_             = 71   // "undefined"
    case number                 = 72   // "number"
    case boolean                = 73   // "boolean"
    case string                 = 74   // "string"
    case object                 = 75   // "object"
    case symbol                 = 76   // "symbol"
    case bigint                 = 77   // "bigint"
    case integer                = 78   // "integer"
    case unknown                = 79   // "unknown"
    case arguments_             = 80   // "arguments"
    case callee                 = 81   // "callee"
    case caller                 = 82   // "caller"

    // Internal names (not visible to JS code)
    case _eval_                 = 83   // "<eval>"
    case _ret_                  = 84   // "<ret>"

    // -----------------------------------------------------------------------
    // MARK: Well-known symbols
    // -----------------------------------------------------------------------
    case Symbol_toPrimitive             = 85   // "Symbol.toPrimitive"
    case Symbol_iterator                = 86   // "Symbol.iterator"
    case Symbol_match                   = 87   // "Symbol.match"
    case Symbol_matchAll                = 88   // "Symbol.matchAll"
    case Symbol_replace                 = 89   // "Symbol.replace"
    case Symbol_search                  = 90   // "Symbol.search"
    case Symbol_split                   = 91   // "Symbol.split"
    case Symbol_toStringTag             = 92   // "Symbol.toStringTag"
    case Symbol_isConcatSpreadable      = 93   // "Symbol.isConcatSpreadable"
    case Symbol_hasInstance             = 94   // "Symbol.hasInstance"
    case Symbol_species                 = 95   // "Symbol.species"
    case Symbol_unscopables             = 96   // "Symbol.unscopables"
    case Symbol_asyncIterator           = 97   // "Symbol.asyncIterator"

    // -----------------------------------------------------------------------
    // MARK: Built-in property names (continued)
    // -----------------------------------------------------------------------
    case description                    = 98   // "description"
    case then                           = 99   // "then"
    case promise                        = 100  // "promise"
    case resolve                        = 101  // "resolve"
    case reject                         = 102  // "reject"
    case toJSON                         = 103  // "toJSON"
    case flags                          = 104  // "flags"
    case source                         = 105  // "source"
    case global_                        = 106  // "global"
    case unicode                        = 107  // "unicode"
    case raw                            = 108  // "raw"
    case next                           = 109  // "next"
    case done                           = 110  // "done"
    case apply                          = 111  // "apply"
    case call                           = 112  // "call"
    case bind                           = 113  // "bind"
    case hasOwnProperty                 = 114  // "hasOwnProperty"
    case isPrototypeOf                  = 115  // "isPrototypeOf"
    case propertyIsEnumerable           = 116  // "propertyIsEnumerable"
    case defineProperty                 = 117  // "defineProperty"
    case getOwnPropertyDescriptor       = 118  // "getOwnPropertyDescriptor"
    case isExtensible                   = 119  // "isExtensible"
    case preventExtensions              = 120  // "preventExtensions"
    case has                            = 121  // "has"
    case deleteProperty                 = 122  // "deleteProperty"
    case defineGetter                   = 123  // "__defineGetter__"
    case defineSetter                   = 124  // "__defineSetter__"
    case lookupGetter                   = 125  // "__lookupGetter__"
    case lookupSetter                   = 126  // "__lookupSetter__"
    case ownKeys                        = 127  // "ownKeys"
    case construct                      = 128  // "construct"
    case getPrototypeOf                 = 129  // "getPrototypeOf"
    case setPrototypeOf                 = 130  // "setPrototypeOf"
    case isArray                        = 131  // "isArray"
    case proxy                          = 132  // "proxy"
    case revocable                      = 133  // "revocable"
    case revoke                         = 134  // "revoke"
    case assign                         = 135  // "assign"
    case keys                           = 136  // "keys"
    case values                         = 137  // "values"
    case entries                        = 138  // "entries"
    case freeze                         = 139  // "freeze"
    case isFrozen                       = 140  // "isFrozen"
    case seal                           = 141  // "seal"
    case isSealed                       = 142  // "isSealed"
    case create                         = 143  // "create"
    case fromEntries                    = 144  // "fromEntries"
    case getOwnPropertyNames           = 145  // "getOwnPropertyNames"
    case getOwnPropertySymbols         = 146  // "getOwnPropertySymbols"
    case getOwnPropertyDescriptors     = 147  // "getOwnPropertyDescriptors"
    case is_                            = 148  // "is"
    case from                           = 149  // "from"
    case of_                            = 150  // "of" (Array.of)
    case concat                         = 151  // "concat"
    case copyWithin                     = 152  // "copyWithin"
    case every                          = 153  // "every"
    case fill                           = 154  // "fill"
    case filter                         = 155  // "filter"
    case find                           = 156  // "find"
    case findIndex                      = 157  // "findIndex"
    case flat                           = 158  // "flat"
    case flatMap                        = 159  // "flatMap"
    case forEach                        = 160  // "forEach"
    case includes                       = 161  // "includes"
    case indexOf                        = 162  // "indexOf"
    case join                           = 163  // "join"
    case lastIndexOf                    = 164  // "lastIndexOf"
    case map                            = 165  // "map"
    case pop                            = 166  // "pop"
    case push                           = 167  // "push"
    case reduce                         = 168  // "reduce"
    case reduceRight                    = 169  // "reduceRight"
    case reverse                        = 170  // "reverse"
    case shift                          = 171  // "shift"
    case slice                          = 172  // "slice"
    case some                           = 173  // "some"
    case sort                           = 174  // "sort"
    case splice                         = 175  // "splice"
    case unshift                        = 176  // "unshift"
    case at                             = 177  // "at"
    case findLast                       = 178  // "findLast"
    case findLastIndex                  = 179  // "findLastIndex"
    case toReversed                     = 180  // "toReversed"
    case toSorted                       = 181  // "toSorted"
    case toSpliced                      = 182  // "toSpliced"
    case arrayWith                      = 183  // "with" (Array.prototype.with)
    case group                          = 184  // "group"
    case groupToMap                     = 185  // "groupToMap"

    // -----------------------------------------------------------------------
    // MARK: String methods and properties
    // -----------------------------------------------------------------------
    case charAt                         = 186  // "charAt"
    case charCodeAt                     = 187  // "charCodeAt"
    case codePointAt                    = 188  // "codePointAt"
    case endsWith                       = 189  // "endsWith"
    case fromCharCode                   = 190  // "fromCharCode"
    case fromCodePoint                  = 191  // "fromCodePoint"
    case localeCompare                  = 192  // "localeCompare"
    case match_                         = 193  // "match"
    case matchAll_                      = 194  // "matchAll"
    case normalize                      = 195  // "normalize"
    case padEnd                         = 196  // "padEnd"
    case padStart                       = 197  // "padStart"
    case repeat_                        = 198  // "repeat"
    case replace_                       = 199  // "replace"
    case replaceAll                     = 200  // "replaceAll"
    case search_                        = 201  // "search"
    case split_                         = 202  // "split"
    case startsWith                     = 203  // "startsWith"
    case substring                      = 204  // "substring"
    case toLocaleLowerCase              = 205  // "toLocaleLowerCase"
    case toLocaleUpperCase              = 206  // "toLocaleUpperCase"
    case toLowerCase                    = 207  // "toLowerCase"
    case toUpperCase                    = 208  // "toUpperCase"
    case toWellFormed                   = 209  // "toWellFormed"
    case isWellFormed                   = 210  // "isWellFormed"
    case trim                           = 211  // "trim"
    case trimEnd                        = 212  // "trimEnd"
    case trimStart                      = 213  // "trimStart"

    // -----------------------------------------------------------------------
    // MARK: Number/Math related
    // -----------------------------------------------------------------------
    case toFixed                        = 214  // "toFixed"
    case toExponential                  = 215  // "toExponential"
    case toPrecision                    = 216  // "toPrecision"
    case isFinite                       = 217  // "isFinite"
    case isNaN                          = 218  // "isNaN"
    case isInteger                      = 219  // "isInteger"
    case isSafeInteger                  = 220  // "isSafeInteger"
    case parseFloat                     = 221  // "parseFloat"
    case parseInt                       = 222  // "parseInt"
    case EPSILON                        = 223  // "EPSILON"
    case MAX_SAFE_INTEGER               = 224  // "MAX_SAFE_INTEGER"
    case MIN_SAFE_INTEGER               = 225  // "MIN_SAFE_INTEGER"
    case MAX_VALUE                      = 226  // "MAX_VALUE"
    case MIN_VALUE                      = 227  // "MIN_VALUE"
    case NEGATIVE_INFINITY_             = 228  // "NEGATIVE_INFINITY"
    case POSITIVE_INFINITY_             = 229  // "POSITIVE_INFINITY"
    case NaN_                           = 230  // "NaN"
    case E                              = 231  // "E"
    case LN10                           = 232  // "LN10"
    case LN2                            = 233  // "LN2"
    case LOG10E                         = 234  // "LOG10E"
    case LOG2E                          = 235  // "LOG2E"
    case PI                             = 236  // "PI"
    case SQRT1_2                        = 237  // "SQRT1_2"
    case SQRT2                          = 238  // "SQRT2"
    case abs                            = 239  // "abs"
    case acos                           = 240  // "acos"
    case acosh                          = 241  // "acosh"
    case asin                           = 242  // "asin"
    case asinh                          = 243  // "asinh"
    case atan                           = 244  // "atan"
    case atan2                          = 245  // "atan2"
    case atanh                          = 246  // "atanh"
    case cbrt                           = 247  // "cbrt"
    case ceil                           = 248  // "ceil"
    case clz32                          = 249  // "clz32"
    case cos                            = 250  // "cos"
    case cosh                           = 251  // "cosh"
    case exp_                           = 252  // "exp"
    case expm1                          = 253  // "expm1"
    case floor                          = 254  // "floor"
    case fround                         = 255  // "fround"
    case hypot                          = 256  // "hypot"
    case imul                           = 257  // "imul"
    case log                            = 258  // "log"
    case log10                          = 259  // "log10"
    case log1p                          = 260  // "log1p"
    case log2                           = 261  // "log2"
    case max                            = 262  // "max"
    case min                            = 263  // "min"
    case pow                            = 264  // "pow"
    case random                         = 265  // "random"
    case round                          = 266  // "round"
    case sign                           = 267  // "sign"
    case sin                            = 268  // "sin"
    case sinh                           = 269  // "sinh"
    case sqrt                           = 270  // "sqrt"
    case tan                            = 271  // "tan"
    case tanh                           = 272  // "tanh"
    case trunc                          = 273  // "trunc"

    // -----------------------------------------------------------------------
    // MARK: Date methods and properties
    // -----------------------------------------------------------------------
    case now                            = 274  // "now"
    case parse                          = 275  // "parse"
    case UTC                            = 276  // "UTC"
    case getDate                        = 277  // "getDate"
    case getDay                         = 278  // "getDay"
    case getFullYear                    = 279  // "getFullYear"
    case getHours                       = 280  // "getHours"
    case getMilliseconds                = 281  // "getMilliseconds"
    case getMinutes                     = 282  // "getMinutes"
    case getMonth                       = 283  // "getMonth"
    case getSeconds                     = 284  // "getSeconds"
    case getTime                        = 285  // "getTime"
    case getTimezoneOffset              = 286  // "getTimezoneOffset"
    case getUTCDate                     = 287  // "getUTCDate"
    case getUTCDay                      = 288  // "getUTCDay"
    case getUTCFullYear                 = 289  // "getUTCFullYear"
    case getUTCHours                    = 290  // "getUTCHours"
    case getUTCMilliseconds             = 291  // "getUTCMilliseconds"
    case getUTCMinutes                  = 292  // "getUTCMinutes"
    case getUTCMonth                    = 293  // "getUTCMonth"
    case getUTCSeconds                  = 294  // "getUTCSeconds"
    case setDate                        = 295  // "setDate"
    case setFullYear                    = 296  // "setFullYear"
    case setHours                       = 297  // "setHours"
    case setMilliseconds                = 298  // "setMilliseconds"
    case setMinutes                     = 299  // "setMinutes"
    case setMonth                       = 300  // "setMonth"
    case setSeconds                     = 301  // "setSeconds"
    case setTime                        = 302  // "setTime"
    case setUTCDate                     = 303  // "setUTCDate"
    case setUTCFullYear                 = 304  // "setUTCFullYear"
    case setUTCHours                    = 305  // "setUTCHours"
    case setUTCMilliseconds             = 306  // "setUTCMilliseconds"
    case setUTCMinutes                  = 307  // "setUTCMinutes"
    case setUTCMonth                    = 308  // "setUTCMonth"
    case setUTCSeconds                  = 309  // "setUTCSeconds"
    case toDateString                   = 310  // "toDateString"
    case toGMTString                    = 311  // "toGMTString"
    case toISOString                    = 312  // "toISOString"
    case toLocaleDateString             = 313  // "toLocaleDateString"
    case toLocaleTimeString             = 314  // "toLocaleTimeString"
    case toTimeString                   = 315  // "toTimeString"
    case toUTCString                    = 316  // "toUTCString"
    case getYear                        = 317  // "getYear"
    case setYear                        = 318  // "setYear"
    case toGMTStringAlias               = 319  // "toGMTString" (alias)

    // -----------------------------------------------------------------------
    // MARK: RegExp
    // -----------------------------------------------------------------------
    case exec                           = 320  // "exec"
    case test                           = 321  // "test"
    case compile_                       = 322  // "compile"
    case dotAll                         = 323  // "dotAll"
    case hasIndices                     = 324  // "hasIndices"
    case ignoreCase                     = 325  // "ignoreCase"
    case multiline                      = 326  // "multiline"
    case sticky                         = 327  // "sticky"
    case input                          = 328  // "input"
    case index                          = 329  // "index"
    case groups                         = 330  // "groups"
    case indices                        = 331  // "indices"
    case lastIndex                      = 332  // "lastIndex"

    // -----------------------------------------------------------------------
    // MARK: JSON
    // -----------------------------------------------------------------------
    case stringify                      = 333  // "stringify"
    case rawJSON                        = 334  // "rawJSON"
    case isRawJSON                      = 335  // "isRawJSON"

    // -----------------------------------------------------------------------
    // MARK: Map / Set / WeakMap / WeakSet / WeakRef
    // -----------------------------------------------------------------------
    case size                           = 336  // "size"
    case add                            = 337  // "add"
    case clear                          = 338  // "clear"
    case deref                          = 339  // "deref"

    // -----------------------------------------------------------------------
    // MARK: Generator / Iterator
    // -----------------------------------------------------------------------
    case return__                       = 340  // "return"
    case throw__                        = 341  // "throw"

    // -----------------------------------------------------------------------
    // MARK: Promise
    // -----------------------------------------------------------------------
    case all                            = 342  // "all"
    case allSettled                     = 343  // "allSettled"
    case any                            = 344  // "any"
    case race                           = 345  // "race"
    case status                         = 346  // "status"
    case reason                         = 347  // "reason"
    case fulfilled                      = 348  // "fulfilled"
    case rejected                       = 349  // "rejected"

    // -----------------------------------------------------------------------
    // MARK: TypedArray / ArrayBuffer / DataView
    // -----------------------------------------------------------------------
    case buffer                         = 350  // "buffer"
    case byteLength                     = 351  // "byteLength"
    case byteOffset                     = 352  // "byteOffset"
    case BYTES_PER_ELEMENT              = 353  // "BYTES_PER_ELEMENT"
    case subarray                       = 354  // "subarray"
    case set_                           = 355  // "set"
    case getInt8                        = 356  // "getInt8"
    case getUint8                       = 357  // "getUint8"
    case getInt16                       = 358  // "getInt16"
    case getUint16                      = 359  // "getUint16"
    case getInt32                       = 360  // "getInt32"
    case getUint32                      = 361  // "getUint32"
    case getFloat32                     = 362  // "getFloat32"
    case getFloat64                     = 363  // "getFloat64"
    case getBigInt64                    = 364  // "getBigInt64"
    case getBigUint64                   = 365  // "getBigUint64"
    case setInt8                        = 366  // "setInt8"
    case setUint8                       = 367  // "setUint8"
    case setInt16                       = 368  // "setInt16"
    case setUint16                      = 369  // "setUint16"
    case setInt32                       = 370  // "setInt32"
    case setUint32                      = 371  // "setUint32"
    case setFloat32                     = 372  // "setFloat32"
    case setFloat64                     = 373  // "setFloat64"
    case setBigInt64                    = 374  // "setBigInt64"
    case setBigUint64                   = 375  // "setBigUint64"
    case isView                         = 376  // "isView"
    case transfer                       = 377  // "transfer"
    case transferToFixedLength          = 378  // "transferToFixedLength"
    case detached                       = 379  // "detached"
    case resizable                      = 380  // "resizable"
    case maxByteLength                  = 381  // "maxByteLength"
    case growable                       = 382  // "growable"
    case grow                           = 383  // "grow"
    case resize                         = 384  // "resize"

    // -----------------------------------------------------------------------
    // MARK: SharedArrayBuffer / Atomics
    // -----------------------------------------------------------------------
    case compareExchange                = 385  // "compareExchange"
    case exchange                       = 386  // "exchange"
    case load                           = 387  // "load"
    case store                          = 388  // "store"
    case sub                            = 389  // "sub"
    case and_                           = 390  // "and"
    case or_                            = 391  // "or"
    case xor_                           = 392  // "xor"
    case wait                           = 393  // "wait"
    case notify                         = 394  // "notify"
    case isLockFree                     = 395  // "isLockFree"

    // -----------------------------------------------------------------------
    // MARK: Error constructors / properties
    // -----------------------------------------------------------------------
    case Error                          = 396  // "Error"
    case EvalError                      = 397  // "EvalError"
    case RangeError                     = 398  // "RangeError"
    case ReferenceError                 = 399  // "ReferenceError"
    case SyntaxError                    = 400  // "SyntaxError"
    case TypeError                      = 401  // "TypeError"
    case URIError                       = 402  // "URIError"
    case AggregateError                 = 403  // "AggregateError"
    case InternalError                  = 404  // "InternalError"

    // -----------------------------------------------------------------------
    // MARK: Global constructors and objects
    // -----------------------------------------------------------------------
    case Object                         = 405  // "Object"
    case Array_                         = 406  // "Array"
    case Function_                      = 407  // "Function"
    case Boolean_                       = 408  // "Boolean"
    case Number_                        = 409  // "Number"
    case String_                        = 410  // "String"
    case Symbol_                        = 411  // "Symbol"
    case BigInt_                        = 412  // "BigInt"
    case RegExp                         = 413  // "RegExp"
    case Date                           = 414  // "Date"
    case Map_                           = 415  // "Map"
    case Set_                           = 416  // "Set"
    case WeakMap                        = 417  // "WeakMap"
    case WeakSet                        = 418  // "WeakSet"
    case WeakRef                        = 419  // "WeakRef"
    case FinalizationRegistry           = 420  // "FinalizationRegistry"
    case ArrayBuffer                    = 421  // "ArrayBuffer"
    case SharedArrayBuffer              = 422  // "SharedArrayBuffer"
    case DataView                       = 423  // "DataView"
    case Promise_                       = 424  // "Promise"
    case Proxy                          = 425  // "Proxy"
    case Reflect                        = 426  // "Reflect"
    case JSON_                          = 427  // "JSON"
    case Atomics                        = 428  // "Atomics"
    case Math                           = 429  // "Math"
    case Int8Array                      = 430  // "Int8Array"
    case Uint8Array                     = 431  // "Uint8Array"
    case Uint8ClampedArray              = 432  // "Uint8ClampedArray"
    case Int16Array                     = 433  // "Int16Array"
    case Uint16Array                    = 434  // "Uint16Array"
    case Int32Array                     = 435  // "Int32Array"
    case Uint32Array_                   = 436  // "Uint32Array"
    case BigInt64Array                  = 437  // "BigInt64Array"
    case BigUint64Array                 = 438  // "BigUint64Array"
    case Float32Array                   = 439  // "Float32Array"
    case Float64Array                   = 440  // "Float64Array"
    case Iterator                       = 441  // "Iterator"
    case GeneratorFunction              = 442  // "GeneratorFunction"
    case AsyncFunction                  = 443  // "AsyncFunction"
    case AsyncGeneratorFunction         = 444  // "AsyncGeneratorFunction"
    case Generator                      = 445  // "Generator"
    case AsyncGenerator                 = 446  // "AsyncGenerator"

    // -----------------------------------------------------------------------
    // MARK: Global functions and misc
    // -----------------------------------------------------------------------
    case globalThis                     = 447  // "globalThis"
    case decodeURI                      = 448  // "decodeURI"
    case decodeURIComponent             = 449  // "decodeURIComponent"
    case encodeURI                      = 450  // "encodeURI"
    case encodeURIComponent             = 451  // "encodeURIComponent"
    case escape                         = 452  // "escape"
    case unescape                       = 453  // "unescape"
    case Infinity_                      = 454  // "Infinity"
    case hasOwn                         = 455  // "hasOwn"
    case structuredClone                = 456  // "structuredClone"

    // -----------------------------------------------------------------------
    // MARK: Miscellaneous property names
    // -----------------------------------------------------------------------
    case toStringTag                    = 457  // "toStringTag"
    case symbolFor                      = 458  // "for" (Symbol.for)
    case keyFor                         = 459  // "keyFor"
    case asIntN                         = 460  // "asIntN"
    case asUintN                        = 461  // "asUintN"
    case register_                      = 462  // "register"
    case unregister                     = 463  // "unregister"
    case target                         = 464  // "target"
    case handler                        = 465  // "handler"
    case proxy_                         = 466  // "proxy"
    case enumerate                      = 467  // "enumerate"
    case species                        = 468  // "species"

    // -----------------------------------------------------------------------
    // MARK: Iterator protocol
    // -----------------------------------------------------------------------
    case iterator                       = 469  // "iterator"
    case asyncIterator                  = 470  // "asyncIterator"
    case drop                           = 471  // "drop"
    case take                           = 472  // "take"
    case toArray                        = 473  // "toArray"

    // -----------------------------------------------------------------------
    // MARK: Module / import
    // -----------------------------------------------------------------------
    case meta                           = 474  // "meta"
    case url                            = 475  // "url"

    // -----------------------------------------------------------------------
    // MARK: Error cause and misc
    // -----------------------------------------------------------------------
    case suppressedErrors               = 476  // "suppressedErrors"
    case SuppressedError                = 477  // "SuppressedError"
    case DisposableStack                = 478  // "DisposableStack"
    case AsyncDisposableStack           = 479  // "AsyncDisposableStack"
    case Symbol_dispose                 = 480  // "Symbol.dispose"
    case Symbol_asyncDispose            = 481  // "Symbol.asyncDispose"
    case disposed                       = 482  // "disposed"
    case use                            = 483  // "use"
    case adopt                          = 484  // "adopt"
    case defer_                         = 485  // "defer"
    case move                           = 486  // "move"

    // -----------------------------------------------------------------------
    // MARK: Console / debug
    // -----------------------------------------------------------------------
    case console                        = 487  // "console"
    case debug                          = 488  // "debug"
    case info                           = 489  // "info"
    case warn                           = 490  // "warn"
    case error                          = 491  // "error"

    // -----------------------------------------------------------------------
    // MARK: Encoding
    // -----------------------------------------------------------------------
    case encode                         = 492  // "encode"
    case decode                         = 493  // "decode"

    // -----------------------------------------------------------------------
    // MARK: Miscellaneous remaining atoms
    // -----------------------------------------------------------------------
    case type                           = 494  // "type"
    case data                           = 495  // "data"
    case ending                         = 496  // "ending"
    case arrayBuffer                    = 497  // "arrayBuffer"
    case text                           = 498  // "text"
    case writable_                      = 499  // "writable"
    case readable                       = 500  // "readable"
    case close                          = 501  // "close"
    case abort                          = 502  // "abort"
    case signal                         = 503  // "signal"

    // -----------------------------------------------------------------------
    // MARK: Additional atoms (not in original QuickJS, needed by JeffJS)
    // -----------------------------------------------------------------------
    case Module                         = 504  // "Module"
    case AsyncIterator_                 = 505  // "AsyncIterator"
    case unicodeSets                    = 506  // "unicodeSets"

    case END                            = 507  // sentinel

    // MARK: - String mapping

    /// The actual string value for each predefined atom.
    var stringValue: String {
        switch self {
        case .null_:                        return "null"
        case .false_:                       return "false"
        case .true_:                        return "true"
        case .if_:                          return "if"
        case .else_:                        return "else"
        case .return_:                      return "return"
        case .var_:                         return "var"
        case .this_:                        return "this"
        case .delete_:                      return "delete"
        case .void_:                        return "void"
        case .typeof_:                      return "typeof"
        case .new_:                         return "new"
        case .in_:                          return "in"
        case .instanceof_:                  return "instanceof"
        case .do_:                          return "do"
        case .while_:                       return "while"
        case .for_:                         return "for"
        case .break_:                       return "break"
        case .continue_:                    return "continue"
        case .switch_:                      return "switch"
        case .case_:                        return "case"
        case .default_:                     return "default"
        case .throw_:                       return "throw"
        case .try_:                         return "try"
        case .catch_:                       return "catch"
        case .finally_:                     return "finally"
        case .function_:                    return "function"
        case .debugger_:                    return "debugger"
        case .with_:                        return "with"
        case .class_:                       return "class"
        case .const_:                       return "const"
        case .enum_:                        return "enum"
        case .export_:                      return "export"
        case .extends_:                     return "extends"
        case .import_:                      return "import"
        case .super_:                       return "super"
        case .implements_:                  return "implements"
        case .interface_:                   return "interface"
        case .let_:                         return "let"
        case .package_:                     return "package"
        case .private_:                     return "private"
        case .protected_:                   return "protected"
        case .public_:                      return "public"
        case .static_:                      return "static"
        case .yield_:                       return "yield"
        case .await_:                       return "await"
        case .emptyString:                  return ""
        case .length:                       return "length"
        case .fileName:                     return "fileName"
        case .lineNumber:                   return "lineNumber"
        case .columnNumber:                 return "columnNumber"
        case .message:                      return "message"
        case .name:                         return "name"
        case .errors:                       return "errors"
        case .stack:                        return "stack"
        case .cause:                        return "cause"
        case .toStringAtom:                 return "toString"
        case .toLocaleString:               return "toLocaleString"
        case .valueOf:                      return "valueOf"
        case .eval_:                        return "eval"
        case .prototype:                    return "prototype"
        case .constructor_:                 return "constructor"
        case .configurable:                 return "configurable"
        case .writable:                     return "writable"
        case .enumerable:                   return "enumerable"
        case .value:                        return "value"
        case .get:                          return "get"
        case .set:                          return "set"
        case .of:                           return "of"
        case .__proto__:                    return "__proto__"
        case .undefined_:                   return "undefined"
        case .number:                       return "number"
        case .boolean:                      return "boolean"
        case .string:                       return "string"
        case .object:                       return "object"
        case .symbol:                       return "symbol"
        case .bigint:                       return "bigint"
        case .integer:                      return "integer"
        case .unknown:                      return "unknown"
        case .arguments_:                   return "arguments"
        case .callee:                       return "callee"
        case .caller:                       return "caller"
        case ._eval_:                       return "<eval>"
        case ._ret_:                        return "<ret>"
        case .Symbol_toPrimitive:           return "Symbol.toPrimitive"
        case .Symbol_iterator:              return "Symbol.iterator"
        case .Symbol_match:                 return "Symbol.match"
        case .Symbol_matchAll:              return "Symbol.matchAll"
        case .Symbol_replace:               return "Symbol.replace"
        case .Symbol_search:                return "Symbol.search"
        case .Symbol_split:                 return "Symbol.split"
        case .Symbol_toStringTag:           return "Symbol.toStringTag"
        case .Symbol_isConcatSpreadable:    return "Symbol.isConcatSpreadable"
        case .Symbol_hasInstance:            return "Symbol.hasInstance"
        case .Symbol_species:               return "Symbol.species"
        case .Symbol_unscopables:           return "Symbol.unscopables"
        case .Symbol_asyncIterator:         return "Symbol.asyncIterator"
        case .description:                  return "description"
        case .then:                         return "then"
        case .promise:                      return "promise"
        case .resolve:                      return "resolve"
        case .reject:                       return "reject"
        case .toJSON:                       return "toJSON"
        case .flags:                        return "flags"
        case .source:                       return "source"
        case .global_:                      return "global"
        case .unicode:                      return "unicode"
        case .raw:                          return "raw"
        case .next:                         return "next"
        case .done:                         return "done"
        case .apply:                        return "apply"
        case .call:                         return "call"
        case .bind:                         return "bind"
        case .hasOwnProperty:              return "hasOwnProperty"
        case .isPrototypeOf:               return "isPrototypeOf"
        case .propertyIsEnumerable:        return "propertyIsEnumerable"
        case .defineProperty:              return "defineProperty"
        case .getOwnPropertyDescriptor:    return "getOwnPropertyDescriptor"
        case .isExtensible:                return "isExtensible"
        case .preventExtensions:           return "preventExtensions"
        case .has:                          return "has"
        case .deleteProperty:              return "deleteProperty"
        case .defineGetter:                return "__defineGetter__"
        case .defineSetter:                return "__defineSetter__"
        case .lookupGetter:                return "__lookupGetter__"
        case .lookupSetter:                return "__lookupSetter__"
        case .ownKeys:                     return "ownKeys"
        case .construct:                   return "construct"
        case .getPrototypeOf:              return "getPrototypeOf"
        case .setPrototypeOf:              return "setPrototypeOf"
        case .isArray:                     return "isArray"
        case .proxy:                       return "proxy"
        case .revocable:                   return "revocable"
        case .revoke:                      return "revoke"
        case .assign:                      return "assign"
        case .keys:                        return "keys"
        case .values:                      return "values"
        case .entries:                     return "entries"
        case .freeze:                      return "freeze"
        case .isFrozen:                    return "isFrozen"
        case .seal:                        return "seal"
        case .isSealed:                    return "isSealed"
        case .create:                      return "create"
        case .fromEntries:                 return "fromEntries"
        case .getOwnPropertyNames:         return "getOwnPropertyNames"
        case .getOwnPropertySymbols:       return "getOwnPropertySymbols"
        case .getOwnPropertyDescriptors:   return "getOwnPropertyDescriptors"
        case .is_:                          return "is"
        case .from:                         return "from"
        case .of_:                          return "of"
        case .concat:                       return "concat"
        case .copyWithin:                   return "copyWithin"
        case .every:                        return "every"
        case .fill:                         return "fill"
        case .filter:                       return "filter"
        case .find:                         return "find"
        case .findIndex:                    return "findIndex"
        case .flat:                         return "flat"
        case .flatMap:                      return "flatMap"
        case .forEach:                      return "forEach"
        case .includes:                     return "includes"
        case .indexOf:                      return "indexOf"
        case .join:                         return "join"
        case .lastIndexOf:                  return "lastIndexOf"
        case .map:                          return "map"
        case .pop:                          return "pop"
        case .push:                         return "push"
        case .reduce:                       return "reduce"
        case .reduceRight:                  return "reduceRight"
        case .reverse:                      return "reverse"
        case .shift:                        return "shift"
        case .slice:                        return "slice"
        case .some:                         return "some"
        case .sort:                         return "sort"
        case .splice:                       return "splice"
        case .unshift:                      return "unshift"
        case .at:                           return "at"
        case .findLast:                     return "findLast"
        case .findLastIndex:                return "findLastIndex"
        case .toReversed:                   return "toReversed"
        case .toSorted:                     return "toSorted"
        case .toSpliced:                    return "toSpliced"
        case .arrayWith:                    return "with"
        case .group:                        return "group"
        case .groupToMap:                   return "groupToMap"
        case .charAt:                       return "charAt"
        case .charCodeAt:                   return "charCodeAt"
        case .codePointAt:                  return "codePointAt"
        case .endsWith:                     return "endsWith"
        case .fromCharCode:                 return "fromCharCode"
        case .fromCodePoint:                return "fromCodePoint"
        case .localeCompare:                return "localeCompare"
        case .match_:                       return "match"
        case .matchAll_:                    return "matchAll"
        case .normalize:                    return "normalize"
        case .padEnd:                       return "padEnd"
        case .padStart:                     return "padStart"
        case .repeat_:                      return "repeat"
        case .replace_:                     return "replace"
        case .replaceAll:                   return "replaceAll"
        case .search_:                      return "search"
        case .split_:                       return "split"
        case .startsWith:                   return "startsWith"
        case .substring:                    return "substring"
        case .toLocaleLowerCase:            return "toLocaleLowerCase"
        case .toLocaleUpperCase:            return "toLocaleUpperCase"
        case .toLowerCase:                  return "toLowerCase"
        case .toUpperCase:                  return "toUpperCase"
        case .toWellFormed:                 return "toWellFormed"
        case .isWellFormed:                 return "isWellFormed"
        case .trim:                         return "trim"
        case .trimEnd:                      return "trimEnd"
        case .trimStart:                    return "trimStart"
        case .toFixed:                      return "toFixed"
        case .toExponential:                return "toExponential"
        case .toPrecision:                  return "toPrecision"
        case .isFinite:                     return "isFinite"
        case .isNaN:                        return "isNaN"
        case .isInteger:                    return "isInteger"
        case .isSafeInteger:                return "isSafeInteger"
        case .parseFloat:                   return "parseFloat"
        case .parseInt:                     return "parseInt"
        case .EPSILON:                      return "EPSILON"
        case .MAX_SAFE_INTEGER:             return "MAX_SAFE_INTEGER"
        case .MIN_SAFE_INTEGER:             return "MIN_SAFE_INTEGER"
        case .MAX_VALUE:                    return "MAX_VALUE"
        case .MIN_VALUE:                    return "MIN_VALUE"
        case .NEGATIVE_INFINITY_:           return "NEGATIVE_INFINITY"
        case .POSITIVE_INFINITY_:           return "POSITIVE_INFINITY"
        case .NaN_:                         return "NaN"
        case .E:                            return "E"
        case .LN10:                         return "LN10"
        case .LN2:                          return "LN2"
        case .LOG10E:                       return "LOG10E"
        case .LOG2E:                        return "LOG2E"
        case .PI:                           return "PI"
        case .SQRT1_2:                      return "SQRT1_2"
        case .SQRT2:                        return "SQRT2"
        case .abs:                          return "abs"
        case .acos:                         return "acos"
        case .acosh:                        return "acosh"
        case .asin:                         return "asin"
        case .asinh:                        return "asinh"
        case .atan:                         return "atan"
        case .atan2:                        return "atan2"
        case .atanh:                        return "atanh"
        case .cbrt:                         return "cbrt"
        case .ceil:                         return "ceil"
        case .clz32:                        return "clz32"
        case .cos:                          return "cos"
        case .cosh:                         return "cosh"
        case .exp_:                         return "exp"
        case .expm1:                        return "expm1"
        case .floor:                        return "floor"
        case .fround:                       return "fround"
        case .hypot:                        return "hypot"
        case .imul:                         return "imul"
        case .log:                          return "log"
        case .log10:                        return "log10"
        case .log1p:                        return "log1p"
        case .log2:                         return "log2"
        case .max:                          return "max"
        case .min:                          return "min"
        case .pow:                          return "pow"
        case .random:                       return "random"
        case .round:                        return "round"
        case .sign:                         return "sign"
        case .sin:                          return "sin"
        case .sinh:                         return "sinh"
        case .sqrt:                         return "sqrt"
        case .tan:                          return "tan"
        case .tanh:                         return "tanh"
        case .trunc:                        return "trunc"
        case .now:                          return "now"
        case .parse:                        return "parse"
        case .UTC:                          return "UTC"
        case .getDate:                      return "getDate"
        case .getDay:                       return "getDay"
        case .getFullYear:                  return "getFullYear"
        case .getHours:                     return "getHours"
        case .getMilliseconds:              return "getMilliseconds"
        case .getMinutes:                   return "getMinutes"
        case .getMonth:                     return "getMonth"
        case .getSeconds:                   return "getSeconds"
        case .getTime:                      return "getTime"
        case .getTimezoneOffset:            return "getTimezoneOffset"
        case .getUTCDate:                   return "getUTCDate"
        case .getUTCDay:                    return "getUTCDay"
        case .getUTCFullYear:               return "getUTCFullYear"
        case .getUTCHours:                  return "getUTCHours"
        case .getUTCMilliseconds:           return "getUTCMilliseconds"
        case .getUTCMinutes:                return "getUTCMinutes"
        case .getUTCMonth:                  return "getUTCMonth"
        case .getUTCSeconds:                return "getUTCSeconds"
        case .setDate:                      return "setDate"
        case .setFullYear:                  return "setFullYear"
        case .setHours:                     return "setHours"
        case .setMilliseconds:              return "setMilliseconds"
        case .setMinutes:                   return "setMinutes"
        case .setMonth:                     return "setMonth"
        case .setSeconds:                   return "setSeconds"
        case .setTime:                      return "setTime"
        case .setUTCDate:                   return "setUTCDate"
        case .setUTCFullYear:               return "setUTCFullYear"
        case .setUTCHours:                  return "setUTCHours"
        case .setUTCMilliseconds:           return "setUTCMilliseconds"
        case .setUTCMinutes:                return "setUTCMinutes"
        case .setUTCMonth:                  return "setUTCMonth"
        case .setUTCSeconds:                return "setUTCSeconds"
        case .toDateString:                 return "toDateString"
        case .toGMTString:                  return "toGMTString"
        case .toISOString:                  return "toISOString"
        case .toLocaleDateString:           return "toLocaleDateString"
        case .toLocaleTimeString:           return "toLocaleTimeString"
        case .toTimeString:                 return "toTimeString"
        case .toUTCString:                  return "toUTCString"
        case .getYear:                      return "getYear"
        case .setYear:                      return "setYear"
        case .toGMTStringAlias:             return "toGMTString"
        case .exec:                         return "exec"
        case .test:                         return "test"
        case .compile_:                     return "compile"
        case .dotAll:                       return "dotAll"
        case .hasIndices:                   return "hasIndices"
        case .ignoreCase:                   return "ignoreCase"
        case .multiline:                    return "multiline"
        case .sticky:                       return "sticky"
        case .input:                        return "input"
        case .index:                        return "index"
        case .groups:                       return "groups"
        case .indices:                      return "indices"
        case .lastIndex:                    return "lastIndex"
        case .stringify:                    return "stringify"
        case .rawJSON:                      return "rawJSON"
        case .isRawJSON:                    return "isRawJSON"
        case .size:                         return "size"
        case .add:                          return "add"
        case .clear:                        return "clear"
        case .deref:                        return "deref"
        case .return__:                     return "return"
        case .throw__:                      return "throw"
        case .all:                          return "all"
        case .allSettled:                   return "allSettled"
        case .any:                          return "any"
        case .race:                         return "race"
        case .status:                       return "status"
        case .reason:                       return "reason"
        case .fulfilled:                    return "fulfilled"
        case .rejected:                     return "rejected"
        case .buffer:                       return "buffer"
        case .byteLength:                   return "byteLength"
        case .byteOffset:                   return "byteOffset"
        case .BYTES_PER_ELEMENT:            return "BYTES_PER_ELEMENT"
        case .subarray:                     return "subarray"
        case .set_:                         return "set"
        case .getInt8:                      return "getInt8"
        case .getUint8:                     return "getUint8"
        case .getInt16:                     return "getInt16"
        case .getUint16:                    return "getUint16"
        case .getInt32:                     return "getInt32"
        case .getUint32:                    return "getUint32"
        case .getFloat32:                   return "getFloat32"
        case .getFloat64:                   return "getFloat64"
        case .getBigInt64:                  return "getBigInt64"
        case .getBigUint64:                 return "getBigUint64"
        case .setInt8:                      return "setInt8"
        case .setUint8:                     return "setUint8"
        case .setInt16:                     return "setInt16"
        case .setUint16:                    return "setUint16"
        case .setInt32:                     return "setInt32"
        case .setUint32:                    return "setUint32"
        case .setFloat32:                   return "setFloat32"
        case .setFloat64:                   return "setFloat64"
        case .setBigInt64:                  return "setBigInt64"
        case .setBigUint64:                 return "setBigUint64"
        case .isView:                       return "isView"
        case .transfer:                     return "transfer"
        case .transferToFixedLength:        return "transferToFixedLength"
        case .detached:                     return "detached"
        case .resizable:                    return "resizable"
        case .maxByteLength:                return "maxByteLength"
        case .growable:                     return "growable"
        case .grow:                         return "grow"
        case .resize:                       return "resize"
        case .compareExchange:              return "compareExchange"
        case .exchange:                     return "exchange"
        case .load:                         return "load"
        case .store:                        return "store"
        case .sub:                          return "sub"
        case .and_:                         return "and"
        case .or_:                          return "or"
        case .xor_:                         return "xor"
        case .wait:                         return "wait"
        case .notify:                       return "notify"
        case .isLockFree:                   return "isLockFree"
        case .Error:                        return "Error"
        case .EvalError:                    return "EvalError"
        case .RangeError:                   return "RangeError"
        case .ReferenceError:               return "ReferenceError"
        case .SyntaxError:                  return "SyntaxError"
        case .TypeError:                    return "TypeError"
        case .URIError:                     return "URIError"
        case .AggregateError:               return "AggregateError"
        case .InternalError:                return "InternalError"
        case .Object:                       return "Object"
        case .Array_:                       return "Array"
        case .Function_:                    return "Function"
        case .Boolean_:                     return "Boolean"
        case .Number_:                      return "Number"
        case .String_:                      return "String"
        case .Symbol_:                      return "Symbol"
        case .BigInt_:                      return "BigInt"
        case .RegExp:                       return "RegExp"
        case .Date:                         return "Date"
        case .Map_:                         return "Map"
        case .Set_:                         return "Set"
        case .WeakMap:                      return "WeakMap"
        case .WeakSet:                      return "WeakSet"
        case .WeakRef:                      return "WeakRef"
        case .FinalizationRegistry:         return "FinalizationRegistry"
        case .ArrayBuffer:                  return "ArrayBuffer"
        case .SharedArrayBuffer:            return "SharedArrayBuffer"
        case .DataView:                     return "DataView"
        case .Promise_:                     return "Promise"
        case .Proxy:                        return "Proxy"
        case .Reflect:                      return "Reflect"
        case .JSON_:                        return "JSON"
        case .Atomics:                      return "Atomics"
        case .Math:                         return "Math"
        case .Int8Array:                    return "Int8Array"
        case .Uint8Array:                   return "Uint8Array"
        case .Uint8ClampedArray:            return "Uint8ClampedArray"
        case .Int16Array:                   return "Int16Array"
        case .Uint16Array:                  return "Uint16Array"
        case .Int32Array:                   return "Int32Array"
        case .Uint32Array_:                 return "Uint32Array"
        case .BigInt64Array:                return "BigInt64Array"
        case .BigUint64Array:               return "BigUint64Array"
        case .Float32Array:                 return "Float32Array"
        case .Float64Array:                 return "Float64Array"
        case .Iterator:                     return "Iterator"
        case .GeneratorFunction:            return "GeneratorFunction"
        case .AsyncFunction:                return "AsyncFunction"
        case .AsyncGeneratorFunction:       return "AsyncGeneratorFunction"
        case .Generator:                    return "Generator"
        case .AsyncGenerator:               return "AsyncGenerator"
        case .globalThis:                   return "globalThis"
        case .decodeURI:                    return "decodeURI"
        case .decodeURIComponent:           return "decodeURIComponent"
        case .encodeURI:                    return "encodeURI"
        case .encodeURIComponent:           return "encodeURIComponent"
        case .escape:                       return "escape"
        case .unescape:                     return "unescape"
        case .Infinity_:                    return "Infinity"
        case .hasOwn:                       return "hasOwn"
        case .structuredClone:              return "structuredClone"
        case .toStringTag:                  return "toStringTag"
        case .symbolFor:                    return "for"
        case .keyFor:                       return "keyFor"
        case .asIntN:                       return "asIntN"
        case .asUintN:                      return "asUintN"
        case .register_:                    return "register"
        case .unregister:                   return "unregister"
        case .target:                       return "target"
        case .handler:                      return "handler"
        case .proxy_:                       return "proxy"
        case .enumerate:                    return "enumerate"
        case .species:                      return "species"
        case .iterator:                     return "iterator"
        case .asyncIterator:                return "asyncIterator"
        case .drop:                         return "drop"
        case .take:                         return "take"
        case .toArray:                      return "toArray"
        case .meta:                         return "meta"
        case .url:                          return "url"
        case .suppressedErrors:             return "suppressedErrors"
        case .SuppressedError:              return "SuppressedError"
        case .DisposableStack:              return "DisposableStack"
        case .AsyncDisposableStack:         return "AsyncDisposableStack"
        case .Symbol_dispose:               return "Symbol.dispose"
        case .Symbol_asyncDispose:          return "Symbol.asyncDispose"
        case .disposed:                     return "disposed"
        case .use:                          return "use"
        case .adopt:                        return "adopt"
        case .defer_:                       return "defer"
        case .move:                         return "move"
        case .console:                      return "console"
        case .debug:                        return "debug"
        case .info:                         return "info"
        case .warn:                         return "warn"
        case .error:                        return "error"
        case .encode:                       return "encode"
        case .decode:                       return "decode"
        case .type:                         return "type"
        case .data:                         return "data"
        case .ending:                       return "ending"
        case .arrayBuffer:                  return "arrayBuffer"
        case .text:                         return "text"
        case .writable_:                    return "writable"
        case .readable:                     return "readable"
        case .close:                        return "close"
        case .abort:                        return "abort"
        case .signal:                       return "signal"
        case .Module:                       return "Module"
        case .AsyncIterator_:               return "AsyncIterator"
        case .unicodeSets:                  return "unicodeSets"
        case .END:                          return ""
        }
    }

    /// Returns an ordered array of all predefined atom strings (index 0 = atom 1).
    /// Used by JSAtomTable.init() to populate the table.
    static var allAtomStrings: [String] {
        var result = [String]()
        result.reserveCapacity(Int(JSPredefinedAtom.END.rawValue) - 1)
        var raw: UInt32 = 1
        while raw < JSPredefinedAtom.END.rawValue {
            if let atom = JSPredefinedAtom(rawValue: raw) {
                result.append(atom.stringValue)
            } else {
                result.append("")
            }
            raw += 1
        }
        return result
    }
}

// MARK: - Convenience accessors for predefined atom IDs

/// Provides fast access to predefined atom IDs without going through the enum.
/// Usage: JSAtomID.length, JSAtomID.prototype, etc.
enum JSAtomID {
    static let null_:                  JSAtom = JSPredefinedAtom.null_.rawValue
    static let false_:                 JSAtom = JSPredefinedAtom.false_.rawValue
    static let true_:                  JSAtom = JSPredefinedAtom.true_.rawValue
    static let if_:                    JSAtom = JSPredefinedAtom.if_.rawValue
    static let else_:                  JSAtom = JSPredefinedAtom.else_.rawValue
    static let return_:                JSAtom = JSPredefinedAtom.return_.rawValue
    static let var_:                   JSAtom = JSPredefinedAtom.var_.rawValue
    static let this_:                  JSAtom = JSPredefinedAtom.this_.rawValue
    static let delete_:                JSAtom = JSPredefinedAtom.delete_.rawValue
    static let void_:                  JSAtom = JSPredefinedAtom.void_.rawValue
    static let typeof_:                JSAtom = JSPredefinedAtom.typeof_.rawValue
    static let new_:                   JSAtom = JSPredefinedAtom.new_.rawValue
    static let in_:                    JSAtom = JSPredefinedAtom.in_.rawValue
    static let instanceof_:            JSAtom = JSPredefinedAtom.instanceof_.rawValue
    static let do_:                    JSAtom = JSPredefinedAtom.do_.rawValue
    static let while_:                 JSAtom = JSPredefinedAtom.while_.rawValue
    static let for_:                   JSAtom = JSPredefinedAtom.for_.rawValue
    static let break_:                 JSAtom = JSPredefinedAtom.break_.rawValue
    static let continue_:              JSAtom = JSPredefinedAtom.continue_.rawValue
    static let switch_:                JSAtom = JSPredefinedAtom.switch_.rawValue
    static let case_:                  JSAtom = JSPredefinedAtom.case_.rawValue
    static let default_:               JSAtom = JSPredefinedAtom.default_.rawValue
    static let throw_:                 JSAtom = JSPredefinedAtom.throw_.rawValue
    static let try_:                   JSAtom = JSPredefinedAtom.try_.rawValue
    static let catch_:                 JSAtom = JSPredefinedAtom.catch_.rawValue
    static let finally_:               JSAtom = JSPredefinedAtom.finally_.rawValue
    static let function_:              JSAtom = JSPredefinedAtom.function_.rawValue
    static let debugger_:              JSAtom = JSPredefinedAtom.debugger_.rawValue
    static let with_:                  JSAtom = JSPredefinedAtom.with_.rawValue
    static let class_:                 JSAtom = JSPredefinedAtom.class_.rawValue
    static let const_:                 JSAtom = JSPredefinedAtom.const_.rawValue
    static let enum_:                  JSAtom = JSPredefinedAtom.enum_.rawValue
    static let export_:                JSAtom = JSPredefinedAtom.export_.rawValue
    static let extends_:               JSAtom = JSPredefinedAtom.extends_.rawValue
    static let import_:                JSAtom = JSPredefinedAtom.import_.rawValue
    static let super_:                 JSAtom = JSPredefinedAtom.super_.rawValue
    static let implements_:            JSAtom = JSPredefinedAtom.implements_.rawValue
    static let interface_:             JSAtom = JSPredefinedAtom.interface_.rawValue
    static let let_:                   JSAtom = JSPredefinedAtom.let_.rawValue
    static let package_:               JSAtom = JSPredefinedAtom.package_.rawValue
    static let private_:               JSAtom = JSPredefinedAtom.private_.rawValue
    static let protected_:             JSAtom = JSPredefinedAtom.protected_.rawValue
    static let public_:                JSAtom = JSPredefinedAtom.public_.rawValue
    static let static_:                JSAtom = JSPredefinedAtom.static_.rawValue
    static let yield_:                 JSAtom = JSPredefinedAtom.yield_.rawValue
    static let await_:                 JSAtom = JSPredefinedAtom.await_.rawValue
    static let emptyString:            JSAtom = JSPredefinedAtom.emptyString.rawValue
    static let length:                 JSAtom = JSPredefinedAtom.length.rawValue
    static let fileName:               JSAtom = JSPredefinedAtom.fileName.rawValue
    static let lineNumber:             JSAtom = JSPredefinedAtom.lineNumber.rawValue
    static let columnNumber:           JSAtom = JSPredefinedAtom.columnNumber.rawValue
    static let message:                JSAtom = JSPredefinedAtom.message.rawValue
    static let name:                   JSAtom = JSPredefinedAtom.name.rawValue
    static let errors:                 JSAtom = JSPredefinedAtom.errors.rawValue
    static let stack:                  JSAtom = JSPredefinedAtom.stack.rawValue
    static let cause:                  JSAtom = JSPredefinedAtom.cause.rawValue
    static let toStringAtom:           JSAtom = JSPredefinedAtom.toStringAtom.rawValue
    static let toLocaleString:         JSAtom = JSPredefinedAtom.toLocaleString.rawValue
    static let valueOf:                JSAtom = JSPredefinedAtom.valueOf.rawValue
    static let eval_:                  JSAtom = JSPredefinedAtom.eval_.rawValue
    static let prototype:              JSAtom = JSPredefinedAtom.prototype.rawValue
    static let constructor_:           JSAtom = JSPredefinedAtom.constructor_.rawValue
    static let configurable:           JSAtom = JSPredefinedAtom.configurable.rawValue
    static let writable:               JSAtom = JSPredefinedAtom.writable.rawValue
    static let enumerable:             JSAtom = JSPredefinedAtom.enumerable.rawValue
    static let value:                  JSAtom = JSPredefinedAtom.value.rawValue
    static let get:                    JSAtom = JSPredefinedAtom.get.rawValue
    static let set:                    JSAtom = JSPredefinedAtom.set.rawValue
    static let of:                     JSAtom = JSPredefinedAtom.of.rawValue
    static let __proto__:              JSAtom = JSPredefinedAtom.__proto__.rawValue
    static let undefined_:             JSAtom = JSPredefinedAtom.undefined_.rawValue
    static let number:                 JSAtom = JSPredefinedAtom.number.rawValue
    static let boolean:                JSAtom = JSPredefinedAtom.boolean.rawValue
    static let string:                 JSAtom = JSPredefinedAtom.string.rawValue
    static let object:                 JSAtom = JSPredefinedAtom.object.rawValue
    static let symbol:                 JSAtom = JSPredefinedAtom.symbol.rawValue
    static let bigint:                 JSAtom = JSPredefinedAtom.bigint.rawValue
    static let integer:                JSAtom = JSPredefinedAtom.integer.rawValue
    static let unknown:                JSAtom = JSPredefinedAtom.unknown.rawValue
    static let arguments_:             JSAtom = JSPredefinedAtom.arguments_.rawValue
    static let callee:                 JSAtom = JSPredefinedAtom.callee.rawValue
    static let caller:                 JSAtom = JSPredefinedAtom.caller.rawValue
    static let Symbol_toPrimitive:     JSAtom = JSPredefinedAtom.Symbol_toPrimitive.rawValue
    static let Symbol_iterator:        JSAtom = JSPredefinedAtom.Symbol_iterator.rawValue
    static let Symbol_match:           JSAtom = JSPredefinedAtom.Symbol_match.rawValue
    static let Symbol_matchAll:        JSAtom = JSPredefinedAtom.Symbol_matchAll.rawValue
    static let Symbol_replace:         JSAtom = JSPredefinedAtom.Symbol_replace.rawValue
    static let Symbol_search:          JSAtom = JSPredefinedAtom.Symbol_search.rawValue
    static let Symbol_split:           JSAtom = JSPredefinedAtom.Symbol_split.rawValue
    static let Symbol_toStringTag:     JSAtom = JSPredefinedAtom.Symbol_toStringTag.rawValue
    static let Symbol_isConcatSpreadable: JSAtom = JSPredefinedAtom.Symbol_isConcatSpreadable.rawValue
    static let Symbol_hasInstance:      JSAtom = JSPredefinedAtom.Symbol_hasInstance.rawValue
    static let Symbol_species:          JSAtom = JSPredefinedAtom.Symbol_species.rawValue
    static let Symbol_unscopables:      JSAtom = JSPredefinedAtom.Symbol_unscopables.rawValue
    static let Symbol_asyncIterator:    JSAtom = JSPredefinedAtom.Symbol_asyncIterator.rawValue
    static let description:             JSAtom = JSPredefinedAtom.description.rawValue
    static let then:                    JSAtom = JSPredefinedAtom.then.rawValue
    static let promise:                 JSAtom = JSPredefinedAtom.promise.rawValue
    static let resolve:                 JSAtom = JSPredefinedAtom.resolve.rawValue
    static let reject:                  JSAtom = JSPredefinedAtom.reject.rawValue
    static let toJSON:                  JSAtom = JSPredefinedAtom.toJSON.rawValue
    static let flags:                   JSAtom = JSPredefinedAtom.flags.rawValue
    static let source:                  JSAtom = JSPredefinedAtom.source.rawValue
    static let global_:                 JSAtom = JSPredefinedAtom.global_.rawValue
    static let unicode:                 JSAtom = JSPredefinedAtom.unicode.rawValue
    static let raw:                     JSAtom = JSPredefinedAtom.raw.rawValue
    static let next:                    JSAtom = JSPredefinedAtom.next.rawValue
    static let done:                    JSAtom = JSPredefinedAtom.done.rawValue
    static let apply:                   JSAtom = JSPredefinedAtom.apply.rawValue
    static let call:                    JSAtom = JSPredefinedAtom.call.rawValue
    static let bind:                    JSAtom = JSPredefinedAtom.bind.rawValue

    // Array/Object method atoms
    static let isArray:                 JSAtom = JSPredefinedAtom.isArray.rawValue
    static let keys:                    JSAtom = JSPredefinedAtom.keys.rawValue
    static let values:                  JSAtom = JSPredefinedAtom.values.rawValue
    static let entries:                 JSAtom = JSPredefinedAtom.entries.rawValue
    static let from:                    JSAtom = JSPredefinedAtom.from.rawValue
    static let of_:                     JSAtom = JSPredefinedAtom.of_.rawValue
    static let concat:                  JSAtom = JSPredefinedAtom.concat.rawValue
    static let copyWithin:              JSAtom = JSPredefinedAtom.copyWithin.rawValue
    static let every:                   JSAtom = JSPredefinedAtom.every.rawValue
    static let fill:                    JSAtom = JSPredefinedAtom.fill.rawValue
    static let filter:                  JSAtom = JSPredefinedAtom.filter.rawValue
    static let find:                    JSAtom = JSPredefinedAtom.find.rawValue
    static let findIndex:               JSAtom = JSPredefinedAtom.findIndex.rawValue
    static let flat:                    JSAtom = JSPredefinedAtom.flat.rawValue
    static let flatMap:                 JSAtom = JSPredefinedAtom.flatMap.rawValue
    static let forEach:                 JSAtom = JSPredefinedAtom.forEach.rawValue
    static let includes:                JSAtom = JSPredefinedAtom.includes.rawValue
    static let indexOf:                 JSAtom = JSPredefinedAtom.indexOf.rawValue
    static let join:                    JSAtom = JSPredefinedAtom.join.rawValue
    static let lastIndexOf:             JSAtom = JSPredefinedAtom.lastIndexOf.rawValue
    static let map:                     JSAtom = JSPredefinedAtom.map.rawValue
    static let pop:                     JSAtom = JSPredefinedAtom.pop.rawValue
    static let push:                    JSAtom = JSPredefinedAtom.push.rawValue
    static let reduce:                  JSAtom = JSPredefinedAtom.reduce.rawValue
    static let reduceRight:             JSAtom = JSPredefinedAtom.reduceRight.rawValue
    static let reverse:                 JSAtom = JSPredefinedAtom.reverse.rawValue
    static let shift:                   JSAtom = JSPredefinedAtom.shift.rawValue
    static let slice:                   JSAtom = JSPredefinedAtom.slice.rawValue
    static let some:                    JSAtom = JSPredefinedAtom.some.rawValue
    static let sort:                    JSAtom = JSPredefinedAtom.sort.rawValue
    static let splice:                  JSAtom = JSPredefinedAtom.splice.rawValue
    static let unshift:                 JSAtom = JSPredefinedAtom.unshift.rawValue

    // ES2023 array methods and newer atoms
    static let at:                      JSAtom = JSPredefinedAtom.at.rawValue
    static let findLast:                JSAtom = JSPredefinedAtom.findLast.rawValue
    static let findLastIndex:           JSAtom = JSPredefinedAtom.findLastIndex.rawValue
    static let toReversed:              JSAtom = JSPredefinedAtom.toReversed.rawValue
    static let toSorted:                JSAtom = JSPredefinedAtom.toSorted.rawValue
    static let toSpliced:               JSAtom = JSPredefinedAtom.toSpliced.rawValue
    static let arrayWith:               JSAtom = JSPredefinedAtom.arrayWith.rawValue
    static let group:                   JSAtom = JSPredefinedAtom.group.rawValue
    static let groupToMap:              JSAtom = JSPredefinedAtom.groupToMap.rawValue
    static let symbolFor:               JSAtom = JSPredefinedAtom.symbolFor.rawValue

    // Object built-in method atoms
    static let hasOwnProperty:          JSAtom = JSPredefinedAtom.hasOwnProperty.rawValue
    static let isPrototypeOf:           JSAtom = JSPredefinedAtom.isPrototypeOf.rawValue
    static let propertyIsEnumerable:    JSAtom = JSPredefinedAtom.propertyIsEnumerable.rawValue
    static let defineGetter:            JSAtom = JSPredefinedAtom.lookupGetter.rawValue   // __defineGetter__
    static let defineSetter:            JSAtom = JSPredefinedAtom.lookupSetter.rawValue   // __defineSetter__
    static let lookupGetter:            JSAtom = JSPredefinedAtom.lookupGetter.rawValue
    static let lookupSetter:            JSAtom = JSPredefinedAtom.lookupSetter.rawValue
    static let getPrototypeOf:          JSAtom = JSPredefinedAtom.getPrototypeOf.rawValue
    static let setPrototypeOf:          JSAtom = JSPredefinedAtom.setPrototypeOf.rawValue
    static let isExtensible:            JSAtom = JSPredefinedAtom.isExtensible.rawValue
    static let preventExtensions:       JSAtom = JSPredefinedAtom.preventExtensions.rawValue
    static let freeze:                  JSAtom = JSPredefinedAtom.freeze.rawValue
    static let isFrozen:                JSAtom = JSPredefinedAtom.isFrozen.rawValue
    static let seal:                    JSAtom = JSPredefinedAtom.seal.rawValue
    static let isSealed:                JSAtom = JSPredefinedAtom.isSealed.rawValue
    static let is_:                     JSAtom = JSPredefinedAtom.is_.rawValue
    static let create:                  JSAtom = JSPredefinedAtom.create.rawValue
    static let defineProperty:          JSAtom = JSPredefinedAtom.defineProperty.rawValue
    static let getOwnPropertyNames:     JSAtom = JSPredefinedAtom.getOwnPropertyNames.rawValue
    static let getOwnPropertySymbols:   JSAtom = JSPredefinedAtom.getOwnPropertySymbols.rawValue
    static let getOwnPropertyDescriptor: JSAtom = JSPredefinedAtom.getOwnPropertyDescriptor.rawValue
    static let getOwnPropertyDescriptors: JSAtom = JSPredefinedAtom.getOwnPropertyDescriptors.rawValue
    static let assign:                  JSAtom = JSPredefinedAtom.assign.rawValue
    static let fromEntries:             JSAtom = JSPredefinedAtom.fromEntries.rawValue

    // Additional atoms
    static let Module:                  JSAtom = JSPredefinedAtom.Module.rawValue
    static let AsyncIterator_:          JSAtom = JSPredefinedAtom.AsyncIterator_.rawValue
    static let unicodeSets:             JSAtom = JSPredefinedAtom.unicodeSets.rawValue
}

// MARK: - First / Last keyword atom helpers

/// The first keyword atom index (for fast keyword detection in the parser).
let JS_ATOM_FIRST_KEYWORD = JSPredefinedAtom.null_.rawValue

/// The last keyword atom index.
let JS_ATOM_LAST_KEYWORD = JSPredefinedAtom.await_.rawValue

/// The last strict-mode reserved word atom index.
let JS_ATOM_LAST_STRICT_KEYWORD = JSPredefinedAtom.yield_.rawValue

/// Check if an atom is a keyword (used by the parser).
func jsAtomIsKeyword(_ atom: JSAtom) -> Bool {
    return atom >= JS_ATOM_FIRST_KEYWORD && atom <= JS_ATOM_LAST_KEYWORD
}

/// The total number of predefined atoms.
let JS_ATOM_END = JSPredefinedAtom.END.rawValue
