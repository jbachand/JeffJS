var k="z"; class A { static [k+"2"] = 2; [k+"3"] = 3; }
console.log("A.z2:", A.z2, "inst z3:", new A().z3);
