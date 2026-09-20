var s=Symbol('x'); var o={}; o[s]=1; o.x=2;
console.log("keys:", Object.keys(o).join(","), "sym:", o[s], "x:", o.x, "own:", Object.getOwnPropertyNames(o).join(","), "syms:", Object.getOwnPropertySymbols(o).length, JSON.stringify(o));
