class P{constructor(){this.v=0} inc(n){this.v+=n; return this.v}}
function f(){ const p=new P(); for(let i=0;i<3000;i++){ p.inc(i&7); } return p.v; }
f(); f();
Number.isSafeInteger(1);
f();
Number.isSafeInteger(1);
