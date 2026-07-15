---
paths:
  - "**/*.kt"
  - "**/*.kts"
  - "**/build.gradle"
  - "**/build.gradle.kts"
  - "**/AndroidManifest.xml"
  - "**/gradle/libs.versions.toml"
  - "**/src/**/test/**"
  - "**/src/**/androidTest/**"
  - ".github/workflows/**"
---

# Android Overlay (Kotlin + Compose + Hilt + Room)

> Path-triggered: loads when Claude reads a file matching this pack's `paths:` glob (`*.kt`/`*.kts`, `build.gradle*`, `AndroidManifest.xml`, …; see frontmatter). Assumes Kotlin + Jetpack Compose + Hilt + Room + Coroutines + Gradle KTS + GitHub Actions. Framework sections (WorkManager, AlarmManager, Health Connect, Vico, Firebase, Play Billing, Glance) are scoped "If you use it" — delete what doesn't apply.

## 5. Architecture Patterns (Compose + Hilt + Room)

These are not preferences — they're how to avoid the bugs Android apps usually ship with. Match them unless you have a documented reason not to.

### 5.1 ViewModel discipline

- **No Android `Context` in ViewModels.** No `Activity`, no `Application`, no `Resources`. ViewModels are `@HiltViewModel` + `@Inject` on pure-Kotlin / pure-domain dependencies.
- **Side effects flow Route ← VM** via a `Channel<Effect>` exposed as `receiveAsFlow()`. The Route collects in a `LaunchedEffect` and invokes Android APIs (`startActivity`, `AppWidgetManager.requestPinAppWidget`, system permission launchers). Sample:

  ```kotlin
  // In VM:
  sealed interface Effect { data object OpenSomeSystemSurface : Effect; ... }
  private val _effects = Channel<Effect>(Channel.BUFFERED)
  val effects = _effects.receiveAsFlow()

  // In Route:
  LaunchedEffect(viewModel) {
      viewModel.effects.collect { effect -> when (effect) { ... } }
  }
  ```

- **State is a single `MutableStateFlow<UiState>`.** Update via `_state.update { it.copy(...) }`. Do not expose `MutableStateFlow` — expose `StateFlow` (or `asStateFlow()`).
- **`Flow.catch` before `.onEach` + `.launchIn(viewModelScope)`.** Without it, an upstream throw leaves the StateFlow stuck at `isLoading=true`. Treat this as a stand-alone bug class; pin it with a test (`upstream Flow exception is surfaced to errorMessage with isLoading false`).
- **`CancellationException` rule.** Inside `runCatching` blocks, re-throw `CancellationException`. A common helper: `runCatching { ... }.rethrowOnCancellationOr(fallback)`. Without it, a Continue-tap mid-`async` lets the trailing `_state.update` land AFTER the user already navigated.
- **Bounded "today" staleness.** `clock.today()` reads at the start of a `flatMapLatest` block re-fire — between fires, a kept-open screen past midnight queries with yesterday's window. Acceptable trade vs. a midnight ticker; document the limitation in KDoc.

### 5.2 Route vs Screen vs Content

- **Route**: knows about navigation, system intents, permission launchers, navController. `composable<X> { XRoute(...) }` in the NavHost.
- **Content** (`@Composable fun XContent(state, onEvent, modifier)`): stateless. Takes `UiState` + `(Event) -> Unit`. No Hilt. Snapshot-testable in isolation.
- **Screen / Route**: wraps `Content` with `Scaffold`, top app bar, `viewModel = hiltViewModel()`, and event dispatch (`viewModel.onEvent(event)` vs `navController.navigate(...)`).

### 5.3 Hilt boundaries

- Production interfaces live in `data/<area>/`. Implementations live in the same package; `Module` binds.
- **Fakes:**
  - Used by **only unit tests** → `app/src/test/.../testsupport/fakes/`.
  - Used by **unit tests AND instrumented tests** (Hilt-injectable, e.g. a `FakeFooClient`) → `app/src/debug/.../testing/` with `@TestInstallIn` to swap the production module. **Never** put shared fakes under `src/main/`.

### 5.4 Compose animation testability

Animations break snapshot tests unless you short-circuit them.

- **Rule:** every animated value MUST collapse to its final frame under `LocalInspectionMode.current == true`.
- For `animateFloatAsState` / `animateIntAsState`: pass `durationMillis = if (inspecting) 0 else N` in the `tween`.
- For `Animatable` + `LaunchedEffect`: branch on inspecting to `snapTo(target)` instead of `animateTo(target, ...)`.
- For Canvas-rendered charts (e.g. Vico): if the chart's draw output is sub-pixel-fragile across runner OS variants, render a **static placeholder** when `LocalInspectionMode.current`. The runtime experience stays full chart.

**Gotcha — first-composition snap.** `animateFloatAsState` / `animateIntAsState` initialise their internal Animatable to `targetValue` on first composition. A "ring draws 0 → final on first paint" requirement is NOT satisfied by `animateFloatAsState(targetValue=0.87f)` — you need `Animatable(0f) + LaunchedEffect { animateTo(target) }`. The snap-vs-animate behavior matters when the user is supposed to perceive a reveal.

### 5.5 Snapshot tests (Roborazzi)

- Base class: a shared `SnapshotTest` parent using `ParameterizedRobolectricTestRunner` with at minimum a 6-cell matrix: `{Pixel5, SmallPhone, MediumTablet} × {light, dark}`. Add RTL and landscape variants once the LTR / portrait surface is stable.
- Subclass declares `@Test` methods inside `snapshot { ... }`; one capture per cell per test.
- **Re-recording goldens** after an intentional visual change:
  ```bash
  ./gradlew :app:testDebugUnitTest --tests "<ClassName>" -Proborazzi.test.record=true
  ./gradlew :app:verifyRoborazziDebug   # confirm clean diff
  ```
- Commit the regenerated PNGs alongside the code change in the same commit.
- **Don't snap parent compositions just because.** Snap the composable that owns the visual (e.g. `XContent`, not `XRoute`). Smaller scope = fewer goldens to re-record on unrelated changes.
- **`changeThreshold`:** set per-call. 5% absorbs cross-OS font-hinting drift between authoring Mac and Linux CI runners; 2% is achievable when the CI runner OS matches the authoring OS (e.g. `runs-on: macos-latest`). Real layout shifts produce diffs much larger than either threshold.

### 5.6 Material 3 + Bottom Sheet pattern

For a bottom sheet whose open state must survive config changes:

- State lives on the **ViewModel** UI state, not in a `remember` inside the Composable.
- Example: `state.detailSheetFor: SomeEntity? = null` + `Event.OpenDetail(entity)` / `DismissDetail`.
- VM toggles the field; Composable conditionally renders `ModalBottomSheet(onDismissRequest = { onEvent(Dismiss) })`.
- `skipPartiallyExpanded = true` for review surfaces (drill-downs); `false` for glanceable surfaces.

### 5.7 NavHost shared elements

Compose 1.7's `SharedTransitionLayout` requires wrapping the entire NavHost. Premature plumbing for a single shared element trades simplicity for one transition. Defer until ≥2 surfaces share content. Document the deferral.

---

## 12. Reactive Patterns (Coroutines + Flow)

Beyond what §5.1 covers:

- **`viewModelScope` only** for VM-owned work. Don't pass `GlobalScope` / arbitrary dispatchers to repositories.
- **`Dispatchers.IO`** for Room queries (Room handles its own dispatch but explicit `withContext(Dispatchers.IO)` for non-suspend work like file ops).
- **`flatMapLatest`** for query parameters that supersede each other (e.g. "selected window") — cancels the previous query as the user changes the parameter.
- **Cold flows** for repository observations (`fooRepository.observeRange(...)`). Hot flows (`StateFlow`) for UI state.
- **`combine` discipline**: only when the latest values from each Flow need to be paired. For one-shot derived state, `map` + `transform` are cheaper.
- **Test the cancellation contract.** `runTest` with `StandardTestDispatcher` exposes coroutine-leak bugs; tests passing under `UnconfinedTestDispatcher` doesn't guarantee correctness.

---

## 6. Release Engineering

### 6.1 Versioning

Pick **one** source of truth and stick to it:

**Option A — `version.properties` at repo root** (recommended for multi-module projects):

```properties
# versionCode: monotonically increasing integer. MAJOR*10_000 + MINOR*100 + PATCH.
#   Pre-1.0:  0.1.0 → 100, 0.1.1 → 101, 0.2.0 → 200.
#   Post-1.0: 1.0.0 → 10000, 1.1.0 → 10100, 2.0.0 → 20000.
# versionName: user-visible semver. Must match git tag (tag vX.Y.Z must equal versionName X.Y.Z).
versionCode=10703
versionName=1.7.3
```

Loaded in `app/build.gradle.kts` via `Properties().apply { load(file("../version.properties").reader()) }`.

**Option B — inline in `app/build.gradle.kts`** (simpler, fine for single-module projects):

```kotlin
defaultConfig {
    versionCode = 10703
    versionName = "1.7.3"
}
```

Either way:
- Bump these BEFORE tagging.
- The release workflow must verify tag-vs-versionName parity (mismatch fails the build).
- **Don't** inline literal versions in multiple places — single source.

### 6.2 Tag-driven Internal Testing deploy

- Tag `vX.Y.Z` on `main` triggers `release.yml`, which builds the signed APK / AAB and uploads to Play Internal Testing (or attaches the APK to a GitHub Release).
- **Production stays manual** — Play Console UI, founder/maintainer action. Never auto-promote to production.
- Release workflow verifies tag-vs-versionName parity; mismatch fails the build.
- Release workflow ships the R8 `mapping.txt` alongside the APK so future stacktraces can be deobfuscated.

### 6.3 CHANGELOG discipline

- Format: [Keep a Changelog](https://keepachangelog.com/) — `## [X.Y.Z] — YYYY-MM-DD` sections.
- Each release section is what the release workflow extracts into the GitHub Release body (typically via `awk "/^## \\[$VERSION\\]/{flag=1; next} /^## /{flag=0} flag" CHANGELOG.md`).
- Bullet voice: past tense for what shipped, present tense for what works today. **Per §2: never mention AI tools, LLMs, or assistants in CHANGELOG entries.** Changes describe what shipped, not what wrote it.
- "Deferred" subsections matter — explicit deferral is better than silent partial-ship.
- Add a "Test plan" subsection per release with checkboxes for the local gate + on-device verification items.

### 6.4 GitHub Release notes convention

Release bodies are written for humans (users read these, engineers paste them into Slack, designers screenshot them). Format:

```
# <Version + one-line theme>
<1–2 sentence lead paragraph>
## Highlights
- <3–7 user-facing bullets, plain English>
## <Optional: Behind the scenes>  (only if material)
## What's next
**Full changelog:** https://github.com/<org>/<repo>/compare/vP...vN
```

Plain English, no commit SHAs in the body, no naked ticket numbers, no emojis (unless the project's tone established them). **Per §2: no mention of AI tools, LLMs, or specific assistants anywhere in release notes** — no footers, no "AI-assisted" tags, no "thanks to Claude" lines, no mention in highlights or behind-the-scenes sections. Release notes are about what shipped to users; the toolchain that produced it is not relevant content.

---

## 7. Quality Gate (local + CI)

### 7.1 Local pre-PR gate

```bash
./gradlew :app:testDebugUnitTest \
          detekt \
          :app:lintDebug \
          :app:assembleDebugAndroidTest \
          :app:compileReleaseKotlin \
          :app:verifyRoborazziDebug
```

Plus any project-specific guards (banned-words audit, source-text boundary checks).
All must pass before pushing.

### 7.2 CI structure (`.github/workflows/build.yml`)

Split into **3 parallel jobs** with an **aggregator job** that becomes the required-status-check name. This saves ~3–6 min per PR on a real codebase vs. a single sequential job.

- **`static-checks`** — Spotless, detekt, lint, banned-words grep guard (if applicable), package-name stale-reference guard, SDK-boundary grep guards.
- **`unit-snapshot`** — `:app:testDebugUnitTest` + `:app:verifyRoborazziDebug`.
- **`assemble`** — `:app:assembleDebug` + `:app:compileReleaseKotlin` (catches the "ships in debug, breaks in release variant" bug class) + `:app:assembleDebugAndroidTest` (catches Hilt graph breakage in androidTest without spinning a device).
- **`build`** (aggregator) — `needs: [static-checks, unit-snapshot, assemble]`; the branch ruleset gates only on this single check name.

**Required: the release-variant compile gate.** Without `:app:compileReleaseKotlin` in `build.yml`, code in `src/main/` that imports a debug-only class compiles fine in CI and only fails at tag-push time. The author has typically moved on; the silent failure can block QA for an entire phase. Wire it.

**Runner choice tradeoff.** `ubuntu-latest` is ~10× cheaper per minute than `macos-latest`. If Roborazzi tolerance is tight (≤2%) and authoring happens on Mac, use `macos-latest` to keep CI renders byte-matched with local renders — this lets you keep a single golden family instead of `*.macos.png` / `*.linux.png` splits. Budget the cost delta deliberately (typically ~$30–60/mo for a small team's build cadence).

### 7.3 Branch protection

- PR required for `main` (no direct push).
- `build` aggregator check must pass.
- Any tier-1 audit (banned-words, security grep) blocks merges on hit.

### 7.4 Domain-specific copy / banned-words CI guard (optional)

User-facing strings (Compose literals, `strings.xml`, AI prompt templates, notification copy) get grep-audited at CI time when the app's domain has high-stakes vocabulary:

- **Health apps:** medical claim triggers ("diagnose", "treat", "cure"), named conditions, "FDA approved"
- **Financial apps:** investment-advice triggers ("guaranteed return", "risk-free", "you should buy")
- **Children's apps:** anything in the Family Policy violation list

Source list lives in `docs/COPY_REVIEW.md`. The CI grep guard in `build.yml` enforces it. **A grep guard catches what code review misses.**

### 7.5 R8 / ProGuard release-build smoke

Source-text tests + the CI release-compile gate catch most cases, but only a real device run catches classes stripped at runtime that the source-text rules missed.

Per release, run `docs/release-smoke-checklist.md` on a target device:
1. `./gradlew :app:assembleRelease` → signed APK.
2. `adb install -r` on the target device.
3. Cold launch — no `NoClassDefFoundError` / `InstantiationException` / DI crash in logcat.
4. Trigger background workers (`adb shell am broadcast -a <action>`); confirm via Vitals.
5. Each major screen renders (proves each `@HiltViewModel` is instantiable post-R8).
6. If anything fails: **do not** silently re-add wholesale keep rules. File a bug per failing class, narrow the keep rule to the minimum reproducer, re-run the full smoke on the next RC.

---

## 8. Test Coverage Policy

### 8.1 Test surfaces (the four-surface model)

Every Android test you write fits into exactly one of these. Pick by what you want to verify, not by where it's easiest to put.

| Surface | Verifies | Lives in | Runs |
|---|---|---|---|
| **Unit** | ViewModel state machines, use-case logic, mappers, scheduler arithmetic. Pure JVM. No Compose. | `app/src/test/java/.../` | Every PR |
| **Snapshot regression** | UI doesn't visually regress. Renders Composables to PNGs per device qualifier; diffs against committed goldens. | `app/src/test/java/.../snapshot/` (sources) + `app/src/test/snapshots/` (goldens) | Every PR |
| **Instrumented** | DAO round-trips, Room migrations, Compose UI tests with the real Hilt graph + in-memory Room. The "does the click actually persist" layer. | `app/src/androidTest/java/.../` | Every push to `release/**`, plus on-demand |
| **Robo / automated crawl** | The unknown-unknown layer. Crawler walks every reachable UI path and reports anything it crashes, hangs, or cannot navigate. | No source (FTL-driven) | Every push to `release/**` |

### 8.2 Coverage thresholds (set deliberately)

There is no universal correct number. Set one and enforce it:

- **Unit coverage:** target ≥70% line, ≥60% branch for `app/src/main/` excluding generated code (Hilt, Room DAOs, Compose previews). Strict enough to surface untested logic; loose enough to not gate trivial PRs.
- **Snapshot coverage:** every stateful Composable (`*Content`) has at least one snapshot test across the 6-cell device × theme matrix. Track this manually — it's a gate on PRs that add new Content composables.
- **Instrumented coverage:** every DAO with non-trivial query logic has a test; every Compose UI on a stateful screen has at least one interaction test (`HiltAndroidTest` + `HiltTestActivity` + `createAndroidComposeRule`).

Wire Jacoco at the unit-test layer:

```kotlin
// In app/build.gradle.kts
plugins {
    id("jacoco")
}

tasks.register<JacocoReport>("jacocoTestReport") {
    dependsOn("testDebugUnitTest")
    reports {
        xml.required.set(true)
        html.required.set(true)
    }
    val excludes = listOf(
        "**/di/**", "**/*_Hilt*.*", "**/*Hilt_*.*",
        "**/*_Factory*.*", "**/*_MembersInjector*.*",
        "**/*ComposableSingletons*.*", "**/databinding/**",
        "**/BuildConfig.*",
    )
    classDirectories.setFrom(
        files(
            fileTree("$buildDir/intermediates/javac/debug/classes") { exclude(excludes) },
            fileTree("$buildDir/tmp/kotlin-classes/debug") { exclude(excludes) },
        )
    )
    sourceDirectories.setFrom(files("src/main/java"))
    executionData.setFrom(fileTree(buildDir).include("jacoco/testDebugUnitTest.exec"))
}
```

Enforce in CI by parsing the XML output and failing the job if either threshold is missed. Update thresholds deliberately when you have a documented reason (new infrastructure module exempted, intentional drop during refactor).

### 8.3 Fixture data discipline

- **Deterministic.** Pin dates (`LocalDate.of(2026, 5, 15)` not `LocalDate.now()`). Avoid `Math.random()` / `Color.random()` in anything that's snapshot-tested.
- **Hand-rolled fakes preferred over mocking frameworks** for repository interfaces. Back state with `MutableStateFlow` so tests can drive observed outputs directly. Mocking frameworks are fine for one-off verification of "was this method called with these args"; they're an anti-pattern for repository-shaped surfaces.
- **In-memory Room** for instrumented tests via a `TestDatabaseModule` swapping the production `DatabaseModule` with `@TestInstallIn`. Don't pollute the developer's on-device DB.

### 8.4 First-render race in Compose UI tests

The default `assertIsDisplayed()` only waits for Compose recomposition idleness, not for the ViewModel's initial-load coroutine. First-touch assertions race the loading-state-clear. Wrap with a helper:

```kotlin
fun ComposeContentTestRule.assertTextEventuallyDisplayed(
    text: String,
    timeoutMs: Long = 5_000,
) {
    waitUntil(timeoutMs) {
        onAllNodesWithText(text).fetchSemanticsNodes().isNotEmpty()
    }
    onNodeWithText(text).assertIsDisplayed()
}
```

Use this for any first-render assertion that depends on a coroutine-loaded state.

---

## 13. Play Store Compliance Watchlist

Play policy is the single biggest source of "release blocked at submission" surprises. Track these per release:

### 13.1 Permissions

- **`USE_EXACT_ALARM` / `SCHEDULE_EXACT_ALARM`** — restricted to alarm-clock and calendar apps as of 2024. Wellness, productivity, fitness reminders **do not qualify**. Use `setAndAllowWhileIdle()` (inexact, idle-safe) instead.
- **`AD_ID`** — required if you use any SDK that touches advertising ID. If your app doesn't show ads, ensure no transitive dep adds it (check the merged manifest).
- **`POST_NOTIFICATIONS`** — runtime permission on API 33+. Required `targetSdk` 33+. Request only when first needed, not at app start.
- **`MANAGE_EXTERNAL_STORAGE`** — Play restricted; requires Play Console form justification.
- **`PACKAGE_USAGE_STATS`, `BIND_ACCESSIBILITY_SERVICE`, `BIND_NOTIFICATION_LISTENER_SERVICE`** — Play restricted; require special use declaration.

### 13.2 Foreground services

- Every foreground service needs a `foregroundServiceType` (Android 14+) AND a matching permission AND a justification in the Play Console form.
- Generic `dataSync` and `mediaPlayback` are scrutinized more closely each release of Play policy.

### 13.3 Package name

- Once published to Play, the `applicationId` is permanent. Renaming = new listing + lost install base + lost reviews.
- Verify the desired `applicationId` is not reserved by anyone else before the first publish. Reserve early.

### 13.4 Auto-backup

- `android:allowBackup="false"` unless you have a deliberate backup strategy. Default `true` silently uploads user data to the user's Google account, which may violate your privacy policy.

### 13.5 Data Safety form

- Sync the form to reality on every release. Any new permission, SDK, or data-collection path triggers a form re-review.
- Common drift: a removed analytics SDK still appears on the form; a newly added crash reporter doesn't.

### 13.6 targetSdk treadmill

- Play requires `targetSdk` ≥ N for new submissions and ≥ N−1 for existing-app updates, where N is the current Android release.
- Update one minor cycle in advance; permission flow changes and background-work restrictions at each level frequently break things at submission.

---


------

## Android workflow addenda

> Extend the universal four-hat workflow (CLAUDE.md §4), secrets (§11), and anti-patterns (§14). These apply on top of the universal rules when working in an Android codebase.

### Review-checklist additions — extends §4 Phase 3 (Code Reviewer)
- Failure-mode lens for Phase 1: also consider lifecycle race, R8 stripping, Play policy.
- Security lens: path traversal, intent redirection, exported component, implicit intent for sensitive data.
- [ ] Composables: do they short-circuit under `LocalInspectionMode` so snapshots stay byte-stable?
- [ ] ViewModels: are they Android-context-free (no Activity / Context refs)?
- [ ] Side effects: do they live at the Route layer, not in the VM?
- [ ] R8 risk: any reflection / serialization / `@HiltViewModel` constructor that needs a keep rule?
- [ ] Play policy: any new permission, foreground service type, exported activity, or background work that triggers Data Safety re-review?
- [ ] Tests: every new logic branch covered? Snapshot goldens regenerated and reviewed by eye if UI changed?

### Error-recovery additions — extends §4.7
| Failure | Stays in current phase? | Recovery |
|---|---|---|
| FTL infra blip | Yes | One retry (`--num-flaky-test-attempts=1` covers this in CI). |
| Lint / detekt finding | No | Back to Phase 2 — but narrow fix, not "fix all detekt findings". |
| Snapshot diff after intentional UI change | Yes | Regenerate goldens, eyeball diff, recommit — stay in current phase. |
| Snapshot diff after unintentional change | No | Back to Phase 2 — real regression. |
| R8 release-build crash post-merge | No | Back to Phase 2 — add narrow keep rule, NOT wholesale `-keep class **`. |

### Secrets inventory (Android) — extends §11
| Secret | Used by | Purpose | Rotation cadence |
|---|---|---|---|
| `UPLOAD_KEYSTORE_BASE64` | `release.yml` | Base64-encoded `.jks` upload keystore for signing release APKs | Never (rotation breaks Play Console signing identity) |
| `KEYSTORE_PASSWORD` | `release.yml` | Password for the upload keystore | When team membership changes |
| `KEY_ALIAS` | `release.yml` | Key alias inside the keystore | Never |
| `KEY_PASSWORD` | `release.yml` | Password for the signing key | When team membership changes |
| `FIREBASE_SERVICE_ACCOUNT` | `connected-tests.yml`, `robo-test.yml` | GCP service account JSON for FTL access | Every 90 days, or on team-change |
| `PLAY_PUBLISHER_JSON` | `release.yml` (if auto-uploading to Play) | Play Console API service account | Every 90 days |
| `CRASHLYTICS_API_TOKEN` | `release.yml` (if applicable) | Crashlytics mapping upload | When team membership changes |
| `SLACK_WEBHOOK_URL` | `release.yml`, `build.yml` (if applicable) | Release notification | When team membership changes |

Maintain this table in `docs/SECRETS.md` and grep CI logs for any secret name that's been removed.

### Anti-patterns (Android) — extends §14
- **Don't snapshot the full Route.** Snapshot the `Content`. Route brings the NavHost + Scaffold + ViewModel collection, all of which generate noise across Compose updates.
- **Don't put bottom-sheet open state in a `remember` inside the Composable.** A config change rotates the device and the sheet snaps closed. State lives on the VM.
- **Don't use `Locale.getDefault()` for fixed-format dates** (analytics keys, file names, internal logs). Use `Locale.US` (or `Locale.ROOT`). User-visible dates can use `Locale.getDefault()`.
- **Don't ship a chart marker / tooltip with text-only y-values from a default formatter** if the chart library renders them. Implement a domain-aware `ValueFormatter` to translate raw values back to your domain row.
- **Don't reach into Compose source to "fix" first-composition behavior of `animateXxxAsState`** — use `Animatable` + `LaunchedEffect`.
- **Don't add icon imports via fully-qualified `Icons.Outlined.Foo`.** Material Icons Compose requires explicit `import androidx.compose.material.icons.outlined.Foo` + `import androidx.compose.material.icons.Icons`. The dotted-path attempt is the most common "icon not found" error.
- **Don't skip the `.catch` on Flow chains.** Every `combine().onEach.launchIn` pattern needs `.catch { ... }` before `.onEach` or an upstream throw leaves `isLoading=true` forever.
- **Don't squash-merge PRs whose feature branches each bumped versions and CHANGELOG without rebasing.** You'll get a conflict on the second one. Rebase first, then push.
- **Don't trust subagent "context preserved" / "I remember from earlier" claims.** Subagents have no memory across invocations. Confirm specific file paths, line numbers, or commit SHAs with `Read` / `Bash` before acting on them.
- **Don't add `--no-verify` to skip a failing pre-commit hook.** Investigate the hook failure; the hook usually catches real problems.
