// Pre-existing leak at 1d88693 (not caused by arc-out work): closures capturing a per-iteration `let`.
// ~117 MB RSS and ~200k live class-1 objects (JEFFJS_TRACK_RC=1) after 200k iterations.
var a=[]; for(let i=0;i<200000;i++){ var f=function(){return i}; a.push(f()); } console.log(a.length);
