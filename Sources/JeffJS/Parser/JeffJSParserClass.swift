// JeffJSParserClass.swift
// JeffJS — class definitions: methods, fields, static blocks and private names.
//
// Port of QuickJS's `js_parse_class` / `js_parse_class_body`.  The shape of
// the generated code follows quickjs.c:
//
//   * instance fields compile into one synthetic function per class
//     (`<class_fields_init>`, held in a class-scope variable).  The
//     constructor calls it with `this` = the new instance: at the top of the
//     body for a base class, right after `super()` returns for a derived one.
//   * static fields and `static { }` blocks each compile into their own
//     synthetic function with `this` = the constructor.  They run once, in
//     source order, after the class object is fully built and after the inner
//     class binding is initialised (so `static b = B.a + 1` works).
//   * a private name is a per-class brand: the class scope holds a variable
//     with the private name (`#x`) whose value is a unique private symbol
//     (fields) or the method/accessor closure (methods).  `this.#x` compiles
//     to scope_get_private_field, which the compiler resolves against that
//     variable, so two classes that both declare `#x` never collide.

import Foundation

/// Per-class state used while parsing a class body.
final class JeffJSClassFieldsCtx {
    var className: JSAtom = 0
    var classScope: Int = 0
    var hasExtends = false

    /// Synthetic function running every instance field initializer with
    /// `this` = the instance (QuickJS `<class_fields_init>`).  Created on the
    /// first instance field or private instance method.
    var fieldsInitFd: JeffJSFunctionDefCompiler?
    /// Offset of the 4-byte placeholder reserved at the start of
    /// `fieldsInitFd` for `push_this; special_object(home_object); add_brand`.
    var brandPatchPos = -1
    var instanceBrandAdded = false
    var staticBrandAdded = false

    /// Class-scope variables holding the deferred static initializers, in
    /// source order.
    var staticInitVars: [JSAtom] = []

    /// Private names already declared in this class (name atom -> var kind).
    var privateKinds: [JSAtom: Int] = [:]

    /// The function definition that ends up as the class constructor (the
    /// synthesized default one, or the explicit `constructor` method once
    /// parseClassBody finds it).  Its `toString` is the whole class text, so
    /// its source span is only known after the closing brace.
    weak var ctorFd: JeffJSFunctionDefCompiler?
}

extension JeffJSParser {

    // =========================================================================
    // MARK: - Synthetic-function helpers
    // =========================================================================

    /// Name atom of the class-scope variable holding the instance field
    /// initializer.
    var classFieldsInitAtom: JSAtom { return getAtom("<class_fields_init>") }

    /// Create a synthetic method-like function definition (own `this`, no
    /// parameters) nested in the current function at the current scope.
    func makeSyntheticFd(name: JSAtom) -> JeffJSFunctionDefCompiler {
        let child = JeffJSFunctionDefCompiler()
        child.parent = fd
        child.funcName = name
        child.definedScopeLevel = fd.curScope
        child.argumentsAllowed = false
        child.superAllowed = true
        child.needHomeObject = true
        child.jsMode = fd.jsMode | JS_MODE_STRICT
        // A field initializer written inside a `with` body still resolves
        // identifiers against the with object (the class body itself is not
        // a strict-mode boundary for the enclosing `with`).
        child.withVarStack = fd.withVarStack
        return child
    }

    /// Run `body` with `fd` switched to `child` (the same save/restore
    /// parseFunctionBody does for a real function body).
    func withSyntheticFd(_ child: JeffJSFunctionDefCompiler, _ body: () -> Void) {
        let savedFd = fd
        let savedInFlag = inFlag
        let savedFinallyScopes = finallyScopes
        let savedBlockEnvIdx = curBlockEnvIdx
        finallyScopes = []
        curBlockEnvIdx = -1
        inFlag = true
        fd = child
        body()
        fd = savedFd
        inFlag = savedInFlag
        finallyScopes = savedFinallyScopes
        curBlockEnvIdx = savedBlockEnvIdx
    }

    /// Emit `fclosure` for a synthetic child function.  The compiler pairs
    /// `childFunctions[i]` with the i-th `fclosure` in the parent's bytecode,
    /// so the append has to happen right here.
    func emitSyntheticClosure(_ child: JeffJSFunctionDefCompiler) {
        fd.childFunctions.append(child)
        let cpoolIdx = addConstPoolValue(.mkVal(tag: .undefined, val: 0))
        emitFClosure(cpoolIdx)
    }

    /// Allocate a fresh class-scope variable with a synthetic name.
    func defineSyntheticClassVar(_ prefix: String) -> JSAtom {
        syntheticClassVarCounter += 1
        let atom = getAtom("\(prefix)\(syntheticClassVarCounter)>")
        _ = defineVar(atom, isConst: false, isLexical: true)
        return atom
    }

    /// `<class_fields_init>` call emitted in a class constructor:
    /// run the instance field initializers with `this` = the new object.
    /// The variable is `undefined` for classes without instance fields.
    func emitClassFieldInit() {
        let atom = classFieldsInitAtom
        let skip = newLabel()
        emitScopeGetVar(atom, scopeLevel: fd.curScope)   // [init]
        emitOp(.dup)                                     // [init, init]
        emitIfFalse(skip)                                // [init]
        emitOp(.push_this)                               // [init, this]
        emitOp(.swap)                                    // [this, init]
        emitCallMethod(0)                                // [result]
        emitLabel(skip)
        emitOp(.drop)
    }

    // =========================================================================
    // MARK: - Private names
    // =========================================================================

    /// The class-scope variable holding a private accessor's getter/setter.
    func privateAccessorAtom(_ name: JSAtom, isSetter: Bool) -> JSAtom {
        let base = (s.ctx as? JeffJSContext)?.atomToSwiftString(name) ?? "#?"
        return getAtom((isSetter ? "<set:" : "<get:") + base + ">")
    }

    /// Declare a private name in the class scope.  Fields get a unique private
    /// symbol (`private_symbol`); methods and accessors get their closure
    /// stored by the caller.  Returns false if the name was already declared
    /// with an incompatible kind.
    @discardableResult
    func declarePrivateName(_ cf: JeffJSClassFieldsCtx, _ name: JSAtom,
                            kind: JSVarKindEnum) -> Bool {
        if let existing = cf.privateKinds[name] {
            // Only a getter/setter pair may share a name.
            if existing == JSVarKindEnum.JS_VAR_PRIVATE_GETTER_SETTER.rawValue &&
               kind == .JS_VAR_PRIVATE_GETTER_SETTER {
                return true
            }
            syntaxError("duplicate private name")
            return false
        }
        cf.privateKinds[name] = kind.rawValue
        _ = defineVar(name, isConst: false, isLexical: true, varKind: kind.rawValue)
        if kind == .JS_VAR_PRIVATE_FIELD {
            emitOp(.private_symbol)
            emitAtom(name)
            emitScopePutVarInit(name, scopeLevel: fd.curScope)
        }
        return true
    }

    /// Brand the constructor so `this.#staticMethod()` checks out on it.
    /// Stack in / out: [ctor, proto].
    func addStaticBrand(_ cf: JeffJSClassFieldsCtx) {
        guard !cf.staticBrandAdded else { return }
        cf.staticBrandAdded = true
        emitOp(.swap)        // [proto, ctor]
        emitOp(.dup)         // [proto, ctor, ctor]
        emitOp(.dup)         // [proto, ctor, ctor, ctor]
        emitOp(.add_brand)   // [proto, ctor]
        emitOp(.swap)        // [ctor, proto]
    }

    /// Brand every instance: patches the placeholder reserved at the start of
    /// the instance field initializer with
    /// `push_this; special_object(home_object); add_brand`.
    func addInstanceBrand(_ cf: JeffJSClassFieldsCtx) {
        guard !cf.instanceBrandAdded else { return }
        let initFd = ensureFieldsInitFd(cf)
        guard cf.brandPatchPos >= 0,
              cf.brandPatchPos + 4 <= initFd.byteCode.buf.count else { return }
        cf.instanceBrandAdded = true
        let p = cf.brandPatchPos
        initFd.byteCode.buf[p] = UInt8(truncatingIfNeeded: JeffJSOpcode.push_this.rawValue)
        initFd.byteCode.buf[p + 1] = UInt8(truncatingIfNeeded: JeffJSOpcode.special_object.rawValue)
        initFd.byteCode.buf[p + 2] = SpecialObjectType.homeObject.rawValue
        initFd.byteCode.buf[p + 3] = UInt8(truncatingIfNeeded: JeffJSOpcode.add_brand.rawValue)
    }

    /// The instance field initializer function, created on first use with a
    /// 4-byte NOP placeholder for the brand prologue.
    @discardableResult
    func ensureFieldsInitFd(_ cf: JeffJSClassFieldsCtx) -> JeffJSFunctionDefCompiler {
        if let f = cf.fieldsInitFd { return f }
        let child = makeSyntheticFd(name: classFieldsInitAtom)
        cf.fieldsInitFd = child
        withSyntheticFd(child) {
            cf.brandPatchPos = fd.byteCode.len
            for _ in 0 ..< 4 { emitOp(.nop) }
            fd.bodyBytecodeStart = fd.byteCode.len
        }
        return child
    }

    // =========================================================================
    // MARK: - Class definition
    // =========================================================================

    func parseClassDeclaration() {
        parseClassDef(isExpression: false)
    }

    /// Parse a class definition (declaration or expression).
    func parseClassDef(isExpression: Bool) {
        // A class constructor's source text is the whole `class ... { ... }`.
        let classStart = s.token.ptr
        expect(JSTokenType.TOK_CLASS.rawValue)

        var className: JSAtom = 0
        if tok == JSTokenType.TOK_IDENT.rawValue {
            className = s.token.identAtom
            next()
        } else if !isExpression {
            syntaxError("expected class name")
            return
        }

        // Heritage clause
        var hasExtends = false
        if tok == JSTokenType.TOK_EXTENDS.rawValue {
            hasExtends = true
            next()
            parseAssignExpr() // superclass expression -- pushes it on stack
        }

        // Class body
        expect(0x7B) // '{'
        let scopeIdx = pushScope()

        let cf = JeffJSClassFieldsCtx()
        cf.className = className
        cf.classScope = fd.curScope
        cf.hasExtends = hasExtends

        // The inner class binding: visible to methods and to static
        // initializers, initialised as soon as the constructor exists.
        if className != 0 {
            _ = defineVar(className, isConst: true, isLexical: true)
        }
        // <class_fields_init> starts out undefined: a class without instance
        // fields and without private instance methods has nothing to run.
        let fieldsInitAtom = classFieldsInitAtom
        _ = defineVar(fieldsInitAtom, isConst: false, isLexical: true)
        emitOp(.undefined)
        emitScopePutVarInit(fieldsInitAtom, scopeLevel: fd.curScope)

        // Create a default constructor first.  If parseClassBody finds an
        // explicit constructor it will replace this one on the stack.
        do {
            let defaultCtorFd = JeffJSFunctionDefCompiler()
            defaultCtorFd.parent = fd
            defaultCtorFd.funcName = className
            defaultCtorFd.newTargetAllowed = true
            defaultCtorFd.definedScopeLevel = fd.curScope
            if hasExtends {
                defaultCtorFd.isDerivedClassConstructor = true
                defaultCtorFd.superCallAllowed = true
            }
            fd.childFunctions.append(defaultCtorFd)
            cf.ctorFd = defaultCtorFd

            let savedFd = fd
            fd = defaultCtorFd
            if hasExtends {
                // constructor(...args) { super(...args); }
                // `this` is uninitialised until super() returns (QuickJS
                // semantics): construct the parent with our new.target and
                // bind the result as `this`.
                emitOp(.undefined)       // dummy popped by get_super
                emitOp(.get_super)       // [parentCtor]
                emitOp(.special_object)
                emitU8(SpecialObjectType.newTarget.rawValue)   // [parentCtor, newTarget]
                emitOp(.rest)
                emitU16(0)               // [parentCtor, newTarget, argsArray]
                emitOp(.apply_constructor)
                emitU16(0)               // [result]
                emitOp(.init_this)       // [this]
                emitClassFieldInit()
                emitOp(.drop)
            } else {
                emitClassFieldInit()
            }
            emitOp(.return_undef)
            fd = savedFd

            let cpoolIdx = addConstPoolValue(.mkVal(tag: .undefined, val: 0))
            emitFClosure(cpoolIdx)
        }

        // Build prototype object.
        // For extends: stack has superclass; build proto with
        //              proto.__proto__ = superclass.prototype.
        //              Keep superclass below ctor+proto for later __proto__ setup.
        // For no extends: build a plain object as proto.
        if hasExtends {
            // Stack: ..., superclass, ctorFunc
            emitOp(.swap)                            // ..., ctorFunc, superclass
            // `class X extends null` is legal: the proto parent is null, not
            // null.prototype (which would throw), and the constructor keeps
            // %Function.prototype% as its own [[Prototype]] (see below).
            let protoParentNull = newLabel()
            let protoParentDone = newLabel()
            emitOp(.dup)                             // ..., ctorFunc, superclass, superclass
            emitOp(.is_null)                         // ..., ctorFunc, superclass, isNull
            emitIfTrue(protoParentNull)
            emitOp(.dup)                             // ..., ctorFunc, superclass, superclass
            emitGetField(getAtom("prototype"))       // ..., ctorFunc, superclass, superclass.prototype
            emitGoto(protoParentDone)
            emitLabel(protoParentNull)
            emitOp(.push_null)                       // ..., ctorFunc, superclass, null
            emitLabel(protoParentDone)
            emitOp(.object)                          // ..., ctorFunc, superclass, protoParent, proto
            emitOp(.swap)                            // ..., ctorFunc, superclass, proto, superclass.prototype
            emitOp(.set_proto)                       // ..., ctorFunc, superclass, proto
            //                                          (proto.__proto__ = superclass.prototype)
            // Move superclass below ctorFunc.
            emitOp(.rot3l)                           // ..., superclass, proto, ctorFunc
            emitOp(.swap)                            // ..., superclass, ctorFunc, proto
        } else {
            // Stack: ..., ctorFunc
            emitOp(.object)                          // ..., ctorFunc, proto
        }

        // Stack (extends): ..., superclass, ctorFunc, proto
        // Stack (base):    ..., ctorFunc, proto
        //
        // parseClassBody always has ctorFunc below proto.  If an explicit
        // constructor is found, it replaces the default ctorFunc in place.
        parseClassBody(className: className, hasExtends: hasExtends, cf: cf)

        // Stack (extends): ..., superclass, ctorFunc, proto
        // Stack (base):    ..., ctorFunc, proto

        // Publish the instance field initializer (with the prototype as its
        // home object, so `super.x` inside a field initializer works).
        if let initFd = cf.fieldsInitFd {
            withSyntheticFd(initFd) { emitOp(.return_undef) }
            emitOp(.dup)                             // ..., ctorFunc, proto, proto
            emitSyntheticClosure(initFd)             // ..., ctorFunc, proto, proto, init
            emitOp(.swap)                            // ..., ctorFunc, proto, init, proto
            emitOp(.set_home_object)
            emitOp(.drop)                            // ..., ctorFunc, proto, init
            emitScopePutVarInit(fieldsInitAtom, scopeLevel: fd.curScope)
        }

        // Wire up ctorFunc.prototype = proto. Class members are never
        // enumerable, so bit 3 (`enumerable`) stays clear; bit 4 marks it as
        // the class's own `prototype`, which is also non-writable and
        // non-configurable (ES2023 15.7.14 step 12).
        emitOp(.dup2)                                // ..., [sc,] ctorFunc, proto, ctorFunc, proto
        emitOp(.define_method)
        emitAtom(getAtom("prototype"))
        emitU8(DefineMethodFlags.classPrototype.rawValue)  // ..., ctorFunc, proto, ctorFunc
        emitOp(.drop)                                // ..., [sc,] ctorFunc, proto

        // Wire up proto.constructor = ctorFunc. define_method also makes the
        // prototype the constructor's [[HomeObject]], so `super.m()` works in
        // a constructor body (QuickJS js_op_define_class).
        emitOp(.dup2)                                // ..., [sc,] ctorFunc, proto, ctorFunc, proto
        emitOp(.swap)                                // ..., [sc,] ctorFunc, proto, proto, ctorFunc
        emitOp(.define_method)
        emitAtom(getAtom("constructor"))
        emitU8(DefineMethodFlags.method.rawValue)    // ..., [sc,] ctorFunc, proto, proto
        emitOp(.drop)                                // ..., [sc,] ctorFunc, proto

        // Set the constructor's name
        if className != 0 {
            emitOp(.swap)                            // ..., [sc,] proto, ctorFunc
            emitOp(.set_name)
            emitAtom(className)                      // ..., [sc,] proto, ctorFunc   (ctorFunc.name = className)
            emitOp(.swap)                            // ..., [sc,] ctorFunc, proto
        }

        // Drop proto, keep ctorFunc
        emitOp(.drop)                                // ..., [sc,] ctorFunc

        if hasExtends {
            // Set ctorFunc.__proto__ = superclass (for super() and static inheritance)
            // Stack: ..., superclass, ctorFunc
            emitOp(.swap)                            // ..., ctorFunc, superclass
            // `extends null`: the constructor keeps %Function.prototype%.
            let ctorProtoSkip = newLabel()
            emitOp(.dup)                             // ..., ctorFunc, superclass, superclass
            emitOp(.is_null)                         // ..., ctorFunc, superclass, isNull
            emitIfTrue(ctorProtoSkip)
            emitOp(.set_proto)                       // ..., ctorFunc   (ctorFunc.__proto__ = superclass)
            let ctorProtoDone = newLabel()
            emitGoto(ctorProtoDone)
            emitLabel(ctorProtoSkip)
            emitOp(.drop)                            // ..., ctorFunc
            emitLabel(ctorProtoDone)
        }

        // The inner class binding is initialised before any static
        // initializer runs (`static b = B.a + 1`).
        if className != 0 {
            emitOp(.dup)
            emitScopePutVarInit(className, scopeLevel: fd.curScope)
        }

        // Static fields and `static { }` blocks, in source order, each with
        // `this` = the class.
        for initVar in cf.staticInitVars {
            emitOp(.dup)                                        // [ctor, ctor]
            emitScopeGetVar(initVar, scopeLevel: fd.curScope)   // [ctor, ctor, fn]
            emitCallMethod(0)                                   // [ctor, result]
            emitOp(.drop)                                       // [ctor]
        }

        popScope(scopeIdx)
        expect(0x7D) // '}'
        if let ctorFd = cf.ctorFd {
            recordSource(ctorFd, from: classStart)
        }

        if !isExpression && className != 0 {
            let varIdx = defineVar(className, isConst: true, isLexical: true)
            emitScopePutVarInit(className, scopeLevel: fd.curScope)
            _ = varIdx
        }
    }

    // =========================================================================
    // MARK: - Class body
    // =========================================================================

    /// Parse the body of a class (between { }).
    /// On entry the stack has: ..., [superclass,] ctorFunc, proto.
    /// ctorFunc is the default constructor created by parseClassDef.
    /// If an explicit constructor method is found, it replaces ctorFunc.
    /// On exit the stack is: ..., [superclass,] ctorFunc, proto.
    @discardableResult
    func parseClassBody(className: JSAtom, hasExtends: Bool,
                        cf: JeffJSClassFieldsCtx) -> Bool {
        let constructorAtom = getAtom("constructor")
        var ctorFound = false

        while tok != 0x7D && tok != JSTokenType.TOK_EOF.rawValue && !shouldAbort {
            if tok == 0x3B { // ';' -- empty member
                next()
                continue
            }

            var isStatic = false
            var isComputed = false
            var isAsync = false
            var isGenerator = false
            var isPrivate = false
            var propKind: PropertyKind = .method

            // Check for 'static'
            if tok == JSTokenType.TOK_STATIC.rawValue {
                let nextTok = s.simpleNextToken()
                // `static` is also a valid member name: `static = 1`, `static(){}`.
                if nextTok != 0x28 && nextTok != 0x3D && nextTok != 0x3B {
                    isStatic = true
                    next()
                }
            }

            // static { ... } -- class static initialization block
            if isStatic && tok == 0x7B {
                parseClassStaticBlock(cf: cf)
                continue
            }

            // First byte of this member's source text. QuickJS excludes the
            // `static` prefix but keeps `async` / `*` / `get` / `set`.
            let memberStart = s.token.ptr

            // Check for 'async' — [no LineTerminator here] between async and method name
            if isIdent("async") {
                let nextTok = s.simpleNextToken()
                if nextTok != 0x28 && nextTok != 0x3D && // not method() or =
                   nextTok != 0x3B && nextTok != 0x7D {  // not ; or }
                    let savedBufPtr = s.bufPtr
                    let savedLineNum = s.lineNum
                    let savedToken = s.token
                    let savedGotLF = s.gotLF
                    let savedLastLineNum = s.lastLineNum
                    let savedLastPtr = s.lastPtr
                    let savedTemplateNest = s.templateNestLevel
                    let savedLastTokenType = s.lastTokenType

                    next() // consume 'async'
                    if !s.gotLF {
                        isAsync = true
                    } else {
                        // LF between async and method name — backtrack
                        s.bufPtr = savedBufPtr
                        s.lineNum = savedLineNum
                        s.token = savedToken
                        s.gotLF = savedGotLF
                        s.lastLineNum = savedLastLineNum
                        s.lastPtr = savedLastPtr
                        s.templateNestLevel = savedTemplateNest
                        s.lastTokenType = savedLastTokenType
                    }
                }
            }

            // Check for generator '*'
            if tok == 0x2A { // '*'
                isGenerator = true
                next()
            }

            // Check for getter/setter
            if isIdent("get") && !isGenerator && !isAsync {
                let nextTok = s.simpleNextToken()
                if nextTok != 0x28 && nextTok != 0x3D && nextTok != 0x3B {
                    propKind = .getter
                    next()
                }
            } else if isIdent("set") && !isGenerator && !isAsync {
                let nextTok = s.simpleNextToken()
                if nextTok != 0x28 && nextTok != 0x3D && nextTok != 0x3B {
                    propKind = .setter
                    next()
                }
            }

            // Parse property name
            var propAtom: JSAtom = 0
            if tok == 0x5B { // '[' computed property
                isComputed = true
                next()
                parseAssignExpr()
                expect(0x5D) // ']'
                emitOp(.to_propkey)
            } else if tok == JSTokenType.TOK_IDENT.rawValue ||
                      tok == JSTokenType.TOK_STRING.rawValue {
                if tok == JSTokenType.TOK_IDENT.rawValue {
                    propAtom = s.token.identAtom
                } else {
                    propAtom = getAtom(s.token.strValue)
                }
                next()
            } else if tok == JSTokenType.TOK_NUMBER.rawValue {
                propAtom = getAtom(JeffJSBuiltinNumber.numberToStringBase10(s.token.numValue))  // "%.0f" named `1.5(){}` "2"
                next()
            } else if tok == JSTokenType.TOK_PRIVATE_NAME.rawValue {
                propAtom = s.token.identAtom
                isPrivate = true
                next()
            } else if isKeywordToken(tok) {
                // Keywords are valid as method/property names in classes
                let kwName = keywordTokenName(tok)
                propAtom = getAtom(kwName)
                next()
            } else {
                syntaxError("expected property name")
                return ctorFound
            }

            // Check for field (no parentheses after name)
            if tok != 0x28 && propKind == .method { // not a method
                parseClassField(cf: cf, propAtom: propAtom, isStatic: isStatic,
                                isComputed: isComputed, isPrivate: isPrivate)
                continue
            }

            // Detect whether this is the class constructor
            let isConstructor = !isStatic && !isComputed && !isPrivate &&
                                propAtom == constructorAtom && propKind == .method

            // Parse method
            expect(0x28) // '('

            let methodFd = JeffJSFunctionDefCompiler()
            methodFd.parent = fd
            methodFd.funcName = accessorFuncName(propKind, propAtom,
                                                 isComputed: isComputed, isPrivate: isPrivate)
            methodFd.definedScopeLevel = fd.curScope
            if isGenerator {
                methodFd.funcKind = isAsync
                    ? JSFunctionKindEnum.JS_FUNC_ASYNC_GENERATOR.rawValue
                    : JSFunctionKindEnum.JS_FUNC_GENERATOR.rawValue
            } else if isAsync {
                methodFd.funcKind = JSFunctionKindEnum.JS_FUNC_ASYNC.rawValue
            }
            if isConstructor {
                methodFd.newTargetAllowed = true
                methodFd.funcName = className
                if hasExtends {
                    methodFd.isDerivedClassConstructor = true
                    methodFd.superCallAllowed = true
                } else {
                    // A base-class constructor runs the instance field
                    // initializers before its own body.
                    methodFd.emitFieldInitAtBodyStart = true
                }
            }
            fd.childFunctions.append(methodFd)
            if isConstructor {
                // The class span is stamped on it once the class body closes.
                cf.ctorFd = methodFd
            }

            let (mDefaults, mRest, mDstructs) = parseFormalParameters(childFd: methodFd)
            expect(0x29) // ')'
            expect(0x7B) // '{'
            parseFunctionBody(childFd: methodFd, defaults: mDefaults, rest: mRest, destructs: mDstructs)
            expect(0x7D) // '}'
            if !isConstructor {
                recordSource(methodFd, from: memberStart)
            }

            let cpoolIdx = addConstPoolValue(.mkVal(tag: .undefined, val: 0))
            emitFClosure(cpoolIdx)

            if isConstructor {
                // Replace the current ctorFunc (default or previous) with
                // the explicit constructor.
                // Stack: ..., ctorFunc, proto, newCtorFunc
                emitOp(.rot3l)   // ..., proto, newCtorFunc, ctorFunc
                emitOp(.drop)    // ..., proto, newCtorFunc
                emitOp(.swap)    // ..., newCtorFunc, proto
                ctorFound = true
            } else if isPrivate {
                definePrivateMethod(cf: cf, propAtom: propAtom,
                                    isStatic: isStatic, propKind: propKind)
            } else {
                // Regular method -- define it on proto (or ctor for static).
                if isStatic {
                    // For static methods, define on the constructor.
                    // Stack: ..., ctorFunc, proto, methodFunc
                    // Rearrange so ctorFunc is below methodFunc for define_method.
                    emitOp(.rot3l)   // ..., proto, methodFunc, ctorFunc
                    emitOp(.swap)    // ..., proto, ctorFunc, methodFunc
                    if isComputed {
                        emitOp(.define_method_computed)
                        emitU8(classMethodFlags(propKind))
                    } else {
                        emitOp(.define_method)
                        emitAtom(propAtom)
                        emitU8(classMethodFlags(propKind))
                    }
                    // Stack: ..., proto, ctorFunc
                    emitOp(.swap)    // ..., ctorFunc, proto
                } else if isComputed {
                    emitOp(.define_method_computed)
                    emitU8(classMethodFlags(propKind))
                } else {
                    emitOp(.define_method)
                    emitAtom(propAtom)
                    emitU8(classMethodFlags(propKind))
                }
            }
        }
        return ctorFound
    }

    /// `#m(){}`, `get #g(){}`, `set #s(v){}`, `static #m(){}`.
    /// Stack in / out: [ctorFunc, proto]; the closure is on top on entry.
    private func definePrivateMethod(cf: JeffJSClassFieldsCtx, propAtom: JSAtom,
                                     isStatic: Bool, propKind: PropertyKind) {
        let isAccessor = (propKind == .getter || propKind == .setter)
        let kind: JSVarKindEnum = isAccessor
            ? .JS_VAR_PRIVATE_GETTER_SETTER : .JS_VAR_PRIVATE_METHOD
        let firstDecl = cf.privateKinds[propAtom] == nil
        declarePrivateName(cf, propAtom, kind: kind)

        // Home object: the prototype for an instance method, the constructor
        // for a static one — that is what the brand check compares against.
        if isStatic {
            // [ctor, proto, func] -> home = ctor
            emitOp(.rot3l)             // [proto, func, ctor]
            emitOp(.set_home_object)   // (func, ctor)
            emitOp(.swap)              // [proto, ctor, func]
        } else {
            // [ctor, proto, func] -> home = proto
            emitOp(.swap)              // [ctor, func, proto]
            emitOp(.set_home_object)   // (func, proto)
            emitOp(.swap)              // [ctor, proto, func]
        }

        // Store the closure. Accessors additionally land in a dedicated
        // <get:#x> / <set:#x> variable so a read picks the getter and a write
        // the setter; the plain name always holds one of them, which is all
        // the brand check (`#x in o`) needs.
        if isAccessor {
            let accessorAtom = privateAccessorAtom(propAtom, isSetter: propKind == .setter)
            _ = defineVar(accessorAtom, isConst: false, isLexical: true,
                          varKind: (propKind == .setter
                                    ? JSVarKindEnum.JS_VAR_PRIVATE_SETTER.rawValue
                                    : JSVarKindEnum.JS_VAR_PRIVATE_GETTER.rawValue))
            if firstDecl {
                emitOp(.dup)
                emitScopePutVarInit(propAtom, scopeLevel: cf.classScope)
            }
            emitScopePutVarInit(accessorAtom, scopeLevel: cf.classScope)
        } else {
            emitScopePutVarInit(propAtom, scopeLevel: cf.classScope)
        }

        if isStatic {
            emitOp(.swap)              // [ctor, proto]
            addStaticBrand(cf)
        } else {
            addInstanceBrand(cf)
        }
    }

    /// A class field: `x = 1`, `#x = 1`, `[k] = 1`, `static x = 1`, ...
    /// Stack in: [ctorFunc, proto(, key)]; out: [ctorFunc, proto].
    private func parseClassField(cf: JeffJSClassFieldsCtx, propAtom: JSAtom,
                                 isStatic: Bool, isComputed: Bool, isPrivate: Bool) {
        // A computed key is evaluated here, at class definition time and in
        // source order (ES2022 ClassDefinitionEvaluation), then kept in a
        // class-scope variable until the initializer runs.
        var keyVar: JSAtom = 0
        if isComputed {
            keyVar = defineSyntheticClassVar("<computed_field_")
            emitScopePutVarInit(keyVar, scopeLevel: cf.classScope)
        }
        if isPrivate {
            declarePrivateName(cf, propAtom, kind: .JS_VAR_PRIVATE_FIELD)
        }

        let initFd: JeffJSFunctionDefCompiler
        if isStatic {
            initFd = makeSyntheticFd(name: propAtom)
        } else {
            initFd = ensureFieldsInitFd(cf)
        }

        // The initializer runs with `this` = the instance (or the class, for a
        // static field), so it is compiled into the synthetic function, not
        // here.
        let hasInit = (tok == 0x3D)
        if hasInit { next() }
        withSyntheticFd(initFd) {
            emitOp(.push_this)
            if isPrivate {
                emitScopeGetVar(propAtom, scopeLevel: fd.curScope)  // private symbol
            } else if isComputed {
                emitScopeGetVar(keyVar, scopeLevel: fd.curScope)
            }
            if hasInit {
                parseAssignExpr()
            } else {
                emitOp(.undefined)
            }
            if isPrivate {
                emitOp(.define_private_field)   // [obj, sym, val] -> []
            } else if isComputed {
                emitOp(.define_array_el)        // [obj, key, val] -> [obj, nextIdx]
                emitOp(.drop)
                emitOp(.drop)
            } else {
                emitDefineField(propAtom)       // [obj, val] -> [obj]
                emitOp(.drop)
            }
        }
        expectSemicolon()

        if isStatic {
            // Defer the initializer: it must see the finished class object.
            withSyntheticFd(initFd) { emitOp(.return_undef) }
            emitSyntheticClosure(initFd)   // [ctor, proto, init]
            emitOp(.rot3l)                 // [proto, init, ctor]
            emitOp(.set_home_object)
            emitOp(.swap)                  // [proto, ctor, init]
            let initVar = defineSyntheticClassVar("<static_init_")
            emitScopePutVarInit(initVar, scopeLevel: cf.classScope)
            emitOp(.swap)                  // [ctor, proto]
            cf.staticInitVars.append(initVar)
        }
    }

    /// Flags byte for `define_method` on a class member: the accessor kind
    /// only. Bit 3 (`enumerable`) is deliberately clear — class members are
    /// non-enumerable (ES §15.7.11); only object literals set it.
    func classMethodFlags(_ propKind: PropertyKind) -> UInt8 {
        return (propKind == .getter ? DefineMethodFlags.getter.rawValue : 0) |
               (propKind == .setter ? DefineMethodFlags.setter.rawValue : 0)
    }

    /// `static { ... }`: a synthetic function run once with `this` = the class.
    private func parseClassStaticBlock(cf: JeffJSClassFieldsCtx) {
        expect(0x7B) // '{'
        let blockFd = makeSyntheticFd(name: getAtom("<static_block>"))
        withSyntheticFd(blockFd) {
            fd.bodyBytecodeStart = fd.byteCode.len
            while tok != 0x7D && tok != JSTokenType.TOK_EOF.rawValue && !shouldAbort {
                parseSourceElement()
            }
            emitOp(.return_undef)
        }
        expect(0x7D) // '}'

        emitSyntheticClosure(blockFd)  // [ctor, proto, block]
        emitOp(.rot3l)                 // [proto, block, ctor]
        emitOp(.set_home_object)
        emitOp(.swap)                  // [proto, ctor, block]
        let initVar = defineSyntheticClassVar("<static_init_")
        emitScopePutVarInit(initVar, scopeLevel: cf.classScope)
        emitOp(.swap)                  // [ctor, proto]
        cf.staticInitVars.append(initVar)
    }
}
