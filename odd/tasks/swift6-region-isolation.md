# Swift 6 complete-concurrency generated contracts

## Objective

Generated Swift must compile under Swift 6 with complete strict concurrency (real code generation, not `-typecheck`). The Swift 5 branch stays as-is. Contract hashes must not change.

## Problem

`swiftc -typecheck` does not run the SIL region-isolation pass. The Swift 6 harness therefore accepted `AsyncStream { cont in Task { ... } }` pumps that fail `swiftc -c -wmo` with `SendingClosureRisksDataRace` / `SendingRisksDataRace` on any contract that has State.

## Why

Hosts compiling generated contracts into a Swift 6 + MainActor-default target (or dropping the Swift 5 module boundary) cannot ship. The gate that claimed to prove this was structurally blind.

## Scope

- Change the Swift 6 compile gate to `-c -wmo` (keep Swift 5 as `-typecheck`).
- Fix the Swift emitter so the Swift 6 branch compiles. Do not hand-edit generated output.
- Kotlin generation must not regress.
- Decide whether `BridgeKitNative` MainActor-default vendoring belongs in this change.

## Constraints

- `#else` (Swift 5) generated APIs stay compiling without host migration.
- Hashes derive from the TS contract; do not change that layer.
- Do not touch Ametller consumer repos.

## Tasks

- [x] T1 — Change `swiftcTypecheckSwift6MainActor` to real code generation (`-c -wmo`, object to a temp path). Keep Swift 5 `-typecheck`.
- [x] T2 — Run the N0c Swift 6 gate and record the three region-isolation errors (red before fix).
- [x] T3 — Audit other `swiftcTypecheck` call sites; report which are structurally blind. Change only what this gate needs.
- [x] T4 — Fix the Swift emitter (and runtime types if the generated code requires it). Swift 5 branch unchanged.
- [x] T5 — Gate green on N0c; regenerate example Swift via CLI, not by hand.
- [x] T6 — Decide and either fix or explicitly defer `BridgeKitNative.swift` MainActor-default default-value error.
- [x] T7 — Full CLI suite (Kotlin included) + example `generate --check`.
- [ ] T8 — Open PR on `malopezr7/bridgekit`. Do not merge.

## Acceptance

- Swift 6 gate uses code generation and fails on the old pump shape.
- After the emitter fix, the same gate exits 0.
- Swift 5 typecheck still exits 0.
- Contract hashes unchanged.
- Kotlin tests pass.

## Checks

- `pnpm --filter @malopezr7/bridgekit-cli test -- src/__tests__/compile-swift.test.ts`
- `pnpm --filter @malopezr7/bridgekit-cli test`
- `pnpm --filter bridgekit-example generate:ios --check` (and brownfield variants)

## Next

T1 — make the Swift 6 gate honest.
