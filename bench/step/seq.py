# Print one loop iteration of a recorded pc sequence in execution order, with source lines.
# usage: seq.py <cli> <seq-file> <period-anchor: 'auto'> [max lines]
import sys,subprocess,re,collections
cli,f=sys.argv[1],sys.argv[2]; maxn=int(sys.argv[3]) if len(sys.argv)>3 else 2000
L=open(f).read().split('\n'); base=int(L[0].split()[1],16); pcs=[int(x,16) for x in L[1:] if x.strip()]
# find the period: the last pc's previous occurrences, pick the most common gap among rare pcs
cnt=collections.Counter(pcs[-200000:])
cand=[v for v in cnt.values() if v>=40]
mn=min(cand)
anchor=next(pc for pc in reversed(pcs) if cnt[pc]==mn)
idx=[i for i,p in enumerate(pcs) if p==anchor]
if len(idx)<3: print('no period found'); sys.exit(1)
a,b=idx[-3],idx[-2]
it=pcs[a:b]
print(f'iteration length {b-a} (anchor seen {len(idx)} times in {len(pcs)} steps)')
uniq=sorted(set(it))
lo=min(uniq)-base+0x100000000; 
addrs=[hex(p-base+0x100000000) for p in uniq]
src={}
for off in range(0,len(addrs),1500):
    res=subprocess.run(['xcrun','atos','-i','-o',cli,'-l','0x100000000']+addrs[off:off+1500],capture_output=True,text=True).stdout
    blocks=[[l for l in bl.split('\n') if l.strip()] for bl in res.split('\n\n')]; blocks=[bl for bl in blocks if bl]
    for a2,bl in zip(uniq[off:off+1500],blocks):
        ch=[]
        for x in bl:
            m=re.search(r'\(([^()]+)\.swift:(\d+)\)\s*$',x)
            ch.append((m.group(1).replace('JeffJS','')+':'+m.group(2)) if m else re.sub(r' \(in .*','',x)[:28])
        src[a2]=' < '.join(ch[:3])
ins={}
# disassemble each function range touched (group by 64K windows)
for p in uniq:
    a2=p-base+0x100000000
    if a2 in ins: continue
    d=subprocess.run(['xcrun','llvm-objdump','-d','--no-show-raw-insn','--start-address=%d'%(a2&~0xfff),'--stop-address=%d'%((a2&~0xfff)+0x1000),cli],capture_output=True,text=True).stdout
    for l in d.split('\n'):
        m=re.match(r'^\s*([0-9a-f]+):\s+(.*)$',l)
        if m: ins[int(m.group(1),16)]=re.sub(r'\s+',' ',re.sub(r' <_\$s[^>]*>','',m.group(2)))
for i,p in enumerate(it[:maxn]):
    a2=p-base+0x100000000
    print(f'{i:4d} {a2:x}  {ins.get(a2,"?")[:40]:40s} {src.get(p,"")}')
