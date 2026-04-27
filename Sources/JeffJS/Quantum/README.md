# JeffJS Quantum Module

Two systems in one module: a **procedural-field data encoder** and a
**Metal-accelerated quantum computer simulator** — both exposed to
JavaScript via `window.jeffjs.quantum`.

---

## What's in here

### 1. Procedural-field encoder (`window.jeffjs.quantum.chain` / `.slice`)

Stores arbitrary data as compact master keys that point into a deterministic
field of 256 moving "qubits." The data lives in the field itself — only the
keys need to be persisted or transmitted. Two encoding schemes:
- **Slice encoder**: multi-key envelope, popcount-slice search
- **Chain encoder**: single deep-octree master key, resolution-deepening

### 2. Quantum computer simulator (`window.jeffjs.quantum.simulator`)

A full quantum circuit simulator with Metal GPU acceleration. Runs real
quantum algorithms from JavaScript:

```javascript
// Factor a number with Shor's algorithm
const result = await window.jeffjs.quantum.simulator.shorFactor(143);
// → { factors: [11, 13], N: 143, numQubits: 9 }

// State vector circuit (Metal-accelerated for 18+ qubits)
const id = window.jeffjs.quantum.simulator.createCircuit(8);
window.jeffjs.quantum.simulator.gate(id, "h", { qubit: 0 });
window.jeffjs.quantum.simulator.gate(id, "cnot", { control: 0, target: 1 });
window.jeffjs.quantum.simulator.measure(id, 0);  // → 0 or 1

// Stabilizer simulator (1000+ qubits, Clifford gates only)
const sid = window.jeffjs.quantum.simulator.createStabilizer(1000);
window.jeffjs.quantum.simulator.stabGHZ(sid, [0,1,2,3,4,5,6,7,8,9]);
window.jeffjs.quantum.simulator.stabMeasure(sid, 0);
```

**Algorithms available via JavaScript Promises:**

| Algorithm | JS API | What it does |
|---|---|---|
| Shor's factoring | `shorFactor(N)` | Factor integers using quantum period-finding |
| Deutsch-Jozsa | `deutschJozsa(n, type, bits)` | Determine constant vs balanced oracle in 1 query |
| Bernstein-Vazirani | `bernsteinVazirani(secret)` | Recover secret string in 1 query |
| Teleportation | `teleport()` | Transfer quantum state via entanglement |
| Superdense coding | `superdenseCoding(b0, b1)` | Send 2 classical bits via 1 qubit |
| Error correction | `errorCorrection(qubit)` | 3-qubit bit-flip code: detect and correct |
| CHSH/Bell test | `chsh(variant, trials)` | 8 variants including Tsirelson bound |
| GHZ correlation | `ghzCorrelation(n, angles, trials)` | O(N) streaming with interference |

**Three simulation backends:**

| Backend | Gate cost | Max qubits | What it handles |
|---|---|---|---|
| State vector (CPU) | O(2^N) | ~20 | Any circuit |
| State vector (Metal GPU) | O(2^N) parallel | ~25 | Any circuit, 18+ qubits auto-GPU |
| Stabilizer tableau | O(N²) | 1000+ | Clifford-only (H, CNOT, S, X, Y, Z) |

---

## What this is — and what it isn't

Be honest about what it **isn't**:

- **Not cryptography.** The procedural field is deterministic; anyone with
  the same generator can read any key.
- **Not a real quantum computer.** The simulator runs Shor's algorithm
  correctly but on classical hardware. For numbers beyond ~15 bits, a
  real quantum computer would be needed.
- **Not production.** The encoder has a precision floor at 48 bits, and
  the simulator is not hardened for adversarial input.

What it **is**:

- A **working quantum computer simulator** that correctly executes Shor's
  algorithm, Deutsch-Jozsa, Bernstein-Vazirani, quantum teleportation,
  superdense coding, and error correction — accessible from JavaScript.
- A **procedural-field data encoder** implementing the resolution-information
  trade-off `Q = R / 2^I` in executable code.
- A **teaching artifact** for quantum computing, information-theoretic
  foundations, and observer-relative resolution.
- A **research platform** with empirical CHSH/Bell tests, GHZ O(N) sampling,
  and entanglement visualization.

---

## Philosophy

> *We believe quantum is a concept, not a physical thing, and can be represented
> in many different ways — including software.*

This module is built on a particular reading of what "quantum" means:

- **The observer is the fourth dimension.** We live in a 4D universe where
  *people* are the observers — the act of observing is itself the fourth axis.
- **A tesseract perfectly describes the 4D nature of reality.** It's a
  representation of an observer that is observing a 3D object in 4D space:
  4D → 4D → 3D.
- **The observer changes the observed by the very act of observing it.** This
  framing fits the experimental record:
  - **Double-slit experiment** — observation collapses the interference.
  - **Entanglement** — two particles connected in 4D space; observing one
    changes the other.
  - **Superposition** — the observer determines which state is "real".
  - **Quantum tunneling** — a quantum thread that is *found* can be represented
    by a start point in spacetime and contain unlimited information by following
    the thread through spacetime; the only thing transmitted is the
    static-size key.
- **The quantum concept can be exercised on a 2D plane with time as the third
  dimension.** That's exactly what this code does: a 2D field of qubits, with
  `t` as the third axis, and the *observer* (the encoder/decoder) as the fourth.

This may not be a metaphor. The first version of this section proposed
*Q = h / N*, with *h* as the universe's native floor and *N* as the
observer's grid. That framing pointed at the right intuition but doesn't
survive a closer look — *h* is action (J·s), and dividing it by a
dimensionless count gives a smaller action, not a smaller position or
energy or time. To make the equation real you have to say which observable
you're resolving and what the observer's information about the system
actually is. The dimensionally-clean form is:

> **Q(O, S) = R(A) / 2^I(O; S)**

Read it as: an observer *O* measuring system *S* in observable *A* can
distinguish cells of size *Q*, where *R(A)* is the range of *A* in its
natural units (length for position, J for energy, etc.) and *I(O; S)* is
the Shannon mutual information **in bits** between the observer's
measurement record and the state of *S*. Each bit of mutual information
halves the cell size. Each bit gained is one octree level deeper into the
field.

This form is **observer-relative**, **dimensionally consistent**, and
recovers known physics in every limit you can throw at it:

| Setting | Plug in | Get back |
|---|---|---|
| Heisenberg conjugate pair (you commit σ_p in momentum) | I = log₂(R_x · σ_p / ℏ) | Q_x = ℏ / σ_p — the position floor, exactly |
| Ideal classical detector with N bins over range R | I = log₂(N) | Q = R / N — bin width |
| Holevo-bounded quantum measurement | I = χ(ρ, M) | Q = R / 2^χ — the Holevo capacity bound |
| The qubit field in this module with N-bit address | I = N | Q = R / 2^N — the octree cell size at level N |
| Maximum-entropy / no-information observer | I = 0 | Q = R — entire range is one cell |

The qubit field is one of those rows. The chain encoder in
`QuantumChainEncoder.swift` is *literally* an instance of this principle:
each bit of the message buys one octree level of resolution, which is one
bit of mutual information about the address. The master key is the
deepest leaf because the encoder has accumulated *I = bitCount* bits of
mutual information about a single point in the field.

Software is strictly more general than physical observation in one
specific way — *you can always add another bit*. There is no h-equivalent
floor in code. The qubit field in this module is currently a 25-bit
observer; widen the address and you widen the universe it can see.

See [`paper.md`](paper.md) for the full long-form whitepaper: seven
recovery cases (Heisenberg, Holevo, classical instrument, Compton, qubit
field, Gaussian channel, CHSH hierarchy), the trans-Planckian reframing,
the CHSH/Tsirelson empirical results with two figures, and an honest
accounting of what the framework does and doesn't claim.

See [`paper-engineer.md`](paper-engineer.md) for a 5-page engineer-focused
version with code examples and API documentation.

---

## Concept Overview

We are encoding a message into a field of qubits that twist and turn through
spacetime.

The core fundamental is finding a deterministic way to address **infinite
25-bit "blocks" with only 25 bits of search space**. The "infiniteness" comes
from two compounding densities:

1. As the view position moves out across the 2D grid, more qubits cluster
   into any given neighborhood.
2. The time dimension multiplies that density — each `t` step rearranges
   which qubits are nearby.

There is a **master key** — a 25-bit address pointing to the start of a
chain. From that one address you regenerate the entire field deterministically
and trace the chain to recover an arbitrary-length message.

We create the 2D field by placing qubits with random-but-deterministic
positions, speeds, radii, and phases (seeded by the seed component of the
address). We then search over a range of view positions `(vx, vy)`, time `t`,
read offset, and seed index to find a specific pattern of bits.

---

## The Key Insight

> **Old approach:** search for an exact 25-bit payload value — probability
> ~1 / 33 M per position. Statistically impossible.
>
> **New approach (this implementation):** search for payload popcount
> *ranges* — probability ~5–25 % per position. Tractable.

This single change is what makes the system actually work. The encoder no
longer has to find a precise needle in the haystack; it has to find a position
whose payload *falls inside the right slice*. With 4 slices, roughly one in
four positions matches any given target value, and chains of 8 values become
findable in a few seconds on GPU.

---

## How it works

### 1. The qubit field

A "qubit field" is 256 deterministic 2D points (each with position, speed,
radius, and phase) generated from a seed. The address space is laid out on a
32 × 32 × 32 × 32 × 32 grid:

| Component | Bits | Range | Meaning |
|-----------|------|-------|---------|
| `vx`      | 5    | 0-31  | view x-coordinate |
| `vy`      | 5    | 0-31  | view y-coordinate |
| `t`       | 5    | 0-31  | time step (× 0.1s) |
| `offset`  | 5    | 0-31  | which closest-qubit to start reading from |
| `seed`    | 5    | 0-31  | which seed generated this field |

Total: **25 bits** of address space ≈ 33.5 M positions.

### 2. Reading bits at an address

At any address `(vx, vy, t, offset, seed)`:

1. Find the `(offset + 25)` qubits closest to `(vx, vy)`.
2. For each of the next 25 qubits, advance its angle by `t` and compute the
   cross-product of its motion vector with `(vx, vy)`. The sign becomes a
   binary bit.
3. Concatenate the 25 bits into a 25-bit "payload".

### 3. Slice-based data encoding

Instead of using exact payload matching (statistically impossible), we use
**popcount slices**:

- The popcount of a 25-bit payload ranges from 0 to 25 (26 values).
- We divide the **usable** popcounts (3 – 22) into `NUM_SLICES` ranges
  (e.g. 4 slices for 2 bits, 8 for 3 bits, 16 for 4 bits).
- Popcounts **0 – 2** and **23 – 25** are reserved as **end markers**.
- Each position's *data* is determined by which slice its payload popcount
  falls into.
- This gives ~5× coverage per slice — each slice covers roughly 25 % of the
  popcount distribution.

### 4. Chain construction

A "chain" is a walk through the field where **each payload IS the next
address**:

```
position₀  →  read 25 bits  →  payload₀   (encodes 2 bits of data via slice index)
   ↓
position₁ = payload₀  →  read 25 bits  →  payload₁   (next 2 bits)
   ↓
position₂ = payload₁  →  read 25 bits  →  payload₂   (next 2 bits)
   ↓
... until end-marker payload (popcount ≤ 2 or ≥ 23)
```

The encoder searches for a `position₀` (the **master key**) whose chain
produces the desired sequence of slice values. Long messages are chunked
(default: 8 values = 16 bits = 2 ASCII chars per chain), each producing its
own master key.

### 5. Knowledge / requirements

- **5 bits each:** vx, vy, t, offset, seed = **25 bits total**
- **Search space:** 2²⁵ = 33.5 M positions
- **Data encoding:** popcount slices (2 – 4 bits per chain step)
- **End markers:** popcount ≤ 2 or popcount ≥ 23
- **Chain rule:** position → read payload → payload IS next address
- **Encoder job:** find a chain where each payload's popcount slice matches
  the required data slice

### 6. GPU acceleration

`QuantumGPU` runs three Metal compute kernels in
`Resources/QuantumSearch.metal`:

| Kernel | Purpose |
|--------|---------|
| `quantum_search_by_slice`   | Find positions whose payload popcount falls in a target slice. |
| `quantum_search_exact`      | Find positions with an exact payload match. |
| `quantum_search_and_trace`  | Combined: find first-slice match, trace chain, verify full sequence. |

The combined `search_and_trace` kernel is the hot path: it parallelizes the
entire chain search across the GPU's thread grid.

CPU fallback exists for tvOS Simulator and other platforms without Metal.

---

## A Second Encoder: Resolution-Deepening Chains

The slice-based encoder above produces *multiple* master keys for any
message longer than ~2 ASCII characters (chunked into chains of 8 values
each). For some uses you want a **single** master key for the whole
message — one address you can write down, transmit, and unwind into the
original data with no chunking metadata.

`QuantumChainEncoder` does that, with a twist that matches the philosophy
section literally: **each bit of the message lives at a different
resolution of the quantum window.**

### The shape of the chain

For an N-bit message `b[0] b[1] … b[N-1]`:

- **Bit `b[N-1]` (the LAST bit)** lives at level 1 — the coarsest cell. The
  field is divided into 8 cells (1 bit per axis: vx, vy, t each ∈ {0, 1}).
  This is the "observable" end of the chain — the cell humans can see at
  low resolution.
- **Bit `b[N-2]`** lives at level 2 — each axis gets one more bit, so the
  field is divided into 64 cells. The level-2 cell that holds `b[N-2]` is a
  *child* of the level-1 cell that holds `b[N-1]`.
- ...
- **Bit `b[0]` (the FIRST bit)** lives at level N — each axis is N bits
  wide. This is the deepest octree cell. Its full N-bit `(vx, vy, t)`
  coordinates are the **master key**.

Adding one bit to each axis subdivides every cell into 8 children. So
encoding bit by bit *zooms* into a smaller and smaller region of the field,
and the master key is the deepest leaf of that octree walk.

### The encoder walks backwards

```
encode(b[N-1]) at level 1   →  pick one of 8 cells whose payload-slice == b[N-1]
encode(b[N-2]) at level 2   →  pick one of its 8 child cells matching b[N-2]
encode(b[N-3]) at level 3   →  pick one of THAT cell's 8 children matching b[N-3]
…
encode(b[0])   at level N   →  the chosen cell's full (vx, vy, t) IS the master key
```

If no child of a parent cell matches the target bit, the encoder
**backtracks** and tries a different parent. If a whole seed exhausts its
backtrack budget (5 000 node visits, ~0.3 s), the encoder rotates to the
next seed and starts over.

### The decoder walks forwards from the deepest point

```
read at master key (level N)   →  popcount slice == b[0]   (FIRST bit)
shift each axis right by 1                                  (level N-1)
read at level N-1              →  popcount slice == b[1]
…
shift                                                       (level 1)
read at level 1                →  popcount slice == b[N-1] (LAST bit)
```

The decoder is **deterministic** and **fast** — no search, just N reads.
Playback starts at the high-precision master-key point and walks *upward*
through resolution to the observable level-1 cell. The first bit you see
during playback was the *last* bit found by the encoder; the last bit you
see was the *first* bit found by the encoder.

### Cell-centered mapping

To prevent parent and child cells from collapsing onto the same fractional
position, every cell is sampled at its *center*:

```
fvx = (vx_int + 0.5) / 2^level × FIELD_SIZE
```

A level-1 cell `vx=0` is at fractional `vx=8` (center of `[0, 16)`); its
level-2 children `vx=0` and `vx=1` are at `vx=4` and `vx=12` — both *inside*
`[0, 16)` but neither equal to the parent. This is what guarantees that
each level reads genuinely different qubit windows.

### Performance and limits

The chain encoder is implemented in **Double precision** so cells remain
distinguishable down to about level 52. The current cap is **48 bits per
message** — roughly 6 ASCII characters per single key — to leave precision
headroom.

| Message | Time (typical) |
|---|---|
| 1 char (8 bits) | ~0.1 s |
| 2 chars (16 bits) | ~0.05 s |
| 3 chars (24 bits) | varies — fast for friendly bit patterns, up to ~12 s for unfriendly |
| 5 chars (40 bits) | ~0.2 s (often faster than 3 chars!) |

Latency is wildly bit-pattern-dependent because the backtracking sometimes
hits dead ends; some seeds are friendly to some patterns and hostile to
others. The 5 000-node-per-seed budget caps worst-case latency at ~10 s.
For longer messages, fall back to the slice-based multi-key encoder.

---

## Outcomes

The slice-based design produces three properties that fall out of the
architecture for free:

- **Storage becomes trivial.** Just store the master key(s) and regenerate the
  qubit field on demand. A 1 KB message and a 1 byte message both occupy the
  same fixed-size key footprint.
- **Transmission becomes trivial.** Just send the master key over any channel.
  The receiver regenerates the identical field deterministically and traces
  the chain to recover the data. Wire size is decoupled from payload size.
- **Security becomes meaningful.** Brute-forcing 25 bits is trivial — but the
  qubit field adds a layer of complexity: an attacker who doesn't know which
  seed offset / popcount slice configuration was used cannot reconstruct the
  field. (See **Caveats** for honest limits — this is obfuscation, not
  cryptography.)

---

## Bigger Than the Universe

A direct consequence of *Q = R / 2^I*: scale up the address resolution
(equivalently, accumulate more mutual information about a single field
cell) and the quantum window can contain more distinguishable states than
there are atoms in the universe. The threshold is shockingly low.

| Quantity | Value |
|---|---|
| Atoms in the observable universe | ~10⁸⁰ ≈ **2²⁶⁶** |
| Current window (25-bit) | 2²⁵ ≈ 33.5 M addresses |
| Window needed to exceed all atoms | **~266 bits** (≈ 53 bits per axis) |
| 64-bit-per-axis window | 2³²⁰ ≈ 10⁹⁶ addresses (16 orders of magnitude past the universe) |
| 128-bit-per-axis window | 2⁶⁴⁰ — more than the *square* of the universe's atom count |

There is no mathematical ceiling. Each axis is just an integer. Make it wider.

### Why this works at all

**The field is defined, not stored.** The qubit at address
`(10²⁰⁰, 10²⁰⁰, …)` exists in the sense that `SplitMix64(seed)` is a
well-defined function that will return a specific value if you ask. But
nothing is instantiated until you ask. The whole field is *lazy*. You only
pay (in computation, in memory) for the addresses you actually query.

So the quantum window is unbounded the same way `[1..]` in Haskell is
unbounded, or the way "the digits of π" are unbounded. The set of
*describable* states is mathematically larger than the universe. The set of
*instantiated* states is whatever you happened to read.

### Where physics actually pushes back

The address space being larger than the universe is fine. The places you
hit real walls are downstream of it:

- **Search.** Lloyd's limit says the universe could have performed at most
  ~10¹²⁰ operations since the Big Bang. So exhaustive search beyond ~400
  bits of address space is *more compute than the universe has ever done*
  — by every star, black hole, and atom treated as a computer, since
  the beginning of time. You can address 2¹⁰⁰⁰⁰ states; you cannot find a
  specific one by brute force.
- **Bekenstein bound.** The maximum information physically storable in a
  region of space scales with its surface area (holographic principle). The
  observable universe maxes out at ~10¹²² bits total. You can *describe* an
  address that needs more bits than this to represent — you just cannot
  *physically write down* that address inside our universe.
- **The key itself.** Every bit you add to the address space is a bit you
  have to store in the master key. A 1000-bit address means a 125-byte
  key. You don't get something for nothing — you've moved the storage cost
  from "data" to "key," but it's still there. This is the
  Kolmogorov / Shannon ceiling reasserting itself.

### The honest punchline

| Claim | True? |
|---|---|
| The mathematical address space can exceed the universe's atom count. | ✅ Trivially. ~266 bits. |
| You can store a key that points to any specific address in that space. | ✅ As long as the key fits in the universe's information capacity (~10¹²² bits). |
| You can search the entire space for matches. | ❌ Hard ceiling around 2⁴⁰⁰ even granting the entire universe as your computer. |
| Most of those addresses correspond to "real" things in any meaningful sense. | ❌ They're potential states. The field is defined everywhere, instantiated nowhere until queried. |

### The pop

A single 100-bit-per-axis quantum window contains more distinguishable
potential states than the observable universe has particles, bonds, quantum
states, Planck volumes, or any other physical accounting unit you care to
use. It is, in a real sense, **larger than the universe it's running
inside.** It just fits because it's lazy.

This is the same trick a brain plays when it imagines the integer 10¹⁰⁰⁰⁰.
That number doesn't fit in your head, the room you're in, or the planet.
But you can point at it, manipulate it symbolically, and prove things about
it. The qubit field is doing the same trick — holding the *handle* to a
space larger than the universe, and only ever touching the parts you ask
about.

That's not an analogy. That's literally what the code does.

---

## Usage

### Cache

```swift
import JeffJS

let cache = QuantumCache()
cache.store("Hello, world!", forKey: "greeting")

let value = cache.retrieve(forKey: "greeting")  // "Hello, world!"
```

### Transport

```swift
let tx = QuantumTransport()

// Encode
let envelope = tx.prepare("Hi")!
let wire = envelope.serialize()       // ~14 bytes
let hex  = envelope.hexString         // for text channels

// Decode
let received = QuantumEnvelope.deserialize(from: wire)!
let message  = tx.receive(envelope: received)  // "Hi"
```

### Direct encoder / decoder

```swift
let encoder = QuantumEncoder()
let decoder = QuantumDecoder()

let result = encoder.encode("Hi")!
print(String(format: "Master key: 0x%07X", result.keys[0]))

let decoded = decoder.decodeString(result: result)  // "Hi"
```

### Chain encoder / decoder

```swift
let encoder = QuantumChainEncoder()
let decoder = QuantumChainDecoder()

let key = encoder.encode("Hi")!     // single QuantumChainKey
print(key.hexString)                // 64-hex-char serialized form
let plain = decoder.decodeString(key)  // "Hi"

// Round-trip through the wire format
let wire = key.hexString
let restored = QuantumChainKey.fromHex(wire)!
let plain2 = QuantumChainDecoder().decodeString(restored)
```

### JavaScript API

When `quantum.enabled` is `true`, the bridge installs `window.jeffjs.quantum`
inside the JeffJS runtime:

```js
window.jeffjs.version             // "1.0.0"
window.jeffjs.quantum.enabled     // true

// --- Slice-based encoder (multi-key envelope) ---

// Envelope round-trip — single self-contained string
const env = window.jeffjs.quantum.slice.encode("Hi");
window.jeffjs.quantum.slice.decode(env);  // "Hi"

// Raw master-key form — bare 25-bit address(es)
const r = window.jeffjs.quantum.slice.encodeRaw("Hi");
// r = { keys: ["0x1234567"], length: 2, seedOffset: 0 }

window.jeffjs.quantum.slice.decodeRaw(r);                            // "Hi"
window.jeffjs.quantum.slice.decodeRaw(r.keys, r.length, r.seedOffset); // "Hi"
window.jeffjs.quantum.slice.decodeRaw("0x1234567", 2, 0);            // "Hi"

// --- Chain encoder (single master key, max ~6 chars) ---

// Sync — blocks the main thread for up to ~10s on hard bit patterns.
const k = window.jeffjs.quantum.chain.encode("Hi");
// "011002000000000016980000000000006c160000000000000901000000000000"
// (64 hex chars = 32 bytes: version + bitCount + msgLen + seed + vx + vy + t)

window.jeffjs.quantum.chain.decode(k);   // "Hi"

// Async — returns a real Promise, runs the encoder on a background queue,
// resolves on the main thread without ever blocking the JS event loop.
window.jeffjs.quantum.chain.encodeAsync("Hi").then(function (k) {
    return window.jeffjs.quantum.chain.decodeAsync(k);
}).then(function (plain) {
    console.log(plain);   // "Hi"
});

// Async/await also works inside an async function:
async function roundTrip(s) {
    const k = await window.jeffjs.quantum.chain.encodeAsync(s);
    return await window.jeffjs.quantum.chain.decodeAsync(k);
}
```

`slice.encode`/`slice.decode` use the envelope format (slice-based,
multi-key). `slice.encodeRaw`/`slice.decodeRaw` give you bare 25-bit
master keys. `chain.encode`/`chain.decode` use the resolution-deepening
chain encoder — **one** master key per message, but capped at ~6
characters. `chain.encodeAsync`/`chain.decodeAsync` are the same chain
encoder running on a background queue and returning real
`Promise<string>` — use these in any real app since the worst-case ~10 s
search would otherwise hang the JS event loop.

#### How the async bridge works

The async pattern is the same one `JeffJSFetchBridge` uses for `fetch()`:

1. The native function `__nativeChainEncodeAsync(plaintext, resolve, reject)`
   takes the JS Promise resolvers as plain function arguments.
2. A JS shim wraps it in `new Promise(function (res, rej) { … })` so callers
   get a real Promise:
   ```js
   q.chain.encodeAsync = function (plaintext) {
       return new Promise(function (resolve, reject) {
           q.chain.__nativeEncodeAsync(String(plaintext), resolve, reject);
       });
   };
   ```
3. The Swift side `dupValue()`s the resolver callbacks and stores them in a
   per-request dictionary so they survive the thread hop.
4. A background `Task { … }` instantiates a fresh `QuantumChainEncoder` (it's
   not actor-isolated and owns its own field cache, so it's safe to use
   off-main) and runs the search.
5. When done, `await MainActor.run { … }` hops back to the main thread,
   sets `JeffJSGCObjectHeader.activeRuntime` so newly-created JS values
   bind to the right runtime, calls `ctx.call(resolve, this:, args:)`, and
   then `ctx.rt.executePendingJobs()` to flush any `.then()` microtasks.

---

## Configuration

All flags live in `Sources/JeffJS/Resources/JeffJSConfig.plist`:

| Key | Default | Description |
|-----|---------|-------------|
| `quantum.enabled`           | `true`  | Master switch. |
| `quantum.preferGPU`         | `true`  | Use Metal when available. |
| `quantum.dataBits`          | `2`     | Bits per chain step (2 / 3 / 4). |
| `quantum.maxChainValues`    | `8`     | Max values per chain before chunking. |
| `quantum.maxEncodeAttempts` | `100`   | Max seed-offset retries when encoding. |

Read them via `JeffJSConfig.quantumEnabled`, etc.

---

## Files

| File | Purpose |
|------|---------|
| `QuantumConfig.swift`        | Constants, slice-range tables. |
| `QuantumAddress.swift`       | 25-bit address packing & popcount utilities. |
| `QuantumQubit.swift`         | Deterministic qubit field generation & bit reading. |
| `QuantumGPU.swift`           | Metal-backed search (conditional on `canImport(Metal)`). |
| `QuantumEncoder.swift`       | Encode bytes → master keys (GPU + CPU paths). |
| `QuantumDecoder.swift`       | Decode master keys → bytes. |
| `QuantumCache.swift`         | Key-value cache wrapping the encoder/decoder. |
| `QuantumTransport.swift`     | Wire-format envelope + send/receive helpers. |
| `QuantumChainKey.swift`      | Single-key chain master key + binary serialization. |
| `QuantumChainField.swift`    | Double-precision qubit field for the chain encoder. |
| `QuantumChainEncoder.swift`  | Backward octree-search chain encoder (`chain.encode`). |
| `QuantumChainDecoder.swift`  | Forward truncation chain decoder (`chain.decode`). |
| `JeffJSQuantumBridge.swift`  | JavaScript bridge (`window.jeffjs.quantum.slice.*` and `window.jeffjs.quantum.chain.*`). |
| `../Resources/QuantumSearch.metal` | Compute kernels. |

---

## Caveats

- **Not cryptography.** The 25-bit address space brute-forces in milliseconds.
  The qubit field is deterministic; anyone with the same seed offset can
  decode any envelope. Treat this as obfuscation, not encryption.
- **Encoding latency.** Encoding scales with chain length and may take
  multiple seconds on CPU for messages longer than a few characters. Always
  GPU-search when latency matters.
- **Chain encoder is also not encryption.** `chain.encode`/`chain.decode`
  are the same kind of obfuscation as the slice-based encoder — anyone
  with the same field generator can decode any master key. The two JS
  sub-namespaces (`slice` and `chain`) exist only to separate the two
  algorithms, not to imply one of them is cryptographic.
- **Chain encoder length cap.** The chain encoder is capped at 48 message
  bits (~6 ASCII chars) due to the Double-precision floor. For longer
  messages use the slice-based `slice.encode`/`slice.encodeRaw` (which
  chunks into multiple keys).
- **Determinism.** The qubit field is deterministic for a given seed offset,
  but the underlying PRNG (`SplitMix64`) is implementation-specific. Two
  different implementations of this encoder will only round-trip if they use
  the same PRNG and the same field-generation parameters.

---

## Files in this directory

### Swift source (compiled into the JeffJS module)

| File | What |
|---|---|
| `QuantumState.swift` | `Complex64` type + state vector + CPU gate operations |
| `QuantumCircuit.swift` | Unified circuit API (routes to Metal GPU or CPU) |
| `QuantumSimulatorGPU.swift` | Metal compute pipeline dispatch layer |
| `QuantumAlgorithms.swift` | Shor's, Deutsch-Jozsa, Bernstein-Vazirani, teleport, superdense, error correction |
| `QuantumStabilizer.swift` | Gottesman-Knill stabilizer tableau (1000+ qubits) |
| `QuantumCliffordT.swift` | T-gate extension via stabilizer decomposition |
| `QuantumBellCHSH.swift` | 8 CHSH variants + GHZ O(N) streaming sampler |
| `QuantumSimulatorBridge.swift` | JS API for `window.jeffjs.quantum.simulator.*` |
| `JeffJSQuantumBridge.swift` | JS API for chain/slice encoders + simulator registration |
| `QuantumChainEncoder.swift` | Resolution-deepening octree encoder |
| `QuantumChainDecoder.swift` | Chain decoder (octree walker) |
| `QuantumChainField.swift` | Double-precision procedural qubit field |
| `QuantumChainKey.swift` | Chain key serialization (64 hex chars) |
| `QuantumEncoder.swift` | Slice-based encoder with GPU search |
| `QuantumDecoder.swift` | Slice-based decoder |
| `QuantumGPU.swift` | Metal kernels for slice-based field search |
| `QuantumQubit.swift` | Float-precision qubit field + SplitMix64 PRNG |
| `QuantumAddress.swift` | 25-bit address packing |
| `QuantumConfig.swift` | Constants and configuration |
| `QuantumTransport.swift` | Wire format and envelope framing |
| `QuantumCache.swift` | Persistent quantum-backed key-value store |

### Metal shaders (in `Resources/`)

| File | What |
|---|---|
| `QuantumSimulator.metal` | 6 GPU kernels: hadamard, pauli_x, cnot, controlled_mod_mult, phase_gate, measure_prob |
| `QuantumSearch.metal` | GPU kernels for slice-based field search |

### Documentation

| File | What |
|---|---|
| `paper.md` → `paper.pdf` | Long-form whitepaper (48 pages, 2 figures) |
| `paper-engineer.md` → `paper-engineer.pdf` | Engineer's edition (5 pages) |
| `experiments.md` | Research agenda: 12 proposed experiments |
| `PAPER_BUILD.md` | How to build the PDFs |
| `README.md` | This file |

### Python prototypes (excluded from SPM build, kept for reference)

| File | What |
|---|---|
| `chsh_prototype.py` | 8 CHSH variants + GHZ scaling test |
| `ghz_simulator.py` | O(N) GHZ sampling, 1M qubits |
| `stabilizer_sim.py` | Gottesman-Knill + CliffordT simulator |
| `quantum_algorithms.py` | Deutsch-Jozsa, Bernstein-Vazirani, Toffoli |
| `shor_factor_15.py` | Shor's for N=15 (original) |
| `shor_general.py` | General Shor's (Python loops) |
| `shor_fast.py` | Vectorized numpy Shor's |
| `shor_iterative.py` | Iterative phase estimation Shor's (fastest) |

### Visualizations

| File | What |
|---|---|
| `chsh_correlation_curves.png` | Figure 1: classical triangle vs quantum cosine |
| `chsh_correlation_plot.py` | Script that generates Figure 1 |
| `qubit_field_entanglement.png` | Static entanglement visualization |
| `qubit_field_filmstrip.png` | Figure 2: 4-frame filmstrip with sub-resolution barrier |
| `qubit_field_entanglement.gif` | Animated version (48 frames) |
| `qubit_field_entanglement_viz.py` | Script that generates the visualizations |
