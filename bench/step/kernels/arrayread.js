var A=[]; for(let i=0;i<3000;i++) A.push(i);
function f(){ const a=A; let s=0; for(let i=0;i<3000;i++){ s=(s+a[i])|0; } return s; }
f(); f();
Number.isSafeInteger(1);
f();
Number.isSafeInteger(1);
