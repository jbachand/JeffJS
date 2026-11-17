function f(){ const o={x:1,y:2,z:3}; let s=0; for(let i=0;i<3000;i++){ o.x=o.y+o.z; s+=o.x; } return s; }
f(); f();
Number.isSafeInteger(1);
f();
Number.isSafeInteger(1);
