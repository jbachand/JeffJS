function f(a,b){ return arguments.length+a+(b||0); } var b=f.bind(null,1); var t=0;
for(let r=0;r<20000;r++){ t+=f(1,2)+f.call(null,1)+f.apply(null,[1,2,3])+b(2); [1,2,3].forEach(function(x){t+=x}); t+=[1,2,3].reduce(function(a,x){return a+x},0); t+=new (class A{constructor(x){this.x=x}})(3).x; try{ (function(){throw 1})() }catch(e){t++} }
console.log(t);
