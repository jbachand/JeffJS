# Report a sampler file: self time by function (leaf pc), and time by the engine function on top of the stack
# (library time charged to the engine function that called into it).
import sys,subprocess,re,collections
cli,f=sys.argv[1],sys.argv[2]; N=int(sys.argv[3]) if len(sys.argv)>3 else 30
L=open(f).read().split('\n'); base=int(L[0].split()[1],16); total=int(L[1].split()[1])
rows=[l.split() for l in L[2:] if l.strip()]
leaf=[(int(r[1],16),int(r[2])) for r in rows if r[0]=='L']
eng=[(int(r[1],16),int(r[2])) for r in rows if r[0]=='E']
lib=collections.Counter()
for r in rows:
    if r[0]=='L' and len(r)>3: lib[r[3]]+=int(r[2])
def sym(rows):
    inexe=[(pc,n) for pc,n in rows if base<=pc<base+0x4000000]
    out=collections.Counter(); out['<outside the executable>']=sum(n for pc,n in rows if not(base<=pc<base+0x4000000))
    addrs=[hex(pc-base+0x100000000) for pc,_ in inexe]
    names=[]
    for off in range(0,len(addrs),2000):
        names+=subprocess.run(['xcrun','atos','-o',cli,'-l','0x100000000']+addrs[off:off+2000],capture_output=True,text=True).stdout.strip().split('\n')
    for (pc,n),nm in zip(inexe,names): out[re.sub(r' \(in .*','',nm)[:78]]+=n
    return out
print('samples',total)
print('== self time (leaf)');
for k,v in sym(leaf).most_common(N): print(f'  {100*v/total:5.1f}%  {k}')
print('== outside the executable, by library symbol')
for k,v in lib.most_common(22): print(f'  {100*v/total:5.1f}%  {k[:70]}')
print('== by engine function on the stack (library time charged to its caller)')
for k,v in sym(eng).most_common(N): print(f'  {100*v/total:5.1f}%  {k}')
