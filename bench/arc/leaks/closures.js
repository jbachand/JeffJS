var s=0; for(let r=0;r<2000;r++){ var fs=[]; for(let i=0;i<50;i++){ fs.push(function(){return i+r}); } for(var f of fs) s+=f(); var g=(x)=>()=>x+s; s=(s+g(1)())%1000003; }
console.log(s);
