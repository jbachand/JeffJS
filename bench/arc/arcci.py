import sys,pickle,collections
b=sys.argv[1]; R='/Users/jeffbachand/www/rnly-agents/engine-B/Sources/JeffJS/'
byaddr,bykind,load,total=pickle.load(open(b+'.pkl','rb'))
res=pickle.load(open(b+'.atos.pkl','rb'))
agg=collections.Counter()
for a,v in byaddr.items():
    ch=res[a]
    if not any('callInternal' in c[0] for c in ch): continue
    # innermost frame with line
    ln=None
    for c in ch:
        if c[2] and 'compiler-generated' not in c[1]: ln=(c[1].split('Sources/JeffJS/')[-1],c[2]);break
    agg[ln]+=v
for k,v in agg.most_common(int(sys.argv[2])):
    t=''
    if k:
        try: t=open(R+k[0]).read().split('\n')[k[1]-1].strip()[:100]
        except: pass
    print(f'{v:5.0f} {k}  {t}')
