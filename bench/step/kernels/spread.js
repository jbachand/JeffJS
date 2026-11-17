function f(){ let s=0; for(let i=0;i<300;i++){ const a=[i,i+1,i+2]; const b=[...a,4]; s+=b.length; } return s; }
f(); f();
Number.isSafeInteger(1);
f();
Number.isSafeInteger(1);
