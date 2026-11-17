var O={}; for(let i=0;i<300;i++) O["k"+i]=i;
function f(){ let s=0; for(let r=0;r<10;r++){ for(const k in O){ s+=O[k]; } } return s; }
f(); f();
Number.isSafeInteger(1);
f();
Number.isSafeInteger(1);
