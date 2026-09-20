var log = [];
class A { x = 1; f = async () => this.x; g = () => this; y = log.push("field"); constructor(){ log.push("ctor"); } }
var a = new A();
a.f().then(v => console.log("async arrow this.x:", v));
console.log("g:", a.g() === a, log.join(","));
log = [];
class B extends A { z = log.push("B field"); constructor(){ log.push("before super"); super(); log.push("after super"); } }
new B();
console.log(log.join(","));
class C extends A {}
var c = new C(); console.log("C:", c.x, c.g() === c);
