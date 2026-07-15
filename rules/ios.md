---
paths:
  - "**/*.swift"
  - "**/*.xcodeproj/**"
  - "**/*.xcworkspace/**"
  - "**/Package.swift"
  - "**/*.plist"
  - "**/Podfile"
  - "**/project.pbxproj"
  - "**/*.entitlements"
  - "**/*.xcprivacy"
---

# iOS Overlay (Swift + SwiftUI)

> Path-triggered: loads when Claude reads a file matching this pack's `paths:` glob (`*.swift`, `*.pbxproj`, `Package.swift`, …; see frontmatter). Assumes a modern stack: Swift 6 (strict concurrency), SwiftUI (+ targeted UIKit interop), the Observation framework, SwiftData or Core Data, Swift Package Manager, XCTest/Swift Testing, fastlane, App Store Connect / TestFlight. Framework sections (WidgetKit, App Intents, StoreKit 2, CloudKit, Core Location, HealthKit) are scoped "If you use it" — delete what doesn't apply.

## 5. Architecture Patterns (SwiftUI + Observation)

- **State ownership is explicit and minimal.** Source of truth lives in one place: `@State` for view-local, `@Observable` model objects passed by reference, `@Binding` to delegate mutation, `@Environment` for cross-cutting dependencies. Don't duplicate state; derive it.
- **MV / MVVM, not Massive View.** Views render and dispatch intent; an `@Observable` model owns business logic and talks to repositories/services. The View never holds a network client, a DB handle, or formatting logic it could push down.
- **Value types by default.** `struct`/`enum` for models and state; `class` only when reference semantics or identity is required (and then think about lifecycle). Model state transitions as enums, not scattered booleans.
- **Dependency boundaries.** No Hilt here — inject via initializers, the `Environment`, or a lightweight container (swift-dependencies / Factory). Protocol at every external boundary (network, persistence, system service); concrete impl bound at the composition root; fakes for tests.
- **Persistence is a boundary.** SwiftData/Core Data/GRDB types do not leak into the view layer — map to domain/UI types. Secrets live in the Keychain, never `UserDefaults`/plist.
- **Navigation is data-driven.** `NavigationStack` + a typed path; routes are values. Side effects (open URL, request permission, present system UI) live at the view/coordinator layer, not in the model.
- **UIKit interop is contained.** `UIViewRepresentable`/`UIViewControllerRepresentable` wrappers are a boundary with a clear ownership/lifecycle contract; keep them thin.

## 6. Release Engineering (App Store / TestFlight)

- **Version source of truth:** `MARKETING_VERSION` (CFBundleShortVersionString, the `X.Y.Z` users see) + `CURRENT_PROJECT_VERSION` (CFBundleVersion, the build number — must monotonically increase per upload). Tag `vX.Y.Z` matches `MARKETING_VERSION`. SemVer for the marketing version.
- **Signing:** code-sign with a Distribution cert + provisioning profile; prefer automatically-managed signing or fastlane `match` for team reproducibility. Never commit `.p12`, profiles, or App Store Connect API keys (§11).
- **Pipeline:** `xcodebuild archive` → export with the right method (app-store) → upload via `xcrun altool`/`notarytool` or fastlane `pilot`/`deliver`. TestFlight for beta → phased App Store release.
- **CHANGELOG** per Keep-a-Changelog; "What to Test" notes for TestFlight builds; App Store "What's New" derived from it.

## 7. Quality Gate (local + CI)

Fail fast. Representative ordering — adapt to the project:
```bash
swiftlint --strict                                   # lint (warnings as errors)
swift-format lint --strict --recursive Sources/      # or swiftformat --lint
xcodebuild build -scheme App -destination 'platform=iOS Simulator,name=iPhone 16' -quiet
xcodebuild test  -scheme App -destination 'platform=iOS Simulator,name=iPhone 16' -quiet  # unit + UI
```
Treat compiler warnings as errors on the app target. With Swift 6 language mode, a concurrency-safety warning is a latent data race — fix it, don't silence it.

## 8. Test Coverage Policy (iOS surfaces)

- **Unit** — model/use-case/mapper logic via XCTest or Swift Testing (`@Test`); pure, fast, no UI, no real I/O. Every new state branch covered.
- **Snapshot** — SwiftUI view output via swift-snapshot-testing; render the stateless view with hand-crafted state across the device/appearance matrix (light/dark, Dynamic Type sizes). Goldens regenerated AND eyeballed, never blind-accepted.
- **UI / integration** — XCUITest for critical user journeys (top flows only — they're slow and brittle). Use accessibility identifiers, not screen coordinates.
- **Concurrency** — test actor isolation and async flows with `await`; avoid arbitrary `sleep` (poll/await an expectation). Deterministic fixtures; injected clock, not wall-clock.
- **Accessibility** — VoiceOver labels, Dynamic Type scaling, contrast, hit targets verified for new surfaces.

## 12. Concurrency (Swift Concurrency)

- **Swift 6 strict concurrency is the floor.** Resolve every data-race warning; don't `@unchecked Sendable` your way out — prove the type is safe or make it an `actor`.
- **`@MainActor` for UI state.** `@Observable` view models that drive SwiftUI are main-actor isolated; hop off (`Task.detached` / a background actor) for heavy work, hop back to update UI. Never block the main thread.
- **`actor` for shared mutable state.** Protect mutable state with actor isolation rather than locks; understand actor reentrancy (state can change across an `await`).
- **Structured concurrency.** `async let` / `TaskGroup` for concurrent work; child tasks cancel with the parent. Propagate cancellation (`Task.checkCancellation()` / check `Task.isCancelled`); don't swallow `CancellationError`.
- **`Sendable` across boundaries.** Anything crossing an isolation boundary is `Sendable`; prefer value types. Capture lists in escaping closures use `[weak self]` to avoid retain cycles — a strong `self` in a long-lived closure is the classic iOS leak.
- **Legacy Combine** is fine where it exists; don't mix paradigms within a flow without reason. Bridge with `.values` async sequences when moving to async/await.

## 13. App Store Compliance Watchlist

- **Privacy manifest (`PrivacyInfo.xcprivacy`):** declare collected data types, tracking, and **required-reason API** usage (file timestamp, system boot time, disk space, `UserDefaults`, active keyboard). Third-party SDKs must ship their own manifests — a missing one blocks submission.
- **App Privacy "nutrition label"** in App Store Connect must match what the app actually collects — a mismatch is a rejection and a trust problem.
- **App Tracking Transparency (ATT):** any cross-app/cross-site tracking or IDFA access requires the ATT prompt and `NSUserTrackingUsageDescription`. No tracking before consent.
- **Permission usage strings:** every entitlement/capability that prompts (camera, location, contacts, health, notifications) needs a clear `NS*UsageDescription`; vague strings get rejected.
- **Entitlements** match capabilities and the provisioning profile (push, App Groups, HealthKit, CloudKit, Sign in with Apple). A new entitlement can trigger added review.
- **Review Guidelines:** account deletion if you offer sign-up; Sign in with Apple if you offer third-party social login; StoreKit for digital goods (no external payment for in-app digital content); no private APIs.
- **Encryption export compliance:** set `ITSAppUsesNonExemptEncryption` correctly.
