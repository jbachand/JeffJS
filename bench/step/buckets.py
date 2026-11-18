# buckets.py <cli> <interp-source> <step-file> <iterations>: split a kernel's instructions per iteration into buckets.
import sys,subprocess,re,collections,json,os
cli,src,stepf,iters=sys.argv[1],sys.argv[2],sys.argv[3],float(sys.argv[4])
here=os.path.dirname(os.path.abspath(__file__))
L=open(stepf).read().split('\n'); base=int(L[0].split()[1],16)
rows=[(int(a,16),int(b)) for a,b in (l.split() for l in L[2:] if l.strip())]
total=sum(n for _,n in rows)
exe=[(pc,n) for pc,n in rows if base<=pc<base+0x4000000]; lib=[(pc,n) for pc,n in rows if not(base<=pc<base+0x4000000)]
B=collections.Counter(); detail=collections.Counter()
# library
res=subprocess.run([here+'/symlib'],input='\n'.join(hex(pc) for pc,_ in lib),capture_output=True,text=True).stdout.split('\n')
for (pc,n),l in zip(lib,res):
    s=l.split(' ',1)[1] if ' ' in l else '?'
    if re.search(r'swift_(retain|release|bridgeObject(Retain|Release)|unknownObject|nonatomic|isUniquelyReferenced)|RefCounts|swift_release_dealloc',s): b='refcount (swift ARC)'
    elif re.search(r'malloc|free|xzm|_szone|swift_allocObject|swift_dealloc|swift_slowAlloc|swift_slowDealloc|calloc|realloc|nano|ContiguousArrayStorage|swift_arrayDestroy|swift_initStackObject|bzero|memset',s): b='allocation'
    elif re.search(r'memmove|memcpy|memcmp',s): b='memcpy/memcmp'
    else: b='other library'
    B[b]+=n; detail['lib:'+s[:50]]+=n
# executable
addrs=[hex(pc-base+0x100000000) for pc,_ in exe]; out=[]
for off in range(0,len(addrs),1500):
    r=subprocess.run(['xcrun','atos','-i','-o',cli,'-l','0x100000000']+addrs[off:off+1500],capture_output=True,text=True).stdout
    bl=[[l for l in b.split('\n') if l.strip()] for b in r.split('\n\n')]; out+=[b for b in bl if b]
assert len(out)==len(exe)
srcl=open(src).read().split('\n'); lab=[None]*(len(srcl)+2); cur=None
for i,l in enumerate(srcl,1):
    m=re.match(r'^( {8}| {12})case \.([A-Za-z0-9_]+)',l)
    if m: cur=m.group(2)
    if re.match(r'^(nonisolated |    static |    @inline|    func |private func |func )',l) and 'func ' in l: cur='<'+re.sub(r'.*func ([A-Za-z0-9_]+).*',r'\1',l)+'>'
    lab[i]=cur
LOOPS=('callInternalRaw','executeFastTrace')
opbody=collections.Counter()
for (pc,n),b in zip(exe,out):
    last=b[-1]; fn=re.sub(r' \(in .*','',last)
    m=re.search(r'\(([^()]+\.swift):(\d+)\)\s*$',last)
    if any(x in fn for x in LOOPS) and 'closure' not in fn:
        ln=int(m.group(2)) if m and m.group(1)=='JeffJSInterpreter.swift' else 0
        c=lab[ln] if 0<ln<len(lab) else None
        if m is None or (m and m.group(1)=='<invalid>') or 'invalid' in last: B['dispatch (switch jump)']+=n
        elif ln==0 or c is None: B['compiler glue in the loops (spills, reloads)']+=n
        elif c.startswith('<'): B['call/return frames (loop entry and exit)']+=n
        elif c in('scope_get_var',): B['call/return frames (loop entry and exit)']+=n
        else: B['opcode bodies']+=n; opbody[c]+=n
    elif re.search(r'dupValue|freeValue|DYLD-STUB\$\$swift_(retain|release|bridgeObject)|outlined (copy|destroy|retain|release|consume)|swift_isUniquely',fn): B['refcount (engine + stubs)']+=n; detail['fn:'+fn[:50]]+=n
    elif re.search(r'[gs]etProperty|hasProperty|findShapeProperty|findHashedShape|ShapeProperty|findOwnProperty|rootShape|addProperty|Shape\b|definePropert',fn): B['property lookup and shapes']+=n; detail['fn:'+fn[:50]]+=n
    elif re.search(r'callConstructor|constructBytecode|callFunction|callRetaining|checkStackOverflow|syncBuf|releaseFrame|acquireFrame|StackFrame|jeffJS_call',fn): B['call/return frames (loop entry and exit)']+=n; detail['fn:'+fn[:50]]+=n
    elif re.search(r'DYLD-STUB\$\$(malloc|free|swift_alloc|swift_dealloc|memset|bzero|realloc)|recycleObject|ObjectPool|newObject|GCObject|allocObject|JeffJSString\.(init|__dealloc)|ArrayBuffer|Array\.|ContiguousArray|deinit',fn): B['allocation']+=n; detail['fn:'+fn[:50]]+=n
    else: B['other engine functions (builtins, conversions)']+=n; detail['fn:'+fn[:50]]+=n
# opcodes executed: indirect branches inside the loop functions
lo=min(pc for pc,_ in exe)-base+0x100000000; hi=max(pc for pc,_ in exe)-base+0x100000000+4
ops=0
d=subprocess.run(['xcrun','llvm-objdump','-d','--no-show-raw-insn','--start-address=%d'%lo,'--stop-address=%d'%hi,cli],capture_output=True,text=True).stdout
brs=set(int(m.group(1),16) for m in re.finditer(r'^\s*([0-9a-f]+):\s+br\s+x\d+',d,re.M))
for (pc,n),b in zip(exe,out):
    fn=b[-1]
    if (pc-base+0x100000000) in brs and any(x in fn for x in LOOPS) and 'closure' not in fn: ops+=n
json.dump({'total':total/iters,'ops':ops/iters,'buckets':{k:v/iters for k,v in B.items()},'detail':{k:v/iters for k,v in detail.most_common(25)},'opbody':{k:v/iters for k,v in opbody.most_common(15)}},sys.stdout)
