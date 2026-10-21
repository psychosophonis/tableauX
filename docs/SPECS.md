# Specification registry

This file maps source files to the spec that governs them. It is the first
thing to read before changing code, and the first thing to update after adding
a file.

## How to use it
- Each spec has a section below.
- Under "Files", list the source files that must obey that spec.
- Under "Verify", give the command that checks compliance.

## architecture.md
Governs:
- `Sources/**` (PlayerCore: § Model, § Sync, § API Contracts; app shell: § Sync, § UI)
- `Tests/**` (§ Verification)
- `Package.swift`
- `scripts/**` (test media for T6, § Targets)

Verify:
```
swift build && swift test
```

---

## Adding a new file
1. Decide which spec governs it.
2. Add its path under that spec's "Files" list.
3. If no spec fits, add a new spec file in docs/ and a section here.

## Status vs. specs
Specs are the contract (what MUST be true). Implementation status — what is
actually built — lives in docs/IMPLEMENTATION.md, not here. The real source of
truth for "is it done?" is whether the tests pass.
