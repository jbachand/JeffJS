var T=new Float64Array(3000);
function f(){ const t=T; let s=0; for(let i=0;i<3000;i++){ t[i]=i*0.5; s+=t[i]; } return s; }
f(); f();
Number.isSafeInteger(1);
f();
Number.isSafeInteger(1);
