class A { #p = 3; get p(){ return this.#p; } set p(v){ this.#p = v; } #m(){ return this.#p * 2; } m(){ return this.#m(); } static #s = 9; static s(){ return A.#s; } static has(o){ return #p in o; } }
var a = new A();
console.log("p:", a.p);
a.p = 10;
console.log("p2:", a.p, "m:", a.m(), "s:", A.s(), "has:", A.has(a), A.has({}));
try { A.prototype.m.call({}); } catch(e) { console.log("err:", e.constructor.name, e.message); }
class D { #x = 1; static inc(o){ return ++o.#x; } }
var d = new D(); console.log("inc:", D.inc(d), D.inc(d));
