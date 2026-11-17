var A=[]; for(let i=0;i<3000;i++) A.push(i);
function f(){ return A.map(function(x){return x+1;}).length; }
f(); f();
Number.isSafeInteger(1);
f();
Number.isSafeInteger(1);
