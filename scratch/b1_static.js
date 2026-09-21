class A { static y = 2; static w; }
console.log("static y:", A.y, "w:", A.w, "hasW:", A.hasOwnProperty("w"));
class B { static a = 1; static b = B.a + 1; }
console.log("static b:", B.b);
