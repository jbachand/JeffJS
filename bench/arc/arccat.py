import os
CLI=os.environ.get('CLI','cli-base')
import sys,pickle,subprocess,collections,re
b=sys.argv[1]
byaddr,bykind,load,total=pickle.load(open(b+'.pkl','rb'))
addrs=list(byaddr)
def atos(addrs):
    out=[]
    for i in range(0,len(addrs),300):
        chunk=addrs[i:i+300]
        r=subprocess.run(['atos','-i','-o',CLI,'-l',load]+[hex(a) for a in chunk],capture_output=True,text=True).stdout
        out+= r.split('\n\n') if False else None or []
        # -i prints inlined chain lines per address with no separators; do one by one fallback
    return out
res={}
for a in addrs:
    o=subprocess.run(['atos','-i','-o',CLI,'-l',load,'-fullPath',hex(a)],capture_output=True,text=True).stdout.strip().splitlines()
    ch=[]
    for l in o:
        m=re.match(r'(.*?) \(in [^)]*\)(?: \((.*?):(\d+)\))?',l)
        if m: ch.append((m.group(1),m.group(2) or '',int(m.group(3) or 0)))
    res[a]=ch
pickle.dump(res,open(b+'.atos.pkl','wb'))
