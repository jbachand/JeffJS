# List the executed instructions of a step histogram in address order with counts/iter and source lines.
# usage: hot.py <cli> <step-file> <iterations> [mincount/iter]
import sys,subprocess,re,collections
cli,stepf,iters=sys.argv[1],sys.argv[2],float(sys.argv[3]); thr=float(sys.argv[4]) if len(sys.argv)>4 else 0.5
L=open(stepf).read().split('\n'); base=int(L[0].split()[1],16)
rows=sorted((int(a,16),int(b)) for a,b in (l.split() for l in L[2:] if l.strip()))
rows=[(pc,n) for pc,n in rows if n/iters>=thr and base<=pc<base+0x4000000]
lo=rows[0][0]-base+0x100000000; hi=rows[-1][0]-base+0x100000000+4
d=subprocess.run(['xcrun','llvm-objdump','-d','--no-show-raw-insn','--start-address=%d'%lo,'--stop-address=%d'%hi,cli],capture_output=True,text=True).stdout.split('\n')
ins={}
for l in d:
    m=re.match(r'^\s*([0-9a-f]+):\s+(.*)$',l)
    if m: ins[int(m.group(1),16)]=re.sub(r'\s+',' ',m.group(2))
addrs=[hex(pc-base+0x100000000) for pc,_ in rows]
src=[]
for off in range(0,len(addrs),1500):
    res=subprocess.run(['xcrun','atos','-i','-o',cli,'-l','0x100000000']+addrs[off:off+1500],capture_output=True,text=True).stdout
    for b in res.split('\n\n'):
        ls=[l for l in b.split('\n') if l.strip()]
        if not ls: continue
        ch=[]
        for x in ls:
            m=re.search(r'\(([^()]+)\.swift:(\d+)\)\s*$',x)
            ch.append((m.group(1).replace('JeffJS','')+':'+m.group(2)) if m else '?')
        src.append(' < '.join(ch[:3]))
prev=None
for (pc,n),s in zip(rows,src):
    a=pc-base+0x100000000
    if prev is not None and a!=prev+4: print('      ...')
    print(f'{n/iters:6.2f} {a:x}  {ins.get(a,"?"):44s} {s}')
    prev=a
