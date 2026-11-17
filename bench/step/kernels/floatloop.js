function f(){ let s=0.5; for(let i=0;i<3000;i++){ s=s*1.0000001+0.25; } return s; }
f(); f();
Number.isSafeInteger(1);
f();
Number.isSafeInteger(1);
