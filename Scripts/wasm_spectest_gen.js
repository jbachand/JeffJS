// Scripts/wasm_spectest_gen.js <jsonDir> <outDir>: wast2json output -> one self-contained JS script
// per .wast that runs the same under node and jeffjs-cli (used by Scripts/wasm_spectest.sh).
const fs = require('fs'), path = require('path');
const [jsonDir, outDir] = process.argv.slice(2);
fs.mkdirSync(outDir, { recursive: true });

const PRELUDE = String.raw`
var __pass = 0, __fail = 0, __skip = 0, __fails = [];
function __hex(s) { var b = new Uint8Array(s.length >> 1); for (var i = 0; i < b.length; i++) b[i] = parseInt(s.substr(i * 2, 2), 16); return b; }
var __dv = new DataView(new ArrayBuffer(8));
function __f32(bits) { __dv.setUint32(0, Number(bits) >>> 0, true); return __dv.getFloat32(0, true); }
function __f64(bits) { __dv.setBigUint64(0, BigInt(bits), true); return __dv.getFloat64(0, true); }
function __f32bits(x) { __dv.setFloat32(0, x, true); return __dv.getUint32(0, true); }
function __f64bits(x) { __dv.setFloat64(0, x, true); return __dv.getBigUint64(0, true); }
var __externs = {};
function __extern(n) { if (!(n in __externs)) __externs[n] = { extern: n }; return __externs[n]; }
function __val(v) {
  switch (v.type) {
    case 'i32': return Number(v.value) | 0;
    case 'i64': return BigInt.asIntN(64, BigInt(v.value));
    case 'f32': return __f32(v.value);
    case 'f64': return __f64(v.value);
    case 'externref': return v.value === 'null' ? null : __extern(v.value);
    case 'funcref': return v.value === 'null' ? null : v.value;
  }
  throw new Error('arg type ' + v.type);
}
function __match(e, a) {
  switch (e.type) {
    case 'i32': return typeof a === 'number' && a === (Number(e.value) | 0);
    case 'i64': return typeof a === 'bigint' && a === BigInt.asIntN(64, BigInt(e.value));
    case 'f32':
      if (typeof a !== 'number') return false;
      if (e.value.startsWith('nan:')) return a !== a;
      return __f32bits(a) === (Number(e.value) >>> 0) || (a !== a && __f32(e.value) !== __f32(e.value));
    case 'f64':
      if (typeof a !== 'number') return false;
      if (e.value.startsWith('nan:')) return a !== a;
      return __f64bits(a) === BigInt(e.value) || (a !== a && __f64(e.value) !== __f64(e.value));
    case 'externref': return e.value === 'null' ? a === null : a === __extern(e.value);
    case 'funcref': return e.value === 'null' ? a === null : typeof a === 'function';
  }
  return false;
}
function __show(a) { if (typeof a === 'bigint') return a + 'n'; if (typeof a === 'number' && Object.is(a, -0)) return '-0'; if (Array.isArray(a)) return '[' + a.map(__show).join(',') + ']'; if (typeof a === 'function') return 'func'; if (a && typeof a === 'object') return JSON.stringify(a); return String(a); }
var __spectest = {
  print: function () {}, print_i32: function () {}, print_i64: function () {}, print_f32: function () {},
  print_f64: function () {}, print_i32_f32: function () {}, print_f64_f64: function () {},
  global_i32: new WebAssembly.Global({ value: 'i32' }, 666),
  global_i64: new WebAssembly.Global({ value: 'i64' }, 666n),
  global_f32: new WebAssembly.Global({ value: 'f32' }, 666.6),
  global_f64: new WebAssembly.Global({ value: 'f64' }, 666.6),
  table: new WebAssembly.Table({ initial: 10, maximum: 20, element: 'anyfunc' }),
  memory: new WebAssembly.Memory({ initial: 1, maximum: 2 }),
};
var __registry = { spectest: __spectest };
var __named = {}, __last = null;
function __ok() { __pass++; }
function __bad(line, msg) { __fail++; __fails.push(line + ': ' + msg); }
function __inst(bytes) { var m = new WebAssembly.Module(__hex(bytes)); return new WebAssembly.Instance(m, __registry); }
function __exp(name) { var i = name ? __named[name] : __last; if (!i) throw new Error('no module'); return i.exports; }
function __invoke(name, field, args) { var f = __exp(name)[field]; if (typeof f !== 'function') throw new Error('no export ' + field); return f.apply(null, args); }
function __get(name, field) { return __exp(name)[field].value; }
function __results(expected, r) {
  if (expected.length === 0) return r === undefined;
  if (expected.length === 1) return __match(expected[0], r);
  if (!Array.isArray(r) || r.length !== expected.length) return false;
  for (var i = 0; i < r.length; i++) if (!__match(expected[i], r[i])) return false;
  return true;
}
function __errName(e) { return e && e.constructor && e.constructor.name ? e.constructor.name + ': ' + e.message : String(e); }
`;

function hex(buf) { return buf.toString('hex'); }
function q(s) { return JSON.stringify(s); }
function action(a) {
  const mod = a.module ? q(a.module) : 'null';
  if (a.type === 'invoke') return `__invoke(${mod}, ${q(a.field)}, [${a.args.map(v => `__val(${JSON.stringify(v)})`).join(', ')}])`;
  if (a.type === 'get') return `__get(${mod}, ${q(a.field)})`;
  throw new Error('action ' + a.type);
}

for (const name of fs.readdirSync(jsonDir).sort()) {
  const dir = path.join(jsonDir, name);
  const spec = JSON.parse(fs.readFileSync(path.join(dir, name + '.json'), 'utf8'));
  const out = [PRELUDE];
  const wasm = f => hex(fs.readFileSync(path.join(dir, f)));
  for (const c of spec.commands) {
    const L = c.line;
    switch (c.type) {
      case 'module': {
        out.push(`try { __last = __inst(${q(wasm(c.filename))}); ${c.name ? `__named[${q(c.name)}] = __last;` : ''} __ok(); } catch (e) { __last = null; __bad(${L}, 'module: ' + __errName(e)); }`);
        break;
      }
      case 'register':
        out.push(`try { __registry[${q(c.as)}] = __exp(${c.name ? q(c.name) : 'null'}); } catch (e) { __bad(${L}, 'register: ' + __errName(e)); }`);
        break;
      case 'action':
        out.push(`try { ${action(c.action)}; __ok(); } catch (e) { __bad(${L}, 'action: ' + __errName(e)); }`);
        break;
      case 'assert_return':
        out.push(`try { var __r = ${action(c.action)}; var __e = ${JSON.stringify(c.expected)}; if (__results(__e, __r)) __ok(); else __bad(${L}, 'got ' + __show(__r) + ' want ' + JSON.stringify(__e)); } catch (e) { __bad(${L}, 'threw ' + __errName(e)); }`);
        break;
      case 'assert_trap':
      case 'assert_exhaustion': {
        const want = c.type === 'assert_trap' ? `e instanceof WebAssembly.RuntimeError` : `(e instanceof RangeError || e instanceof WebAssembly.RuntimeError)`;
        out.push(`try { var __r = ${action(c.action)}; __bad(${L}, 'no trap (${c.text}), got ' + __show(__r)); } catch (e) { if (${want}) __ok(); else __bad(${L}, 'wrong error for ${c.text}: ' + __errName(e)); }`);
        break;
      }
      case 'assert_invalid':
      case 'assert_malformed':
        if (c.module_type !== 'binary') { out.push(`__skip++;`); break; }
        out.push(`try { var __b = __hex(${q(wasm(c.filename))}); if (WebAssembly.validate(__b)) { __bad(${L}, 'validate() true (${c.text})'); } else { try { new WebAssembly.Module(__b); __bad(${L}, 'compiled (${c.text})'); } catch (e) { if (e instanceof WebAssembly.CompileError) __ok(); else __bad(${L}, 'wrong error: ' + __errName(e)); } } } catch (e) { __bad(${L}, 'validate threw ' + __errName(e)); }`);
        break;
      case 'assert_unlinkable':
        out.push(`try { __inst(${q(wasm(c.filename))}); __bad(${L}, 'linked (${c.text})'); } catch (e) { if (e instanceof WebAssembly.LinkError) __ok(); else __bad(${L}, 'wrong error for ${c.text}: ' + __errName(e)); }`);
        break;
      case 'assert_uninstantiable':
        out.push(`try { __inst(${q(wasm(c.filename))}); __bad(${L}, 'instantiated (${c.text})'); } catch (e) { if (e instanceof WebAssembly.RuntimeError) __ok(); else __bad(${L}, 'wrong error for ${c.text}: ' + __errName(e)); }`);
        break;
      default:
        out.push(`__skip++; // ${c.type}`);
    }
  }
  out.push(`console.log(${q(name)} + ' PASS ' + __pass + ' FAIL ' + __fail + ' SKIP ' + __skip); for (var __i = 0; __i < __fails.length && __i < 40; __i++) console.log('  ' + __fails[__i]);`);
  fs.writeFileSync(path.join(outDir, name + '.js'), out.join('\n') + '\n');
}
