// ES2022 class features: compare with qjs
var log = [];
class A {
  static order = log.push("sf1");
  static { log.push("sblock"); this.fromBlock = 1; }
  static late = log.push("sf2");
  static w;
  x = 1;
  arr = [];
  f = () => this.x;
  #p = 3;
  static #sp = 9;
  #m() { return this.#p * 2; }
  get #g() { return this.#p + 1; }
  set #g(v) { this.#p = v; }
  get p() { return this.#p; }
  set p(v) { this.#p = v; }
  m() { return this.#m(); }
  gg() { this.#g = 8; return this.#g; }
  static sp() { return A.#sp; }
  static has(o) { return #p in o; }
}
console.log(log.join(","), A.fromBlock, A.order, A.late, "w" in A);
var a = new A(), b = new A();
a.arr.push(1);
console.log(a.x, a.f(), a.arr.length, b.arr.length);
console.log(a.p, a.m(), a.gg(), A.sp(), A.has(a), A.has({}));
a.p = 5; console.log(a.p);
class D extends A { y = 2; constructor(){ log.push("pre"); super(); log.push("post"); } }
log = [];
var d = new D();
console.log(log.join(","), d.x, d.y, A.has(d));
class E { #n = 1; bump(){ this.#n++; this.#n += 10; return this.#n } z(){ this.#n = 0; this.#n ||= 4; return this.#n } }
var e = new E(); console.log(e.bump(), e.z());
class F { #q = 1; static { this.fromF = 2; } }
console.log(F.fromF, F.name, E.name);
var k = "dyn";
class G { [k] = 7; static [k + "2"] = 8; }
console.log(new G().dyn, G.dyn2);
