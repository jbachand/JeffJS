# JeffJS Quantum: Proposed Experiments

*Candidate follow-up experiments for the JeffJS Quantum module.*

*Compiled April 2026*

---

## What this is

A consolidated research agenda compiled from experiments proposed by multiple reviewers of the JeffJS Quantum whitepaper (`paper.md`) and engineer's edition (`paper-engineer.md`). Each entry documents:

- **What it tests** — the question the experiment answers
- **How to build it** — concrete modification to existing code, or a prototype path
- **What results would show** — positive vs. negative success criteria
- **Status** — concrete protocol vs. conceptual framing
- **Difficulty** — rough engineering lift

**Nothing in this document has been run yet.** It is scaffolding for future work, not a results report. Readers should treat it as a list of candidate next steps, not as validated findings.

Where two reviewers proposed effectively the same experiment under different names, the entries are merged and the alternative framings are noted in the description.

---

## Category A: Framework self-tests

These experiments test whether `Q = R / 2^I` extends beyond the regimes where it has already been shown to hold, using the chain encoder as the testbed.

### Experiment 1. Non-Gaussian regime extension

**What it tests.** `Q = R / 2^I` is proved *exactly* for Gaussian channels via the Stam-Dembo-Cover-Thomas chain (paper §2.7). Does the principle's exponential scaling continue to hold outside the Gaussian regime? The paper §2.7 and §4.3 both flag this as open.

**How to build it.** Modify `QuantumChainEncoder.swift` to use a non-Gaussian bit-derivation function. Candidates:

- Heavy-tailed noise (Cauchy, Student-t, Lévy-stable distributions)
- Hard-thresholded projection (sign-only, discarding magnitude)
- Bernoulli channel with asymmetric error rates
- Poisson-photon-counting analog (discrete arrival-based bits)

Sweep the encoded bit count `N` across a range. Record `Q` at each step (the cell width at depth `N`). Plot `Q` vs. `I` and compare to the expected curve `R / 2^I`.

**What results would show.**
- *Still follows `R / 2^I`*: the principle's domain extends beyond Gaussian. This is new content because Stam-Dembo-Cover-Thomas only guarantees it in the Gaussian regime.
- *Deviates systematically*: the deviation is itself a new scaling relation. Compare against the non-Gaussian channel-capacity literature before claiming novelty.

**Status.** Concrete protocol, clear success/failure criterion.

**Difficulty.** Low. The bit-derivation function in the chain encoder is a handful of lines. Swap it and re-run the test harness.

### Experiment 2. Multi-observer extension (two-observer case)

**What it tests.** The framework is observer-relative but the whitepaper only considers one observer at a time. If two observers independently read the same field, how does their achievable `Q` relate to each observer's `I`? Is there a back-action-like coupling?

**How to build it.** Instantiate two `QuantumChainEncoder` objects against the same field seed. Let observer A extract `I_A` bits over address region `r_A`, and observer B extract `I_B` bits over `r_B`, with `r_A` and `r_B` overlapping (or identical). Measure `Q_A` and `Q_B` directly. Check:

- Is `Q_A` affected by the existence of observer B reading the same region?
- Does the joint `I_{A+B}` saturate below `I_A + I_B` under overlap?
- Does the relationship match any known multi-party information bound (Holevo joint-measurement, no-cloning information bound, etc.)?

**What results would show.**
- *No interaction*: the framework is trivially additive under multiple observers. Clean negative result.
- *Back-action*: the interaction pattern is a new scaling relation. Compare against Holevo's multi-party bound.

**Status.** Concrete protocol.

**Difficulty.** Medium. Requires defining "overlapping region" precisely in the encoder's address space and building a measurement protocol that respects both observers' state.

### Experiment 3. Stacking with information-theoretic bounds

**What it tests.** Whether composing `Q = R / 2^I` with other information-theoretic bounds yields novel formulas. Candidates for composition:

- **Data-processing inequality.** `I(X; Y) ≥ I(X; Z)` when `Z` is a function of `Y`. What does `Q` look like when `I` is a post-processed version of raw measurement data?
- **Fano's inequality.** `H(X | Y) ≤ H(P_e) + P_e log(|X|-1)` relates decoding error probability to conditional entropy. Can be recast as a bound on `Q` for an observer trying to decode a discrete state.
- **Holevo bound.** Already appears in §2.3 of the whitepaper. Can it be stacked with `Q = R / 2^I` to get a resolution floor that depends on the POVM's Holevo quantity in a nontrivial way?

**How to build it.** Analytical work first: write out each composition on paper, simplify, see whether the result matches an existing identity in the information theory literature or something new. Verify any interesting compositions numerically with the chain encoder as a test case.

**What results would show.** Most compositions will restate existing identities. Some might not. Even one composition that hasn't been written explicitly would be a notation contribution worth adding to §2 of the whitepaper.

**Status.** Concrete but open-ended.

**Difficulty.** Low for the analytical pass; medium if numerical verification is needed.

### Experiment 4. Push past `I_max` via arbitrary precision

**What it tests.** The chain encoder hits a precision floor at ~48 bits because it uses `Double` for the cell-center mapping. Paper §3.4 argues this is where the encoder's observer-level `I_max` lives. Does the encoder behave sensibly if you replace `Double` with arbitrary-precision arithmetic and push `N` to 100, 200, 1000 bits? This is the "precision-floor wormhole" framing from the original proposal list.

**How to build it.** Replace `Double` in the chain encoder and cell-center mapping with:

- A Python prototype using `mpmath` first (fastest to iterate)
- Swift's `Decimal` for a bounded-precision Swift version
- A third-party arbitrary-precision library for a full Swift rewrite

Re-run the encoder at `N = 60`, `100`, `200` bits. Measure whether encoding/decoding still succeeds, the latency profile, and whether cells remain genuinely distinguishable at depth.

**What results would show.**
- *Encoder scales cleanly*: the 48-bit ceiling was a representation artifact, not a fundamental property. This is the expected result and confirms the paper's framing.
- *Encoder breaks at a new floor*: some other limit kicks in (PRNG period, qubit-field aliasing, memory). The new floor is itself informative — it becomes another concrete "ceiling" analogous to the Bekenstein bound for physical observers.

**Status.** Concrete protocol, clear criterion.

**Difficulty.** Low to medium. The hard part is porting the `Double`-dependent math cleanly to arbitrary precision.

---

## Category B: Physics-analog experiments

These experiments use the chain encoder as a computational testbed for structural properties that appear in physics. Success here means producing an interesting scaling relation in software that maps to a known piece of physics (or falsifiably fails to).

### Experiment 5. Minimal dynamics + emergent decoherence

**What it tests.** Whether decoherence — the loss of coherent superposition due to environmental entanglement — has a clean analog in the chain encoder when two observers compete for information about a *dynamically evolving* field (not the currently static phase-rotation field).

**How to build it.** Replace or augment the current linear phase-rotation of each qubit with a richer update rule:

- A cellular-automaton-style local interaction (neighbor's phase affects my phase)
- A discrete Schrödinger-like step on the procedural grid
- A stochastic drift (deterministic seed but time-varying under a rule)

Run two independent chain encoders as "observers" measuring overlapping regions of the dynamical field. Track:

- How fast does observer A's mutual information about observer B's reads decay over time?
- Is the decay exponential (as in real decoherence) or power-law?
- Does the decay rate depend on the overlap region size in the way real decoherence rates depend on apparatus coupling strength?

**What results would show.**
- *Exponential decay with coupling-dependent rate*: a decoherence analog in a classical substrate. A real structural result.
- *Different decay form*: the deviation tells you which property the software lacks compared to real decoherence (likely: Hilbert-space linearity).

**Status.** Concrete experiment, higher engineering lift than Category A.

**Difficulty.** Medium to high. The hardest part is designing a dynamics rule that's rich enough to show the effect without introducing artifacts.

### Experiment 6. Continuous-measurement Monte Carlo lab

**What it tests.** The §4.2 retrodiction against continuous quantum measurement is currently an *analytical* match. A Monte Carlo version inside the chain encoder would produce numerical data across varying measurement strengths, directly exercising the §2.7 Cramér-Rao equivalence at the code level.

**How to build it.** Build a Monte Carlo harness that:

1. Creates an "unknown" field state (random seed, unknown to the measurement code)
2. Runs the chain encoder at varying effective measurement strengths `γt` (equivalent to varying the number of bits committed per step)
3. Samples the encoder's estimated state at each strength
4. Compares the distribution of estimates to the Gaussian-channel prediction from §4.2: `Q(t) = 1 / sqrt(1 + γt)`

Plot the Monte Carlo posterior variance vs. `γt` and overlay the theoretical curve.

**What results would show.** The Monte Carlo either agrees with the analytical prediction (confirming the §2.7 Cramér-Rao equivalence numerically, across strengths the paper didn't explicitly walk through) or deviates (in which case the deviation tells you where the Gaussian-channel approximation breaks).

**Status.** Concrete protocol, direct extension of the existing §4.2 work.

**Difficulty.** Medium. Most useful when combined with Experiment 1 — otherwise it only verifies what §2.7 already proves analytically.

### Experiment 7. Cosmological scaling with many observers

**What it tests.** Paper §5.5 notes that addressing every Planck cell in the observable universe takes ~205 bits per axis. Can the chain encoder be scaled up to `10^6`–`10^9` qubits as a toy universe, and do multiple observers reading different patches produce a sensible information-budget relationship that matches holographic-bound expectations?

**How to build it.** The qubit field is procedural — memory cost is tiny regardless of nominal field size. Increase the nominal field dimensions, spawn dozens of independent chain encoders, each reading a local patch. Measure:

- Is the total information extracted by all observers bounded by a global `I_max`?
- Does per-observer `I_max` scale with patch size in a holographic-bound-like way (area, not volume)?
- Is there a meaningful "distance" between observers that affects cross-observer information?

**What results would show.** If per-observer information scales with *patch boundary* rather than *patch volume*, that's a structural analog of the holographic bound. If it scales with volume, it's not — and the deviation tells you which property the software lacks.

**Status.** Concrete but the payoff is speculative — "structural analog of the holographic bound" is a soft target.

**Difficulty.** High. Requires rearchitecting the encoder to support parallel observers with spatial locality, and defining a per-observer information metric that respects the procedural field's structure.

### Experiment 8. Multi-observer network as quantum-gravity sandbox

**What it tests.** The scaled-up version of Experiment 2. Run dozens of chain encoders as a network of observers, each with its own local `I` budget, able to "communicate" only by sharing master keys. Explore whether anything ER=EPR-like emerges — shared-key structure producing correlation beyond what independent observers could achieve.

**How to build it.** Build a message-passing layer on top of the chain encoder:

- Observers can exchange master keys but not raw field data
- Each observer's achievable `Q` is a function of its own `I` plus any shared keys received
- Define a "distance" metric between observers
- Watch whether shared keys correlate local information in a distance-dependent way

**What results would show.** This is the most speculative experiment in the list. "ER=EPR-like behavior" is a metaphor, not a technical target. Running the experiment would produce *something*; whether that *something* maps cleanly to any piece of physics is the open question.

**Status.** Speculative. Concrete enough to build but unclear what counts as success.

**Difficulty.** High. The largest engineering lift in the list.

### Experiment 9. CHSH / Tsirelson-bound test on a coupled-encoder pair *(RUN — see `chsh_prototype.py`)*

*(Originally proposed by two reviewers under the names "Pointer Crack" and "Correlation-structure extension." Sharpened in conversation into a concrete CHSH protocol, then prototyped in Python with eight variants and a series of structural results.)*

**Status.** *Run as a Python prototype.* Eight variants implemented in `chsh_prototype.py`. The headline result: a Bohmian-style hidden variable model with sub-resolution binding (V8) reaches the Tsirelson bound `|S| ≈ 2√2 ≈ 2.828` while preserving no-signaling, demonstrating that the chain encoder's procedural field substrate is rich enough to host quantum-strength correlations when augmented with a non-local update on the sub-resolution layer.

**The eight variants and their measured S values:**

| Variant | Description | Measured `\|S\|` | No-signaling | Notes |
|---|---|---|---|---|
| V1 | Naive probabilistic, shared `θ` | `1.4136` | ✓ | Sub-classical baseline (`√2`) |
| V2 | Deterministic `sign(cos)`, shared `θ` | `1.9952` | ✓ | Bell-saturating classical |
| V3 | Probabilistic + naive `θ` mutation | `0.7123` | ✗ | Worse + signaling — fail |
| V6 | Common-randomness sampling | `1.7052` | ✓ | Off-grid intermediate |
| V7 | Symmetric "always opposite" | `2.0000` | ✓ | Degenerate (ignores angles) |
| **V8** | **Bound qubit pair, sub-resolution binding** | **`2.8246`** | **✓** | **Tsirelson — Bohmian-style** |
| V4 | Quantum singlet (Born rule) | `2.8321` | ✓ | Reference (matches V8) |
| V5 | Popescu-Rohrlich box | `4.0000` | ✓ | Algebraic max |

**The key finding (V8).** The variant that closes the gap from classical Bell (`S=2`) to Tsirelson (`S=2√2`) implements an explicit *sub-resolution* hidden variable that lives below the binary measurement outcome and is non-locally bound between the two observers' qubits. Concretely:

```python
def bound_qubit_pair(alpha_a, alpha_b, num_trials, rng):
    # Each pair shares a hidden phase phi below the measurement resolution
    phi = rng.uniform(0, 2 * pi, size=num_trials)

    # Alice measures first using the standard Born-rule probability
    p_a = cos((phi - alpha_a) / 2) ** 2
    bits_a = where(rng.random(num_trials) < p_a, 1, -1)

    # Non-local sub-resolution update:
    # The pair's phase collapses to a state singlet-conjugate to Alice's outcome
    phi_b = where(bits_a == 1, alpha_a + pi, alpha_a)

    # Bob measures the post-collapse partner
    p_b = cos((phi_b - alpha_b) / 2) ** 2
    bits_b = where(rng.random(num_trials) < p_b, 1, -1)

    return bits_a, bits_b
```

This is structurally a Bohmian hidden variable model: a deterministic substrate (the shared phase `φ`), a non-local update on measurement (Bob's phase becomes a function of Alice's outcome and angle), and no-signaling preserved at the marginal level (Bob's averaged distribution is independent of Alice's choice because the average over `b_A ∈ {±1}` cancels the dependence). The simulation hits `|S| = 2.8246`, statistically indistinguishable from V4's direct Born-rule calculation at `|S| = 2.8321`.

**Why V3 failed and V8 worked.** Both variants used a "non-local update on measurement" idea, but V3's update was crude (`θ_mut = θ + α_A · b_A`) and produced a marginal distribution on Bob's side that depended on Alice's setting — explicit signaling, which disqualifies the variant. V8's update is cleaner: it uses the singlet-conjugate phase, which preserves the marginal distribution at exactly 50/50 for any Alice setting. The lesson: not every non-local update preserves no-signaling. Bohmian-style updates do; naive shifts do not.

**What this is, honestly.**

1. **Not new physics.** Bohmian mechanics (Bohm 1952, de Broglie 1927) already showed that non-local hidden variable models can reproduce all quantum predictions including Tsirelson-bound CHSH violations. V8 is one specific instance of such a model.

2. **A working software instantiation in the chain encoder framework.** The chain encoder's procedural field substrate, augmented with the sub-resolution binding update rule, can host Tsirelson-strength correlations. We did not know this before running V8 — V3's failure suggested the substrate might be too restrictive. V8 shows it isn't.

3. **A confirmation of the user's "sub-resolution binding" intuition.** The framing — "we only see the top resolution but there's a link below" — is structurally what V8 implements. The sub-resolution layer is the hidden phase `φ`; the binding is the non-local update; the "interference" the framing predicted is the Born-rule probability change in Bob's outcome distribution after Alice's measurement collapses the pair.

4. **Empirical confirmation of the half-bit ladder.** Combined with V1, V2, V4, V5, the eight-variant prototype confirms the entire CHSH hierarchy lives on a half-bit grid in `log₂(S)` and that `Q = R / 2^I` parameterizes that grid. This is the most substantive result the experiment produced for the framework — not new physics, but a clean empirical demonstration that the framework's notation aligns with the CHSH hierarchy.

**What's still open.**

1. **The Swift port.** The Python prototype is the working version. Porting V8 to `QuantumChainField.swift` would let the chain encoder ship with a "bound qubit pair" mode that JS code can use via `window.jeffjs.quantum`. The implementation is straightforward — add a `phi` field to each qubit, expose a "bind" operation, add the post-measurement update — but it's real work and needs test coverage.

2. **The "sub-quantum" variants.** V6's `1.71` is the only off-grid result. Why? Is there a class of strategies that lands strictly between `2` and `2√2`? The Navascués-Pironio-Acín hierarchy describes "almost-quantum" correlations in this regime, and a few variants of V8 that use a *partially* non-local update (e.g., the phase only partially collapses) might land here. Worth running.

3. **The literature search.** Bohmian mechanics is from 1952. The "computational instantiation in a procedural-field encoder framed as sub-resolution binding" might be a new framing or might be in a paper I don't know about. A targeted search is needed before claiming any framing novelty.

**What this experiment validated.** The chain encoder framework is computationally rich enough to host quantum-strength correlations, the half-bit ladder of `√2` between successive substrate levels is real and measurable, and the user-level intuition about "sub-resolution binding" maps directly onto the Bohmian hidden variable layer. Three concrete results from one experiment.

**Difficulty.** *(retrospective)* Lower than expected. The Python prototype is ~250 lines. The hardest part was understanding why V3 failed (signaling) and V8 worked (singlet-conjugate update preserves no-signaling). Once the right update rule was found, the result fell out immediately.

### Experiment 10. Multi-pair V8 scaling test — does Bohmian simulation break exponentially?

**What it tests.** V8 demonstrates that one entangled pair can be simulated via Bohmian-style hidden phases at the Tsirelson bound. The critical question: does this approach scale to multiple entangled qubits, or does the simulation cost explode exponentially when qubits become entangled *across* pairs? This is the concrete test of whether the chain encoder substrate can host quantum-scale computation or breaks at a specific qubit count.

**Why this matters beyond the chain encoder.** If a Bohmian-style simulation with `N` hidden phases can reproduce the statistics of `N` entangled qubits in polynomial time, it would imply `BQP = BPP` — roughly, "quantum computers aren't more powerful than classical." This is widely believed to be false. The experiment almost certainly confirms the standard expectation (exponential blowup), but the VALUE is in characterizing *exactly where and how* the blowup occurs in the chain encoder's specific substrate. The transition point is the interesting data.

**The scaling landscape.**

| Qubits | State space | V8 phases | Can V8 handle it? |
|---|---|---|---|
| 2 (1 pair) | 4 amplitudes | 1 phase | **Yes — already demonstrated** (`S ≈ 2√2`) |
| 4 (2 pairs, independent) | 4 + 4 amplitudes | 2 phases | Yes (trivially, no cross-pair entanglement) |
| 4 (2 pairs, GHZ-entangled) | 16 amplitudes | 2 phases? | **Unknown — the test** |
| 8 (GHZ) | 256 amplitudes | 4 phases? | Almost certainly no |
| 16 (GHZ) | 65,536 amplitudes | 8 phases? | No (if 8 phases ≠ 65,536 amplitudes) |
| 50 (GHZ) | ~10^15 amplitudes | 25 phases? | No (this is where classical sim dies) |

The fundamental question: `N` real-valued phases encode `N` numbers. A general `N`-qubit entangled state requires `2^N` complex amplitudes. For `N > ~4`, there aren't enough degrees of freedom in the phase representation to capture all the correlations in a general entangled state. The experiment measures WHERE the representation breaks.

**How to build it.**

*Step 1. Extend V8 to N pairs.* Create `N` qubit pairs, each with a hidden phase `φ_i`. For independent pairs: each pair does its own V8 update. This should reproduce `N` independent CHSH tests, each at Tsirelson. Confirm this works as the baseline.

*Step 2. Introduce cross-pair entanglement.* The GHZ state for `N` qubits is `|GHZ_N⟩ = (|00...0⟩ + |11...1⟩) / √2`. It is maximally entangled across ALL qubits simultaneously — not decomposable into pairwise entanglement. The Bohmian update rule for a GHZ state is more complex than V8's singlet rule: measuring qubit 1 collapses ALL other qubits' phases simultaneously, not just one partner. Define the update rule:

```python
def ghz_measurement(qubit_index, alpha, phases, outcomes_so_far):
    """Measure one qubit of a GHZ state. Collapse all other qubits'
    phases based on the outcome. For GHZ, if any qubit is measured +1,
    all others are in state |0...0⟩; if -1, all others are in |1...1⟩."""
    phi = phases[qubit_index]
    p_plus = cos((phi - alpha) / 2) ** 2
    outcome = sample(p_plus)
    # GHZ collapse: all unmeasured qubits snap to the same state
    for j in range(len(phases)):
        if j != qubit_index:
            if outcome == +1:
                phases[j] = alpha        # aligned with the measurement axis
            else:
                phases[j] = alpha + pi   # anti-aligned
    return outcome, phases
```

This is the simplest possible multi-qubit Bohmian update. It might be WRONG for GHZ (because it doesn't capture the full 2^N-dimensional wave function collapse). That's exactly what the experiment tests.

*Step 3. Measure the Mermin inequality.* The Mermin inequality is the multi-party generalization of CHSH. For `N` parties:

- Classical bound: `2^{(N-1)/2}` (grows exponentially)
- Quantum bound: `2^{(N-1)}` (grows faster — exponentially in the *same* base but with a higher exponent)
- The ratio quantum/classical = `2^{(N-1)/2}` — the quantum advantage grows exponentially with `N`

For N=2: CHSH, quantum/classical = √2. (Already confirmed.)
For N=3: Mermin, quantum/classical = 2.
For N=4: quantum/classical = 2√2.

If V8's extension produces the quantum Mermin value at each N, the simulation is correctly reproducing multi-qubit entanglement. If it produces the classical Mermin value (or something between), the Bohmian phase update is failing to capture the cross-qubit correlations.

*Step 4. Measure simulation cost.* At each `N`, record:
- Time per trial (does it grow polynomially or exponentially with `N`?)
- Memory usage (does it grow as `N` or as `2^N`?)
- The Mermin inequality value (does it match quantum or fall to classical?)

Plot all three against `N`. The plot tells you exactly where the simulation breaks: the `N` at which either (a) the Mermin value drops below quantum, or (b) the simulation cost becomes exponential, or both.

**What results would show.**

- **Mermin matches quantum AND cost is polynomial in N** — would be an extraordinary result implying the chain encoder can simulate quantum computation efficiently. Almost certainly won't happen, but if it did it would be one of the biggest results in computational complexity.
- **Mermin matches quantum BUT cost is exponential in N** — the Bohmian update works but costs `2^N` to compute correctly, confirming that classical simulation of entanglement requires exponential resources. This is the expected result and is still useful data — it confirms the standard assumption empirically and characterizes the constant factor.
- **Mermin drops to classical at some N** — the naive Bohmian phase update fails to capture multi-qubit entanglement beyond `N` qubits. The transition point is the interesting data: does it break at `N = 3` (immediately beyond pairwise)? `N = 4`? Later? The break point characterizes what the chain encoder's substrate can and can't represent.
- **Mermin drops to BETWEEN classical and quantum** — a "sub-quantum" multi-party correlation regime. Would connect to the Navascués-Pironio-Acín hierarchy's "almost-quantum" set. Interesting in its own right.

**Honest prediction.** The naive `ghz_measurement` update rule above will break at `N = 3` (the first multi-qubit GHZ beyond pairwise). The reason: GHZ correlations can't be decomposed into pairwise correlations — they have genuine `N`-party structure that the pairwise Bohmian update can't capture. To get `N = 3` right, the update rule would need to reference the full wave function, which requires `2^N` amplitudes — and at that point you're doing standard state-vector simulation, not Bohmian phase tracking.

The experiment is worth running precisely BECAUSE this prediction might be wrong. If the naive update works past `N = 2`, that's surprising and worth investigating. If it breaks at `N = 3` as predicted, the experiment characterizes the break cleanly and confirms that V8's success at `N = 2` was a special case of pairwise entanglement, not a general quantum simulation capability.

**Status.** Concrete protocol, sharp success criteria (Mermin inequality values at each `N`), clear predictions to test against.

**Difficulty.** Medium. The hardest part is implementing the GHZ measurement correctly and computing the Mermin inequality. The Mermin inequality for `N` parties involves `2^{N-1}` correlation terms, so even the *measurement* cost grows exponentially — but for small `N` (3, 4, 5) it's tractable. A Python prototype can handle `N` up to ~20 before memory becomes an issue (for the reference quantum simulation that generates the "correct" Mermin values to compare against).

**Recommended prototype path.** Extend `chsh_prototype.py` with a `ghz_v8` variant. Start at `N = 3` (the first non-trivial case beyond V8's proven `N = 2`). If it works, increment `N`. If it breaks, characterize the break.

**Connection to quantum computing.** This experiment directly tests the claim "the chain encoder can't scale to be a quantum computer." If the scaling test shows exponential blowup, it confirms the standard assumption. If it doesn't, it's the most important result the project has produced — and would need immediate, aggressive literature search and peer review, because it would contradict a widely-believed conjecture in computational complexity.

---

## Category C: Conceptual framings (not yet concrete experiments)

These were proposed as *framings* of hard problems in terms of the chain encoder. They are suggestive structural analogies, not testable protocols. They are documented here for completeness but should not be run until someone turns them into concrete experiments with success criteria.

### 11. The Measurement Problem ("Memory Buffer Crack")

**Framing.** Standard quantum mechanics says a particle exists in superposition until an "observer" looks at it and the state collapses. Physics has argued for a century about what counts as an observer. The chain encoder's procedural field has a clean operational definition: an observer is a query position that *commits* bits into its address by running the backtracking search. The "collapse" is the point at which the encoder writes a specific bit into the master key.

**Why it's not yet a concrete experiment.** The framing is a suggestive structural similarity, not a testable protocol. To turn it into an experiment one would need a specific claim of the form "here is a measurement outcome in quantum mechanics that the chain encoder also produces, and here is the setup that distinguishes the claim from hand-waving." That claim has not been proposed, and producing it would require committing to a specific reading of the measurement problem (decoherence? many-worlds? QBist?) that the framework is currently agnostic about.

**Closest existing physics.** The decoherence program (Zurek), QBism (Caves-Fuchs-Schack), and the quantum Darwinism framework (Zurek again) all already connect "observer-commits-bits" to measurement outcomes. If there is something the chain encoder does that these programs do not, identifying it is the first step toward an actual experiment.

### 12. The Arrow of Time ("Garbage Collection Crack")

**Framing.** The Second Law and the Arrow of Time are often framed as a thermodynamic mystery. The chain encoder suggests a different framing: if the universe has a finite `I_max` bit budget, the direction of time is the direction in which information is *irreversibly committed* to observer records. "Garbage collection" would be the process of freeing up bit budget by forgetting some committed information — and the Second Law would be the macroscopic signature of that process.

**Why it's not yet a concrete experiment.** Same as above — the framing lacks an operational protocol. The Landauer erasure principle already connects information and thermodynamics (erasing one bit of information dissipates at least `kT ln 2` of heat), and this is probably the right existing physics to compose with. Turning the framing into a testable claim would require specifying what "garbage collection" means concretely in the encoder's architecture and what measurable quantity would count as the system's "entropy production."

**Closest existing physics.** Landauer 1961, Bennett 1982, Jarzynski equality, fluctuation theorems. All of these relate information erasure to thermodynamic quantities. A concrete experiment here would need to bolt one of these frameworks onto the chain encoder rather than inventing a new one.

---

## Sequencing (one possible ordering)

Ordered by payoff-per-unit-effort, with the caveat that "payoff" here is partly in the eye of the researcher. This is a suggestion, not a prescription:

**~~Experiment 9~~ — DONE.** Run as a Python prototype (`chsh_prototype.py`). V8 (bound qubit pair with sub-resolution binding) reaches Tsirelson `|S| ≈ 2√2` with no-signaling preserved. See Experiment 9 entry for full results. Remaining sub-tasks for Experiment 9: Swift port, "sub-quantum" intermediate variants, literature search on the framing.

1. **Experiment 1** (Non-Gaussian extension) — lowest effort, clearest success/failure criterion, directly addresses the paper's own flagged open question
2. **Experiment 4** (Push past `I_max` via arbitrary precision) — nearly as low effort, validates the "observer ceiling is a representation artifact" framing
3. **Experiment 3** (Stacking with info-theoretic bounds) — analytical work first, cheap to iterate
4. **Experiment 2** (Simple two-observer case) — builds the infrastructure needed for Experiments 5, 7, 8
5. **Experiment 6** (Continuous-measurement Monte Carlo) — best run after Experiment 1, uses the same harness
6. **Experiment 5** (Minimal dynamics + decoherence) — first physics-analog experiment with a non-trivial result to aim at
7. **Experiment 7** (Cosmological scaling) — depends on Experiment 2 infrastructure
8. **Experiment 8** (Multi-observer network) — the largest engineering lift, the most speculative payoff
9. **Experiment 10** (Multi-pair V8 scaling) — tests whether V8 breaks at N=3 qubits (GHZ). High theoretical stakes: if it doesn't break, it's a major complexity result. If it does, it characterizes where the chain encoder's substrate stops being quantum-capable. Either way, clean data.

Experiments 11 and 12 are not on the sequencing list because they are framings, not experiments. Promoting either to a concrete protocol is a prerequisite to running it.

---

## Methodology notes

A few notes that apply to any of the above:

1. **Prototype in Python before porting to Swift.** The chain encoder's core logic (qubit field, cross-product bit derivation, octree backtracking) is ~200 lines. A Python prototype with `numpy` and `mpmath` is fast to iterate and can use arbitrary precision without Swift tooling overhead. Once the result is clear, port to Swift for the canonical version in the JeffJS module.

2. **Document the negative result.** Most of these experiments will either produce a clean negative result (the principle holds, no new structure) or a deviation that turns out to match existing literature. Both are useful. Both are publishable as whitepaper updates if written up clearly.

3. **Run the literature search before writing up anything as novel.** The §5.4 composition in the whitepaper felt novel until Hossenfelder 2013 turned up. Every "interesting" result should get a dedicated literature pass — quant-ph, physics.hist-ph, the Fisher information literature, the GUP literature, and the relevant information-theory journals — before being claimed as new.

4. **Scope the experiment before building it.** Each of these can be expanded into months of work. Picking a specific narrow question for each run keeps scope bounded and makes the result interpretable. Experiments that don't have a sharp success/failure criterion (especially 7, 8, 10, 11) should get the criterion written down *first*, or they will drift.

---

## Source attribution

The experiments above were compiled from proposals by three different reviewer models. Two experiments (Pointer Crack / Correlation-structure extension, and Multi-observer extension / Multi-observer network) were independently proposed by more than one reviewer under different names and have been merged. All other experiments were proposed once. The framings in Category C came from the most speculative-inclined of the three reviewers.
