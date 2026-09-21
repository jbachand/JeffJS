class A { static z; static { A.z = 5; } }
console.log("A.z:", A.z);
class B { static { this.q = 7; } }
console.log("B.q:", B.q);
var order = [];
class C { static a = order.push("a"); static { order.push("block"); } static b = order.push("b"); }
console.log(order.join(","));
