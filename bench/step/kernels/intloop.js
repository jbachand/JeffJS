function f(){ let s=0; for(let i=0;i<3000;i++){ s=(s+i)|0; } return s; }
f(); f();
Number.isSafeInteger(1);
f();
Number.isSafeInteger(1);
