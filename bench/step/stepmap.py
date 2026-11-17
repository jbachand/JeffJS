# Map a single-step PC histogram to source: per outermost source line and per enclosing `case .op` label.
# usage: stepmap.py <cli> <step-file> <interp-source> <iterations> [N]
import sys,subprocess,re,collections,json
cli,stepf,src,iters=sys.argv[1],sys.argv[2],sys.argv[3],float(sys.argv[4]); N=int(sys.argv[5]) if len(sys.argv)>5 else 40
L=open(stepf).read().split('\n'); base=int(L[0].split()[1],16)
rows=[(int(a,16),int(b)) for a,b in (l.split() for l in L[2:] if l.strip())]
total=sum(n for _,n in rows)
exe=[(pc,n) for pc,n in rows if base<=pc<base+0x4000000]; other=total-sum(n for _,n in exe)
addrs=[hex(pc-base+0x100000000) for pc,_ in exe]
out=[]
for off in range(0,len(addrs),1500):
    res=subprocess.run(['xcrun','atos','-i','-o',cli,'-l','0x100000000']+addrs[off:off+1500],capture_output=True,text=True).stdout
    blocks=[b for b in res.split('\n\n')]
    blocks=[[l for l in b.split('\n') if l.strip()] for b in blocks]; blocks=[b for b in blocks if b]
    out+=blocks
assert len(out)==len(exe),(len(out),len(exe))
srcl=open(src).read().split('\n')
# enclosing case label: nearest preceding line that looks like a dispatch-level `case .x` (indent 8..12)
lab=[None]*(len(srcl)+2); cur=None
for i,l in enumerate(srcl,1):
    m=re.match(r'^( {8}| {12})case \.([A-Za-z0-9_]+)',l)
    if m: cur=m.group(2)
    if re.match(r'^(nonisolated |    static |    @inline|    func |private func |func )',l) and 'func ' in l: cur='<'+re.sub(r'.*func ([A-Za-z0-9_]+).*',r'\1',l)+'>'
    lab[i]=cur
byline=collections.Counter(); bycase=collections.Counter(); byfn=collections.Counter(); inner=collections.Counter()
for (pc,n),b in zip(exe,out):
    last=b[-1]; m=re.search(r'^(.*?) \(in [^)]*\) \(([^()]+\.swift):(\d+)\)\s*$',last)
    fn=re.sub(r' \(in .*','',last)[:50]
    byfn[fn]+=n
    if m and m.group(2)=='JeffJSInterpreter.swift':
        ln=int(m.group(3)); byline[ln]+=n; bycase[lab[ln] if ln<len(lab) else '?']+=n
    else:
        bycase['~'+fn[:44]]+=n
    mi=re.search(r'\(([^()]+\.swift):(\d+)\)\s*$',b[0]); inner[(mi.group(1)+':'+mi.group(2)) if mi else re.sub(r' \(in .*','',b[0])[:40]]+=n
print(f'{cli.split("/")[-3] if "build" in cli else cli.split("/")[-2]}: total {total} = {total/iters:.2f}/iter; outside exe {other} = {other/iters:.2f}/iter')
print('-- by function'); 
for k,v in byfn.most_common(8): print(f'  {v/iters:8.2f}  {k}')
print('-- by case label / callee')
for k,v in bycase.most_common(N): print(f'  {v/iters:8.2f}  {k}')
json.dump({'case':dict(bycase),'line':{str(k):v for k,v in byline.items()},'inner':dict(inner),'iters':iters},open(stepf+'.json','w'))
