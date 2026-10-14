import sys,subprocess,collections,re
def load(cli,cnt):
    L=open(cnt).read().split('\n'); base=int(L[0].split()[1],16)
    c=collections.Counter()
    for l in L[2:]:
        p=l.split()
        if len(p)==7:
            a=int(p[0],16)
            if base<=a<base+0x2000000: c[a]+=sum(map(int,p[3:]))
    addrs=list(c); f=collections.Counter()
    for a in addrs:
        out=subprocess.run(['atos','-i','-o',cli,'-l',hex(base),'-fullPath',hex(a-1)],capture_output=True,text=True).stdout.splitlines()
        key=None
        for o in out:
            m=re.match(r'(.*?) \(in [^)]*\) \((.*?):(\d+)\)',o)
            if m and m.group(3)!='0' and 'compiler' not in m.group(2): key=m.group(2).split('/')[-1]+':'+m.group(3); break
        if key is None: key='?'+(out[-1][:50] if out else '')
        f[key]+=c[a]
    return f
a=load(sys.argv[1],sys.argv[2]); b=load(sys.argv[3],sys.argv[4])
d={k:b.get(k,0)-a.get(k,0) for k in set(a)|set(b)}
for k,v in sorted(d.items(),key=lambda x:-abs(x[1]))[:int(sys.argv[5])]: print(f'{v:+11d} {a.get(k,0):10d} -> {b.get(k,0):10d}  {k}')
