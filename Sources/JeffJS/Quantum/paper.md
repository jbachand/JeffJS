# JeffJS Quantum: An Information-Theoretic Encoding Framework

*Whitepaper — the resolution principle `Q = R / 2^I` and its Swift instantiation*

*Jeff Bachand*

*April 2026*

---

> **A note on framing.** This is a whitepaper documenting a software module and the conceptual ideas behind its design. It is not a research paper, it does not claim novelty for the underlying physics, and it has not been peer reviewed. A short engineer-focused companion document (`paper-engineer.md`) is the recommended starting point for readers who want the system without the full theoretical chain.

---

## Abstract

This whitepaper documents the JeffJS Quantum module — a Swift implementation of an information-theoretic encoding framework — along with the conceptual ideas that motivated its design. The module instantiates a resolution-information trade-off, written as

`Q(O, S) = R(A) / 2^{I(O; S)}`,

where `O` is an observer (measurement apparatus plus recording instrument), `S` is the system being measured, `A` is a specific physical observable, `R(A)` is the range of `A` in its natural units, `I(O; S)` is the Shannon mutual information in bits between the observer's record and the state of `S`, and `Q(O, S)` is the smallest cell of `A` distinguishable to that observer. Each additional bit of mutual information halves the cell size. The expression is observer-relative and dimensionally consistent: `R` carries the units of `A`, the exponential factor is dimensionless, so `Q` is in the units of `A`.

The framework rests on a substantial body of prior work in the information-theoretic foundations of measurement — Stam 1959, Frieden 1998, Reginatto 1998, Hall and Reginatto 2002, Brukner and Zeilinger from 1999 onward, Rovelli 2013, the Cramér-Rao chain formalized by Dembo, Cover and Thomas 1991, and the broader Wheeler / QBism / Relational Quantum Mechanics neighborhood. **This document does not claim novelty for the underlying physics.** What it provides is: a compact Shannon-bit restatement of those ideas in one notation; a six-row table aligning Heisenberg, Holevo, classical instrument resolution, Compton, the qubit field implementation, and the no-information limit under one form; an explicit composition with the Bronstein-Hossenfelder Planck-collapse argument as motivation for the resolution floor; a worked retrodiction against the standard continuous-quantum-measurement formula at three measurement strengths; and — the centerpiece — the working Swift implementation: a procedural qubit field with an octree-deepening chain encoder that instantiates the principle as executable code, exposed to JavaScript via `window.jeffjs.quantum`.

The implementation is the substance. The theoretical material is included as background and as motivation for design decisions. The repository — the source code, the tests, the JS bridge — is the canonical artifact; this whitepaper is reference documentation.

---

## 1. The equation and its dimensional argument

### 1.1 The folk version and its problem

In casual physics talk one sometimes hears the slogan "quantum is `h / N`": the universe has a native floor of resolution `h` (Planck's constant), and any observer with `N` distinguishable cells gets a coarsened version of it. I have used that slogan myself; the JeffJS quantum module's README still carries it. It is the first thing a programmer who wants to take "observer-relative resolution" seriously will write down.

The slogan is wrong on units. `h` has dimensions of action (energy times time, or equivalently length times momentum). `N` is a dimensionless count. Their ratio is action. But the resolution one wants to talk about — the smallest *position*, the smallest *frequency*, the smallest *energy* an instrument can distinguish — is not action. It is in the units of whatever observable one is measuring. `Q = h / N` cannot be the resolution of any specific observable; it is, at best, an action-valued constant attached to a coarse-graining count, and one then has to do additional work to convert it into the units of the actual measurement. That additional work is exactly the part that is interesting, and the slogan elides it.

So I want a sharper version: a single expression that gives the resolution available to a particular observer for a particular observable, in the natural units of that observable, as a function of how much that observer actually knows about the system.

### 1.2 The expression

I propose

`Q(O, S) = R(A) / 2^{I(O; S)}`

with the readings:

- `A` is the physical observable in question — position, momentum, frequency, energy, time of arrival, voltage, an angle on a dial. It has natural units.
- `R(A)` is the *range* of `A` over which the observer is asking the question: the length of the position window, the bandwidth of the frequency window, the energy interval being scanned, the duration of the experimental run. `R(A)` carries the units of `A`.
- `O` is an observer, defined operationally: a measurement apparatus coupled to `S` plus a recording instrument that retains the apparatus's outputs. Importantly, `O` is not a person and is not metaphysical. It is a physical system whose state, after the measurement, contains a record correlated with `S`.
- `I(O; S)` is the Shannon mutual information in bits between the post-measurement state of `O` and the state of `S`. It is a non-negative real number; its unit is bits.
- `Q(O, S)` is the resulting resolution: the smallest cell of `A` that the observer can distinguish from its neighbors using its record of `S`. `Q` is in the units of `A`.

Because `I` is in bits, `2^I` is dimensionless and `Q = R / 2^I` carries the units of `R`, which are the units of `A`. The dimensional accounting is clean. There is no leftover action to dispose of.

### 1.3 The reading

The expression should be read as a *commitment*. The observer commits, by building or operating an apparatus in a particular way, to extracting some specific number of bits of mutual information about `S`. Once that commitment is made — once the apparatus is fixed and `I(O; S)` is determined by the joint state — the resolution available to the observer for the observable `A` is exactly `R(A) / 2^{I(O; S)}`. The exponential is the price of bits: every additional bit of mutual information halves the cell size.

This is a flip of the usual textbook framing, in which "the system has a resolution" — phrased as if the resolution is a property of `S` alone. Under the principle proposed here, the resolution is a property of the *pair* `(O, S)`, mediated entirely by `I(O; S)`. Two different observers looking at the same `S` see different `Q`'s. A coarser observer sees a coarser cell. There is no resolution without an observer to have it.

I want to be careful about one thing. The expression does not compute `I(O; S)` for you. Computing `I(O; S)` is the hard part of any measurement problem: it requires knowing the joint state, the POVM associated with the apparatus, and the channel by which the apparatus's record is stored. The expression is an *organizing principle* for the answer — once you know `I`, you know `Q` — not a calculator that hands you `I` for free. The principle's job is to make claims about resolution dimensionally consistent and observer-relative; it is not to do the bookkeeping of any specific quantum-information calculation.

The deeper claim, which I will defend by recovery in Section 2 and by the worked software model in Section 3, is that the principle identifies the *epistemic bottleneck* of measurement. Every act of observation — quantum, classical, electromagnetic, gravitational, mechanical, optical, thermometric — passes through the same chokepoint: it produces correlations between the apparatus's record and the system's state, and those correlations are quantified by `I(O; S)`. The downstream resolution `Q` is what comes out the other side of the bottleneck, scaled by the range of the observable. *No measurement, of any kind, by any observer, on any system, escapes this constraint.* The physical apparatus differs across cases; the bottleneck does not. Heisenberg, Holevo, classical-instrument resolution, and the qubit field demo are not five different results that happen to look similar — they are five views of the same bottleneck, taken from different physical instantiations of "observer."

I want to be immediately honest that this epistemic-bottleneck claim is not new. Wheeler's "It from Bit" (1990), Brukner and Zeilinger's information-invariance program (1999 onward), Zurek's physical entropy and decoherence program (2003), Caves-Fuchs-Schack's QBism, Rovelli's Relational Quantum Mechanics and his *"Relative information at the foundation of physics"* (2013), and especially Frieden's *Physics from Fisher Information* (1998) all articulate versions of the same move: information is foundational for measurement, and physical quantities are observer-relative readouts of an information-theoretic structure. This whitepaper does not originate that claim. It reformulates it in a specific one-line parameterization using Shannon mutual information in bits (rather than Fisher information or nats or Brukner-Zeilinger's quadratic measure), presents a seven-case unified table in that parameterization (including the CHSH/Tsirelson hierarchy added in §2.8), and ships a working software artifact that instantiates the form in code. The full list of predecessor literature is in §6.5; the placement within the existing tradition is established up front so a reader sees it before the rest of the document.

### 1.4 Why bits, why exponentials

A reader of an information-theoretic bent might ask: why bits, why base-2 exponentials, why not nats and `e^I`? The answer is convention. `I(O; S)` measured in nats and `2` replaced by `e` gives the same expression up to a relabelling. I use bits and powers of two because the binary form is unambiguous about the meaning of "one more bit of mutual information halves the cell," and because the worked software example in Section 3 is naturally an octree (three binary axes, eight children per parent), so bits keep the connection to that example sharp. Anyone who prefers nats may translate. Nothing physical depends on the base.

---

## 2. Theoretical background: how the framework relates to known physics

The framework's compact form `Q = R / 2^I` lines up with six existing results from quantum mechanics, classical instrument theory, and information theory, when the appropriate `I` and `R` are plugged in. **The individual derivations are not original to this whitepaper.** They belong to the literature listed in §1.3 and §6.5. What this section provides is the *unified presentation in one notation*, intended as background for the implementation in §3 and as motivation for the design choices the encoder makes.

Readers who already know the Stam-Frieden-Reginatto-Hall-Reginatto / Brukner-Zeilinger / Rovelli information-theoretic-foundations tradition can skim this section: the substance is familiar, only the parameterization is being lined up.

### 2.1 Heisenberg uncertainty relation

*Heritage note.* The derivation of the Heisenberg uncertainty relation from the Cramér-Rao bound is due to A. J. Stam, in *"Some inequalities satisfied by the quantities of information"*, *Information and Control* 2, 101-112, 1959. This section restates Stam's result in Shannon-bit parameterization; the recovery is not original to this whitepaper. The restatement is included because the bit-parameterization is what connects Heisenberg to the other cases in §2 under a single one-line form. See §6.5 for the full predecessor literature.

Consider an observer `O` who measures the position of a particle `S` whose state is a Gaussian wavepacket with prior position spread `σ_x` and conjugate momentum spread `Δp`. (For a minimum-uncertainty Gaussian, `σ_x · Δp = ℏ/2`; in general `σ_x · Δp ≥ ℏ/2`.) The observer couples a position-pointer apparatus of intrinsic noise width `σ_n` to the particle, performs the measurement, and reads the pointer.

Treat this as a Gaussian channel: the input is the particle's position with prior variance `σ_x^2`; the output is the pointer reading with additive Gaussian noise of variance `σ_n^2`. The Shannon mutual information for a Gaussian-input Gaussian-noise channel is the standard formula

`I = (1/2) log_2(1 + σ_x^2 / σ_n^2)`     (bits).

This is exact, not approximate. It is the Gaussian channel capacity from Shannon (1948), used here as the per-shot mutual information between the particle's position and the apparatus's record.

The conditional posterior variance of the position estimate, after one measurement, is the standard Bayesian Gaussian update:

`σ_post^2 = σ_x^2 · σ_n^2 / (σ_x^2 + σ_n^2)`.

In the high-information limit (`σ_n ≪ σ_x`), this simplifies to `σ_post ≈ σ_n`, but the exact relation between `σ_x`, `σ_n`, `σ_post`, and `I` is

`σ_post = σ_x / 2^I`     (exactly, in any regime).

To see this, expand `2^I = sqrt(1 + σ_x^2 / σ_n^2) = sqrt((σ_x^2 + σ_n^2)/σ_n^2)`, so `2^{2I} = (σ_x^2 + σ_n^2)/σ_n^2`, and `σ_post^2 = σ_x^2 σ_n^2 / (σ_x^2 + σ_n^2) = σ_x^2 / 2^{2I}`. Taking the square root gives `σ_post = σ_x / 2^I`. **This identity is the principle**: with the convention that `R ≡ σ_x` (the prior standard deviation, the natural scale of the observable to the observer) and `Q ≡ σ_post` (the posterior standard deviation, the smallest distinguishable cell after the measurement), we have

`Q = R / 2^I`     (exactly, by Bayesian Gaussian inference).

Where does Heisenberg appear? It appears as the constraint on how small `σ_n` can be made for a *physical* apparatus measuring a *quantum* particle. Quantum mechanics requires that any apparatus coupling to position with effective resolution `σ_n` must back-react on momentum with at least `Δp_back ≥ ℏ / (2 σ_n)`. So the achievable `σ_n` is bounded below by what the experimenter is willing to pay in conjugate-momentum disturbance. The Heisenberg uncertainty relation `σ_x · Δp ≥ ℏ / 2` is the statement that there is no apparatus with `σ_n` smaller than the conjugate `ℏ / (2 Δp)`, and therefore `Q` cannot be made smaller than `ℏ / (2 Δp)` no matter how much information `I` the observer commits to extract.

Plug in: at the Heisenberg-saturation point, `σ_n = σ_n^min = ℏ / (2 Δp)`, the per-shot information is

`I_max = (1/2) log_2(1 + (2 σ_x Δp / ℏ)^2)`,

and the achievable resolution is `Q_min = σ_x / 2^{I_max}`. For a minimum-uncertainty Gaussian (`σ_x Δp = ℏ/2`), `I_max = (1/2) log_2(1 + 1) = 1/2` bit per shot, and `Q_min = σ_x / sqrt(2)`. The square-root-of-two is the Gaussian half-information point: with one half-bit of information from a single quantum measurement, the observer halves the variance of the position estimate. Subsequent measurements accumulate `I`, and `Q` shrinks as `σ_x / 2^{∑I}` until decoherence or other practical limits intervene.

The relation `Q = R / 2^I` is therefore not just a notational rewrite of Heisenberg. It is the exact Bayesian-Gaussian identity, and Heisenberg enters as the lower bound on `σ_n` that any quantum apparatus must respect. The principle separates what is *information-theoretic* (the inverse-exponential scaling of `Q` with `I`) from what is *quantum-mechanical* (the floor on `σ_n` set by `ℏ`). Both pieces are necessary; the principle is the first piece written cleanly.

### 2.2 Classical instrument resolution

The trivial limit. Consider an ideal classical detector with `N` perfectly distinguishable bins covering a range `R`: `N` voltage levels on an analog-to-digital converter, `N` cells on a CCD, `N` counts on an interferometer scan. Each measurement assigns the system to exactly one bin, so the mutual information per measurement is

`I = log_2(N)` bits.

Plug in:

`Q = R / 2^{log_2(N)} = R / N`.

That is the bin width. The classical case is the formula's trivial fixed point: with `N` distinguishable cells, the resolution is `R / N`, and this is the textbook definition of instrument resolution. The principle is consistent with the classical limit by inspection.

### 2.3 Holevo bound

A less trivial recovery. For a quantum system in state `ρ` and a measurement described by a POVM `M`, the Holevo theorem (Holevo 1973) sets a ceiling on the classical mutual information any observer can extract from the system's preparation:

`I(O; S) ≤ χ(ρ, M)`,

where `χ` is the Holevo quantity associated with the ensemble and the measurement. Equality is achieved by some POVMs (notably the optimal one for distinguishing pure states drawn from an ensemble); for most realistic measurements `I` is strictly less. Either way, the maximum extractable mutual information is bounded above by `χ`.

Plug the Holevo ceiling into the principle:

`Q_min = R / 2^χ`.

This is the *finest resolution any observer can have for an observable of range `R` on a state `ρ` measured by a POVM `M`*. It is observer-relative in the proper sense: change the POVM, change `χ`, change `Q_min`. The Holevo bound, viewed through the principle, becomes a statement about the *minimum cell size* that quantum mechanics permits any observer to achieve via that measurement. The principle does not derive Holevo — it inherits it. But it gives Holevo an immediate physical reading in terms of resolution, which the bare information-theoretic statement does not.

To make the recovery concrete: if a single qubit is prepared in one of two non-orthogonal states with equal prior, the maximum extractable `χ` for any POVM is bounded by the Helstrom-distinguishability constant, typically much less than one bit. Plug `χ < 1` into the principle and `Q > R / 2`: no observer can resolve the qubit's state to better than half the available range, no matter what apparatus is used. That is the qualitative content of "non-orthogonal states cannot be perfectly distinguished," translated into the units of the observable being measured.

### 2.4 The Compton limit

For a relativistic particle of mass `m`, there is a hard physical floor on single-particle position localization that is independent of Heisenberg uncertainty: the *reduced Compton wavelength* `λ_C = ℏ/(mc)`. Localizing a particle to a region smaller than `λ_C` requires probe energies above `mc²`, at which point the measurement spontaneously creates particle-antiparticle pairs out of the vacuum, and the single-particle state being measured no longer exists. This is a standard result in quantum field theory; the textbook derivation is in Peskin & Schroeder Chapter 2.

Take `λ_C` as `Q_min` and substitute into the principle:

`Q = R / 2^I = ℏ / (mc)`,

so

`m = (ℏ / (cR)) · 2^I`.

This is *not* a new derivation of mass. It is the standard inverse Compton wavelength formula `m = ℏ / (c · λ_C)` with `λ_C` replaced by the principle's expression for the smallest distinguishable cell. The two equations are algebraically equivalent — the substitution just changes which variable is treated as primitive.

**The information-theoretic reading.** Solving for `I` instead of `m`:

`I_max = log_2(m c R / ℏ)`.

For a fixed prior spatial range `R` over which the observer is asking about position, the mass of the particle bounds the maximum number of bits of position information the observer can extract before pair production destroys the single-particle state. A particle of larger mass has a smaller Compton wavelength and a higher `I_max` — heavier particles can hold more positional information than lighter ones before the measurement breaks the system. The framework restates this as: *mass is the informational capacity of a single particle as a localization channel.*

This restatement is *not* novel as physics. The connection between mass-energy and informational capacity is already explicit in Bekenstein 1973 (information bound scales with mass-energy), Margolus & Levitin 1998 (computational rate scales with mass-energy), Wheeler 1990 (the "It from Bit" proposal that mass arises from information), and the holographic principle generally. What the framework adds is the *parameterization*: mass becomes a function of the bit-budget required for localization, in the same notation as Heisenberg, Holevo, and the cosmological scaling. It joins the recovery table as one more case in which a separately-derived physical floor coincides with the principle's exponential structure.

**One thing to be careful about.** The Compton wavelength is a *single-particle* floor. It is not a bound on what an observer with multi-particle apparatus can measure: with sufficient energy, an observer can always create more particles and probe sub-Compton structure in a pair-production-renormalized way. (This is what high-energy collider experiments do.) So `m = (ℏ/(cR)) · 2^I` is a recovery of the *single-particle Compton floor*, not of "mass" in the deeper field-theoretic sense. The formal definition of mass in quantum field theory involves renormalization, bare-vs-physical mass distinctions, and running coupling constants the framework does not touch. The honest framing is therefore that the principle re-expresses the inverse Compton wavelength in its own variables, and the re-expression has a clean information-theoretic reading; it does not derive mass from information in any way the existing literature has not already done.

**The massless limit: does light have informational depth?** The substitution `m = (ℏ/(cR)) · 2^I` is degenerate at `m = 0`: the equation has no finite solution for `I`. Photons and other massless particles have *no Compton wavelength* and therefore no Compton-set localization floor. This is consistent with the fact that a single photon below `2 m_e c²` cannot pair-produce in vacuum: pair production for one photon requires the presence of an external field. The framework respects this: the Compton recovery applies only to massive particles. For photons, the relevant length scale is the wavelength `λ = 2π c / ω`, which depends on the photon's frequency rather than any rest-frame intrinsic property. Substituting `Q = λ` into the principle gives

`I_max(photon) = log_2(R ω / (2π c))`

bits of position information about a photon over a prior range `R` — finite, frequency-dependent, and in agreement with the standard diffraction-limited resolution `~λ/2` of optical microscopy. The framework therefore distinguishes *intrinsic informational depth* (the Compton case, set by mass, frame-invariant) from *frame-dependent informational depth* (the photon case, set by frequency, observer-relative). This is not a new physical observation; it is a clean expression of the standard fact that photons have no rest frame and no proper position operator. Light *does* have informational depth in the framework's sense; it just is not characterized by a Compton wavelength because it has no rest mass.

**The energetic cost of optical bits: photons as probes.** The previous paragraph treats the photon as the *system being measured*. There is a complementary case in which the photon is the *probe* used to measure something else — the standard setup of optical, X-ray, gamma-ray, and (with electrons standing in for photons) electron microscopy. In that setup, asking the principle to give a position resolution `Q` requires a probe photon with wavelength `λ ≤ Q`, and from the Planck-Einstein relation `E = hc/λ`, the required probe energy is

`E = (hc / R) · 2^I`.

Each additional bit of mutual information about the system requires *doubling the probe photon's energy*. This is the same exponential structure as the Compton case for mass, and it is the same exponential structure as the gravitational Planck-collapse argument that will appear in Section 5.4. Three independent physical mechanisms — pair production at electroweak scales, photon-energy escalation in microscopy at optical-to-gamma scales, and gravitational collapse at the Planck scale — all enforce the principle's exponential cost in `I` against three different physical ceilings. The exponential cost is structural; the ceiling depends on which piece of physics happens to break first as `I` grows.

This recovery is *not new physics*. It is the foundational principle of all microscopy: short wavelengths require high energies, and atomic-resolution probes require X-ray or higher photon energies. Optical microscopists know this rule as the diffraction limit (`Q ≥ λ/2`), X-ray crystallographers know it as the wavelength-resolution trade-off, electron microscopists know it as the de Broglie inverse-momentum relation. The framework's contribution is, again, the shared parameterization: all three statements are the same one-line equation `E = (hc/R) · 2^I`, written in the same units as the rest of the recovery cases. The everyday observation that *high-resolution microscopy destroys the sample* becomes, in this notation, the observation that the principle's exponential cost in `I` eventually exceeds the binding energy of the target — the principle's exponential cost is enforced not just gravitationally and via pair production but also, more mundanely, via the destruction of any system probed at high enough `I`. The exponential cost is not unique to exotic physics; it is the same cost the user of a microscope pays every day.

**The status of `c` in the framework.** The speed of light `c` appears throughout the paragraphs above as a conversion factor: in `λ_C = ℏ/(mc)` it converts mass to length; in `E = hc/λ` it converts wavelength to energy; in `ℓ_p = sqrt(ℏ G/c^3)` (Section 5.4) it sets the Planck scale. The framework is observer-relative in `I` and `Q`, and a natural question is whether `c` is observer-relative too. It is not, and the framework makes its status precise in a way worth stating explicitly.

*`c` is the bit-propagation rate of the epistemic bottleneck.* The no-superluminal-signaling theorem of quantum field theory states that no mutual information can propagate faster than `c`. In the framework's language this becomes: for an observer at spatial range `R` from a system, the maximum rate at which `I` can accumulate is bounded above by roughly `c / R` bits per unit time (the inverse light-crossing time of the region), and the minimum time to extract `I` bits is at least `R / c`. `c` is not a quantity the framework derives; it is the universal ceiling on how fast the epistemic bottleneck can be traversed. This reading is not new — it is the standard information-theoretic statement of no-superluminal-signaling — but the framework gives it a one-line form compatible with `Q = R / 2^I`.

*`c` is frame-invariant, and the framework respects this.* Special relativity requires that every inertial observer measure the same value of `c`, to the parts-per-billion precision of modern experiments. The framework does not derive this invariance; it takes it as input. Frame-dependence of photon measurements — the same photon looking different to different-velocity observers — enters the framework through the photon's *frequency* `ω`, which Doppler-shifts with observer velocity, rather than through `c`, which does not. The photon-position formula `I_max(photon) = log_2(R ω / (2π c))` makes this explicit: `ω` is frame-dependent, `c` is frame-invariant, and the product `R ω / c` correctly tracks the frame-dependence of photon information without violating the invariance of the speed of light. Different inertial observers extract different `I` from the same photon because the photon *looks* different to them (different frequency, different wavelength, different energy), not because the speed of propagation varies. The framework does not fight special relativity; it incorporates it.

*`c` is observer-dependent in measurement precision only.* As with any physical constant, a finite-`I_max` observer can measure `c` only to precision bounded by their information budget. This is the trivial and universal sense in which "`c` is observer-dependent" that the framework forces on all constants equally — not a special property of light, just a consequence of finite resolution. All observers converge on the same *value* of `c` in the limit of perfect measurement; what varies is the tightness of the confidence interval.

*A speculative footnote.* The question of whether `c`, or any fundamental constant, could be *derived* from information-theoretic primitives rather than postulated is an open research program in foundations of physics. Wheeler's "It from Bit," 't Hooft's cellular-automaton interpretation of quantum mechanics, Smolin's deeper-unification attempts, and the broader digital-physics tradition all live in this neighborhood. The framework `Q = R / 2^I` is consistent with such a program in the sense that it treats mutual information as primitive and physical quantities as observer-relative readouts of an information-theoretic bottleneck. It does not currently attempt a derivation of `c`, and I do not claim it can. If a derivation of `c` from purely information-theoretic inputs were ever found, the framework would host it naturally; that is the strongest claim I am willing to make on this point.

**Connection to §5.4.** The Compton limit and the Planck-collapse argument from Section 5.4 are both physical-floor enforcements of the principle's exponential cost in `I`. They operate at different scales (Compton wavelengths near electroweak energies; the Planck length at quantum-gravity energies) by different mechanisms (vacuum pair production vs Schwarzschild-radius formation). The fact that two unrelated pieces of physics independently enforce the principle's exponential cost at two very different scales is non-trivial structural evidence: it suggests the cost is not an artifact of any one piece of physics but a property of the form `Q = R / 2^I` itself, against which separate pieces of physics happen to set separate ceilings.

### 2.5 The qubit field demo

Now the worked software example, which is the case the principle was tuned to fit and which I take seriously as an instance rather than as an analogy.

The JeffJS quantum module builds a deterministic procedural field of 256 two-dimensional points — *qubits*, in the loose sense of a binary cell that an observer can read at a chosen resolution. The field is generated lazily from a seed by `SplitMix64`. Each address `(vx, vy, t)` selects a cell, advances each qubit's phase by `t`, and computes a derived bit from the qubits closest to `(vx, vy)`.

The chain encoder, `QuantumChainEncoder.swift`, encodes an `N`-bit message into a single octree address by walking a backward search. Bit `b[N-1]` (the *last* message bit) is placed at level 1 — the coarsest cell, `vx, vy, t ∈ {0, 1}`, which divides the field into eight cells. Bit `b[N-2]` is placed at level 2 — each axis gets one more bit, dividing the level-1 parent cell into eight children (sixty-four total cells). Bit `b[0]` (the *first* message bit) is placed at level `N` — each axis is `N` bits wide, and the full `(vx, vy, t)` triple at that depth is the master key. Decoding walks the octree back upward by truncating one bit per axis per step: `N` reads, fully deterministic, no search.

Two facts about this construction make it an instance of the principle.

*First*, the address bits at each level are mutual information about the message. Reading the cell at level `k` with the correct master key recovers exactly the message bit that was encoded there. A receiver who knows the full master key (`N` bits per axis, so `3N` bits of address total, but the message is recovered by walking the chain so the relevant information per axis is `N` bits) holds `I = N` bits of mutual information about the message. A receiver who knows only the top `k` bits per axis holds `I = k` bits and recovers the top `k` message bits.

*Second*, the cell width at level `k` in the field of size `R = 2^{25}` is `R / 2^k`. That is the geometric statement of the octree: every additional bit of address resolution halves the cell size on each axis. So for the qubit-field observer,

`Q = R / 2^I` with `R = 2^{25}` and `I = N` bits.

At `N = 1`, `Q = 2^{24}` (half the field). At `N = 25`, `Q = 1` (a single qubit cell). At `N = 48`, the chain encoder's hard cap, `Q = 2^{-23}` of a field unit per axis — well below the integer-cell granularity, hence the *resolution-deepening* framing: we are using the field at a finer resolution than its native qubit grid, and the cell width is what limits us. The double-precision floor (~48 bits per axis, before round-off swamps the `(vx + 0.5) / 2^k` cell-center mapping) is the real-world enforcement of the principle: at some point you cannot keep doubling the bits because your representation runs out of headroom.

The qubit field is, in an exact sense, an observer with a tunable `I`. The chain encoder makes that tuning explicit: every bit of message encoded is one more bit of mutual information committed by the observer's address, and the cell size shrinks by exactly a factor of two. The principle is not approximated by the encoder; the encoder *is* the principle, in code.

### 2.6 Maximum entropy / no-information limit

The trivial sanity check: `I = 0 → Q = R`. An observer with no mutual information about `S` cannot distinguish any cell of `A` from any other; the entire range collapses to one cell. The principle correctly handles the no-knowledge limit by inspection. This is the boundary condition that any resolution principle must pass and that gives the formula its sign convention: bits *reduce* the cell size, bits *cannot* take you below the cell size implied by your information.

### 2.7 The Cramér-Rao equivalence

*Heritage note.* The mathematical equivalence between the Shannon mutual information for a Gaussian channel, the Cramér-Rao bound on Fisher information, the Heisenberg uncertainty relation, and the entropy power inequality was formalized by A. Dembo, T. M. Cover, and J. A. Thomas in *"Information theoretic inequalities"*, *IEEE Transactions on Information Theory* 37, 1501-1518, 1991. The Heisenberg-from-Cramér-Rao half of the chain is Stam 1959 (see §2.1). B. R. Frieden's *Physics from Fisher Information* (Cambridge University Press, 1998) develops a large program deriving physics from Fisher information, with Heisenberg as a special case at equation 4.53. This section is best read as a restatement of the Stam-Dembo-Cover-Thomas chain in Shannon-bit parameterization — *not* as a fresh theorem. See §6.5 for the predecessor literature.

Section 2.1 showed that for a Gaussian channel, `Q = R / 2^I` is *exactly* the Bayesian update identity, with `R` interpreted as the prior standard deviation `σ_x` and `Q` interpreted as the posterior standard deviation `σ_post`. This is not specific to position measurements. It is a general theorem about any measurement that can be modelled as a Gaussian channel with Gaussian prior, which is the standard framework for *every* weak measurement and *every* continuous quantum measurement in the literature.

I want to state this cleanly because it is the strongest defensive position the principle has against the "tautology" critique discussed in Section 6.

**Theorem (Cramér-Rao equivalence).** *For an observer measuring a system with prior standard deviation `σ_x` over an observable `A`, through a Gaussian-noise channel with effective noise width `σ_n`, the Bayesian-posterior standard deviation `σ_post` and the Shannon mutual information `I` (in bits) between the measurement record and the system state are related by*

`σ_post = σ_x / 2^I,`

*where*

`I = (1/2) log_2(1 + σ_x^2 / σ_n^2).`

*Proof.* Direct substitution. From the Gaussian-channel mutual information, `2^{2I} = 1 + σ_x^2/σ_n^2 = (σ_x^2 + σ_n^2)/σ_n^2`. From the Bayesian Gaussian posterior, `σ_post^2 = σ_x^2 σ_n^2 / (σ_x^2 + σ_n^2)`. Multiply: `σ_post^2 · 2^{2I} = σ_x^2 σ_n^2 / (σ_x^2 + σ_n^2) · (σ_x^2 + σ_n^2)/σ_n^2 = σ_x^2`. Therefore `σ_post = σ_x / 2^I`. **QED.**

Identifying `R ≡ σ_x` and `Q ≡ σ_post`, this is the principle. It is exact, not approximate, in any regime where the measurement model is Gaussian. The vast majority of practical quantum measurements (homodyne, heterodyne, phase-preserving amplifier readout, weak position measurement, weak spin measurement) fall in this regime.

In the **strong-measurement limit** `σ_n ≪ σ_x`, the formula reduces to `2^I → σ_x/σ_n` and `σ_post → σ_n`, which is the standard projective-measurement statement that the resolution equals the apparatus noise width and the information equals the log of the dynamic range. In the **weak-measurement limit** `σ_n ≫ σ_x`, `2^I → 1 + σ_x^2/(2 σ_n^2 ln 2)` (Taylor expanding), and `σ_post → σ_x · (1 - σ_x^2 / (2 σ_n^2))^{1/2}` — the posterior is barely changed from the prior, and the information per shot is small but nonzero. Both limits respect `Q = R / 2^I` exactly.

The **Cramér-Rao bound** for estimating `σ_x` from a Gaussian channel with `N` shots gives a per-shot Fisher information of `1/σ_n^2`, so the lower bound on the variance of the post-measurement estimate after `N` shots is `σ_n^2 / N`. Plugging into the principle, `σ_post = sqrt(σ_n^2/N) = σ_n/sqrt(N)`, and the accumulated mutual information is `I_N = (N/2) log_2(1 + σ_x^2/σ_n^2)`. Substitute and verify: `R / 2^{I_N} = σ_x · (1 + σ_x^2/σ_n^2)^{-N/2}`, which for `σ_x^2/σ_n^2 ≫ 1` reduces to `σ_x · (σ_x/σ_n)^{-N} = σ_n^N / σ_x^{N-1}`. This matches `σ_n / sqrt(N)` only when `N = 1`; for larger `N`, the principle's scaling of `σ_post` with `2^{-I}` is *exponential* while the Cramér-Rao scaling is *power-law*. The two agree for a single-shot measurement; they diverge for repeated measurements because mutual information accumulates *additively* across shots while the Cramér-Rao posterior shrinks only as the *square root* of the number of shots.

This divergence is the place where the principle has actual content beyond "trivial restatement of Cramér-Rao." The mutual information available to an observer who performs `N` repeated measurements is bounded above by `N · I_1` only if the measurements are *independent*. For correlated measurements (which include all measurements on a quantum state that has been disturbed by previous measurements), the accumulated information saturates well below `N · I_1`, and the achievable resolution stops shrinking as `2^{-I_N}` and starts following the Cramér-Rao power-law instead. The principle predicts that for a *single* measurement, or for a *parallel* measurement on `N` independent copies, the exponential scaling holds. For sequential measurements on a single quantum system, the principle predicts the exponential scaling holds *only until the measurement back-action becomes the dominant noise source*, at which point the apparent information rate saturates and `Q` stops shrinking.

This is the prediction the framework actually makes. It is sharper than "Q = R/2^I in general" and weaker than "new physics." It says: in any regime where the Gaussian channel model is valid and back-action is negligible, the principle is exact; in any regime where back-action dominates, the apparent saturation of `Q` corresponds to a measurable saturation of `I`, and the two saturate together in a way the principle predicts as a single curve. Section 4 walks through what this looks like for a continuous qubit measurement.

### 2.8 The CHSH hierarchy: `Q = R / 2^I` as a parameterization of the Bell-Tsirelson ladder

*Heritage note.* Bell's inequality (Bell 1964) and its CHSH refinement (Clauser-Horne-Shimony-Holt 1969) are foundational results in quantum foundations. The Tsirelson bound (Tsirelson 1980) is the maximum CHSH violation achievable by quantum mechanics. The Popescu-Rohrlich box (Popescu-Rohrlich 1994) is the maximum violation achievable by no-signaling theories generally. The information-theoretic derivation of Tsirelson via "information causality" is Pawlowski et al, *Nature* 2009. The canonical review of all of these results is Brunner, Cavalcanti, Pironio, Scarani and Wehner, *"Bell nonlocality"* (*Reviews of Modern Physics* 86, 419, 2014). **None of these results are original to this whitepaper, and the framing in this section is in the same neighborhood as Pawlowski 2009.** A targeted literature search (summarized in §6.5) found no direct precedent for the specific "half-bit grid in `log_2(S)`" framing below, but the math is one line of arithmetic given the four landmark values, and the framing is best read as a notational re-presentation of standard results, not as a discovery.

**The half-bit ladder for the canonical CHSH landmarks.** Setting `R = 4` (the algebraic maximum of `S` for binary inputs and outputs), the framework gives:

`S = R / 2^I = 4 / 2^I`

with `I` interpreted as the *information suppressed by the substrate's structural constraints* — the bits of correlation budget the substrate withholds from the algebraic maximum. The three canonical landmarks of the CHSH hierarchy (PR box, Tsirelson, Bell) sit at three discrete grid points spaced by `1/2` bit:

| Substrate | Suppressed `I` (bits) | `S = 4/2^I` | Name |
|---|---|---|---|
| No-signaling polytope, optimally tuned | `0` | `4` | Popescu-Rohrlich (algebraic max) |
| Quantum set (singlet state) | `1/2` | `2√2` | Tsirelson |
| Local polytope, Bell-saturating | `1` | `2` | Bell (classical max) |

The three landmark CHSH values are spaced by `√2` because the suppressed-information increments are exactly `1/2` bit. The framework's exponential structure converts half-bit increments into `√2` correlation increments. The three rungs correspond to extremal points of the no-signaling polytope, the quantum set, and the local polytope respectively — they are not arbitrary. The half-bit spacing is a *trivial* consequence of `log_2(2√2) − log_2(2) = log_2(4) − log_2(2√2) = 1/2`, but it is not, to my knowledge, written explicitly as a "half-bit grid" anywhere in the literature.

![**Figure 2.** Visualizing entanglement in the chain encoder's qubit-field substrate at four time slices. Each row is a snapshot at increasing time `t`, showing two procedural fields `F_A` (left) and `F_B` (right) generated from the same seed, separated by the *sub-resolution barrier strip* in the middle. **Yellow circles** are the 256 qubits at deterministic positions. **Orange arrows** show each qubit's phase orientation, which advances as `phase(t) = phase_0 + speed_i · t`; the arrows rotate visibly across the four time slices. **Faint blue grids** in the side panels are nested octree resolution layers at depths 3 (8×8 cells), 4 (16×16), and 5 (32×32) — the resolutions an observer can address through the chain encoder's normal binary readout. **Three colored cells** highlight the octree cells at three different resolution levels (pink: large 8×8 cell at level 3, blue: medium 16×16 cell at level 4, green: small 32×32 cell at level 5). **The thin middle strip is the sub-resolution layer**, rendered with a *finer* grid (level 6, 64×64 cells) that is visibly different from the side-panel grids and *only accessible "through" the barrier*. **The thick orange edges of the strip are the `I_max` barrier walls** — the observer resolution ceiling. The hidden phase `φ` that V8's entanglement binding uses lives inside this strip; an observer reading bits in the side panels cannot see it directly. **Three colored curved threads** are the V8 entanglement links connecting selected qubit pairs across the two fields, *passing through the sub-resolution layer*. The link "lives at" a particular octree level — the highlighted cell at that level is the smallest cell containing the linked qubit. The threads remain static while the qubit phases rotate, because the entanglement is a property of the *sub-resolution* hidden phase, not of the qubit phases the observer sees. *This visualization combines four properties — procedural spatial field, cross-field entanglement link, multi-resolution octree overlay, and explicit barrier between observable and sub-resolution layers — that exist individually in the literature (cellular automaton interpretations, tree tensor networks, MERA visualizations) but, per a targeted literature search, have not been combined in this way before.* For the live animation (48-frame loop, ~4 seconds), see `qubit_field_entanglement.gif`. Reproduced by `python3 qubit_field_entanglement_viz.py`.](qubit_field_filmstrip.png)

**A note on V1 and the sub-classical baseline.** The empirical eight-variant table below includes V1, a "naive probabilistic" strategy that lands at `S ≈ √2`. **V1 is not a fourth rung of the hierarchy above.** It is a specific sub-optimal classical strategy whose particular value happens to fall at `√2` because of the specific construction (uniform shared `θ`, sampling from `(1+cos)/2`). The standard CHSH literature does not single out `√2` as a privileged sub-classical anchor — sub-optimal classical strategies span a continuous range, and `V1`'s position at `√2` reflects the *specific Born-rule averaging* used in that variant, not a structural property of all classical strategies. I include V1 in the table because it is a natural starting point for any "what does naive probabilistic sampling give you?" question, and because its value at `√2` is suggestive of the same `√2`-grid structure as the canonical landmarks. But the suggestiveness is *not* an honest claim of a fourth rung. The honest hierarchy has three rungs: Bell, Tsirelson, PR box.

**Software instantiation.** The chain encoder's empirical CHSH landscape was measured in `chsh_prototype.py` (next to this whitepaper) with eight variants. The four substrate-extremal variants land on the half-bit grid:

| Variant | Description | Measured `\|S\|` | Grid position |
|---|---|---|---|
| V1 | Naive probabilistic, shared `θ` | `1.4136` | `≈ √2` |
| V2 | Deterministic `sign(cos)`, shared `θ` | `1.9952` | `≈ 2` |
| V8 | Bound qubit pair, sub-resolution binding | `2.8246` | `≈ 2√2` |
| V5 | Popescu-Rohrlich box (mathematical reference) | `4.0000` | `= 4` |

V4 (the singlet state implemented via the Born rule directly) lands at `2.8321`, statistically indistinguishable from V8's `2.8246`. V8 and V4 produce the same observable joint statistics; the difference is the generating mechanism. V8 uses a chain-encoder-style hidden variable substrate; V4 uses the Born rule.

![**Figure 1.** The geometric signature of entanglement, plotted from `chsh_prototype.py` data. Each data point is the empirical correlation `E(δ) = ⟨b_A · b_B⟩` for a particular angle difference `δ = α_B - α_A`, averaged over 30,000 trials per angle. **Gray dots (V1)** are naive probabilistic strategies, tracing a half-amplitude `(1/2)cos(δ)` curve. **Blue squares (V2)** are the Bell-saturating classical strategy, tracing the linear *triangle wave* — the maximum that any local hidden variable model can achieve. **Red diamonds (V4)** are the quantum singlet computed via the Born rule, and **green triangles (V8)** are the chain encoder's Bohmian-style sub-resolution binding (Toner-Bacon-equivalent); both trace the smooth `-cos(δ)` curve and overlap to within Monte Carlo noise. The shaded orange region is the *Bell gap* — the area where the quantum cosine has larger magnitude than the classical triangle at the same angle. **That orange region is the entire reason CHSH violates 2 in quantum mechanics.** At `δ = π/4` the gap is exactly `√2/2 - 1/2 ≈ 0.207`, and the CHSH sum picks up a factor of `√2` because four such gaps combine across the four CHSH angle pairs. The figure is mathematically backed end-to-end: each marker is real Monte Carlo data, the dashed theoretical curves are the closed-form predictions, and the orange region is the exact difference `|cos(δ)| - |triangle(δ)|`. Reproduced by `python3 chsh_correlation_plot.py` against `chsh_prototype.py`.](chsh_correlation_curves.png)

**The most interesting variant: V8.** It implements a *Bohmian-style* hidden variable model in the chain encoder framework. Each pair of qubits shares a hidden phase `φ` below the binary measurement resolution. Alice measures first using the standard Born-rule probability `P(b_A = +1 | φ, α_A) = cos²((φ − α_A)/2)`. Her outcome non-locally collapses the partner qubit's hidden phase to the singlet-conjugate state (`α_A + π` if Alice got `+1`, otherwise `α_A`). Bob's subsequent measurement uses the post-collapse phase. The resulting joint statistics replicate the singlet state at Tsirelson's bound, and no-signaling is preserved at the marginal level: Bob's distribution averaged over Alice's possible outcomes is independent of Alice's setting.

V8 is **not new physics.** Non-local hidden variable models that reach Tsirelson have been known since Bohm 1952 and de Broglie 1927; the framework here calls them "Bohmian-style" because the substrate is deterministic and the non-locality lives in a hidden update rule. What V8 demonstrates is that the chain encoder's procedural field substrate is *computationally rich enough* to host such a model: the "sub-resolution structure" the framework predicts (a hidden layer below the observable cell at depth `I`) corresponds exactly to the hidden phase Bohmian models use, and the procedural-field encoder can naturally instantiate it. Earlier failure modes (V3's naive seed mutation broke no-signaling and disqualified itself) confirm that not every "non-local update" preserves the framework's structure — the right update is the singlet-conjugate phase used in V8.

**The honest framing.** The framework `Q = R / 2^I`:

1. **Parameterizes the CHSH hierarchy** as a discrete half-bit grid of suppressed information
2. **Empirically aligns with the eight measured CHSH variants** in the chain encoder, with the substrate-extremal cases (V1, V2, V8/V4, V5) landing exactly on the grid points
3. **Hosts a Bohmian-style instantiation** of Tsirelson-saturating correlations via sub-resolution binding (V8), demonstrating that the chain encoder substrate can reach quantum-strength correlations when augmented with the right non-local hidden variable update

It does **not**:

1. *Derive* Bell's bound from `Q = R / 2^I` alone — Bell's bound comes from the locality factorization of the joint distribution, which is an external structural constraint, not an information bound. The framework parameterizes the hierarchy but does not pick which rung a substrate sits on.
2. *Discover* that non-local hidden variable models can reach Tsirelson — this is Bohm 1952, de Broglie 1927.
3. *Prove* that the chain encoder is structurally equivalent to a Hilbert space — V8's joint statistics match the singlet, but the substrate is classical procedural-field code, not a Hilbert space. V8 is one specific instantiation of Bohmian mechanics in the chain encoder framework, not a derivation that the framework *is* quantum mechanics.

**What this section actually contributes — calibrated honestly after two literature searches.** The half-bit-ladder parameterization is *novel as a framing but trivial as math*. The four landmark CHSH values being known is older than this whitepaper by decades; taking `log_2` of them to expose the half-bit grid is a one-line rewrite that the literature has not bothered with because the grid is a numerical fact about the CHSH scenario, not a substrate-indexing theorem. The framing's value, if any, is pedagogical — it gives the framework `Q = R / 2^I` a clean way to talk about the CHSH hierarchy in its own units. Whether this clean re-presentation is worth the cost of yet another piece of notation is a judgment for the reader. **The honest contribution of this section, after both literature searches, is two things:** (i) the empirical eight-variant CHSH landscape from `chsh_prototype.py` measured against five known reference points (V1 sub-classical, V2 Bell, V4 quantum, V5 PR box, V8 Bohmian/Toner-Bacon), and (ii) the *one specific software instantiation* in V8 — neither of which is novel mechanism, both of which are runnable code that any reader can clone and re-run. The closest existing information-theoretic framing is Pawlowski et al's information causality (2009), which derives Tsirelson from an `m`-bit communication bound; a future version of this section should walk through the precise relationship between Pawlowski's `m` and this section's "suppressed `I`," because they are likely the same parameter under a relabeling.

**Prior art and how V8 compares.** A targeted literature search produced five close matches that need to be cited and explicitly distinguished from V8:

1. **Toner & Bacon, *"Communication cost of simulating Bell correlations"*** (*Physical Review Letters* 91, 187904, 2003) — *the structural twin*. Toner and Bacon proved that **one bit of classical communication suffices** to simulate the singlet correlations exactly. V8's "non-local sub-resolution phase update" *is* a form of communication: Alice's measurement angle `α_A` and her outcome `b_A` are transmitted (implicitly, via the deterministic phase update rule) to Bob's qubit. V8 transmits *more* than 1 bit per measurement — it transmits an angle plus a bit — so it is *less* efficient than the Toner-Bacon protocol while reaching the same Tsirelson statistics. **V8 is best understood as a Toner-Bacon-style 1-bit-communication model dressed in procedural-field clothing**, not as an independent route to Tsirelson. The contribution is the implementation in a specific software substrate, not the mechanism.

2. **Garza & Hance, *"Quantum-Like Correlations from Local Hidden-Variable Theories Under Conservation Law"*** (arXiv:2511.06043, November 2025) — *closest match in framing*. A recent paper that uses "measurement precision alters the hidden-variable measure space" — essentially the "sub-resolution" idea, applied to a *local* (not non-local) hidden variable model under conservation-law constraints. The V8 "binding lives below the resolution we observe at" framing reads as a non-local cousin of Garza & Hance's local construction. Any reader of this whitepaper familiar with Garza & Hance will note the similarity, and any conscientious literature search by a future reviewer will catch it.

3. **'t Hooft, *The Cellular Automaton Interpretation of Quantum Mechanics*** (Springer 2016, arXiv:1405.1548) — *closest framing match for "deterministic substrate beneath quantum statistics."* 't Hooft's program builds quantum mechanics on a deterministic cellular-automaton substrate ("ontological states") with binary measurement outputs on top. The differences are substantive: 't Hooft escapes Bell's bound via *superdeterminism* (rejecting counterfactual definiteness in measurement settings), not via non-local updates between observers. He does not ship a runnable CHSH simulator. V8 takes the opposite route — it accepts setting independence and uses an explicit non-local communication channel (the phase update) instead. Both are consistent with the data; they are different points in the no-signaling polytope.

4. **Michielsen / De Raedt event-by-event Bell-simulation program** (15+ years; the most recent survey is De Raedt et al, *"What do we learn from computer simulations of Bell experiments?"*, arXiv:1611.03444, 2016) — *the most omitted-by-default body of prior work*. A long-running program building event-by-event classical computer simulations of Bell experiments. Their simulators reproduce the standard quantum statistics (including CHSH) using detection-loophole-style mechanisms rather than explicit non-local communication. V8's mechanism is different (non-local phase update vs. detection-efficiency exploitation), but the *category* — "event-by-event classical computer simulation that produces quantum-strength CHSH correlations" — is exactly what they have spent fifteen years working on. Not citing them is a fifteen-year omission.

5. **Emmerson, *"Phenomenological Velocity and Bell-CHSH"*** (PhilArchive / IJQF, 2024) — *closest runnable code*. A hidden-parameter model with selection-simulation code that reproduces `E(a,b) = -cos(a-b)` and reaches Tsirelson scale. The mechanism is post-selection plus phenomenological-velocity-indexed microcausal SU(2) conjugation, not non-local phase collapse on a procedural-field substrate. Different mechanism; same target value; runnable code in both cases.

6. **Darrow & Bush, *"Convergence to Bohmian Mechanics in a de Broglie-Like Pilot-Wave System"*** (*Foundations of Physics* 55, 2025; arXiv:2408.05396) — runnable pilot-wave simulation, but for single-particle position measurement rather than two-party CHSH. Same Bohmian heritage; different observable.

**The honest re-calibration after the literature search.** V8 is not novel in mechanism. It is structurally a Toner-Bacon-style 1-bit (or more) classical communication protocol implemented via implicit "phase update" rather than explicit messaging. The "sub-resolution binding" framing is a specific way of *talking about* this kind of model that I have not found written elsewhere, but the underlying physics is standard. The contribution shrinks to: *a specific procedural-field-encoder instantiation of a known communication-cost simulation, packaged with a half-bit-ladder parameterization of the CHSH hierarchy.* That is a smaller claim than "the chain encoder hosts a Bohmian model that reaches Tsirelson," but it is the honest one.

**A terminology note for cross-discipline readers.** The phrase "procedural field" is borrowed from computer graphics and game development, where it refers to functions that generate world content lazily from a seed. The standard physics-foundations term for what the chain encoder hosts is closer to *ontological state space* or *beable basis* (in 't Hooft's terminology). When this section talks about a "sub-resolution layer," the corresponding object in the foundations literature is a hidden variable layer in a deterministic substrate. The two vocabularies describe the same thing; the procedural-field framing is the software-engineering view, the beable framing is the foundations-physics view. A reader from either side should be able to translate.

### 2.9 Summary table

| Case | `I(O; S)` | `R(A)` | `Q = R / 2^I` | Standard result |
|---|---|---|---|---|
| Heisenberg conjugate position | `(1/2) log_2(1 + σ_x^2/σ_n^2)` | `σ_x` | `σ_post` (Bayesian) | `Δx · Δp ≥ ℏ/2` |
| Classical N-bin instrument | `log_2(N)` | `R` | `R / N` | bin width |
| Holevo bound | `χ(ρ, M)` | `R` | `R / 2^χ` | Holevo information ceiling |
| Compton single-particle floor | `log_2(m c R / ℏ)` | `R` | `ℏ / (mc)` | reduced Compton wavelength |
| JeffJS qubit field | `N` bits (octree depth) | `2^{25}` | `2^{25 - N}` | cell-center octree |
| No information | `0` | `R` | `R` | range-as-cell |
| Gaussian channel (general) | `(1/2) log_2(1 + σ_x^2/σ_n^2)` | `σ_x` | `σ_post` | Cramér-Rao saturation |
| **CHSH hierarchy** | **suppressed `I ∈ {0, 1/2, 1}`** | **`4`** | **`{4, 2√2, 2}`** | **PR / Tsirelson / Bell** |

In each row the recovery is mechanical: pick `I` from the existing physics, pick `R` from the natural scale of the observable, plug in. The principle does no work the existing physics did not do — it just expresses the answer in a single line, in the units of the observable, observer-relative. The Gaussian channel row is the *general theorem* that the first six rows are special cases of. The new bottom row (CHSH hierarchy) extends the framework to multi-observer joint correlations and is empirically confirmed by the eight-variant prototype `chsh_prototype.py`.

---

## 3. The software model: JeffJS quantum chain encoder

Section 2.5 sketched the qubit field as a special case of the principle. This section describes the software model in enough detail that a reader could build a counterpart.

### 3.1 The qubit field

The base structure is a deterministic procedural field of 256 two-dimensional points. Each qubit has a position `(x, y)`, a speed, a radius, and a phase, all generated from a 32-bit field seed by a `SplitMix64` PRNG. The field is *defined*, not *stored*: there is no array of qubits sitting in memory until something asks for them. The qubit at any position exists in the sense that the generator function is well-defined; nothing is instantiated until a query touches that part of the field. This laziness is what lets the address space be conceptually very large without paying for it in memory.

A read at address `(vx, vy, t)` selects the `25` qubits closest to `(vx, vy)` in the plane, advances their phases by `t`, and computes for each one a single derived bit by signing the cross-product of its motion vector with `(vx, vy)`. The 25 bits are concatenated into a 25-bit *payload*. The bit derived from the closest qubit is the one the chain encoder uses; the popcount of the full 25-bit payload is what the slice-based encoder uses, but the chain encoder is the relevant one for this paper.

### 3.2 The chain encoder algorithm

Encode an `N`-bit message into a single 64-byte master key as follows.

1. Start at level 1. The coarsest octree cell has each axis represented by one bit; there are eight cells total (`2^3 = 8`).
2. For each candidate level-1 cell, sample at the *center* of the cell — `(0.5/2 · field_size, 0.5/2 · field_size, 0.5/2 · field_size)` for cell `(0,0,0)`, and so on for the other seven. Read the derived bit at the center. Pick a cell whose derived bit equals message bit `b[N-1]` (the *last* bit of the message).
3. Descend to level 2. The chosen level-1 cell is now the parent; its eight children are the eight ways to extend each axis by one more bit. Sample each child at *its* center. Pick a child whose derived bit equals `b[N-2]`.
4. Continue. At level `k`, the chosen cell has `(k-1)` bits per axis already fixed; the eight children explore the `k`-th bit on each axis. Pick one whose derived bit equals `b[N-k]`.
5. Stop when level `N` is reached. The chosen cell's full `(vx, vy, t)` — `N` bits per axis — is the master key.

If at any level no child cell matches the target bit, the encoder backtracks: it returns failure to its parent, the parent tries a different child combination, and so on. The backtrack budget is capped at 5 000 node visits per seed (~0.3 s of compute), after which the encoder rotates to the next field seed and starts over. Across 32 seeds the worst-case latency is roughly 10 s; for friendly bit patterns it returns in under 100 ms.

Decoding is the inverse and requires no search:

1. Start at the master-key address `(vx, vy, t)` at level `N`.
2. Sample at the cell center for level `N`, `(vx + 0.5)/2^N · field_size`. Read the derived bit. That is `b[0]` — the *first* message bit.
3. Shift each axis right by 1 (truncate the lowest bit). The result is the parent cell at level `N-1`. Sample at its center. That bit is `b[1]`.
4. Continue, shifting right and reading, until level 1 is reached. The bit at level 1 is `b[N-1]` — the *last* message bit.

Decoding is `N` reads, fully deterministic, ~microsecond cost. Encoding is the expensive part because of the search; decoding is the cheap part because the master key has already located the unique deepest cell.

### 3.3 The cell-center mapping

The detail that makes the construction work is that every cell is sampled at its *center*, not its *corner*. The mapping is

`fvx = (vx_int + 0.5) / 2^level · field_size`.

A level-1 cell with `vx_int = 0` is sampled at `vx = 8` (the center of `[0, 16)` in a 32-unit field). Its level-2 children with `vx_int ∈ {0, 1}` are sampled at `vx = 4` and `vx = 12` — both inside `[0, 16)` but neither equal to the parent. This guarantees that consecutive levels read genuinely different qubit windows, so the bit at level 2 is genuinely independent of the bit at level 1, so the encoder has eight new degrees of freedom at every step rather than re-sampling the same point. Without cell-centering the levels would collapse onto each other and the chain would carry no information past level 1.

### 3.4 The double-precision floor

The chain encoder is implemented in `Double` (IEEE 754 binary64). The cell width at level `k` is `field_size / 2^k`. With `field_size = 32` and Double's 52-bit mantissa, the cell width drops below the smallest representable spacing at roughly `k = 52`. The encoder caps at `maxBits = 48` to leave headroom against round-off error in the cell-center mapping. Forty-eight bits is six ASCII characters per single key — a meaningful payload, but a hard ceiling. The cap is the principle in action: the precision of your representation imposes a maximum `I` you can store, and beyond that maximum the cells stop being distinguishable. In principle one can move to arbitrary-precision arithmetic and push the cap arbitrarily high; in practice the trade-off between precision and cost reasserts itself.

### 3.5 The encoder is the principle

Putting it together: the chain encoder is one of very few foundations-of-physics constructions where you can read the principle off the source code. The address space `2^{25}` is the range. The N-bit address is the mutual information. The cell at depth `N` has size `R / 2^N`. The encoder is a *physical instantiation* of the equation `Q = R / 2^I`, not a metaphor for it.

I think it is unusual for a foundations paper to come with a working software artifact attached. The JeffJS module is open source (the repository URL is a placeholder until the user publishes — see References). A reader who wants to play with the principle in code, vary `N`, watch the cell shrink, observe the precision floor, can do so in a few minutes after cloning. I take this seriously as evidence that the principle is well-defined enough to compile.

### 3.6 Structural analogies to physical concepts

The chain encoder uses several specific algorithmic primitives that have structural analogs in physics. None of these analogies are *derivations* — the encoder does not prove statistical mechanics or quantum mechanics from its operations. They are real structural similarities at the algebraic and combinatorial level, and a reader who recognizes them may find the encoder's design choices clearer. I list them explicitly because the framework's "epistemic bottleneck" reading naturally raises the question *"what other physics has the same structural shape?"*, and the honest answers are useful even when they are not load-bearing.

**Popcount slicing and combinatorial concentration.** The slice encoder's central optimization is to search for cells whose 25-bit payload has popcount in a target range, rather than for cells whose payload exactly matches a target value (Section 2.3 of the original paper draft). This works because the popcount distribution of random 25-bit strings is binomial, sharply concentrated around its mean of 12.5. Four popcount slices each cover roughly 25% of cells, giving the encoder a useful match probability of ~25% per cell instead of `2^{-25}` per cell.

The same combinatorial concentration is what makes Boltzmann's statistical mechanics work. Macrostates with more microstates are exponentially more common than macrostates with fewer microstates; thermodynamic equilibrium emerges because the system spends most of its time in the largest macrostate. **The encoder is using the same combinatorial fact** — summary statistics concentrate around their means — for a different purpose. Statistical mechanics uses it for thermodynamic prediction; the encoder uses it for search efficiency. This is a structural similarity, not a derivation. The encoder does not prove Boltzmann's law; it uses the same combinatorial fact that motivates it. A reader who recognizes the analogy may see why the slice encoder works as well as it does, and may find Boltzmann's law slightly less mysterious as a result.

**Chain structure and partial order.** The chain encoder's structure imposes a strict partial order on the message bits: bit `b[k]` is determined by, and can only be reached from, the bits at levels `1` through `k-1`. Information flows from coarse (level 1) to fine (level N) at encoding time, then from fine to coarse at decoding time. This is a specific kind of partial-order structure: a tree where each node has a single parent and at most 8 children.

In physics, causal partial orders are the structure of relativistic spacetime: an event at point `P` can affect only events in `P`'s future light cone. Light cones are a *metric* causal structure, with a maximum signal speed `c`. The chain encoder's partial order is *non-metric* — it has no analog of `c`, no signal speed, no Lorentzian geometry. The two share only the structural feature that "later events depend on earlier events," which is true of any deterministic system. The analogy is therefore weak as physics but useful pedagogically: the chain encoder is one of the simplest concrete examples of a discrete partial-order structure with observers, and a reader who has been told about causal sets in quantum gravity but never run one may find the encoder a useful warm-up.

**Cross-product bit derivation and spin projection.** The bit-derivation function

`cross = sin(α) · dx − cos(α) · dy;   bit = (cross < 0) ? 1 : 0`

has the algebraic form of a measurement on a 2D vector projected onto a chosen axis. The qubit's angular phase `α` plays the role of the measurement axis; the displacement `(dx, dy)` plays the role of the vector being measured. The binary outcome is the sign of the projection.

This algebraic form is the same form that appears in quantum spin projection for a spin-1/2 particle: a measurement along axis `n` returns `±ℏ/2` with probabilities determined by the projection of the spin state onto `n`. The encoder's bit-derivation has the same shape (binary outcome from a vector projection) but lacks the quantum-mechanical structure (no Hilbert space, no superposition, no Born rule, no interference). It is a deterministic classical analog of a spin measurement, where the "spin state" is the qubit's angular phase and reading bits at different observer positions samples this state from different angles. This is structural similarity at the level of algebra. It is not a derivation of quantum mechanics, and a reader should not take it as one. It may, however, be a useful first concrete example for a reader who has only seen spin projection in textbook notation and never as a working binary classifier on a spatial field.

**Why these analogies are in the paper.** They are not load-bearing for any of the paper's claims. The framework `Q = R / 2^I` does not depend on any of them being more than analogies. They are included because the encoder *as a piece of software* uses three primitives that have specific structural analogs in physics, and a reader trying to understand what the encoder is doing may find it useful to know what physical concept each primitive corresponds to. The intent is pedagogical, not foundational.

### 3.7 Proof by construction: one structural property, instantiated

I want to make a small philosophical claim about the chain encoder, and I want to be careful to size it correctly, because this is the place in the paper where it is easiest to slide from a defensible statement into an indefensible one. So let me state both the claim and its limits explicitly, in that order.

**The claim.** The framework's central equation `Q = R / 2^I` and its associated structural properties (a procedural seed that generates a deterministic field, observer-relative bit readouts via a fixed function, exponential resolution-information scaling, an observer-floor `I_max`) could in principle be made as theoretical assertions and left as speculation. That is what most foundations-of-physics papers in this tradition do. Wheeler's *"It from Bit"* is an essay. Brukner and Zeilinger's information-invariance program is a series of theoretical derivations. Frieden's *Physics from Fisher Information* is a 328-page mathematical treatise. None of them ship a runnable counterpart.

This paper does. The chain encoder is a working Swift module that **instantiates this one specific structural property — the resolution-information trade-off — as executable code**. A reader can clone the repository, run `swift build`, execute `chain.encode("Hi")`, and watch the principle run on commodity hardware. The qubit field, the cross-product bit-derivation function, the cell-center mapping, the precision floor as an observer ceiling — all are not arguments. They are objects that exist on the reader's machine after a five-minute clone-and-build.

This shifts the epistemic status of one specific narrow claim in a small but real way: **the proposition "the resolution-information trade-off `Q = R / 2^I` can be instantiated as a deterministic procedural field with observer-relative readouts on real hardware" is no longer hypothetical**. It is demonstrated by worked example. A reader who doubted that such a structure could be made consistent on a real machine can resolve the doubt by running the code.

**The limits, which I want to make load-bearing rather than parenthetical.** The chain encoder is *not* a model of foundational physics, and §3.7 should not be read as saying it is.

- The qubit field has **no Lorentz invariance.** Cross-product PT is not even a symmetry of the bit-derivation function. There is no `c`, no metric causal structure, no relativistic constraint of any kind.
- The qubit field has **no conservation laws.** Energy, momentum, charge, lepton number, angular momentum — none of these are conserved or even definable in the field's vocabulary.
- The qubit field has **no quantum mechanics.** It is fully classical and deterministic. No Hilbert space, no superposition, no Born rule, no entanglement, no measurement collapse. The bit-derivation function has the algebraic *shape* of a spin projection (Section 3.6) but it is not a quantum measurement in any operational sense.
- The qubit field has **no matter, no fields, no forces, no gravity, no dynamics beyond a fixed angular rotation.** The "qubits" are 256 deterministic 2D points whose orientations advance linearly in `t`. They do not interact, attract, repel, scatter, decay, or evolve under any Hamiltonian.
- The qubit field has **no observers in any rich sense.** An "observer" in the field is a query position `(vx, vy, t)` — a point in the address space at which bits are read. It has no internal state, no memory, no perception, no capacity to act, no continuity over time. The word "observer" in this paper means "query position." Nothing more.
- The chain encoder **does not derive** any physical law from computational primitives. It *uses* primitives (cross products, popcount distributions, Bayesian updates) that have analogs in physics, but it does not produce them. The structural analogies in Section 3.6 are analogies, not derivations, and I want that distinction to remain load-bearing here too.

So **the chain encoder is not a universe that follows foundational physics**, and Section 3.7 is not the claim that we have built one. The chain encoder is a procedural field with **one specific structural property** — the resolution-information trade-off — instantiated in working code, alongside an absence of essentially every other property that physical universes have. The qubit field and the actual universe share one feature out of many.

**What this small instantiation actually shifts.** Even given those limits, the worked example does one specific thing for the literature. Most claims in the digital-physics, "It from Bit," and computational-universe traditions are theoretical: they argue that some piece of physical structure is *possible in principle* to instantiate computationally. The standard objection is that "in principle" hides assumptions about computability, observer-construction, information-readout structure, and self-consistency. The chain encoder removes that objection **for one specific structural property** — the resolution-information trade-off — by exhibiting a worked example. It does not remove it for any *other* structural property of physics. It does not address whether quantum mechanics, relativity, conservation laws, or anything else can be instantiated computationally. Those questions remain open.

The shift, calibrated honestly, is: *for the resolution-information trade-off specifically*, the burden of proof has moved from "could this be instantiated at all" to "does this trade-off (already known from Stam, Frieden, Heisenberg, Holevo) admit a deterministic computational realization with observer-relative readouts." The answer to the second question is now "yes, the chain encoder is one." The answer to the first question — "is this a model of physics" — is still "no, this is one structural property in a sea of other properties physics has and the encoder does not."

I am the author of this paper and I want to state explicitly that I think the temptation to read §3.7 as something larger than this is real and worth resisting. The paper does *not* claim to have modeled a universe that follows foundational physics. It claims to have instantiated one structural property of physical measurement in code, and to have done so in a way that no other paper in the information-theoretic-foundations tradition has. That is the entire claim of §3.7. Anything stronger is overreach, and a careful reader should hold the paper to the smaller version.

**The contribution, calibrated.** The chain encoder is, to my knowledge, the first foundations-of-physics software artifact in the information-theoretic-measurement tradition where a reader can run the resolution-information principle as executable code rather than only read about it. The closest analog is the cellular-automaton tradition (Wolfram, Toffoli, Fredkin), where toy universes have been built and studied — but those are not framed around an information-theoretic resolution principle, and they are not connected to a continuous-coordinate cross-product readout function. The chain encoder occupies a small unoccupied niche, and "small unoccupied niche" is exactly the right size of claim.

This is, to my reading, the most distinctive thing the paper has to offer. Not the equation, which is in the Stam-Frieden tradition. Not the unification, which is mostly notational. Not even the trans-Planckian framing, which is a sharper formulation of an existing question. **The most distinctive thing is that this paper ships a worked instantiation of the resolution-information principle that a reader can clone, build, and run, and that this instantiation is one of the few existing concrete handles on what an information-theoretic foundation of measurement looks like as software rather than as math.** This is a small contribution. It is also a real one. I am asking the reader to hold both of those at once, and to neither dismiss the contribution as insignificant nor inflate it into something it does not claim to be.

---

## 4. Predictive consequences and a proposed test

### 4.1 What kind of claim this is

The principle does not predict any phenomenon not derivable from existing quantum mechanics plus information theory. I want to be flat about that. The only thing it does is *organize* claims about resolution into a single dimensional form so that one can compare regimes that are usually treated separately. That is a contribution if you think unification is a contribution and not if you don't.

But the principle does make a sharp claim that is testable in a non-trivial sense: *the trade-off between information extracted by an observer and resolution achievable in the observable should follow `Q = R / 2^I` across regimes where it has been independently measured*. That is, in any experiment that measures both the information acquired in one stage and the resolution achievable in a subsequent stage, the data should fall on the curve. If the data fall off the curve in some regime, the principle is wrong (or the regime is one where some hidden term I have not accounted for matters).

### 4.2 The retrodiction: continuous qubit measurement

The Cramér-Rao equivalence theorem in Section 2.7 already does most of the work. It shows that for any Gaussian channel — which is the standard model for weak measurements — the principle is exactly the Bayesian-Gaussian update, *not approximately*, in any regime. This already counts as a retrodiction in the sense that any experiment achieving the Gaussian-channel benchmark *automatically* verifies `Q = R / 2^I`. The remainder of this section walks through a specific concrete case to make the recovery vivid.

**Setup.** Take the standard continuous quantum measurement of a superconducting qubit's `σ_z` observable, of the kind realized by the Murch, Weber, and Siddiqi groups using dispersive readout through a microwave cavity (Murch et al. 2013, Weber et al. 2014). The qubit state evolves under Hamiltonian dynamics; a microwave probe coupled to the cavity picks up a phase shift that depends on `σ_z`; the homodyne-detected phase is the apparatus pointer.

The relevant parameters of any such experiment are:

- **Measurement rate `γ`** (units: inverse time). This is the standard measurement-strength parameter. For dispersive qubit readout, `γ = 4 χ^2 n̄ κ / (κ^2/4 + Δ^2)` in the textbook formulation (Wiseman-Milburn equation 3.180), where `χ` is the dispersive shift, `n̄` is the cavity photon number, `κ` is the cavity decay rate, and `Δ` is the detuning. The experimentalist tunes `n̄` to vary `γ`.
- **Integration time `t`** (units: time). The total time over which the homodyne signal is integrated.
- **Prior on `σ_z`** with standard deviation `σ_z^prior`. For an unknown qubit state in the equatorial plane, `σ_z^prior = 1` (the full Bloch-vector range).

The standard result, derived in Wiseman-Milburn and verified to four decimal places by all the groups doing continuous qubit measurement, is that the **Fisher information rate** is

`F_rate = γ`

(in units of inverse `σ_z^2` per unit time), and the per-shot mutual information for a Gaussian-channel approximation of the homodyne record is

`I(t) = (1/2) log_2(1 + γ t · (σ_z^prior)^2)`     (bits).

This is the standard result. It is in the textbooks. I am not deriving anything new; I am about to plug it into the principle.

**The retrodiction.** Apply Section 2.7's Cramér-Rao equivalence theorem with `σ_n^2 = 1/(γ t)` (the effective Gaussian noise width of an integrated homodyne signal, from the standard derivation) and `σ_x = σ_z^prior = 1`. The principle says

`Q(t) = σ_z^prior / 2^{I(t)} = 1 / sqrt(1 + γ t)`.

This is exactly the standard result for the conditional variance of `σ_z` after integration time `t` for an ideal continuous quantum measurement (compare Wiseman-Milburn equation 3.196, or any of the experimental papers above). At `t = 0`, `Q = 1` (the full Bloch-vector range, no information). As `γ t → ∞`, `Q → 0` (perfect knowledge of `σ_z`). The intermediate scaling matches every continuous-qubit measurement experiment to date, because every such experiment is fitting its data to *exactly this curve*.

**Numerical sanity check with realistic parameters.** Take `γ = 1 μs^{-1}` (a typical measurement rate for a superconducting qubit dispersively read through a high-Q cavity) and `t = 200 ns` (a typical integration time before the Hamiltonian evolution becomes the dominant effect). Then:

- `γ t = 0.2`
- `I(t) = (1/2) log_2(1.2) ≈ 0.132` bits — that is, the experimenter has extracted about an eighth of a bit of information about `σ_z` from this single weak measurement
- `Q(t) = 1 / sqrt(1.2) ≈ 0.913` — the residual standard deviation of the `σ_z` estimate is about 91% of its prior value, meaning the measurement has barely tightened the posterior

Plug into the principle:

`Q = R / 2^I = 1 / 2^{0.132} = 1 / 1.096 ≈ 0.913`. **Match.**

The principle exactly recovers the standard textbook result. It does not predict it independently; it *is* the standard result, written in different notation. That is what the Cramér-Rao equivalence theorem in Section 2.7 establishes, and this numerical check is one instance of it.

Take a longer integration: `t = 5 μs`, so `γ t = 5`.

- `I(t) = (1/2) log_2(6) ≈ 1.292` bits
- `Q(t) = 1 / sqrt(6) ≈ 0.408`
- Principle: `1 / 2^{1.292} = 1 / 2.448 ≈ 0.408`. **Match.**

Take a strong-measurement regime: `t = 100 μs`, so `γ t = 100`.

- `I(t) = (1/2) log_2(101) ≈ 3.329` bits
- `Q(t) = 1 / sqrt(101) ≈ 0.0995`
- Principle: `1 / 2^{3.329} ≈ 0.0995`. **Match.**

The agreement is exact at every value of `γ t`, weak through strong, because the principle and the standard continuous-measurement formula are the same equation written in different units. There is no weak-measurement experiment in the literature that can distinguish them, because they are not different.

**What this proves.** The principle is consistent with all existing continuous quantum measurement data — every Murch-style continuous-qubit experiment, every Steinberg-style weak-value experiment, every Hosten-Kwiat-style weak-value-amplification experiment that operates within the Gaussian-channel regime — by construction. The Cramér-Rao equivalence theorem in Section 2.7 says any such experiment achieving the Gaussian-channel benchmark automatically lies on the principle's curve, and this section's numerical walk-through is one explicit instance.

**What this does not prove.** The retrodiction confirms the principle in the regime where the Gaussian-channel model is valid. It does not address regimes where the measurement model is non-Gaussian (single-photon counting at the discrete level, projective spin measurements, certain joint measurements of incompatible observables). Those regimes are where I would expect the principle's exponential scaling to break down in interesting ways, and where the framework would have actual content beyond the Cramér-Rao bound. I do not have a worked example of that breakdown to offer here. It is the next thing I would investigate if I were continuing this work.

**Honest summary.** The retrodiction is *successful* in the sense that the principle exactly matches the standard result for continuous Gaussian measurement, and *unsurprising* in the sense that the Cramér-Rao equivalence theorem guarantees this in advance. It is a verification of self-consistency, not a verification of new physics. The contribution of doing the worked example explicitly is that it removes any doubt about whether the framework actually compiles when you plug numbers in, and it makes the priority claim for future work concrete: extending the principle to non-Gaussian measurement regimes is the obvious next research question, and I have not done it.

### 4.3 Retrodiction vs. prediction

I want to be explicit about what kind of test the Section 4.2 worked example is. The analytical retrodiction is exactly that — a retrodiction, in the strong sense that the principle is *provably* equivalent to the standard Cramér-Rao-saturated Gaussian-channel formula in any regime where that formula applies (Section 2.7). It recovers existing data from a unified principle. It is not a prediction of something unmeasured. Both retrodictions and predictions are valuable, but they are valuable in different ways. A retrodiction in this strong sense tells you that the principle's form correctly captures the structural content of an existing piece of physics. A prediction would tell you that the principle constrains what is unknown. The principle as it stands has done the first; it has not done the second.

A genuine prediction from the principle would be an experiment in some regime where the Gaussian-channel measurement model breaks down — single-photon counting, projective spin readout, certain joint POVMs of incompatible observables — and where the principle says something specific about what the resolution-information trade-off should be in that regime. The Cramér-Rao equivalence in Section 2.7 only applies in the Gaussian regime; outside it, the principle's exponential scaling either continues to hold (which would be a non-trivial prediction worth testing) or breaks down in a structured way (which would itself be informative). I do not have a worked candidate experiment for the non-Gaussian regime, and I flag this as the obvious place where the framework could either earn or lose a stronger predictive claim. If a candidate experiment emerges, that would be the upgrade from "this organizes existing physics" to "this constrains new physics."

The honest claim, after Sections 2.6 and 4.2, is sharper than I could state in earlier drafts: a single line that recovers Heisenberg, Holevo, the classical-instrument bound, the software model, and the standard continuous-quantum-measurement formula in the same notation, and that has been verified analytically against the Gaussian-channel benchmark at multiple measurement strengths. The retrodiction in §4.2 is consistent with all existing weak-measurement and continuous-measurement data in the Gaussian regime by construction, because the principle is the same equation written in different units. That is a smaller claim than "new physics" and a larger claim than "tautology" — it is the claim that the existing math has a cleaner one-line form that exposes its structural meaning, and that the cleaner form connects directly to a working software artifact. It is the size of claim I think is supportable.

### 4.4 From prototype to quantum circuit simulator

The chain encoder in §3 and the CHSH prototype in §2.8 were built in Python as research prototypes. The methodology — *build software that instantiates a physics principle, run experiments on it, check against known results, iterate* — proved productive enough that the prototypes were extended into a full quantum circuit simulator, then ported to Swift with Metal GPU acceleration and exposed through the JeffJS JavaScript engine as `window.jeffjs.quantum.simulator`.

**What was built and validated.** The quantum simulator correctly executes six quantum algorithms, each verified against known results:

1. **Shor's algorithm** (iterative phase estimation) — factors integers using quantum period-finding. Uses `n+1` qubits for an `n`-bit number (one counting qubit measured and recycled `2n` times, replacing the full `2n`-qubit counting register). Validated on 15, 21, 35, 77, 143, 323, 1007, 3127, 5767, 11009, and 29999 — all factored correctly. The iterative optimization reduces the state vector from `2^{3n}` to `2^{n+1}` amplitudes, which is what makes factoring 29,999 (15 bits, 16 qubits, 65536 amplitudes) feasible in under one second on a single CPU core.

2. **Deutsch-Jozsa** — determines whether an oracle is constant or balanced in one query. Tested on 8 oracle configurations (4-bit, 8-bit, 16-bit inputs), all correct.

3. **Bernstein-Vazirani** — recovers a secret string in one query. Tested on strings up to 20 bits, all recovered perfectly.

4. **Quantum teleportation** — transfers a quantum state via entanglement and classical communication. The 3-qubit circuit (data + Alice + Bob) correctly transfers `|+⟩` with 100% success rate.

5. **Superdense coding** — sends 2 classical bits using 1 qubit plus a shared Bell pair. All four input combinations verified.

6. **Error correction** — a 3-qubit bit-flip repetition code with syndrome extraction. Correctly detects and corrects single-qubit X errors.

**The GHZ O(N) interference discovery.** During the development of the multi-qubit scaling experiments, a specific O(N) sampling algorithm for GHZ states was derived from the failure mode of the V8 Bohmian model. The key finding: for GHZ = `(|00...0⟩ + |11...1⟩)/√2`, the quantum interference cross-term `2ab ∏ cos_i ∏ sin_i` cancels when computing marginal probabilities at intermediate measurement steps (because the remaining qubits' states are orthogonal and trace to zero), but survives at the **last qubit** where there are no remaining qubits to trace over. This means the GHZ joint distribution can be sampled exactly by:

1. For qubits 1 through N-1: use the no-interference formula `P(+1) = a^2 cos^2(α/2) + b^2 sin^2(α/2)`, updating coefficients `(a, b)` with correct signs at each step
2. For the last qubit N: use the interference formula `P(+1) = (a cos(α_N/2) + b sin(α_N/2))^2`

This is O(N) per trial, O(TRIALS) memory, and produces the exact quantum statistics at arbitrary measurement angles. It was validated against the Born-rule reference at N=3 (max error 0.003 across 7 angle configurations at 200K trials) and scaled to N=1,000,000 at `σ_x` angles (E = +1.0000 in 144 seconds on one CPU core).

The algorithm is a consequence of the GHZ state having only two terms in its superposition. For general N-qubit states with `2^N` terms, no such shortcut exists — the full state vector is required. But for GHZ specifically, the chain encoder's "procedural, not stored" principle applies: the state is always just two numbers `(a, b)`, computed on the fly, never stored as an exponential-size vector.

**The V8-to-N=3 failure and what it teaches.** The V8 Bohmian model (§2.8) correctly reproduces Tsirelson-bound CHSH correlations for N=2 (one entangled pair). When extended to N=3 (GHZ), the sequential measurement model breaks: the 3-party correlation collapses to zero (indistinguishable from uncorrelated noise). The reason is structural: after measuring qubit 1, the remaining 2-qubit state is still entangled (`a'|00⟩ + b'|11⟩`), but the sequential probability formula `P = a'^2 c^2 + b'^2 s^2` drops the cross-term that carries the residual entanglement. The V8 model's `P = |a|^2 c^2 + |b|^2 s^2` is a sum of squares; the correct quantum probability `P = |ac + bs|^2` is a squared sum. The difference — the interference term — is exactly what the "last qubit" fix restores.

**The Swift + Metal port.** The full simulator was ported from Python to Swift (~2,900 lines) with Metal GPU compute shaders for gate operations (Hadamard, CNOT, controlled modular multiplication, phase gate, Pauli-X, measurement probability reduction). The GPU path activates automatically for circuits with 18+ qubits (262K+ amplitudes), where Metal's parallel thread dispatch outperforms CPU loops. For smaller circuits (including Shor's iterative QPE at 16 qubits), the CPU path is faster due to Metal command buffer overhead. All algorithms are exposed to JavaScript via `window.jeffjs.quantum.simulator` with async Promise support for long-running computations (Shor's, etc.) running on background threads.

---

## 5. Physical motivation for the resolution floor

The framework `Q = R / 2^I` is observer-relative in `I` but says nothing about what value of `I` a physical observer can actually reach. The chain encoder in §3 has a precision floor at roughly 48 bits because Double-precision arithmetic stops distinguishing cells; the analogous question for any *physical* observer is what bounds `I` from above in the actual universe. This section walks through the standard answer from the foundations-of-physics literature: physical observers have a finite `I_max`, set jointly by decoherence, thermal noise, finite measurement time, and the Bekenstein bound on the information capacity of any region they inhabit. Under this reading the Planck length is the value of `Q` evaluated at `I_max` — a useful intuition for why the encoder's "precision floor" framing has a natural cosmic counterpart, even though the encoder itself does not implement any of the gravitational physics described here.

**This section is background, not a derivation.** The Planck-collapse argument used in §5.4 traces to Bronstein 1936 and is developed extensively in the GUP literature (Maggiore 1993, Garay 1995, Hossenfelder 2013); none of it is original to this whitepaper. The contribution is that all of it lines up with the framework's exponential cost in `I`, in a way that motivates why an encoder of this kind has to have a precision floor at all.

Stated more precisely, for spatial-position measurements the smallest cell that any physical observer can distinguish is bounded by

`Q_min = R / 2^{I_max}`

where `I_max` is the maximum mutual information any apparatus inside our universe can extract from the system. Plugging in Bekenstein's bound — the maximum information storable in a region of surface area `A` is `A / 4` in Planck units — and identifying that with the apparatus's information capacity, gives `Q_min` on the order of the Planck length when `R` is the spatial window of the experiment and `A` is the spatial extent of the apparatus.

This is not a derivation of the Planck length from first principles. It is a statement that the Planck length is the value of `Q` at the maximum `I` that observers like us can pay. Other observers — with different decoherence environments, different apparatus capacities, or operating in different regions of spacetime — would have different `I_max` and therefore different `Q_min`. Under this reading the Planck length is not a fundamental property of nature; it is the resolution floor that observers like us can reach.

### 5.1 The open question: is the equation meaningful for `I > I_max`?

The principle has well-defined `Q` values for any `I`, including values above what any physical observer can reach. The equation does not stop at `I_max`. It just says nothing about what observers below the `I_max` horizon can do, because by construction those observers do not exist.

The interpretive question is: **does real structure exist at the `Q` values that correspond to `I > I_max`?**

Three positions are coherent within the framework, and each connects to a different active research program in quantum gravity.

**Position 1: no.** The universe stops at the Planck length. Loop quantum gravity, in some readings, says spacetime is genuinely discrete at the Planck scale and the question "what is between two Planck cells" is empty. Under this reading, `Q = R / 2^I` is vacuous for `I > I_max` — not because of an inability to compute, but because there is no system to ask about.

**Position 2: yes, but it is hidden.** The substrate has finer structure than any observer can read. This is closest to the holographic / ER=EPR / Bohmian camp. The "true path" of an entangled pair, the wormhole throat connecting them, the non-local hidden variables that produce quantum correlations — all would live in the regime `I > I_max`. Sub-Planck structure exists, but the only way to reason about it is indirectly, through its effects on the observable layer.

**Position 3: the question is coordinate-dependent.** This is the dual-of-T-duality reading. String theory's T-duality at the string scale identifies sub-string-length physics with super-string-length physics — they are the same physics, observed differently. Under this reading, "below the Planck length" is a coordinate artifact in `I`-space; there is no privileged direction, only different observers operating at different `I`.

The principle does not pick between these. It just makes the question precise: each position is a different stance on whether the equation has content beyond the `I_max` horizon, and each makes the same observable predictions, because by construction `I > I_max` is not observable.

### 5.2 The connection to ER=EPR

If Position 2 is correct — if real structure exists below the observer ceiling — then the obvious candidate for what lives there is the wormhole-bridge structure proposed by Maldacena and Susskind in the ER=EPR conjecture (Maldacena & Susskind 2013). Two entangled particles share a microscopic Einstein-Rosen bridge that cannot be traversed and cannot transmit signals, but exists as a geometric feature of spacetime.

In the language of `Q = R / 2^I`, ER=EPR is a specific proposal about what kind of structure exists at `I > I_max`: the connectivity of spacetime at the sub-observer level is non-trivial in a way that produces the entanglement correlations we see at the observable layer. The principle gives a clean technical home for the conjecture: ER=EPR is the claim that the equation's `I > I_max` regime is geometrically meaningful and that the geometry is wormhole-rich.

This is not a derivation of ER=EPR and not a verification of it. It is a statement that the framework `Q = R / 2^I` admits the conjecture as a natural extension and gives it a precise location in the formalism: the regime above the observer ceiling.

### 5.3 The software model says the same thing twice

In the JeffJS chain encoder there are two distinct floors. The encoder's *bit-resolution floor* is whatever value of `N` the encoder is currently running at — the depth of the octree it can address. With `N = 25` the encoder can resolve `2^{25}` cells; with `N = 48` it can resolve `2^{48}`. This is the *observer-level* floor: the resolution the program is committed to right now.

Underneath that sits the *substrate-level* floor — the Double-precision representation. Below approximately `2^{-52}` the underlying floating-point numbers can no longer distinguish positions, regardless of what the encoder asks for. The substrate has its own ceiling.

When the encoder runs at `N = 25`, there is real structure between `N = 25` and `N = 52` that the encoder cannot see but the substrate can represent. Increasing the encoder's bit count to `48` makes that structure addressable. It was always there; it just was not being observed.

This is a working software model of Position 2. Below the observer layer, structure exists. Whether it can be read depends on how many bits of `I` the observer commits to. The substrate bounds what is representable at all; the observer bounds what is currently being read. The gap between those two bounds is exactly the regime where any sub-observable physics — entanglement bridges, hidden variables, the "true path" — would have room to operate without surfacing at the observable layer.

I take this as a working metaphor, not as evidence. The chain encoder is a software artifact; the universe is not. But the *shape* of the question — the existence of two distinct floors and a finite gap between them — is the same shape, and it is the right shape for thinking about whether the Planck length is a hard floor or a horizon.

### 5.4 The mechanical enforcement of the I_max ceiling

Section 5 has so far proposed that physical observers in our universe have a finite mutual information ceiling `I_max`, set jointly by decoherence, thermal noise, finite measurement time, and the Bekenstein bound. The cosmological scaling in Section 5.5 will give `I_max ≈ 10^{123}` as a number. But none of this answers a more basic question: *why is there an `I_max` at all? what is the mechanism that actually prevents an observer from extracting one more bit?*

The principle, composed with the Heisenberg recovery from Section 2.1, gives a clean answer in one substitution step. The answer is gravitational, and the derivation does not require Bekenstein's bound, the holographic principle, or any cosmological input.

**The composition.** From Section 2.1, the Heisenberg-saturated form of the recovery is `Q ≈ ℏ / σ_p`, where `σ_p` is the apparatus's momentum-pointer width at saturation. (Factors of two are absorbed for clarity; the conclusion is order-of-magnitude robust.) From the principle, `Q = R / 2^I`. These must give the same `Q` for the same observer making the same measurement. Set them equal and solve for `σ_p`:

`σ_p = (ℏ / R) · 2^I`.

This is the **energetic cost of bits**: each additional bit of mutual information about the system requires *doubling* the apparatus's momentum-pointer width. For a relativistic probe with kinetic energy `E ≈ σ_p · c`, doubling the momentum doubles the energy. Each bit of resolution costs an apparatus-energy doubling.

The result is not new in the same way the principle itself is not new. It is the same statement as the de Broglie wavelength: a probe of momentum `p` resolves features of size `ℏ/p`, so finer resolution requires more momentum. But the *parameterization* is different: the principle's exponential cost in `I` is the same physics as the inverse cost in `Q`, restated in a way that connects to the rest of Section 5's information-theoretic framing.

**Pushing to the Planck cell.** Apply the cosmological scaling that will be developed in Section 5.5: addressing one Planck cell anywhere in the observable universe requires `2^{I_max} = R / ℓ_p`. Substitute into the `σ_p` formula:

`σ_p,max = (ℏ / R) · (R / ℓ_p) = ℏ / ℓ_p`.

The `R` cancels. The result is *independent of the apparatus size*. To resolve at the Planck cell, the required momentum-pointer width is `ℏ / ℓ_p`, regardless of how large the apparatus is or how far apart the observer and the system are.

Verify that `ℏ / ℓ_p` is the Planck momentum. With `ℓ_p = sqrt(ℏ G / c^3)`:

`ℏ / ℓ_p = ℏ / sqrt(ℏ G / c^3) = sqrt(ℏ^2 c^3 / (ℏ G)) = sqrt(ℏ c^3 / G) = p_P`.

Yes. The composition produces the Planck momentum exactly, by purely information-theoretic input.

**The gravitational closure.** A probe with Planck momentum has energy `E_P = p_P · c = sqrt(ℏ c^5 / G)`, the Planck energy. Localizing the Planck energy inside a Planck-volume sphere gives a Planck-mass particle whose Schwarzschild radius is `r_s = 2 G M_P / c^2 = 2 ℓ_p`. The probe sits *inside its own Schwarzschild radius* — it forms a black hole.

So the chain closes: extracting one more bit of mutual information at the Planck floor requires a probe with Planck momentum, which carries energy that gravitationally collapses the apparatus before the bit can be read out. **The `I_max` ceiling is mechanically enforced by gravity.** The framework does not need to invoke this mechanism axiomatically — it falls out of composing the principle with the Heisenberg recovery, and the gravitational consequence is one further step in standard general relativity.

**Priority: this argument is not new.** I want to be explicit. The Planck-collapse argument — that any apparatus capable of sub-Planckian resolution must concentrate Planck-mass energy in a Planck-volume region and therefore form a black hole — was first floated by Matvei Bronstein in 1936 (Bronstein 1936), and has been the standard motivation for the Generalized Uncertainty Principle (GUP) literature in string theory and loop quantum gravity from the 1990s onward (Maggiore 1993, Garay 1995, Hossenfelder 2013). It is in the textbooks. What the framework adds is a *one-line derivation route*: instead of needing Heisenberg, the Schwarzschild radius, and an energy-concentration argument as three separate pieces of machinery, the framework lets you compose the principle with the Heisenberg saturation and read off `σ_p,max = ℏ / ℓ_p` in two algebraic steps. The physics is identical; the *form* is cleaner.

This is the same kind of contribution as the rest of the paper. Not new physics. Cleaner notation that lets previously-separate pieces of physics talk to each other.

**One thing this composition does not prove.** The composition derives that the `I_max` ceiling is *gravitationally enforced*. It does not derive *what the value of `I_max` is*. The Bekenstein bound has its own derivation, going through black hole entropy and the second law of thermodynamics, and the value of `I_max` it sets agrees with the Planck-collapse value as a non-trivial consistency check between two independent arguments — not as a derivation. The framework shows the *enforcement mechanism*; Bekenstein gives the *numerical ceiling*. Both are real, both are needed, and the framework should not be read as making the second redundant.

**Connection to the three positions in §5.1.** The mechanical enforcement gives all three positions a common substrate to argue from. They disagree about *what (if anything) lives above `I_max`*: Position 1 says nothing, Position 2 says hidden structure, Position 3 says coordinate artifact. They agree that *any observer attempting to extract bits above `I_max` gravitationally collapses their apparatus*. The disagreement is metaphysical; the agreement is mechanical. The framework's composition makes the agreement explicit in a way the prose-level debate does not, and thereby restricts the metaphysical disagreement to questions that no observer inside the universe can ever resolve by measurement — which is, I think, where it belongs.

### 5.5 The cosmological scaling

Section 5.3 walked through the principle inside a software encoder where the observer floor sits at 25–48 bits and the substrate floor sits at the Double-precision boundary near level 52. The same scaling argument applies, with very different numbers, at the cosmological scale, and the cosmological numbers are striking enough to deserve their own walk-through.

Take the observable universe as the spatial range. The radius of the observable universe is approximately `R = 4.4 × 10^{26}` m. Take the Planck length as the resolution: `Q = 1.6 × 10^{-35}` m. The ratio is `R / Q ≈ 2.75 × 10^{61}`. To address every Planck-volume cell along a single spatial axis from one edge of the observable universe to the other requires

`I = log_2(R / Q) ≈ 205` bits.

**About two hundred bits.** Per axis. For full three-dimensional Planck-resolution addressing of every cell in the observable universe, roughly `615` bits — slightly larger than a modern cryptographic key.

This is a remarkable number for two reasons. First, it is small enough to fit comfortably inside the address space of a modest extension of the JeffJS chain encoder. The current 25-bit encoder addresses 33 million cells; a 615-bit encoder, structurally identical except for the Double-precision arithmetic which would have to be replaced by an arbitrary-precision representation, would address every Planck volume in the observable universe. The software model in Section 3 is not an analogy for the cosmological scaling. It is a small instance of the same equation, capped by floating-point precision instead of the Bekenstein bound.

Second, 205 bits is *enormously* smaller than the Bekenstein-Hawking information capacity of the observable universe. The de Sitter horizon area in Planck units is approximately `10^{123}`, and the holographic bound caps the information content of any region by one quarter of its boundary area. The maximum information storable in the observable universe — the upper limit on what *any* observer in our universe could in principle accumulate about the universe's state — is therefore `I_universe ≈ 10^{123}` bits. (Lloyd 2002 derives a related but distinct bound on computational operations since the Big Bang at `~10^{122}`; both numbers are in the same regime, and the gap to 205 bits is similar.)

The two numbers next to each other:

| Quantity | Bits | What it represents |
|---|---|---|
| Bits to address one Planck cell along one axis of the observable universe | `~205` | `Q = R / 2^I` solved for the Planck floor |
| Bits to address every Planck cell in three dimensions | `~615` | Linear scaling of the above |
| Bekenstein-Hawking bound on the observable universe's information capacity | `~10^{123}` | Holographic limit on cosmic horizon |
| Gap between needed and available | `~10^{120} ×` | Twenty orders of magnitude of slack |

To address every Planck cell in the observable universe, you need fewer than a thousand bits. The universe has *room for* something like `10^{123}` bits on its boundary. The Planck length is roughly twenty orders of magnitude *coarser* than what the universe's holographic information capacity could in principle resolve, if the observer had access to the full capacity and the principle's exponential scaling extended into that regime.

**What this does and does not prove.** The math is suggestive enough to lead to overreach, and I want to be specific about which parts are unambiguous and which parts are not.

What the math *does* show: applied to cosmological `R` with Bekenstein-bounded `I`, the principle `Q = R / 2^I` predicts that the resolution achievable by an observer with full access to the cosmic information capacity would be exponentially smaller than the Planck length. If you slide `I` past `~205` bits, `Q` goes through the Planck length and keeps falling. If you slide `I` anywhere near `10^{123}` bits, `Q` is smaller than the Planck length by a factor with more zeros than fit on this page.

What the math *does not* show: that this sub-Planck resolution corresponds to anything physically real. The Bekenstein bound is a bound on information *capacity* — it says how many bits the universe's boundary could in principle encode — not a proof that those bits index meaningful sub-Planckian degrees of freedom an observer could in principle read out.

All three positions from Section 5.1 remain consistent with the cosmological math. **Position 1** (the universe stops at the Planck length) is consistent: the `10^{123}` bits might exhaust themselves describing degrees of freedom *at the Planck scale and above*, with nothing finer below; the gap between 205 bits and `10^{123}` bits would then represent the universe's capacity to describe distinct *Planck-resolution states*, not finer ones. **Position 2** (sub-Planck structure exists, hidden) is consistent: the `10^{123}` bits might index sub-Planckian content that no local observer can reach directly through any apparatus inside the universe. **Position 3** (the question is coordinate-dependent) is consistent: the apparent gap might be a coordinate artifact of how observers count bits versus how the boundary encodes them.

The principle does not pick between them. What it *does* do is convert the trans-Planckian question into a precise quantitative form: **the universe has room for `~10^{123}` bits of state on its boundary; the principle's exponential scaling says that 205 bits per axis would already address the Planck floor in the bulk; what does the universe actually do with the bits between 205 and `10^{123}`?**

That is no longer a metaphysical question. It is a question about what the holographic information capacity is *for*. It is the same question the prose-level trans-Planckian debate has been asking for thirty years, written in a single variable, with a definite numerical gap to argue about.

**The honest summary.** The cosmological scaling does not prove that sub-Planck structure exists. It shows that the principle `Q = R / 2^I` is *consistent* with sub-Planck structure existing all the way down to the holographic resolution floor of `~10^{-3 × 10^{121}}` m, and that the trans-Planckian debate is therefore not a question about whether the universe has *room* for sub-Planck content (it has enormous room) but about whether the universe *uses* that room, and whether any observer inside the universe has an apparatus that can address it. The principle gives the question a precise variable to point at and a quantitative gap to argue about. That is what foundations of physics is for.

### 5.6 Why this matters even though it predicts nothing new

Nothing in this section produces a new experimental prediction. Position 1 and Position 2 above make identical observable claims, and Position 3 does too. The framework cannot, from inside, distinguish between "the universe stops at the Planck length" and "the universe has rich sub-Planck structure that observers cannot reach." Anything any side could measure happens at `I ≤ I_max`. The principle is silent above the ceiling.

What the principle does provide is a **clean technical statement of an interpretive question**. Instead of arguing about whether spacetime is discrete or continuous in vague language, one can ask: given `Q = R / 2^I`, what content does the equation have for `I > I_max`? The three positions above are concrete answers. They make the same predictions about observable physics, but they are different stances on the metaphysics, and they connect to different ongoing research programs in quantum gravity (loop quantum gravity, ER=EPR, string-theoretic T-duality respectively).

The teeth of this framing are not in a new prediction but in three things it lets one say with precision that one cannot say with the textbook framing:

1. **It makes "trans-Planckian" a quantitative concept rather than a vague one.** Any experiment that successfully probes structure at scales smaller than the Planck length must have implicitly extracted `I > I_max` worth of mutual information. Under the standard estimate of `I_max` from the Bekenstein bound, this is impossible inside our universe — no observer has the information capacity to do it. Under a corrected `I_max` (if our estimate is wrong, or if some clever indirect channel routes around the apparent bound), it becomes possible. Either way, the framework converts the vague question "can we probe sub-Planckian physics?" into the sharp question "what is `I_max` for this experimental setup, and is it large enough?" That conversion is itself a deliverable, even without a prediction.

2. **It identifies what kind of evidence would actually settle the matter.** Position 1 and Position 2 are observationally indistinguishable from inside the observer ceiling — but they are *not* indistinguishable in their *predictions about anomalies in our estimate of `I_max`*. If the framework's recovery of the Bekenstein bound is correct (Section 2 should be extended in a future revision to include this; I have not done it here), and an experiment ever measures structure at a resolution incompatible with that bound, then Position 1 (the universe stops at Planck) is falsified and Position 2 (sub-Planck structure exists, accessed through some indirect channel) is the only remaining option. This is a real falsification path, even if we have no current experiment that walks it.

3. **It locates the entire trans-Planckian debate inside one variable.** Loop quantum gravity, string theory, asymptotic safety, ER=EPR, causal set theory — all of them, as far as I can see, can be re-stated as different positions on the same question: what is the content of `Q = R / 2^I` for `I > I_max`? Loop quantum gravity says: the equation is empty there. String theory and ER=EPR say: the equation has rich content there, geometrically realized. Asymptotic safety says: the equation extrapolates smoothly without a horizon. The framework does not adjudicate, but it puts all of them in conversation with each other inside one expression. This is the kind of consolidation that foundations of physics rewards.

I think this is what foundations of physics is for. Not new predictions — those come from the upstream physics — but cleaner statements of the questions the upstream physics does not answer, and a single variable in which the existing answers can be compared. The principle `Q = R / 2^I` gives the question of sub-Planck structure a precise location: it is the question of whether the equation is meaningful above its observer ceiling. That formulation is sharper than "is space discrete?" because it has a variable to point at and a regime to argue about, and it makes the existing positions in the literature commensurable in a way the prose-level debate does not.

The principle does not say the answer is yes. It does not say the answer is no. It says: this is where to look, this is what would count as evidence either way, and this is the variable in which the answer would be expressed.

---

### 5.7 The hourglass resolution model of entanglement

The three positions in §5.1 disagree about what lives above the `I_max` horizon. The CHSH hierarchy in §2.8 shows that the framework parameterizes the Bell-Tsirelson ladder via suppressed information. The V8 Bohmian model in §2.8 demonstrates that a sub-resolution hidden variable layer can produce Tsirelson-strength correlations when augmented with a non-local phase update. And the qubit field visualization in Figure 2 renders the sub-resolution barrier as a literal strip between two procedural fields, with entanglement links passing through it.

These pieces suggest a specific geometric interpretation that I want to state explicitly — not as a theorem, but as a **fourth interpretive position**. It is a refinement of Position 2 in §5.1 (sub-Planck structure exists but is hidden), with a specific geometric shape proposed for the connection between the observable and hidden sectors. It is incompatible with Position 1 (universe stops at Planck), because the hourglass requires structure below the barrier. It is potentially compatible with Position 3 (coordinate-dependent), if the hourglass waist is itself a coordinate artifact rather than an invariant geometric feature.

**Position 4: the hourglass resolution model.** Every entangled pair consists of two components separated by the observer-relative resolution barrier defined by `Q = R / 2^I`:

- One component (the observable particle) sits above the barrier and is directly accessible to the observer's measurement apparatus.
- Its entangled partner sits below the barrier in a sub-resolution regime that is, in principle, unresolvable by any observer whose mutual information `I` is capped at the local `I_max`.
- The two components are connected by a narrow, hourglass-shaped waist whose constriction lies precisely at the resolution barrier. The waist acts as the sole channel through which interference can flow between the observable and hidden sectors.

Because the waist is narrower than the resolution limit of any local observer, the interference propagating through it is invisible. When we measure the observable (top) particle, we detect the interference pattern, but its source appears non-local or "spooky" because the connecting structure and the partner particle lie below the barrier we can resolve.

![**Figure 3.** The hourglass resolution model of entanglement. The translucent blue surface above the waist is the *observable region* — the regime where the observer has `I ≤ I_max` bits of mutual information and can resolve structure. The violet surface below is the *sub-resolution region* — the regime where `I > I_max` and the observer cannot directly access. The bright orange ring at the constriction is the *`I_max` barrier*, the resolution floor defined by `Q = R / 2^I`. The gold dot above the barrier is the observable particle; the violet dot below is its entangled partner. The green and red helical threads passing through the waist are the *interference channels* — the sub-resolution binding that produces entanglement correlations at the observable level. The faint rings at various z-levels show the octree resolution grid, with finer resolution below the barrier (more rings, closer spacing) than above (fewer rings, wider spacing). The hourglass waist is the physical location of the resolution barrier; entanglement is the visible effect of interference crossing it.](hourglass_model.png)

**The hourglass geometry as an extension of ER=EPR.** Maldacena and Susskind's ER=EPR conjecture (2013) proposes that entangled particles are connected by microscopic Einstein-Rosen bridges (wormholes). The hourglass model is a specific extension of this conjecture: the wormhole throat is not a symmetric bridge between two equal regions, but an **asymmetric hourglass whose narrowest point coincides with the observer's resolution limit**. Different observers with different `I_max` see different waist widths — the hourglass is observer-relative in the same way the principle `Q = R / 2^I` is observer-relative. An observer with a higher `I_max` (better measurement apparatus, larger information budget) sees a narrower waist and can resolve finer sub-resolution structure, but the waist never vanishes entirely because `I_max` is finite (§5.4's gravitational enforcement ensures this).

**The connection to the software artifacts.** The hourglass model has a concrete structural analog in the software, subject to the calibration in §3.7 (the chain encoder is not a model of foundational physics — it instantiates one structural property, not the full geometry). With that caveat: the V8 Bohmian model in §2.8 instantiates *one feature* of the hourglass — the sub-resolution binding — as a hidden phase `φ` that lives below the binary measurement resolution and transmits interference via a non-local update. Figure 2's qubit field visualization renders the topology explicitly, with the sub-resolution barrier strip (the I_max walls) and the entanglement links passing through it. The chain encoder's precision floor at 48 bits (§3.4) is a software analog of the waist: there is real structure below the floor (the Double-precision representation extends to 52 bits), but the encoder cannot access it. **None of these software artifacts prove the hourglass model.** They instantiate one structural property (sub-resolution binding with a resolution barrier) that the model proposes as the mechanism of entanglement. The model goes beyond what the software demonstrates; the software provides a concrete handle on one piece of what the model describes.

**What this position does and does not claim.**

The hourglass model *claims*:
1. Entanglement is interference crossing a sub-resolution geometric link (the waist) that sits at the observer's `I_max` floor.
2. The non-locality of entanglement is the non-locality of the waist: the two ends of the hourglass are spatially separated, and the interference propagates through a channel that the observer cannot resolve directly.
3. The framework `Q = R / 2^I` defines the waist width, and the CHSH hierarchy (§2.8) is the observable consequence of the waist's existence.

The hourglass model *does not claim*:
1. That the waist involves actual spacetime geometry modification. The ER=EPR conjecture proposes this; the hourglass model is consistent with it but does not require it. The waist could be a geometric feature of spacetime (Position 4a) or a non-local hidden variable channel without geometric realization (Position 4b). The distinction is empirically inaccessible from above the barrier.
2. That entanglement is "not action-at-a-distance." The waist IS a non-local connection — the two ends are spatially separated and interference propagates between them. The model relocates the non-locality from "spooky action" to "sub-resolution geometric link," but does not eliminate it.
3. That the model is falsifiable in its current form. It is an interpretive proposal, consistent with the framework, connected to the software artifacts, and awaiting a specific falsifiable prediction to become a testable theory. The distance from interpretation to theory is the distance from "this is where the non-locality lives" to "this is what you can measure about it."

**The CHSH experiment as waist tomography.** There is a direct geometric relationship between the CHSH correlation curves in §2.8 (Figure 1) and the hourglass waist cross-section (Figure 3). When the correlation function `E(δ)` is plotted in polar coordinates — with the angle difference `δ` as the polar angle and `|E(δ)|` as the radius — the resulting shape IS the cross-section of the waist:

- The quantum singlet correlation `|E| = |cos(δ)|` traces an **oval** (two tangent circles) — the L₂ norm ball.
- The classical Bell-saturating correlation (triangle wave) traces a **diamond** — the L∞ norm ball.
- At the CHSH-optimal measurement angle `δ = π/4`: the oval has radius `√2/2 ≈ 0.707`, the diamond has radius `0.5`. The ratio is exactly `√2`.

![**Figure 4.** The CHSH correlation curve IS the hourglass waist cross-section. **Left:** the standard correlation plot from §2.8 — blue triangle (classical Bell-saturating) vs red cosine (quantum singlet), with the orange gap at `π/4` showing the `√2` factor. **Right:** the same data plotted in polar coordinates (`r = |E|`, `θ = δ`), revealing the waist shape directly. The classical waist is a diamond (L∞ norm ball). The quantum waist is an oval (L₂ norm ball). At 45° the oval extends `√2` further than the diamond — this geometric difference IS the entire Tsirelson bound. The dashed orange circle shows the `I_max` barrier ring from Figure 3 at scale. Sweeping the CHSH measurement angle from 0 to `2π` is literally tomography of the waist: each angle probes one direction through the hole, and the correlation at that angle reports the width. The full sweep maps the complete cross-section. Reproduced by `python3 waist_tomography.py`.](waist_tomography.png)

This connection makes the hourglass model concrete in a specific way: the CHSH experiment is not just a test of Bell's inequality — it is a **tomographic measurement of the waist shape**. Each measurement angle probes one direction through the hole, and the correlation at that angle reports the "width" of the waist at that angle. The quantum waist is wider than the classical waist at 45° by exactly `√2`, and this geometric fact is the entire content of Tsirelson's bound.

The underlying mathematics is standard: Tsirelson's original proof (1980) is a Cauchy-Schwarz inequality on the Hilbert space, which is equivalent to saying the quantum set is the L₂ ball while the classical set is the L∞ ball. What the hourglass model adds is the **geometric interpretation**: the L₂ ball IS the waist cross-section, the L∞ ball IS the classical waist cross-section, and the ratio between them IS the amount of interference that can flow through the hourglass at each measurement angle. The formula `Q = R / 2^I` parameterizes this: `I = 1/2` bit of suppression corresponds to a round waist (L₂), `I = 1` bit corresponds to a square waist (L∞), and the half-bit difference is the geometric cost of the waist being round rather than square.

**What would upgrade the hourglass model to a testable theory.**
- A derivation showing that the hourglass waist width constrains the maximum CHSH violation to exactly `2√2` (Tsirelson) rather than `4` (PR box). If the geometry of the waist predicts the quantum bound as a geometric consequence, the model does real explanatory work.
- A measurable relationship between waist width and entanglement fidelity as a function of `I_max`. If better measurement apparatus (higher `I_max`) produces tighter correlations in a specific functional form predicted by the hourglass geometry, that is testable.
- A prediction about what happens when the chain encoder is pushed past its precision floor with arbitrary-precision arithmetic. If the hidden-sector correlations produce specific, predicted patterns (rather than generic noise), the hourglass model would have empirical content from the software side.

Until one of these is delivered, the hourglass model is a **specific interpretive visualization** — the most concrete picture of entanglement to emerge from this project, connected to working software artifacts, and honestly sized as interpretation rather than theory.

### 5.8 Resolution is infinite, observers are finite

I want to close Section 5 with an observation about the barrier itself. I do not think the barrier exists.

The formula `Q = R / 2^I` has no floor. There is no value of `I` where the formula says "stop." Add a bit, `Q` halves. Add another, it halves again. The math is infinitely divisible. The formula never runs out of resolution.

In the chain encoder, this is concrete: the procedural qubit field is defined at every real-valued coordinate. Push the precision from 48-bit `Double` to 100-bit arbitrary precision — the field answers with real, deterministic bits at every level. There is always another octree level. The structure does not run out. The representation does.

In physics, the Planck-collapse argument from §5.4 says the **probe** forms a black hole at the Planck scale. But a black hole is not nothing — it is an object with Bekenstein-Hawking entropy, internal structure, and its own information content. The measurement does not fail; it **transforms**. The observer stops measuring empty space and starts measuring a black hole. The resolution did not hit a wall. The thing being resolved changed character.

This means the `I_max` barrier in the hourglass model (§5.7) is not a property of spacetime. It is a property of the observer. The waist is always present because observers are always finite — but the waist is never actually closed, because there is always structure on the other side of it. The hourglass is what entanglement looks like to a finite observer. An observer with a higher `I_max` (better apparatus, larger information budget) sees a wider waist. In the limit of infinite `I`, the waist vanishes and the two spheres merge into one continuous geometry — entanglement is just ordinary spatial connection through structure the finite observer could not resolve.

Under this reading:

- The Tsirelson bound `S = 2√2` is not a fundamental limit on correlations. It is what correlations look like at the resolution quantum mechanics can access. A more complete theory, operating below the Planck scale, might see correlations above Tsirelson — but no observer inside our universe can test this, because our `I_max` is gravitationally enforced (§5.4).
- The "barrier" in the hourglass is an observational horizon, like the event horizon of a black hole. Nothing special happens at the horizon itself. It is simply the point beyond which a particular observer cannot see.
- Entanglement is not spooky action at a distance. It is ordinary connection through structure the observer has not resolved yet. The "spookiness" is the observer's surprise at seeing correlations from a source they cannot image.
- The three positions in §5.1 collapse: Position 1 (universe stops at Planck) is ruled out because the formula never stops. Position 2 (sub-Planck structure exists but is hidden) is correct but understates the case — the structure is not hidden by a wall, it is hidden by the observer's finite `I`. Position 3 (coordinate-dependent) is closest: the "barrier" is an artifact of the observer's coordinate system, not a feature of the geometry.

The framework `Q = R / 2^I` encodes this reading directly. The formula is symmetric in `I`: it works at `I = 1` bit (the coarsest measurement), at `I = 48` bits (the chain encoder's `Double` floor), at `I = 205` bits (the Planck length per §5.5), and at `I = 10^{123}` bits (the Bekenstein-Hawking cosmic ceiling). At every scale, the formula says the same thing: *the resolution available to you is determined by the information you have, and there is always more information below.*

**Resolution is infinite. Observers are finite.** The barrier is us.

It does not matter how much resolution you add when you are measuring a particle. The wall moves with you. There will always be a wall — because there has to be one, not because one is there.

---

## 6. Honest limits and what this is not

I want to enumerate what the principle does *not* do, because the surface form of `Q = R / 2^I` is small enough that an enthusiastic reader could mistake it for more than it is.

### 6.1 What the principle does not compute

The expression `Q = R / 2^I` is not a calculator. It does not tell you `I(O; S)` for any specific physical setup. Computing `I(O; S)` requires the full apparatus of quantum information theory: the joint state, the channel, the POVM, the observer's recording instrument's noise model. All of that work still has to be done. The principle is a *consistency relation* on the answer, not a shortcut to it. If you cannot compute `I` for your system, the principle gives you no `Q`.

This is the most common honest objection to organizing principles of this kind. A reader who is sympathetic to the goal but unimpressed by the form will say: "fine, but the entire content is in `I`, and `I` is the hard part." That is correct. The principle is not claiming to make `I` easy. It is claiming that *once `I` is in hand, the resolution is in the obvious form*, and that this is not currently how textbook treatments of resolution are organized. The unification is in the form, not in any new tractability.

### 6.2 What the principle does not predict

The principle does not predict any phenomenon that existing quantum mechanics plus information theory does not already cover. The Heisenberg uncertainty relation, the Holevo bound, classical-instrument resolution, no-information limits — all are already in the textbooks. The principle re-derives them from a single line; it does not produce them from somewhere new.

In particular, the principle does not predict new particles, new forces, modifications to general relativity, or any phenomenon outside the standard apparatus of quantum information. I am not claiming that. Any unification of existing material into a more compact form is a clarification, not a discovery.

### 6.3 What the principle does not solve

The principle does not solve the measurement problem. It does not pick a side on wave-function collapse, decoherence, many-worlds, hidden-variables, QBism, or any other interpretation of quantum mechanics. It is *compatible* with most of them: each interpretation has its own story about what `I(O; S)` *means* metaphysically, but the dimensional accounting `Q = R / 2^I` works whether one reads `I` as "the bits the wave function has irreversibly written into the observer's records" (decoherence framing) or "the bits the agent's epistemic state has updated by" (QBist framing) or "the bits the world line of the observer's branch has acquired" (many-worlds framing). The principle is one level above the interpretation question. It does not adjudicate it.

It also does not address locality, contextuality, the Bell inequalities, or quantum non-locality. These are downstream of the joint state and the measurements; the principle takes them as inputs, not outputs.

### 6.4 What the principle does not replace

The principle does not replace any part of quantum mechanics. It sits alongside it. The Schrödinger equation still evolves states. Born's rule still computes probabilities. The Heisenberg relation still holds. The principle is an expression of resolution that is *consistent* with all of these and that organizes them under one form. Removing the principle would not change any prediction of quantum mechanics. Adding it does not change any prediction either. It is a notational unification.

### 6.5 Theoretical heritage

The framework rests on a substantial body of prior work. This subsection lists the predecessor literature so a reader can find the original sources for any of the framework's structural moves. None of the items below are novel to this whitepaper.

**The bare algebraic form.** `Q = R / 2^N` is the quantization-step formula for an analog-to-digital converter with `N` bits of precision. It has been in signal-processing textbooks since the 1960s. §2.2's classical-instrument resolution recovery is literally the ADC formula, extended from hardware bits to mutual information in bits.

**Heisenberg from the Cramér-Rao bound.** A. J. Stam, in *"Some inequalities satisfied by the quantities of information"* (*Information and Control* 2, 101-112, 1959), derived the Weyl-Heisenberg uncertainty principle from a specific version of the Cramér-Rao bound. The Shannon-Cramér-Rao-Heisenberg-entropy-power chain was subsequently formalized by Dembo, Cover, and Thomas in *"Information theoretic inequalities"* (*IEEE Transactions on Information Theory* 37, 1501-1518, 1991), which shows the four inequalities are mathematically equivalent via Young's inequality and Rényi entropy. §2.1 and §2.7 of this whitepaper restate the Stam-Dembo-Cover-Thomas result in Shannon-bit parameterization.

**Physics from Fisher information.** B. Roy Frieden's 1998 book *Physics from Fisher Information: A Unification* (Cambridge University Press) and the expanded 2004 edition *Science from Fisher Information* build an entire program around deriving physics from Fisher information. Frieden derives Heisenberg (his equation 4.53), the Schrödinger equation, Klein-Gordon, Dirac, Maxwell's equations, Boltzmann's equation, and more from a Fisher-information extremization principle. The relationship to this whitepaper is primarily notational: Frieden uses Fisher information as the primitive, the framework here uses Shannon mutual information in bits. The two are related for Gaussian channels by `I_Shannon = (1/2) log_2(1 + F · σ^2)`.

**Minimum Fisher information and the Schrödinger equation.** M. Reginatto, *"Derivation of the equations of nonrelativistic quantum mechanics using the principle of minimum Fisher information"* (*Physical Review A* 58, 1775, 1998), derives the Schrödinger equation from minimum Fisher information. M. J. W. Hall and M. Reginatto subsequently developed the *"exact uncertainty principle"* framework (multiple papers from 2002 onward), deriving the Schrödinger equation from an exact uncertainty relation closely related to the Cramér-Rao bound. The Hall-Reginatto "exact uncertainty" is the closest existing match to this whitepaper's framing.

**Information as foundational for quantum mechanics.** J. A. Wheeler's *"Information, physics, quantum: the search for links"* (in *Complexity, Entropy, and the Physics of Information*, 1990) proposed "It from Bit." Č. Brukner and A. Zeilinger developed an information-invariance program for quantum mechanics in a series of papers from 1999 onward. W. H. Zurek's *"Decoherence, einselection, and the quantum origins of the classical"* (*Reviews of Modern Physics* 75, 715, 2003) develops "physical entropy" relative to an observer. Caves, Fuchs, and Schack's QBism program treats the wave function as a Bayesian state of an agent. C. Rovelli's *"Relative information at the foundation of physics"* (arXiv:1311.0054, 2013) proposes Shannon's mutual information as the foundation of statistical mechanics and quantum mechanics explicitly. Rovelli's Relational Quantum Mechanics (from 1996 onward) treats quantum state as information one physical system has about another. All predate this whitepaper and all are in the same conceptual neighborhood.

**The Planck-collapse argument.** §5.4's composition of the framework with the Heisenberg recovery to derive the Planck momentum as a resolution floor is a restatement, in the framework's vocabulary, of the Bronstein-Planck argument first floated by Matvei Bronstein in 1936 and developed extensively in the Generalized Uncertainty Principle (GUP) literature from the 1990s onward (Maggiore 1993, Garay 1995, Hossenfelder 2013). Hossenfelder in particular writes essentially this argument in plain English in her 2013 *Living Reviews in Relativity* survey on minimal length scenarios. The framework's contribution is one-line algebraic compactness, not new physics.

**Bell's inequality, CHSH, Tsirelson, and the no-signaling polytope.** §2.8's CHSH parameterization rests on a long sequence of foundational results: J. S. Bell's *"On the Einstein-Podolsky-Rosen paradox"* (*Physics* 1, 195-200, 1964) introduced the local hidden variable bound; Clauser, Horne, Shimony, and Holt's *"Proposed experiment to test local hidden-variable theories"* (*Physical Review Letters* 23, 880-884, 1969) refined it to the now-standard CHSH form; B. S. Tsirelson's *"Quantum generalizations of Bell's inequality"* (*Letters in Mathematical Physics* 4, 93-100, 1980) established the quantum maximum at `2√2`; and S. Popescu and D. Rohrlich's *"Quantum nonlocality as an axiom"* (*Foundations of Physics* 24, 379-385, 1994) defined the no-signaling-but-super-quantum boxes that reach `S = 4`. Pawlowski et al's *"Information causality as a physical principle"* (*Nature* 461, 1101-1104, 2009) derives Tsirelson from an `m`-bit communication bound, and the Navascués-Pironio-Acín hierarchy (*Physical Review Letters* 98, 010401, 2007) characterizes the quantum set inside the no-signaling polytope. The canonical comprehensive review is Brunner, Cavalcanti, Pironio, Scarani, and Wehner, *"Bell nonlocality"* (*Reviews of Modern Physics* 86, 419-478, 2014, arXiv:1303.2849), which collects all four landmark CHSH values along with the polytope structure. **None of this is new.** A targeted literature search did not find the specific "half-bit grid in `log_2(S)`" framing of §2.8 written explicitly in any of these sources, but the math is one line of arithmetic, and the closest implicit content is Pawlowski 2009's `m`-bit communication bound. The most likely referee gotcha for §2.8 is *"this is information causality restated in different units"*; that gotcha is partially valid and the section now acknowledges it explicitly.

**Bohmian / pilot-wave hidden variable models.** §2.8's V8 (the "bound qubit pair with sub-resolution binding") is structurally a Bohmian-style hidden variable model. The original program is Louis de Broglie's pilot wave proposal at the 1927 Solvay conference (*Rapport au V'e Conseil de Physique*, Gauthier-Villars 1928) and David Bohm's *"A suggested interpretation of the quantum theory in terms of 'hidden' variables"* (*Physical Review* 85, 166-179 and 180-193, 1952). Modern formulations of Bohmian mechanics are reviewed in Goldstein, *"Bohmian mechanics"* (*Stanford Encyclopedia of Philosophy*, 2001/2021) and Dürr, Goldstein, Zanghì, *Quantum Physics Without Quantum Philosophy* (Springer 2013). 't Hooft's *The Cellular Automaton Interpretation of Quantum Mechanics* (Springer 2016, arXiv:1405.1548) is the closest framework to "deterministic substrate that produces quantum statistics," with explicit non-local hidden variables — but 't Hooft escapes Bell via superdeterminism rather than via the kind of non-local communication V8 uses. **V8 is one specific computational instantiation of this family of models within the chain encoder framework.** It does not discover that such models exist; it shows that the procedural-field substrate is rich enough to host them.

**Communication-cost simulations of Bell correlations.** V8's non-local phase update is structurally a form of classical communication between observers, and the literature on the *minimum communication cost* of simulating quantum correlations is directly relevant. Toner and Bacon, *"Communication cost of simulating Bell correlations"* (*Physical Review Letters* 91, 187904, 2003), proved that **one classical bit of communication suffices** to reproduce the singlet correlations exactly. V8 transmits more than one bit per measurement (a measurement angle plus an outcome bit) so it is *less efficient* than Toner-Bacon while reaching the same Tsirelson statistics. **V8 should be read as a specific procedural-field implementation of a Toner-Bacon-style protocol, not as an independent route to Tsirelson.** The mechanism is known; the packaging is what's new.

**Event-by-event classical Bell simulators.** Michielsen, De Raedt, Hess and collaborators have built event-by-event computer simulations of Bell experiments since the early 2000s. The most recent survey is De Raedt et al, *"What do we learn from computer simulations of Bell experiments?"* (arXiv:1611.03444, 2016), with earlier papers in *Computer Physics Communications*, *Foundations of Physics*, and other venues. Their simulators reproduce Bell-violating CHSH correlations from classical event-by-event computations using detection-loophole-style mechanisms — different from V8's non-local phase update, but the same general category of "classical computer simulation that produces quantum-strength CHSH correlations." This is a 15-year body of prior work that any future revision of §2.8 must engage with.

**Recent (2024-2025) work on resolution and conservation-law hidden variable models.** Two papers from the last two years sit close to V8 in framing:
- **Garza & Hance, *"Quantum-Like Correlations from Local Hidden-Variable Theories Under Conservation Law"*** (arXiv:2511.06043, November 2025) — uses "measurement precision alters the hidden-variable measure space," structurally close to V8's "sub-resolution binding" framing, applied to a *local* hidden variable model.
- **Emmerson, *"Phenomenological Velocity and Bell-CHSH: Exceptional-Locus Semantics"*** (PhilArchive / IJQF, 2024) — runnable hidden-parameter selection simulation that reproduces `-cos(a-b)` and reaches Tsirelson scale via post-selection plus microcausal SU(2) conjugation.
- **Darrow & Bush, *"Convergence to Bohmian Mechanics in a de Broglie-Like Pilot-Wave System"*** (*Foundations of Physics* 55, 2025; arXiv:2408.05396) — runnable pilot-wave simulator for single-particle position measurement.

These three papers and the Toner-Bacon / Michielsen-De Raedt programs cover most of the conceptual neighborhood §2.8 inhabits. None of them packages the framework as "`Q = R / 2^I` half-bit ladder + procedural-field encoder + Bohmian-style sub-resolution binding," but several of them implement substantial parts of that combination, and any honest claim to framing novelty has to be calibrated against them.

### 6.6 Position summary

Given the heritage in §6.5, the position this whitepaper takes is:

1. The expression `Q = R / 2^I` is a compact reformulation of the resolution-information trade-off, sitting inside the existing Stam / Frieden / Reginatto / Hall-Reginatto / Brukner-Zeilinger / Rovelli tradition. It is **not** a foundational discovery.
2. The seven-row table in §2.9 lines up Heisenberg, Holevo, classical instrument resolution, Compton, the qubit field implementation, the no-information limit, the Gaussian channel, and the CHSH/Bell-Tsirelson hierarchy under one notation. The individual derivations are each in the prior literature; the unified table is the framing contribution.
3. The Cramér-Rao equivalence theorem (§2.7) is the Stam-Dembo-Cover-Thomas chain restated in Shannon bits. The retrodiction in §4.2 is a numerical walk-through of an existing standard result, not a new prediction.
4. The CHSH parameterization (§2.8) is the observation that the *three* canonical CHSH landmarks (Bell at `S=2`, Tsirelson at `S=2√2`, PR box at `S=4`) lie on a discrete half-bit grid in `log_2(S)`, and that `Q = R / 2^I` gives a one-line parameterization of that grid. The chain encoder hosts a Bohmian-style instantiation of Tsirelson-saturating correlations (V8 in `chsh_prototype.py`), demonstrating that the procedural field substrate is computationally rich enough for the full hierarchy. **Two targeted literature searches refined this contribution down significantly:** (i) V8's mechanism is structurally a Toner-Bacon (2003) communication-cost protocol implemented via implicit phase update rather than explicit messaging — V8 is *less* efficient than Toner-Bacon and does not exceed it as a route to Tsirelson; (ii) the half-bit grid framing has no direct precedent in the polytope or information-causality literatures, but the math is a one-line rewrite of standard CHSH values, and the closest implicit work is Pawlowski et al 2009's `m`-bit communication bound, which is likely the same parameter as §2.8's "suppressed `I`" under a relabeling. The V1 sub-classical anchor at `S = √2` is included as an empirical data point, but is *not* a fourth rung of the canonical hierarchy — the standard treatment absorbs all sub-optimal classical strategies into the local polytope, and the V1 value reflects the specific Born-rule averaging used in that variant, not a structural property. None of the underlying physics is new; the framing and the procedural-field-encoder packaging are notational at best, and any framing-novelty claim has to be calibrated against Pawlowski 2009 and Brunner et al 2014.
5. The trans-Planckian reframing (§5) gives the question of sub-Planck structure a precise variable to point at. The underlying physics is standard.
6. The chain encoder (§3) is the centerpiece — a working Swift implementation of the resolution-information trade-off that a reader can clone, build, and run. The CHSH prototype (§2.8) extends the implementation to multi-observer correlations with an empirical landscape across eight variants.

7. The hourglass resolution model (§5.7) is a **specific interpretive proposal** — a geometric visualization of entanglement as interference crossing a sub-resolution waist at the observer's `I_max` floor. It is a refinement of Position 2 in §5.1, extended with an asymmetric hourglass topology that specifies the ER=EPR conjecture's wormhole throat as observer-relative. It is an interpretation, not a theory: it makes no falsifiable predictions in its current form. The software artifacts (V8, the qubit field visualization, the chain encoder's precision floor) instantiate one structural property of the proposed geometry but do not prove the model. Three specific upgrades that would make it testable are listed in §5.7.
8. The quantum circuit simulator (§4.4) correctly executes Shor's algorithm (factoring up to 29,999), Deutsch-Jozsa, Bernstein-Vazirani, quantum teleportation, superdense coding, and error correction — all accessible from JavaScript via `window.jeffjs.quantum.simulator`. The GHZ O(N) interference-at-last-qubit sampling trick scales to 1M+ qubits. The simulator is ported to Swift with Metal GPU acceleration.

The whitepaper is reference documentation for the JeffJS Quantum module, with the theoretical material as background. The substance is the implementation. The contribution this whitepaper actually makes is *one runnable software artifact instantiating an existing structural property*, *a compact notation that lines up seven standard results in one table*, *a half-bit-ladder parameterization of the CHSH hierarchy* with worked software examples for each rung, *a quantum circuit simulator that runs real algorithms from JavaScript*, and *an interpretive proposal (the hourglass model) that gives entanglement a specific geometric shape connected to the framework*. That is the line the reader is asked to hold the document to.

---

## References

Aharonov, Y., Albert, D. Z., & Vaidman, L. (1988). How the result of a measurement of a component of the spin of a spin-1/2 particle can turn out to be 100. *Physical Review Letters*, 60(14), 1351-1354.

Bachand, J. (2026). JeffJS quantum module source code. https://github.com/jeffbachand/JeffJS [placeholder; repository not yet public]

Bekenstein, J. D. (1973). Black holes and entropy. *Physical Review D*, 7(8), 2333-2346.

Bell, J. S. (1964). On the Einstein-Podolsky-Rosen paradox. *Physics*, 1(3), 195-200.

Bohm, D. (1952). A suggested interpretation of the quantum theory in terms of "hidden" variables. I and II. *Physical Review*, 85(2), 166-179 and 180-193.

Bronstein, M. P. (1936). Quantentheorie schwacher Gravitationsfelder. *Physikalische Zeitschrift der Sowjetunion*, 9, 140-157. (The earliest published statement of the Planck-collapse argument.)

Brukner, Č., & Zeilinger, A. (2003). Information and fundamental elements of the structure of quantum theory. In *Time, Quantum, Information* (pp. 323-354). Springer.

Brunner, N., Cavalcanti, D., Pironio, S., Scarani, V., & Wehner, S. (2014). Bell nonlocality. *Reviews of Modern Physics*, 86(2), 419-478. arXiv:1303.2849. (The canonical comprehensive review of Bell nonlocality, including all four landmark CHSH values and the polytope structure of local, quantum, and no-signaling correlations.)

Clauser, J. F., Horne, M. A., Shimony, A., & Holt, R. A. (1969). Proposed experiment to test local hidden-variable theories. *Physical Review Letters*, 23(15), 880-884.

Caves, C. M., Fuchs, C. A., & Schack, R. (2002). Quantum probabilities as Bayesian probabilities. *Physical Review A*, 65(2), 022305.

Compton, A. H. (1923). A quantum theory of the scattering of x-rays by light elements. *Physical Review*, 21(5), 483-502.

Cramér, H. (1946). *Mathematical Methods of Statistics*. Princeton University Press. (The Cramér-Rao bound on estimator variance is in Chapter 32.)

Darrow, D., & Bush, J. W. M. (2025). Convergence to Bohmian Mechanics in a de Broglie-Like Pilot-Wave System. *Foundations of Physics*, 55. arXiv:2408.05396.

de Broglie, L. (1928). La nouvelle dynamique des quanta. In *Rapport au V'e Conseil de Physique*, Solvay 1927, Gauthier-Villars. (The original pilot wave proposal.)

Dembo, A., Cover, T. M., & Thomas, J. A. (1991). Information theoretic inequalities. *IEEE Transactions on Information Theory*, 37(6), 1501-1518. (Formalizes the Shannon-entropy / Cramér-Rao / Heisenberg / entropy-power inequality chain via Young's inequality and Rényi entropy.)

De Raedt, H., Michielsen, K., & Hess, K. (2016). What do we learn from computer simulations of Bell experiments? arXiv:1611.03444. (Survey of the 15-year event-by-event Bell-simulation program.)

Dürr, D., Goldstein, S., & Zanghì, N. (2013). *Quantum Physics Without Quantum Philosophy*. Springer. (Modern Bohmian mechanics review.)

Emmerson, P. (2024). Phenomenological Velocity and Bell-CHSH: Exceptional-Locus Semantics, Selection Simulations of -cos, and a Microcausal Realization. *International Journal of Quantum Foundations* (PhilArchive). (Runnable hidden-parameter simulation reaching Tsirelson scale.)

Frieden, B. R. (1998). *Physics from Fisher Information: A Unification*. Cambridge University Press. (Derives Heisenberg, Schrödinger, Klein-Gordon, Dirac, Maxwell, Boltzmann transport, and more from a Fisher-information extremization principle. The Heisenberg derivation is at equation 4.53. Second edition published 2004 as *Science from Fisher Information*.)

Garza, M., & Hance, J. R. (2025). Quantum-Like Correlations from Local Hidden-Variable Theories Under Conservation Law. arXiv:2511.06043. (Uses measurement-precision-altered hidden variable measure space to produce Bell-violating correlations from a local model — closest framing match to §2.8's "sub-resolution binding" idea.) (Derives Heisenberg, Schrödinger, Klein-Gordon, Dirac, Maxwell, Boltzmann transport, and more from a Fisher-information extremization principle. The Heisenberg derivation is at equation 4.53. Second edition published 2004 as *Science from Fisher Information*.)

Hall, M. J. W., & Reginatto, M. (2002). Schrödinger equation from an exact uncertainty principle. *Journal of Physics A: Mathematical and General*, 35(14), 3289-3303.

Garay, L. J. (1995). Quantum gravity and minimum length. *International Journal of Modern Physics A*, 10(2), 145-165.

Heisenberg, W. (1927). Über den anschaulichen Inhalt der quantentheoretischen Kinematik und Mechanik. *Zeitschrift für Physik*, 43(3-4), 172-198. English translation: "The physical content of quantum kinematics and mechanics," in Wheeler & Zurek (eds.), *Quantum Theory and Measurement*, Princeton, 1983.

Holevo, A. S. (1973). Bounds for the quantity of information transmitted by a quantum communication channel. *Problemy Peredachi Informatsii*, 9(3), 3-11. (English translation in *Problems of Information Transmission*, 9, 177-183.)

Hossenfelder, S. (2013). Minimal length scale scenarios for quantum gravity. *Living Reviews in Relativity*, 16, 2.

Lloyd, S. (2002). Computational capacity of the universe. *Physical Review Letters*, 88(23), 237901.

Maggiore, M. (1993). A generalized uncertainty principle in quantum gravity. *Physics Letters B*, 304(1-2), 65-69.

Navascués, M., Pironio, S., & Acín, A. (2007). Bounding the set of quantum correlations. *Physical Review Letters*, 98, 010401. (The NPA hierarchy that characterizes the quantum set inside the no-signaling polytope.)

Margolus, N., & Levitin, L. B. (1998). The maximum speed of dynamical evolution. *Physica D*, 120(1-2), 188-195.

Murch, K. W., Weber, S. J., Macklin, C., & Siddiqi, I. (2013). Observing single quantum trajectories of a superconducting quantum bit. *Nature*, 502, 211-214.

Pawlowski, M., Paterek, T., Kaszlikowski, D., Scarani, V., Winter, A., & Żukowski, M. (2009). Information causality as a physical principle. *Nature*, 461, 1101-1104. (Derives Tsirelson's bound from an information-theoretic principle.)

Popescu, S., & Rohrlich, D. (1994). Quantum nonlocality as an axiom. *Foundations of Physics*, 24(3), 379-385. (Defines the no-signaling boxes that reach S = 4.)

Reginatto, M. (1998). Derivation of the equations of nonrelativistic quantum mechanics using the principle of minimum Fisher information. *Physical Review A*, 58(3), 1775-1778.

Rovelli, C. (2013). Relative information at the foundation of physics. In *It From Bit or Bit From It?*, ed. Aguirre, Foster, Merali (Springer, 2015). arXiv:1311.0054.

Shannon, C. E. (1948). A mathematical theory of communication. *Bell System Technical Journal*, 27, 379-423 and 623-656. (The Gaussian channel capacity formula is in Section 24.)

Stam, A. J. (1959). Some inequalities satisfied by the quantities of information of Fisher and Shannon. *Information and Control*, 2(2), 101-112. (The earliest derivation of the Weyl-Heisenberg uncertainty principle from the Cramér-Rao bound.)

't Hooft, G. (2016). *The Cellular Automaton Interpretation of Quantum Mechanics*. Springer. arXiv:1405.1548. (Deterministic substrate program for quantum mechanics with explicit non-local hidden variables; escapes Bell via superdeterminism rather than non-local communication.)

Toner, B. F., & Bacon, D. (2003). Communication cost of simulating Bell correlations. *Physical Review Letters*, 91(18), 187904. (One classical bit of communication suffices to reproduce the singlet correlations exactly. §2.8's V8 is a less-efficient procedural-field implementation of this result.)

Tsirelson, B. S. (1980). Quantum generalizations of Bell's inequality. *Letters in Mathematical Physics*, 4(2), 93-100.

Weber, S. J., Chantasri, A., Dressel, J., Jordan, A. N., Murch, K. W., & Siddiqi, I. (2014). Mapping the optimal route between two quantum states. *Nature*, 511, 570-573.

Wheeler, J. A. (1990). Information, physics, quantum: the search for links. In *Complexity, Entropy, and the Physics of Information*, ed. W. H. Zurek, Addison-Wesley, 3-28.

Wiseman, H. M., & Milburn, G. J. (2009). *Quantum Measurement and Control*. Cambridge University Press.

Zurek, W. H. (2003). Decoherence, einselection, and the quantum origins of the classical. *Reviews of Modern Physics*, 75(3), 715-775.
