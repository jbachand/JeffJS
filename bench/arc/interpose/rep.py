import sys,subprocess,collections,re,os
cli,cnt,N=sys.argv[1],sys.argv[2],int(sys.argv[3]); R=os.path.expanduser('~/www/rnly-agents/engine-B/Sources/JeffJS/')
lines=open(cnt).read().split('\n')
base=int(lines[0].split()[1],16); tot=lines[1].split()[1:]
rows=[]
for l in lines[2:]:
    p=l.split()
    if len(p)==7: rows.append((int(p[0],16),[int(x) for x in p[3:]],int(p[1],16),int(p[2],16)))
agg=collections.Counter(); aggf=collections.Counter()
def sym(a):
    o=subprocess.run(['atos','-i','-o',cli,'-l',hex(base),'-fullPath',hex(a-1)],capture_output=True,text=True).stdout.strip().splitlines()
    return o
exe=[r for r in rows if base<=r[0]<base+0x2000000]
other=[r for r in rows if not(base<=r[0]<base+0x2000000)]
print('in-exe',sum(sum(r[1]) for r in exe),'other (runtime-internal)',sum(sum(r[1]) for r in other))
rows=exe
rows.sort(key=lambda r:-sum(r[1]))
print('TOTAL retain/release/bridgeRetain/bridgeRelease',tot)
ts=sum(sum(r[1]) for r in rows)
for a,n,a1,a2 in rows[:N]:
    o=sym(a); o1=sym(a1) if a1 else []; o2=sym(a2) if a2 else []
    ch=[]
    for x in o:
        m=re.match(r'(.*?) \(in [^)]*\)(?: \((.*?):(\d+)\))?',x)
        if m: ch.append((m.group(1)[:48],(m.group(2) or '').split('/')[-1],m.group(3) or ''))
    inner=next(((f,l) for fn,f,l in ch if l and l!='0' and 'compiler' not in f),('',''))
    txt=''
    if inner[0]:
        try:
            for root,_,fs in os.walk(R):
                if inner[0] in fs: txt=open(os.path.join(root,inner[0])).read().split('\n')[int(inner[1])-1].strip()[:70]; break
        except: pass
    c1=(re.match(r'(.*?) \(in',o1[0]).group(1)[:40] if o1 and re.match(r'(.*?) \(in',o1[0]) else '')
    c2=(re.match(r'(.*?) \(in',o2[0]).group(1)[:34] if o2 and re.match(r'(.*?) \(in',o2[0]) else '')
    print(f'{sum(n):10d} {n[0]:9d}r {n[1]:9d}R {n[2]:8d}b {n[3]:8d}B  {ch[-1][0] if ch else "?":40s} <- {c1:34s} <- {c2:34s} {inner[0]}:{inner[1]}  {txt}')
