import sys,pickle,collections,re
b=sys.argv[1]
byaddr,bykind,load,total=pickle.load(open(b+'.pkl','rb'))
res=pickle.load(open(b+'.atos.pkl','rb'))
RULES=[
 ('payload enum copy/destroy (init/destroy/assign JeffJSObjectPayload)', r'JeffJSObjectPayload'),
 ('createClosure / varRefs arrays / var-ref pool', r'createClosure|varRefsFast|setVarRefs|varRefPool|JeffJSObjectAux|JeffJSVarRef|varRefsRaw'),
 ('object/function/array recycle pool + free', r'jeffJS_recycle|freeObject|freeGCObject|JeffJSFastArrayStorage|recycleObject|objectPool|JeffJSObjectPool'),
 ('array alloc (newArray / Array<JeffJSValue> COW,grow)', r'newArray|ContiguousArrayBuffer|_ArrayBuffer|Array\._|installFastArray|newArrayFrom|arrayPayloadSlow'),
 ('GC bookkeeping (addGCObject/removeGCObject/gcObjects)', r'addGCObject|removeGCObject|JeffJSGC'),
 ('native->JS entry (callFunction/callInRealm/dispatchCFunction/nativeCallFromSlots)', r'callFunction|dispatchCFunction|nativeCallFromSlots|callInRealm|callElementCallback|ElementCursor'),
 ('frame / interp-buf pool', r'releaseFrame|acquireFrame|acquireInterpBuf|releaseInterpBuf'),
 ('JSON/String/Swift String', r'JSON|StringGuts|String\.|toSwiftString|JeffJSString|SmallString'),
 ('property get/set/shape lookup', r'getPropertyInternal|setPropertyInternal|findShape|findHashedShape|getOwnPropertyNames|hasProperty|JeffJSShape|definePropert|keyedGet|PropStorage'),
 ('trace interpreter', r'executeFastTrace'),
 ('builtins (Array.prototype etc.)', r'JeffJSBuiltin'),
 ('callInternal', r'callInternal'),
]
cat=collections.Counter(); ci=collections.Counter(); other=collections.Counter()
for a,v in byaddr.items():
    ch=res[a]; names=[c[0] for c in ch]; s=' | '.join(names)
    chosen=None
    for n,p in RULES:
        if re.search(p,s): chosen=n;break
    if chosen=='callInternal':
        ln=[c[2] for c in ch if 'callInternal' in c[0] and c[2]]
        ln=ln[0] if ln else 0
        if ln==0: part='callInternal: unattributed (prologue/epilogue tail)'
        elif ln<7900: part='callInternal: prologue (<7900)'
        elif ln>13600: part='callInternal: epilogue/return (>13600)'
        else: part='callInternal: opcode bodies'
        ci[part]+=v; chosen='callInternal (split below)'
    if chosen is None:
        chosen='other'; other[names[0][:80] if names else '?']+=v
    cat[chosen]+=v
print(f'### {b}: total {total:.0f} ms, ARC+runtime leaf {sum(cat.values()):.0f} ms ({100*sum(cat.values())/total:.1f}%)')
for k,v in cat.most_common(): print(f'{v:7.0f} {100*v/total:5.1f}%  {k}')
for k,v in ci.most_common(): print(f'      {v:7.0f} {100*v/total:5.1f}%  {k}')
print(' other:',[(k,round(v)) for k,v in other.most_common(6)])
