import os
import sys,pickle,subprocess,collections,re
b=sys.argv[1]; N=int(sys.argv[2]); R=''+os.path.expanduser("~/www/rnly-agents/engine-B/")+''
byaddr,bykind,load,total=pickle.load(open(b+'.pkl','rb'))
addrs=sorted(byaddr,key=lambda a:-byaddr[a])[:600]
agg=collections.Counter(); outer=collections.Counter(); first={}
cover=0
for a in addrs:
    out=subprocess.run(['atos','-i','-o','cli-base','-l',load,'-fullPath',hex(a)],capture_output=True,text=True).stdout.strip().splitlines()
    ch=[]
    for l in out:
        m=re.match(r'(.*?) \(in [^)]*\) \((.*?):(\d+)\)',l)
        if m: ch.append((m.group(1),m.group(2),int(m.group(3))))
    # innermost frame with real line (>0) and not compiler-generated
    key=None
    for fn,f,ln in ch:
        if ln>0 and 'compiler-generated' not in f: key=(f.split('Sources/JeffJS/')[-1],ln); break
    if key is None: key=('?:'+(ch[0][0][:50] if ch else '?'),0)
    agg[key]+=byaddr[a]
    of=ch[-1][0][:70] if ch else '?'
    outer[of]+=byaddr[a]
print('top outer functions:')
for k,v in outer.most_common(14): print(f'{v:6.0f} {100*v/total:4.1f}% {k}')
print('\ntop innermost source lines:')
for (f,l),v in agg.most_common(N):
    txt=''
    if l:
        try: txt=open(R+'Sources/JeffJS/'+f).read().split('\n')[l-1].strip()[:90]
        except Exception as e: txt=''
    print(f'{v:6.0f} {100*v/total:4.1f}% {f}:{l}  {txt}')
