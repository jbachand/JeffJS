var n=0; for(let r=0;r<2000;r++){ var m=new Map(), s=new Set(); for(let i=0;i<30;i++){ m.set('k'+i,{v:i}); s.add(i%7);} m.forEach(function(v,k){n+=v.v}); m.delete('k3'); n+=m.size+s.size; for(var [k,v] of m) n+=v.v; var w=new WeakMap(); var key={}; w.set(key,1); n+=w.get(key); }
console.log(n);
