import sys,subprocess,collections,re
def load(cli,cnt):
    L=open(cnt).read().split('\n'); base=int(L[0].split()[1],16)
    c=collections.Counter(); 
    for l in L[2:]:
        p=l.split()
        if len(p)==7:
            a=int(p[0],16)
            if base<=a<base+0x2000000: c[a]+=sum(map(int,p[3:]))
    addrs=list(c); names={}
    for i in range(0,len(addrs),200):
        ch=addrs[i:i+200]
        out=subprocess.run(['atos','-o',cli,'-l',hex(base)]+[hex(a-1) for a in ch],capture_output=True,text=True).stdout.splitlines()
        for a,o in zip(ch,out): names[a]=re.sub(r' \(in .*','',o)[:70]
    f=collections.Counter()
    for a,n in c.items(): f[names[a]]+=n
    return f
a=load(sys.argv[1],sys.argv[2]); b=load(sys.argv[3],sys.argv[4])
d={k:b.get(k,0)-a.get(k,0) for k in set(a)|set(b)}
for k,v in sorted(d.items(),key=lambda x:-abs(x[1]))[:int(sys.argv[5])]: print(f'{v:+11d} {a.get(k,0):10d} -> {b.get(k,0):10d}  {k}')
