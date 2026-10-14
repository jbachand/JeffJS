import sys,pickle,collections,re
b=sys.argv[1]; pat=sys.argv[2]; N=int(sys.argv[3]); R='/Users/jeffbachand/www/rnly-agents/engine-B/Sources/JeffJS/'
byaddr,bykind,load,total=pickle.load(open(b+'.pkl','rb'))
res=pickle.load(open(b+'.atos.pkl','rb'))
agg=collections.Counter()
for a,v in byaddr.items():
    ch=res[a]; s=' | '.join(c[0] for c in ch)
    if not re.search(pat,s): continue
    ln=None
    for c in ch:
        if c[2] and 'compiler-generated' not in c[1]: ln=(c[0][:40],c[1].split('Sources/JeffJS/')[-1],c[2]);break
    agg[ln or (ch[0][0][:60] if ch else '?',)]+=v
for k,v in agg.most_common(N):
    t=''
    if len(k)==3:
        try: t=open(R+k[1]).read().split('\n')[k[2]-1].strip()[:90]
        except: pass
    print(f'{v:5.0f} {k}  {t}')
