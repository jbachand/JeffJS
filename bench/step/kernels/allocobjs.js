function f(){ let s=0; for(let i=0;i<3000;i++){ const o={a:i,b:i+1}; s+=o.a+o.b; } return s; }
f(); f();
Number.isSafeInteger(1);
f();
Number.isSafeInteger(1);
