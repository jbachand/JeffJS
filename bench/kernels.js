// Benchmark kernels shared between JeffJS and jsc. Each kernel runs once to
// warm up and once timed. Results are collected and emitted at the end so the
// file works under both engines regardless of console availability.
var LOG = [];
function out(s) { LOG.push(s); }
function now() { return (typeof performance !== "undefined" && performance.now) ? performance.now() : Date.now(); }
function bench(name, fn) { fn(); var t = now(); fn(); var dt = now() - t; out(name + "\t" + dt.toFixed(2)); }

bench("int-loop",      function(){ let s=0; for(let i=0;i<20000000;i++){ s=(s+i)|0; } return s; });
bench("float-loop",    function(){ let s=0.5; for(let i=0;i<10000000;i++){ s=s*1.0000001+0.25; } return s; });
bench("calls",         function(){ function f(a,b){return a+b;} let s=0; for(let i=0;i<5000000;i++){ s=f(s,i)|0; } return s; });
bench("prop-get-set",  function(){ const o={x:1,y:2,z:3}; let s=0; for(let i=0;i<5000000;i++){ o.x=o.y+o.z; s+=o.x; } return s; });
bench("method-call",   function(){ class P{constructor(){this.v=0} inc(n){this.v+=n; return this.v}} const p=new P(); for(let i=0;i<3000000;i++){ p.inc(i&7); } return p.v; });
bench("alloc-objs",    function(){ let s=0; for(let i=0;i<1000000;i++){ const o={a:i,b:i+1}; s+=o.a+o.b; } return s; });
bench("array-push",    function(){ const a=[]; for(let i=0;i<2000000;i++){ a.push(i); } let s=0; for(let i=0;i<a.length;i++) s+=a[i]; return s; });
bench("string-concat", function(){ let s=""; for(let i=0;i<200000;i++){ s+="ab"; } return s.length; });
bench("closure",       function(){ function mk(){ let c=0; return function(){ return ++c; }; } const f=mk(); for(let i=0;i<3000000;i++) f(); return f(); });
bench("fib25",         function(){ function fib(n){ return n<2?n:fib(n-1)+fib(n-2);} return fib(25); });

var __report = LOG.join("\n");
if (typeof console !== "undefined" && console.log) console.log(__report); else print(__report);
