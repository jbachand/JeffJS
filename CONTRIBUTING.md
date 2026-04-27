# Contributing to JeffJS

Thanks for considering a contribution. JeffJS is, at its heart, a one-person port of [QuickJS](https://bellard.org/quickjs/) into Swift. The bar for changes is **fidelity to QuickJS** in the engine core, and **good taste plus tests** for everything else.

## Ground rules

- **No new external dependencies.** The package is intentionally `import Foundation` and (optionally) `import Metal`. Keep it that way. If you find yourself reaching for a transitive dep, the answer is almost always to write the small thing inline.
- **Tests for anything that touches the language.** Add a case to `Tests/JeffJSTests/JeffJSTestRunner.swift` (or one of the focused test files). `swift test` must stay green on every PR.
- **Comment the non-obvious.** The QuickJS port is dense; future readers — including future you — will thank you. Don't comment the obvious; do comment the *why*.
- **Match the style of the file you're editing.** Indentation, brace placement, naming, organization — copy what's already there. The codebase is internally consistent and we want to keep it that way.
- **One PR, one concern.** A bugfix and a refactor go in two PRs. A typo and a behavior change go in two PRs.

## What we accept readily

- Bug fixes with a regression test.
- Spec compliance fixes with a [test262](https://github.com/tc39/test262) reference (or a hand-rolled test that exercises the same surface).
- Performance improvements with a `JeffJSPerfTests` benchmark showing the delta.
- Documentation fixes — typos, broken links, unclear paragraphs in README or inline doc comments.
- New surface that's already in the spec (Web APIs, language features) gated behind a configuration toggle if it's substantial.

## What needs an issue first

- Architectural changes to `Core/`, `Parser/`, `Bytecode/`, the GC, or the regex engine.
- New top-level subsystems (e.g. another GPU-accelerated path, another browser API surface).
- Anything that diverges from QuickJS by design.

Open a discussion in [GitHub Issues](https://github.com/jeffbachand/JeffJS/issues) describing the change and why before writing the code. Saves both of us time.

## What we typically don't accept

- Cosmetic refactors with no functional benefit.
- Changes that swap a working approach for a personal preference.
- New dependencies (see ground rules).
- Auto-generated code, AI-generated patches with no human review, or PRs that touch >500 lines without context.

## Submitting a PR

1. Fork. Branch off `main`.
2. Make your change. Run `swift test`. Make sure it passes.
3. If you touched a `Core/`, `Parser/`, `Bytecode/`, or builtin file, the commit message should reference the QuickJS file/function it ports (e.g. `quickjs.c:JS_NewObjectFromShape`). The Swift code already does this in comments; commit messages are nice to keep that thread.
4. Open a PR. Fill out the template. CI runs `swift test` on every push.
5. Be patient — review may take a week.

## Local development

```sh
# Clone + build the package
git clone https://github.com/jeffbachand/JeffJS.git
cd JeffJS
swift build
swift test

# Open the Console sample app
open JeffJSConsole/JeffJSConsole.xcodeproj
```

The package builds for iOS 16+, macOS 13+, watchOS 9+, tvOS 16+, and visionOS 1+. CI runs on macOS only — Linux is not a supported target (we lean on Foundation features that are still macOS-only in Swift on Linux).

## Code of conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md). Be kind. The port has earned the right to be opinionated; that's not the same as being unkind to people.

## Reporting security issues

Please **do not** open a public issue for security vulnerabilities. See [SECURITY.md](SECURITY.md) for the disclosure process.
