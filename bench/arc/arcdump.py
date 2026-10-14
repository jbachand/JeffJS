import os
CLI=os.environ.get('CLI','cli-base')
import sys, re, collections, subprocess, xml.etree.ElementTree as ET
path=sys.argv[1]; top=int(sys.argv[2]) if len(sys.argv)>2 else 40
root=ET.parse(path).getroot(); ids={}
for el in root.iter():
    i=el.get('id')
    if i is not None: ids[i]=el
def res(e):
    if e is None: return None
    r=e.get('ref'); return ids.get(r) if r else e
ARC=re.compile(r'^(DYLD-STUB\$\$)?(swift_retain|swift_release|swift_bridgeObject|swift_unknownObject|swift_weak|swift_isUniquely|swift_arrayInitWith|swift_arrayDestroy|swift_allocObject|swift_deallocClassInstance|swift_retain_n|swift_release_n|_swift_release_dealloc|swift_unownedRetain|swift_unownedRelease|swift_beginAccess|swift_endAccess|swift_dynamicCast)|RefCounts|^(outlined|specialized|assignWith|initializeWith|destroy for)')
RT=re.compile(r'^(DYLD-STUB\$\$)?(swift_(retain|release|bridgeObject|unknownObject|weak|isUniquely|arrayInit|arrayDestroy|allocObject|deallocClass|retain_n|release_n|unowned|beginAccess|endAccess|dynamicCast))|RefCounts|_swift_release_dealloc')
total=0; arc=0
byaddr=collections.Counter(); bykind=collections.defaultdict(collections.Counter)
loadaddr=None
for row in root.iter('row'):
    w=res(row.find('weight')); ms=int(w.text)/1e6 if w is not None and w.text else 1
    bt=res(row.find('backtrace'))
    if bt is None: continue
    fr=[res(f) for f in bt.iter('frame')]
    if not fr: continue
    total+=ms
    if not RT.search(fr[0].get('name') or ''): continue
    arc+=ms
    # first frame not RT and in our binary
    for f in fr[1:]:
        if RT.search(f.get('name') or ''): continue
        b=res(f.find('binary'))
        if b is not None and 'cli' in (b.get('path') or ''):
            loadaddr=b.get('load-addr'); path_bin=b.get('path')
            a=int(f.get('addr'),16)
            byaddr[a]+=ms; bykind[a][re.sub(r'DYLD-STUB\$\$','',fr[0].get('name'))[:24]]+=ms
        break
print(f'total {total:.0f} arc {arc:.0f} ({100*arc/total:.1f}%) binary {path_bin} load {loadaddr}')

import pickle
pickle.dump((dict(byaddr),{a:dict(k) for a,k in bykind.items()},loadaddr,total),open(path.replace('.xml','.pkl'),'wb'))
