var t=0; async function f(x){ await null; var y=await Promise.resolve(x); return y+1; }
async function main(){ for(let r=0;r<3000;r++){ t+=await f(r); try{ await Promise.reject(1);}catch(e){t++} t+=(await Promise.all([f(1),f(2)])).length; } console.log(t); }
main();
