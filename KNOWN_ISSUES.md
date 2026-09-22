# Known issues

The gaps between what BridgeKit promises and what it proves today. Every entry
names the code that carries the gap, what a consumer observes, and what closes
it. Nothing here silently corrupts data; that is the bar for shipping with an
entry still open.

Resolved entries stay at the bottom until the fix has shipped in a published
version, so the changelog and this file agree on what a given release contains.

## Open

### BF-IOS-01 — packaged `package:ios` still needs a host-side Swift package

The public `BridgeKit` module is C++-free. Getting it into a Node-free host is
done by adding `packages/core` as a local Swift package (see
`apps/example-callstack-brownfield/ios/HostApp`). `@callstack/react-native-brownfield`
does not yet copy an arbitrary xcframework into `spm-artifacts/` the way it
copies `ExpoModulesCore`. `BRIDGEKIT_HOST_PROVIDES_RUNTIME=1` keeps the public
module out of the packaged RN framework so there is one runtime.

Draft upstream issue (not filed):

> `package:ios` copies a hard-coded allowlist of xcframeworks into
> `spm-artifacts/` (e.g. ExpoModulesCore). A third-party Swift module that the
> **host** must `import` (not fuse into BrownfieldLib) has no hook to join that
> list. Please accept extra xcframeworks / Swift package products so a
> C++-free API can ship beside the RN framework without a local path package.

### RT-IOS-01 — iOS has no diagnostics module

Android exposes `BridgeKitDiagnostics` (structured logcat traces, drop and
fire-failure counters, `dumpCounters()`). iOS has no equivalent.

- **Observed:** on iOS, a seam encoding failure on `onStreamOpen`,
  `onStreamClose` or `onStateWrite` — the three callbacks that carry no
  terminal — is reported with `print` through
  `SeamEncoding.reportFailure` (`packages/core/ios/engine/SeamEncoding.swift`)
  instead of a counter. `dump()` on iOS has no counters section.
- **Not affected:** invoke, stream values and stream terminals. Those carry the
  failure to JS as a typed `SEAM_ENCODE_FAILED` error; the parity tests cover it.
- **Closes it:** an iOS diagnostics module with the Android surface, and
  redirecting `SeamEncoding.reportFailure` to it. That function is the single
  call site to change.

### RT-IOS-02 — the iOS engine does not compile clean under the Swift 6 language mode

The engine serialises everything through one `NSRecursiveLock` and shares it by
`unowned(unsafe)` reference (`StreamHub`, `StateStore`, `OutboundCallerImpl`,
`BridgeKit`); `BridgeKitNative` holds its delegate as `nonisolated(unsafe)`.
`packages/core/Package.swift` declares `swift-tools-version: 5.9`, and the
podspec sets no `swift_version`, so the engine builds in the Swift 5 language
mode everywhere it is built today (CocoaPods, the facade XCFramework, CI).

- **Observed:** nothing at runtime. The locking is correct in Swift 5 mode and
  the 50 engine tests plus the parity suite run against it. A consumer that
  compiles BridgeKit *from source* with `-swift-version 6` gets strict
  concurrency errors.
- **Not affected:** consumers of the facade XCFramework or the podspec — the
  framework is compiled separately and its interface is plain Swift.
- **Closes it:** an actor-based or `Sendable`-audited engine. Not a mechanical
  change; it needs the same parity tests to pass afterwards.

### RT-CORE-01 — `CloseReason.Replacing` does not park in-flight invokes

A `REPLACING_GRACE_MS = 1500` constant used to be declared on both platforms and
was never read. It advertised a behaviour that does not exist: when a binding is
replaced, in-flight invokes against the old binding are not held for the new
one. Mirrored *state* does get a grace window (`StateStore.replacingGraceMs`,
250 ms) — that is implemented and tested, and it is a different mechanism.

- **Observed:** an invoke that races a re-provide of the same contract may fail
  with `CONTRACT_NOT_PROVIDED` instead of resolving against the replacement.
  Readiness waiters (`awaitProvided`) are unaffected: they are parked and woken
  by the replacement.
- **Tracked in code:** `packages/core/android/src/main/java/com/bridgekit/core/Binding.kt`
  and `packages/core/ios/engine/BindingEntry.swift`.
- **Closes it:** parking the in-flight call in `ParkBuffer` on `Replacing`, on
  both platforms, with a test that exercises the race.

### DSL-01 — `t.binary()` is not validated across the native boundary

`t.binary()` exists in the TypeScript DSL with a Base64 codec and round-trips on
the JS side. No native binary-specific codec exists and no on-device test
carries a binary payload end to end.

- **Observed:** treat `t.binary()` as a JS-level, experimental capability.
  Payloads cross as Base64 strings; nothing rejects them, nothing proves them.
- **Closes it:** a native round-trip test on both platforms, and a decision on
  whether the wire format should carry blobs (see *Hard transport limits* in
  `apps/docs/src/content/docs/reference/limitations.md`).

### TOOLING-01 — `pnpm audit` still reports advisories that need a major bump

Dependabot "security update" runs on `main` fail with
`security_update_not_possible`: the vulnerable packages are transitive
dependencies of the example apps, the docs site and the Jest toolchain, and
Dependabot cannot bump them through the pnpm lockfile on its own. The ones with
a patch inside the same major are now pinned through `pnpm.overrides` in the
root `package.json` (`nanoid`, `postcss`, `brace-expansion`, `tar`, `sharp`,
`svgo`, `shell-quote`, `browserslist`, …). What remains needs a major bump of a
tool this repository does not own, or has no fix:

| Advisory | Pulled in by | Why it stays |
| -------- | ------------ | ------------ |
| `js-yaml` 4.x | `@astrojs/starlight` | fix is 5.x, ESM-only; Astro 6 imports its default export |
| `astro` 6.x | `apps/docs` | Astro 7 is a major; Dependabot PR #39 tracks it |
| `uuid` 7.x, `fast-xml-parser` 4.x, `adm-zip` 0.5.x | `@callstack/brownfield-cli` | fixes are majors of a dependency of the brownfield example's CLI |
| `esbuild` 0.27.x | `vite` (docs) | fix is 0.28, a breaking line for Vite |
| `image-size` 1.x | `metro` | no patched version exists |

- **Not affected:** the published packages. `@gamitolab/bridgekit` has no
  runtime dependencies and `@gamitolab/bridgekit-cli` depends only on `chalk`;
  none of the advisories is reachable from either tarball.
- **Closes it:** upgrading the tools that pull them in (Astro 7, the next
  brownfield CLI). Renovate is deliberately excluded until the first stable
  release (see `RELEASING.md`).

## Resolved, not yet published

### RT-IOS-03 — Xcode 27 could not build the BridgeKit Clang module (`<regex>` missing)

Compiling BridgeKit as an Objective-C module on Xcode 26.4+ / 27 failed with
`NitroTypeInfo.hpp: #include <regex> file not found` → `could not build
Objective-C module 'BridgeKit'`. Autolinking succeeded; the pod did not compile.
The module was being parsed as C, so the C++ standard library header was
invisible.

- **Fix:** regenerate with Nitrogen 0.37.1 (`SWIFT_INSTALL_OBJC_HEADER=NO` for
  static linkage on Xcode 26.4+), keep `SWIFT_OBJC_INTEROP_MODE=objcxx`, and
  force `CLANG_CXX_LIBRARY=libc++` on the BridgeKit pod. The host still chooses
  RN/Nitro via peer ranges (`react-native` >= 0.86, `react-native-nitro-modules`
  ^0.37).
- **Ships in:** `@gamitolab/bridgekit` 0.2.0-alpha.1.

### RT-AND-03 / RT-AND-04 — StreamHub races on Android (WS-5)

`StreamHub` (`packages/core/android/src/main/java/com/bridgekit/core/StreamHub.kt`)
had two lifecycle races. 28 unit tests across seven files were quarantined with
`@Ignore("QUARANTINED(WS-5) …")` because they tripped over them under load.

- **RT-AND-03:** the upstream provider Flow was started by `attach()` before the
  consumer's `SharedFlow` subscription was registered. A provider that emits
  synchronously could run ahead of the consumer that opened it; with
  `replay = 0` those emissions were dropped, so the first consumer lost the head
  of its own stream, and a terminal emitted in that window was lost entirely —
  the consumer hung.
- **RT-AND-04:** a hub entry whose upstream had terminated, or whose last
  consumer had left, stayed reachable in the map for a window and was revived by
  the next `attach()`. The new consumer received the stale terminal, or joined an
  entry whose cancelled upstream's `finally` then evicted the live replacement.
  A `lateinit` consumer `Job` read from inside its own collector also threw
  `UninitializedPropertyAccessException` when a replayed terminal arrived before
  `launch` returned; the exception escaped the engine scope.
- **Fix:** the upstream is started from inside the first consumer's collector
  after `onSubscription`; an entry is closed exactly once (upstream terminated
  or refcount reached zero) and never revived — a later attach gets a fresh
  entry and a fresh provider invocation, matching the iOS `StreamHub`;
  consumers end themselves by throwing `CancellationException` from their own
  collector. All 28 tests are un-quarantined and the Android suite runs 158/158
  repeatedly on a JVM harness.
- **Ships in:** `@gamitolab/bridgekit` 0.1.0-alpha.1.

### CI — `iOS Facade` gate red on `main`

The committed `ios-facade` `.swiftinterface` files still declared
`CloseReason.replacingGraceMs` after the dead constant was removed from
`BindingEntry.swift`, so the declaration-level comparison in
`.github/workflows/ios-facade.yml` failed on every push to `main` and would have
blocked `release.yml` for every `core-v*` tag. The three interface files are
back in sync with the source.

- **Ships in:** `@gamitolab/bridgekit` 0.1.0-alpha.1.
