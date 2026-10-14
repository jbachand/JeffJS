var out=[]; var vals=[0,1,-1,127,128,255,256,-129,65535,65536,2147483647,2147483648,4294967295,4294967296,-4294967297,1.5,-1.5,2.5,254.5,255.5,0.1,NaN,Infinity,-Infinity,1e300,-1e300,"7","x",null,true,undefined,3.4e38,1e-50,-0];
var ctors=[Int8Array,Uint8Array,Uint8ClampedArray,Int16Array,Uint16Array,Int32Array,Uint32Array,Float32Array,Float64Array];
for (var C of ctors){ var a=new C(4); for (var v of vals){ a[1]=v; a[5]=v; a[-1]=v; a[1.5]=v; out.push(C.name+":"+String(v)+"="+Object.is(a[1],-0)+"/"+a[1]+"/"+a[5]+"/"+a[-1]+"/"+a[1.5]); }
  var b=new C(new ArrayBuffer(64),8,4); b[0]=3.7; b[3]=-9; b[4]=1; out.push(C.name+" view "+b[0]+","+b[3]+","+b[4]+","+b.length+","+b.byteOffset);
  var sub=a.subarray(1,3); sub[0]=9; out.push(a[1]+","+sub[1]+","+sub.length); }
var big=new BigInt64Array(2); big[0]=5n; out.push(String(big[0])); var ub=new BigUint64Array(2); ub[1]=2n**63n; out.push(String(ub[1]));
var buf=new ArrayBuffer(16); var u=new Uint8Array(buf); u[0]=1; var t=buf.transfer?buf.transfer():null; out.push(String(u[0])+","+u.length+","+(t?t.byteLength:'-'));
var f=new Float64Array(3); f[0]=0.5; var s=0; for(var i=0;i<3;i++) s+=f[i]; out.push(s);
console.log(out.join("\n"));
