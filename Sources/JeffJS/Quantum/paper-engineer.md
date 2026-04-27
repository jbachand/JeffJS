# JeffJS Quantum (Engineer's Edition)

*A short whitepaper for engineers who want to use the module*

*Jeff Bachand*

*April 2026*

---

> **What this is.** A 5-page guide to the JeffJS Quantum module: what it does, how to call it, what it's for, and what it isn't. The longer companion document `paper.md` walks through the underlying information-theoretic framework in full. Read this one first.

---

## 1. What you can do with it

JeffJS Quantum is a Swift module inside the JeffJS JavaScript engine. It exposes two encoders to JS code via `window.jeffjs.quantum`:

- **`slice` encoder** — encodes arbitrary strings into a list of compact 25-bit master keys plus envelope metadata. The data is stored implicitly in a deterministic procedural field; only the keys travel.
- **`chain` encoder** — encodes a short string (up to 6 ASCII chars) into a single 64-hex-char "chain key" via backtracking octree search. The decoder walks the octree back without searching.

```js
// Slice — multi-key envelope, fast, ~hundreds of bytes per word
const env = window.jeffjs.quantum.slice.encode("hello world");
const out = window.jeffjs.quantum.slice.decode(env);   // "hello world"

// Chain — single deep key, up to 6 chars, sync up to ~10s worst case
const key = window.jeffjs.quantum.chain.encode("Hi");
const dec = window.jeffjs.quantum.chain.decode(key);   // "Hi"

// Chain — async variants return real Promises
const k = await window.jeffjs.quantum.chain.encodeAsync("Hi");
const s = await window.jeffjs.quantum.chain.decodeAsync(k);
```

That is the entire surface area. There is also `quantum.enabled` (a bool feature flag) and `slice.encodeRaw` / `slice.decodeRaw` for callers who want the raw key array instead of a hex envelope.

---

## 2. The principle in one line

The chain encoder is built around a single equation:

`Q(O, S) = R(A) / 2^{I(O; S)}`.

Read it as: an *observer* `O` measuring a *system* `S` for an *observable* `A` can distinguish cells of size `Q`, where `R` is the range of `A` in its natural units and `I` is the Shannon mutual information **in bits** between the observer's record and the system's state. **Each additional bit halves the cell size.** This is the ADC quantization formula `Q = R/N` extended from physical bits (`N = 2^k` distinguishable bins) to mutual information bits (`I` bits of correlation between observer and system).

In the chain encoder:
- `R` = `2^{25}` (the field's address range per axis)
- `I` = `N` bits (the encoded message length, 1 bit at level 1, `N` bits at level `N`)
- `Q` = `R / 2^N` = `2^{25-N}` (the cell width at depth `N`)

The encoder *is* the equation: every bit of message you encode buys one octree level of resolution, which is one bit of mutual information. Decode walks the octree back upward by truncating one bit per axis per step. `N` reads, deterministic, no search.

This expression of the resolution-information trade-off is **not novel**. It belongs to the information-theoretic-foundations tradition (Wheeler 1990, Brukner-Zeilinger 1999, Frieden 1998, Reginatto 1998, Hall-Reginatto 2002, Rovelli 2013). The Heisenberg-from-Cramér-Rao chain it relies on traces to Stam 1959 and was formalized by Dembo, Cover and Thomas 1991. What is unusual is that the framework is *instantiated as runnable Swift code* — that is the contribution this module actually makes.

---

## 3. How the chain encoder works

Three components:

**Qubit field.** A deterministic procedural field of 256 two-dimensional points, generated lazily from a seed by `SplitMix64`. Each qubit has a position, speed, radius, and phase. Nothing is allocated until a query touches that part of the field. See `QuantumChainField.swift`.

**Bit-derivation function.** At any address `(vx, vy, t)`, find the closest qubit, advance its phase by `t`, take the cross-product of its motion vector with `(vx, vy)`, and read the sign as a bit. This is the function that turns a 3D address into a single bit.

**Octree backtracking search.** To encode an `N`-bit message:

1. Start at level 1 (each axis is 1 bit, eight cells total).
2. For each candidate cell, sample its *center* and read the derived bit.
3. Pick a cell whose bit equals message bit `b[N-1]` (the *last* message bit).
4. Descend: at level `k`, the chosen parent has `(k-1)` bits per axis fixed; the eight children explore the `k`-th bit on each axis. Pick one whose derived bit equals `b[N-k]`.
5. At level `N`, the full address is the master key.
6. If at any level no child matches, backtrack (parent tries a different combination, budget capped at 5000 visits per seed).

See `QuantumChainEncoder.swift`. The cell-center mapping `(vx_int + 0.5) / 2^level × field_size` is what makes consecutive levels read independent qubit windows — without it, the chain would carry no information past level 1.

**Decoding** is the inverse and requires no search: start at the full master-key address at level `N`, read the bit, shift each axis right by 1, read the bit at level `N-1`, continue up to level 1. `N` reads, microsecond cost.

**Capacity ceiling.** The encoder is implemented in `Double` (IEEE 754 binary64). The cell width at level `k` is `field_size / 2^k`; round-off swamps the cell-center mapping near `k = 52`. The encoder caps at `maxBits = 48` to leave headroom — 48 bits = 6 ASCII characters per key. Moving to arbitrary precision would push the cap arbitrarily high at the cost of speed.

This precision floor is the principle in action: your representation imposes a hard `I_max`, beyond which cells stop being distinguishable. The cosmic version of the same argument (with the Planck length playing the role of the Double-precision floor) is in `paper.md` §5; the engineering version is right here.

---

## 4. The slice encoder, briefly

The slice encoder solves a different problem. Rather than encoding all message bits into one deep address via backtracking, it splits the message into 25-bit blocks and finds *one master key per block* whose 25-bit payload's popcount falls in a target range (4 slices of popcount 3-22 gives 2 bits per key, 8 slices gives 3 bits, etc.).

The trick is searching for a *popcount slice* (probability ~25% per cell) instead of an exact 25-bit value (probability ~`2^{-25}` per cell). That single change moves the search from statistically impossible to a few seconds on GPU.

```js
const result = window.jeffjs.quantum.slice.encodeRaw("payload");
// result.keys: ["0x1234567", "0x89abcde", ...]  (7-hex-char keys)
// result.length: int
// result.seedOffset: int

const decoded = window.jeffjs.quantum.slice.decodeRaw(result);
```

GPU acceleration via Metal lives in `QuantumGPU.swift`. The Metal kernels are loaded at runtime from the Swift package bundle. CPU fallback is automatic.

Use `chain` when you want a single short key for a small payload. Use `slice` for arbitrary-length data.

---

## 5. What this is *not*

These are honest disclaimers. Don't ship anything based on misreading them.

- **Not cryptography.** The field is fully deterministic. Anyone with the same seed and encoder can read any key. There is no secret material.
- **Not compression.** Kolmogorov complexity still applies. For large inputs, total key size grows with data size — slice encoder trades message size for key count.
- **Not production infrastructure.** Latency is bit-pattern-dependent (the chain encoder backtracks; pathological patterns are slow). The chain encoder's hard precision floor is ~48 bits. Nothing here is hardened for adversarial input or scale.
- **Not new physics.** The framework `Q = R / 2^I` rests on existing work from the information-theoretic-foundations tradition. The compact form is a notation contribution, not a discovery. The Planck-collapse argument in `paper.md` §5.4 is Bronstein 1936 + the GUP literature.
- **Not a model of foundational physics.** The qubit field has no Lorentz invariance, no conservation laws, no Hilbert space, no gravity, no dynamics. It instantiates *one specific structural property* — the resolution-information trade-off — and lacks essentially every other property physical universes have. `paper.md` §3.7 walks through this calibration in detail.

What it **is**: a working instantiation of one piece of the information-theoretic-foundations framework, in the form of a Swift module that a reader can clone, build, and run on commodity hardware. That is small. It is also real.

---

## 6. The quantum computer simulator

The module includes a full quantum circuit simulator with Metal GPU acceleration, accessible from JavaScript via `window.jeffjs.quantum.simulator`. This was prototyped in Python, validated against known quantum results, then ported to Swift with Metal compute shaders.

### What it can do

**Shor's algorithm** — factors integers using quantum period-finding with iterative phase estimation. Uses only `n+1` qubits for an `n`-bit number (instead of `3n` for full QPE). Validated results:

| N | Factors | Qubits | Time (release build) |
|---|---|---|---|
| 15 | 3 x 5 | 5 | instant |
| 21 | 3 x 7 | 6 | instant |
| 143 | 11 x 13 | 9 | instant |
| 323 | 17 x 19 | 10 | instant |
| 29,999 | 131 x 229 | 16 | < 1s |

**Other algorithms** — all validated:
- **Deutsch-Jozsa**: determines constant vs balanced oracle in 1 query (8/8 oracle configs correct)
- **Bernstein-Vazirani**: recovers secret strings up to 20 bits in 1 query
- **Quantum teleportation**: transfers quantum state via entanglement (100% success rate)
- **Superdense coding**: sends 2 classical bits using 1 qubit + entanglement
- **Error correction**: 3-qubit bit-flip code with syndrome extraction and correction

**Bell/CHSH tests** — 8 variants measuring the CHSH inequality `S`, from sub-classical (`S = sqrt(2)`) through Bell-saturating (`S = 2`) to Tsirelson (`S = 2sqrt(2)`), including a Bohmian-style sub-resolution binding model (V8) that reaches quantum-strength correlations.

**GHZ states** — O(N) streaming sampler using the "interference at the last qubit" trick: for GHZ = `(|00...0> + |11...1>) / sqrt(2)`, all intermediate measurement conditionals are interference-free, but the last qubit's conditional preserves the cross-term. Scales to 1M+ qubits.

### Three simulation backends

| Backend | Cost per gate | Max qubits | When it's used |
|---|---|---|---|
| State vector (CPU) | O(2^N) | ~20 | Circuits under 18 qubits |
| State vector (Metal GPU) | O(2^N) parallel | ~25 | Circuits with 18+ qubits |
| Stabilizer tableau | O(N^2) | 1000+ | Clifford-only circuits (H, CNOT, S, X, Y, Z) |

### JS API

```js
// Shor's algorithm
const result = await window.jeffjs.quantum.simulator.shorFactor(143);
// { factors: [11, 13], N: 143, numQubits: 9 }

// Deutsch-Jozsa
const dj = await window.jeffjs.quantum.simulator.deutschJozsa(4, "balanced", [0,1]);
// { isConstant: false, measurements: [1,0,1,0] }

// Bernstein-Vazirani
const bv = await window.jeffjs.quantum.simulator.bernsteinVazirani("10110011");
// { recovered: "10110011" }

// Teleportation
const tp = await window.jeffjs.quantum.simulator.teleport();
// { success: true, bobOutcome: 0 }

// Superdense coding
const sd = await window.jeffjs.quantum.simulator.superdenseCoding(1, 0);
// { sent: [1,0], received: [1,0], success: true }

// Error correction
const ec = await window.jeffjs.quantum.simulator.errorCorrection(1);
// { corrected: true, errorQubit: 1, syndrome: [1,1] }

// CHSH Bell test
const bell = window.jeffjs.quantum.simulator.chsh("boundQubitPair", 10000);
// { S: -2.83, noSignaling: true }

// Raw circuit (Metal-accelerated for 18+ qubits)
const id = window.jeffjs.quantum.simulator.createCircuit(8);
window.jeffjs.quantum.simulator.gate(id, "h", { qubit: 0 });
window.jeffjs.quantum.simulator.gate(id, "cnot", { control: 0, target: 1 });
const outcome = window.jeffjs.quantum.simulator.measure(id, 0);

// Stabilizer simulator (1000+ qubits, Clifford gates only)
const sid = window.jeffjs.quantum.simulator.createStabilizer(1000);
window.jeffjs.quantum.simulator.stabGHZ(sid, [0,1,2,3,4,5,6,7,8,9]);
window.jeffjs.quantum.simulator.stabMeasure(sid, 0);
```

### Key discovery: interference at the last qubit

During development, we found that for GHZ states, the quantum interference (the cross-term `2ab cos sin` that distinguishes quantum from classical correlations) cancels when you trace over remaining qubits at each intermediate step — but survives at the **last qubit** where there's nothing left to trace over. This means you can sample N-1 qubits using the classical no-interference formula, track two coefficients `(a, b)` with correct signs, and apply the interference correction *once* at the final measurement. The result is an O(N) sampling algorithm that produces exact quantum statistics for GHZ at arbitrary measurement angles, scaling to 1M+ qubits.

This is what makes the GHZ `ghzCorrelation()` API work at scale. It's also why the V8 Bohmian entanglement model (which uses sequential measurement) breaks at N=3 GHZ — sequential measurement inherently drops the interference that joint measurement preserves.

---

## 7. Building and testing

```sh
swift build              # debug build (slower runtime, faster compile)
swift build -c release   # release build (100x faster runtime for Shor's)
swift test               # runs the deterministic test suite
```

**Important:** Shor's and other algorithms are 100x faster in release mode due to Swift optimization and array bounds check elimination. Use `swift build -c release` for performance testing.

---

## 8. Where to go next

- **`paper.md`** — full long-form whitepaper (48 pages). Seven recovery cases, CHSH hierarchy with half-bit ladder, two figures, trans-Planckian framing, full literature search.
- **`paper-engineer.md`** — this document.
- **`experiments.md`** — 12 proposed experiments including the completed CHSH/Tsirelson test (Experiment 9) and GHZ scaling test (Experiment 10).
- **`README.md`** — complete file listing and module overview.
- **`chsh_prototype.py`** — the original 8-variant CHSH prototype (Python).
- **`shor_iterative.py`** — the iterative phase estimation Shor's prototype (Python).
- **`QuantumAlgorithms.swift`** — the Swift port of all algorithms.
- **`QuantumSimulatorBridge.swift`** — the JS bridge for the simulator API.
