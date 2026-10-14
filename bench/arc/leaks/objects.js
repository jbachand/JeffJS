var t=0; for(let r=0;r<20000;r++){ var o={a:1,b:'x',c:[1,2],d:{e:r}}; o.f=function(){return this.a}; t+=o.f()+o.d.e; var p=Object.create(o); t+=p.a; var j=JSON.parse(JSON.stringify(o.d)); t+=j.e; delete o.b; t+=Object.keys(o).length; var {a,...rest}=o; t+=Object.keys(rest).length; }
console.log(t);
