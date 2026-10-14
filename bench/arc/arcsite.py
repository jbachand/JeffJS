import sys,pickle,subprocess,collections,re
OD='/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/llvm-objdump'
b=sys.argv[1]; N=int(sys.argv[2])
byaddr,bykind,load,total=pickle.load(open(b+'.pkl','rb'))
l=int(load,16)
# full disasm once
import os
if not os.path.exists('full.s'):
    open('full.s','w').write(subprocess.run([OD,'-d','--no-show-raw-insn','cli-base'],capture_output=True,text=True).stdout)
ins={}
cur=None
for line in open('full.s'):
    m=re.match(r'\s*([0-9a-f]+):\s+(.*)',line)
    if m: ins[int(m.group(1),16)]=m.group(2).strip()
STUB={0x1003d7198:'retain',0x1003d7180:'release',0x1003d6fc4:'bridgeRelease',0x1003d6fdc:'bridgeRetain',0x1003d718c:'release_n',0x1003d71a4:'retain_n',0x1003d7168:'isUniqNative',0x1003d715c:'isUniqBridge',0x1003d6f94:'arrayDestroy'}
rows=[]
for a,v in sorted(byaddr.items(),key=lambda x:-x[1])[:N]:
    o=a-l+0x100000000
    prev=ins.get(o-4,'')
    # source of x0: walk back
    src=''
    kind=prev
    reg='x0'
    for k in range(2,40):
        s=ins.get(o-4*k,'')
        if not s: break
        m=re.match(r'mov\s+(\w+), (\w+)$',s)
        if m and m.group(1)==reg: reg=m.group(2); continue
        m=re.match(r'ldr\s+(\w+), \[(\w+)(?:, #(0x[0-9a-f]+))?\]',s)
        if m and m.group(1)==reg: src=f'ldr {reg}<-[{m.group(2)}+{m.group(3) or 0}]'; break
        m=re.match(r'(bl|blr)\s',s)
        if m: src='after call'; break
        if re.match(r'(ldp|add|adrp)\s+'+reg+r'\b',s): src=s; break
    rows.append((v,hex(o),prev[:60],src))
    out=subprocess.run(['atos','-i','-o','cli-base','-l',load,hex(a)],capture_output=True,text=True).stdout.strip().splitlines()
    print(f'{v:5.0f} {prev[:44]:44s} | {src:34s} | {out[0][:70] if out else ""}')
