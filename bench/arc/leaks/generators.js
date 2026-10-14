function* g(n){ for(let i=0;i<n;i++){ var x=yield i; if(x) i+=x; } return 7; }
var t=0; for(let r=0;r<3000;r++){ var it=g(10); var v=it.next(); while(!v.done){ t+=v.value; v=it.next(1);} t+=v.value; for(var q of g(5)) t+=q; var it2=g(5); it2.next(); it2.return(3); try{ var it3=g(5); it3.next(); it3.throw(new Error('e')); }catch(e){ t++; } }
console.log(t);
