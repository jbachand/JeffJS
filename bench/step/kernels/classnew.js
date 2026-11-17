class A{constructor(x){this.x=x;}} class B extends A{constructor(x){super(x); this.y=1;} get z(){return this.x+this.y;}}
function f(){ let s=0; for(let i=0;i<300;i++){ const b=new B(i); s+=b.z; } return s; }
f(); f();
Number.isSafeInteger(1);
f();
Number.isSafeInteger(1);
