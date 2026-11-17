var M=new Map(); for(let i=0;i<300;i++) M.set("k"+i,i);
function f(){ let s=0; for(let i=0;i<300;i++){ s+=M.get("k"+(i%300)); } return s; }
f(); f();
Number.isSafeInteger(1);
f();
Number.isSafeInteger(1);
