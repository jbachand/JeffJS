# Break the samples that fall inside one function down by enclosing `case .op` label and by source line.
# usage: smpfn.py <cli> <smp-file> <function-substring> <interp-source> [N]
import sys,subprocess,re,collections
cli,f,fnsub,src=sys.argv[1:5]; N=int(sys.argv[5]) if len(sys.argv)>5 else 40
L=open(f).read().split('\n'); base=int(L[0].split()[1],16); total=int(L[1].split()[1])
rows=[l.split() for l in L[2:] if l.strip()]
leaf=[(int(r[1],16),int(r[2])) for r in rows if r[0]=='L' and base<=int(r[1],16)<base+0x4000000]
addrs=[hex(pc-base+0x100000000) for pc,_ in leaf]
out=[]
for off in range(0,len(addrs),1500):
    res=subprocess.run(['xcrun','atos','-i','-o',cli,'-l','0x100000000']+addrs[off:off+1500],capture_output=True,text=True).stdout
    blocks=[[l for l in b.split('\n') if l.strip()] for b in res.split('\n\n')]; out+=[b for b in blocks if b]
assert len(out)==len(leaf)
srcl=open(src).read().split('\n'); lab=[None]*(len(srcl)+2); cur=None
for i,l in enumerate(srcl,1):
    m=re.match(r'^( {8}| {12})case \.([A-Za-z0-9_]+)',l)
    if m: cur=m.group(2)
    lab[i]=cur
bycase=collections.Counter(); byline=collections.Counter(); infn=0; inner=collections.Counter()
for (pc,n),b in zip(leaf,out):
    last=b[-1]
    if fnsub not in last: continue
    infn+=n
    m=re.search(r'\(([^()]+\.swift):(\d+)\)\s*$',last)
    ln=int(m.group(2)) if m and m.group(1)=='JeffJSInterpreter.swift' else 0
    bycase[lab[ln] if 0<ln<len(lab) else '(no line)']+=n; byline[ln]+=n
    mi=re.search(r'^(.*?) \(in [^)]*\)(?: \(([^()]+\.swift):(\d+)\))?',b[0]); 
    if len(b)>1 and mi: inner[mi.group(1)[:60]]+=n
print(f'{fnsub}: {infn} samples = {100*infn/total:.1f}% of {total}')
print('-- by case label (percent of all samples)')
for k,v in bycase.most_common(N): print(f'  {100*v/total:5.2f}%  {k}')
print('-- by source line')
for k,v in byline.most_common(24): print(f'  {100*v/total:5.2f}%  {k}: {srcl[k-1].strip()[:90] if k>0 else ""}')
print('-- by inlined callee')
for k,v in inner.most_common(14): print(f'  {100*v/total:5.2f}%  {k}')
