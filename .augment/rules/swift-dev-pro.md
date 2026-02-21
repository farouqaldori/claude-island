---
type: "agent_requested"
description: "Modern Swift Best Practices for macOS"
---

# Swift 6+ coding guidelines development

**Swift 6.2 with macOS 26 Tahoe, iOS 26, and aligned platform versions represents the most significant leap in Swift's evolution since its introduction.** The combination of approachable concurrency (SE-0461, SE-0466), compile-time data race safety, non-copyable types with generics, typed throws, and the Observation framework creates a language that is simultaneously safer, more expressive, and more performant than any prior version. These guidelines cover every major domain — from language fundamentals through architecture patterns — exclusively targeting the newest platforms with zero legacy compromise.

**Critical platform note:** At WWDC 2025, Apple unified all platform version numbers to the calendar year. What the original task refers to as "iOS 19" is officially **iOS 26**; "watchOS 12" is **watchOS 26**; "tvOS 19" is **tvOS 26**; "visionOS 3" is **visionOS 26**. macOS 26 Tahoe is correct. All guidelines below use the official naming.

---

## 1. Swift version progression from 6.0 through 6.2

Swift 6.0 (September 2024, Xcode 16) introduced the foundational pillars: **strict concurrency with compile-time data race safety**, typed throws (SE-0413), non-copyable generics (SE-0427), the Synchronization module with `Mutex` and `Atomic` (SE-0410, SE-0433), 128-bit integers (SE-0425), and `sending` parameter values (SE-0430). Over 23 evolution proposals shipped in this release alone. Enabling `-swift-version 6` makes data race violations hard errors rather than warnings.

Swift 6.1 (March 2025, Xcode 16.3) refined the experience with trailing commas everywhere (SE-0439), `nonisolated` on types and extensions (SE-0449), TaskGroup child type inference (SE-0442), `@objc @implementation` for incremental Objective-C migration (SE-0444), and package traits for conditional SPM dependencies (SE-0450).

Swift 6.2 (September 2025, Xcode 26) is the flagship release for the latest platforms. Its headline feature, **Approachable Concurrency**, restructures how developers interact with the concurrency system through three pillars: default `@MainActor` isolation at module level (SE-0466), nonisolated async functions inheriting the caller's executor (SE-0461), and the explicit `@concurrent` attribute for parallel work. Additional major features include `InlineArray` for fixed-size stack-allocated arrays (SE-0458), `Span<T>` for safe contiguous memory access (SE-0453), `Task.immediate` for synchronous task starts (SE-0472), task naming for debugging (SE-0469), isolated actor deinit (SE-0371), and opt-in strict memory safety (SE-0477).

| Feature | Swift 6.0 | Swift 6.1 | Swift 6.2 |
|---------|-----------|-----------|-----------|
| Data race safety enforcement | ✅ | ✅ | ✅ Enhanced |
| Typed throws | ✅ SE-0413 | — | — |
| Non-copyable generics | ✅ SE-0427 | — | — |
| Mutex / Atomic | ✅ SE-0433/0410 | — | — |
| Int128 / UInt128 | ✅ SE-0425 | — | — |
| Trailing commas everywhere | — | ✅ SE-0439 | — |
| `nonisolated` on types | — | ✅ SE-0449 | — |
| Package traits | — | ✅ SE-0450 | — |
| InlineArray | — | — | ✅ SE-0458 |
| Span / RawSpan | — | — | ✅ SE-0453 |
| `@concurrent` attribute | — | — | ✅ SE-0461 |
| Default MainActor isolation | — | — | ✅ SE-0466 |
| Task.immediate | — | — | ✅ SE-0472 |
| Task naming | — | — | ✅ SE-0469 |
| `@abi` attribute | — | — | ✅ SE-0476 |
| WebAssembly support | — | — | ✅ Official |

### Compiler flags and build settings

Xcode 26 introduces a consolidated **Approachable Concurrency** build setting that enables five upcoming feature flags simultaneously: `DisableOutwardActorInference`, `GlobalActorIsolatedTypesUsability`, `InferIsolatedConformances`, `InferSendableFromCaptures`, and `NonisolatedNonsendingByDefault`. The **Default Actor Isolation** build setting controls SE-0466, allowing `MainActor` as the module-level default.

In SPM, configure these per-target:

```swift
.target(
    name: "MyTarget",
    swiftSettings: [
        .swiftLanguageMode(.v6),
        .defaultIsolation(MainActor.self),
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
        .enableUpcomingFeature("InferIsolatedConformances"),
        .treatAllWarnings(as: .error),
        .treatWarning("DeprecatedDeclaration", as: .warning),
    ]
)
```

### What's deprecated and what replaces it

`@UIApplicationMain` and `@NSApplicationMain` are deprecated in favor of `@main`. Bare existential types without the `any` keyword produce errors in Swift 6 mode (SE-0335). String-based `NotificationCenter` is superseded by typed notification structs using `MainActorMessage` and `AsyncMessage` protocols. `UnsafeBufferPointer` for safe memory access is replaced by `Span`. The `rethrows` keyword is largely superseded by typed throws with `throws(E)` for generic error propagation.

---

## 2. Concurrency and data race safety as the default

### The Swift 6 concurrency model

In Swift 6 language mode, **data race safety is enforced at compile time as errors**. The compiler performs complete checking of actor isolation boundaries, `Sendable` conformance across concurrency domains, global variable safety, and closure captures in concurrent contexts. SE-0414's region-based isolation allows the compiler to prove that non-Sendable values are safe when they don't cross isolation regions, dramatically reducing false positives compared to Swift 5.10.

Global variables must be safe: either `Sendable` constants, isolated to a global actor, or explicitly marked `nonisolated(unsafe)` as an escape hatch.

```swift
let sharedConfig = AppConfig()          // ✅ Immutable + Sendable
@MainActor var appState = AppState()    // ✅ Isolated to MainActor
nonisolated(unsafe) var legacyGlobal = 0 // ⚠️ Escape hatch — avoid
```

### Approachable Concurrency in Swift 6.2

The three pillars of Swift 6.2's concurrency redesign fundamentally change how developers write concurrent code. **Default `@MainActor` isolation** (SE-0466) means all declarations in a module implicitly run on the main actor unless explicitly opted out. **Nonisolated async functions inherit the caller's executor** (SE-0461), unifying behavior with synchronous functions and eliminating the surprising thread-hopping of prior versions. The **`@concurrent` attribute** explicitly marks functions for background execution:

```swift
// With default MainActor isolation enabled:
struct ImageCache {
    static var cached: [URL: Image] = [:]  // Protected by MainActor automatically

    static func create(from url: URL) async throws -> Image {
        if let image = cached[url] { return image }
        let image = try await fetchImage(at: url)
        cached[url] = image
        return image
    }

    @concurrent
    static func fetchImage(at url: URL) async throws -> Image {
        // Explicitly runs on global concurrent executor
        let (data, _) = try await URLSession.shared.data(from: url)
        return try decode(data)
    }
}
```

### Actor isolation patterns

Actors serialize access to mutable state. Only one task accesses an actor's state at a time. Key rules: all mutable properties and methods are isolated by default; immutable `let` properties can be accessed without `await`; actors automatically conform to `Sendable`. Actors execute **highest-priority work first** (not FIFO like `DispatchQueue`).

Use `nonisolated` for methods that don't access actor state. In Swift 6.2 with `NonisolatedNonsendingByDefault`, nonisolated sync functions run on the caller's thread while nonisolated async functions run on the **caller's actor** — use `@concurrent` to explicitly opt into background execution.

**Actor reentrancy** is critical: when an actor suspends at an `await`, other work can execute on the same actor. Always re-check state after suspension points.

```swift
actor ImageCache {
    private var cache: [URL: Image] = [:]

    func getImage(for url: URL) async -> Image {
        if let cached = cache[url] { return cached }
        let image = await downloadImage(from: url)
        cache[url] = cache[url] ?? image  // Re-check after suspension
        return cache[url]!
    }
}
```

### Making types properly Sendable

Value types (structs/enums) where all stored properties are Sendable gain automatic conformance. For classes, use `final class` with only immutable `let` Sendable properties. For mutable class state, **use `Mutex` from the Synchronization module** — this is the proper Swift 6 pattern replacing `@unchecked Sendable` with manual locks:

```swift
import Synchronization

final class ThreadSafeCache: Sendable {
    private let storage = Mutex<[String: Data]>([:])

    func get(_ key: String) -> Data? {
        storage.withLock { $0[key] }
    }

    func set(_ key: String, value: Data) {
        storage.withLock { $0[key] = value }
    }
}
```

The `sending` keyword (SE-0430) enables explicit transfer of non-Sendable values across isolation boundaries when the compiler can prove the caller gives up access.

### Structured concurrency patterns

Use **`async let`** for a fixed number of concurrent operations and **`TaskGroup`** for dynamic collections. Discarding task groups (`withThrowingDiscardingTaskGroup`) are ideal for long-running services where results aren't needed — resources are freed immediately as tasks complete, preventing memory accumulation.

```swift
// Fixed concurrent operations
func loadDashboard() async throws -> Dashboard {
    async let profile = fetchProfile()
    async let notifications = fetchNotifications()
    async let settings = fetchSettings()
    return try await Dashboard(profile: profile, notifications: notifications, settings: settings)
}

// Dynamic concurrent operations
func fetchAllUsers(ids: [Int]) async throws -> [User] {
    try await withThrowingTaskGroup(of: User.self) { group in
        for id in ids { group.addTask { try await api.fetchUser(id: id) } }
        return try await group.reduce(into: []) { $0.append($1) }
    }
}
```

### The Synchronization module: Atomic and Mutex

Available since Swift 6.0 (macOS 15+ / iOS 18+, fully available on macOS 26+). **`Mutex`** provides synchronous mutual exclusion — use it when you need synchronous access to shared state or can't use async. **`Atomic`** provides hardware-level lock-free operations for simple counters and flags.

| Scenario | Tool |
|----------|------|
| UI state management | `@MainActor` |
| Shared mutable state (async access) | `actor` |
| Shared mutable state (sync access) | `Mutex` |
| Simple counters and flags | `Atomic` |

```swift
import Synchronization

let requestCount = Atomic<Int>(0)
requestCount.add(1, ordering: .relaxed)

let flag = Atomic<Bool>(false)
let (exchanged, _) = flag.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing)
```

### Task executors and task naming (Swift 6.2)

Task executor preference (SE-0417) controls where nonisolated async code runs. Preferences propagate to child tasks in structured concurrency but are overridden by actor isolation. **Task naming** (SE-0469) enables meaningful debugging labels, and **task priority escalation APIs** (SE-0462) allow detecting and responding to priority changes.

```swift
Task(name: "user-profile-fetch") {
    await fetchProfile()
}

await withTaskExecutorPreference(ioExecutor) {
    await performDiskIO()  // Runs on ioExecutor
}
```

---

## 3. Ownership, non-copyable types, and safe memory access

### The ownership and borrowing model

Swift 6 provides three parameter ownership modifiers. **`borrowing`** gives the function temporary read-only access without taking ownership — the caller retains the value. **`consuming`** transfers ownership to the callee, invalidating the caller's binding. **`inout`** provides exclusive mutable access. For most code, Swift's defaults work well; these modifiers provide guaranteed predictable behavior for performance-critical paths where compiler optimizations alone aren't reliable.

```swift
func preview(file: borrowing FileHandle) { print(file.description) }
func close(file: consuming FileHandle) { /* takes ownership, file invalid at caller */ }

let data = LargeData()
let handle = DataProcessor(data: consume data)  // Explicit ownership transfer
// data is no longer valid here
```

### Non-copyable types (~Copyable)

Non-copyable types enforce unique ownership — preventing accidental duplication of resources that must have single owners. Unlike regular structs, **non-copyable types can have `deinit`**, enabling RAII-style resource management:

```swift
struct FileDescriptor: ~Copyable {
    private let fd: Int32
    consuming func close() { discard self }  // Suppress deinit
    deinit { close(fd) }  // Auto-cleanup fallback
}
```

Non-copyable generics (SE-0427, Swift 6.0) removed the restriction that prevented noncopyable types from working with generics, protocols, and existentials. `Optional`, `Result`, and other standard library types now support non-copyable payloads (SE-0437). Protocols can declare `~Copyable` requirements.

### Span for safe buffer access (Swift 6.2)

**`Span<T>`** is a safe, non-owning, non-escapable view over contiguous memory that replaces `UnsafeBufferPointer` patterns. It provides bounds-checked subscript access and **cannot escape the scope** of the data it references — the compiler enforces this at compile time via the `~Escapable` constraint:

```swift
let array = [1, 2, 3, 4]
let span: Span<Int> = array.span  // Safe, bounds-checked view
for i in 0..<span.count { process(span[i]) }

// RawSpan for untyped byte access
// MutableSpan for writable access (Swift 6.2)
```

### InlineArray for stack-allocated fixed-size data (Swift 6.2)

**`InlineArray<N, Element>`** provides fixed-size, stack-allocated arrays with no heap allocation:

```swift
struct Game {
    var bricks: [40 of Sprite]  // Shorthand for InlineArray<40, Sprite>
    init(_ sprite: Sprite) { bricks = .init(repeating: sprite) }
}
```

---

## 4. Typed throws transform error handling

### Typed throws as the default approach (SE-0413, Swift 6.0)

Typed throws replace the blanket `throws` with precise error typing. The catch block receives the exact error type — no casting required. When used in generic contexts, typed throws subsume `rethrows`: if a closure doesn't throw, the error type infers as `Never`, making the function non-throwing.

```swift
enum ValidationError: Error {
    case emptyName
    case nameTooShort(length: Int)
}

func validate(name: String) throws(ValidationError) {
    guard !name.isEmpty else { throw .emptyName }
    guard name.count >= 3 else { throw .nameTooShort(length: name.count) }
}

do throws(ValidationError) {
    try validate(name: input)
} catch {
    switch error {  // error is ValidationError — exhaustive matching
    case .emptyName: print("Empty!")
    case .nameTooShort(let len): print("Too short: \(len)")
    }
}
```

**When to use typed throws:** fixed error sets unlikely to change, when callers need exhaustive handling, same module/package owns caller and callee, and performance-sensitive code avoiding existential boxing. **When to keep untyped throws:** public APIs where error types may evolve, composing multiple error domains, or when callers don't need exhaustive handling.

`throws(Never)` is equivalent to non-throwing and enables generic functions to propagate error types cleanly:

```swift
// When given non-throwing closure, E = Never, so count() is non-throwing
func count<E: Error>(where predicate: (Element) throws(E) -> Bool) throws(E) -> Int
```

### Result still has its place

`Result` remains appropriate for storing outcomes for later inspection, callback-based APIs that haven't migrated to async/await, and passing error outcomes through non-throwing interfaces. With SE-0437/SE-0465, `Result` now supports non-copyable and non-escapable payloads.

---

## 5. SwiftUI with @Observable is a different framework

### The Observation framework replaces Combine-based patterns

The `@Observable` macro (Observation framework, iOS 17+) represents a fundamental shift from push-based broadcasting to **pull-based, access-tracked observation**. Views only re-render when properties they actually read in their body change. With `ObservableObject`, any `@Published` property change invalidated all observing views. This single change eliminates entire categories of performance problems.

```swift
// ✅ MODERN: @Observable (iOS 17+ / THE standard for 2025+)
@Observable final class UserViewModel {
    var name = ""
    var age = 0
    var unrelatedFlag = false  // Changes do NOT affect views that don't read it
}

struct ProfileView: View {
    @State private var viewModel = UserViewModel()  // @State for owned instances
    var body: some View {
        Text(viewModel.name)  // Only re-renders when name changes
    }
}
```

The migration mapping from legacy to modern is definitive:

| Legacy | Modern |
|--------|--------|
| `class VM: ObservableObject` | `@Observable class VM` |
| `@Published var` | Plain `var` (auto-tracked) |
| `@StateObject` | `@State` |
| `@ObservedObject` | Plain property or `@Bindable` |
| `@EnvironmentObject` | `@Environment(MyType.self)` |
| `.environmentObject(obj)` | `.environment(obj)` |

**`@Bindable`** is the critical new pattern: when you receive an `@Observable` object (not owning it via `@State`), use `@Bindable` to create bindings to its properties. `@Binding` is for value types; `@Bindable` is for `@Observable` reference types.

```swift
struct PostEditor: View {
    @Bindable var post: Post  // Creates bindings to @Observable properties
    var body: some View { TextField("Edit...", text: $post.text) }
}
```

### New SwiftUI APIs in macOS 26 / iOS 26

The **Liquid Glass** design system is the headline visual change — a translucent, blurred glass aesthetic adopted automatically when recompiling with Xcode 26. The `.glassEffect()` modifier applies it to custom views. The `@Animatable` macro auto-synthesizes `animatableData`, replacing manual boilerplate. Native `WebView` and `WebPage` types eliminate UIKit wrapper needs. `TextEditor` now supports `AttributedString` bindings for rich text editing.

**Performance gains are dramatic:** lists on macOS load **6× faster** for 100,000+ items; list updates are up to **16× faster**; nested lazy stacks in scroll views now properly defer loading. A new SwiftUI Performance Instrument in Xcode 26 provides dedicated profiling lanes.

iPadOS 26 brings resizable windows, a swipe-down menu bar, and full `Commands` API support matching macOS. The `@Animatable` macro replaces manual `animatableData` boilerplate, and `ToolbarSpacer` enables precise toolbar layout control.

### The `Observations` async sequence (Swift 6.2)

A new mechanism for streaming transactional state changes from `@Observable` types:

```swift
let observations = Observations(tracking: myModel) { model in
    (model.title, model.count)
}
for await (title, count) in observations {
    // Batched per transaction — all synchronous changes included
}
```

---

## 6. Architecture patterns leverage @Observable and strict concurrency

### MVVM with @Observable

The recommended MVVM structure uses `@Observable` classes as view models, owned via `@State` in the view that creates them. Not every view needs a ViewModel — only root/feature views with complex logic. Pure display views receive data as simple properties.

```swift
@Observable final class TripListViewModel {
    var trips: [Trip] = []
    var isLoading = false
    private let service: TripServiceProtocol

    init(service: TripServiceProtocol) { self.service = service }

    func loadTrips() async {
        isLoading = true
        defer { isLoading = false }
        trips = (try? await service.fetchTrips()) ?? []
    }
}

struct TripListView: View {
    @State private var viewModel: TripListViewModel

    init(service: TripServiceProtocol) {
        _viewModel = State(initialValue: TripListViewModel(service: service))
    }

    var body: some View {
        List(viewModel.trips) { TripRow(trip: $0) }
            .task { await viewModel.loadTrips() }
    }
}
```

### Dependency injection with swift-dependencies

Point-Free's **swift-dependencies** library (v1.10+) provides environment-style DI that works outside SwiftUI views — in models, services, and CLI tools. It uses Swift's `TaskLocal` machinery, provides `liveValue`/`testValue`/`previewValue` contexts, and is fully Swift 6 compatible with zero data race safety errors:

```swift
import Dependencies

struct APIClient: Sendable {
    var fetchUser: @Sendable () async throws -> User
}

extension APIClient: DependencyKey {
    static let liveValue = APIClient(fetchUser: { try await network.get() })
    static let testValue = APIClient(fetchUser: unimplemented("fetchUser"))
}

// In tests:
@Test func testLoading() async {
    await withDependencies { $0.apiClient.fetchUser = { .mock } } operation: {
        let vm = ProfileViewModel()
        await vm.load()
        #expect(vm.user == .mock)
    }
}
```

For simpler apps, **SwiftUI Environment-based DI** with closure-based service structs works well without additional dependencies. Define services as `Sendable` structs with closure properties, register them via `EnvironmentKey`, and override in previews.

### The Composable Architecture adapts to Swift 6

TCA post-1.7 uses `@ObservableState` (TCA's value-type equivalent of `@Observable`) and eliminates `ViewStore` — views access state directly from the store. For Swift 6 strict concurrency, mark `State` and `Action` as `Sendable`, and use `@Dependency` locally inside effect closures rather than on reducer properties to avoid sendability issues.

### Modular architecture with Swift packages

Break apps into feature modules as local Swift packages. Use `package` access level (SE-0386) to share implementation details between targets within a package without making them `public`. Feature modules expose protocols for inter-module communication, third-party dependencies get wrapped in bridge modules, and each module should be independently buildable and testable.

---

## 7. Swift Package Manager evolves with traits and precision controls

The latest `swift-tools-version: 6.2` adds `defaultIsolation` settings (SE-0466) and precise warning control (SE-0480). Swift 6.0 made the default language mode Swift 6 with full strict concurrency; opt out per-target with `.swiftLanguageMode(.v5)` if needed.

### Package traits enable conditional compilation (SE-0450, Swift 6.1)

Traits act as feature flags at the package level, enabling conditional dependencies and compilation:

```swift
// swift-tools-version: 6.1
let package = Package(
    name: "MyServer",
    traits: [
        "Logging",
        .trait(name: "FullDiagnostics", enabledTraits: ["Logging", "Metrics"]),
        .default(enabledTraits: ["Logging"]),
    ],
    targets: [
        .target(name: "MyServer", dependencies: [
            .product(name: "Logging", package: "swift-log",
                     condition: .when(traits: ["Logging"])),
        ]),
    ]
)
```

Traits must be strictly additive. Enable via CLI: `swift build --traits Logging,Metrics`.

### Build plugins and macro packaging

Build tool plugins run automatically during builds for code generation; command plugins are manually invoked for formatting or linting. Macros are distributed as `.macro` targets depending on SwiftSyntax. Swift 6.2 ships **pre-built swift-syntax** binaries, significantly reducing CI build times for macro-heavy packages.

---

## 8. Swift Testing replaces XCTest as the primary framework

### Core design

The `@Test` macro marks any function as a test — no naming conventions required. `@Suite` organizes tests into types (struct, final class, enum, or actor). **Two assertion macros** replace XCTest's 20+ assertion functions: `#expect` for non-fatal assertions that capture both sides of expressions for rich failure messages, and `#require` for fatal assertions that halt the test.

```swift
import Testing

@Suite("Payment Processing")
struct PaymentTests {
    @Test("Valid amounts are accepted", arguments: [100, 200, 500])
    func validPayment(amount: Int) async throws {
        let result = try await processor.charge(amount)
        #expect(result.status == .approved)
    }

    @Test func invalidCardThrows() {
        #expect(throws: PaymentError.invalidCard) {
            try processor.validate(card: .expired)
        }
    }
}
```

Tests run in parallel by default using Swift Concurrency task groups — **in-process**, not multi-process like XCTest. Struct suites provide value-semantics isolation (each test gets a fresh instance). Parameterized tests with `@Test(arguments:)` run each argument as an independent, re-runnable test case.

### Test traits enable precise control

Tags organize tests across suites. Conditions enable/disable tests programmatically. Time limits prevent hung tests. The `.serialized` trait forces sequential execution for suites with shared state. The `.bug()` trait links tests to issue trackers. `withKnownIssue` marks expected failures without failing the test.

Swift 6.2 adds **exit testing** (verify crash/precondition behavior), **test attachments** (images, logs, JSON in test results), and raw identifier test names using backtick syntax.

### Mocking compatible with strict concurrency

Use **actor-based mocks** for thread-safe mock state in concurrent test environments, or **closure-based service structs** (`Sendable` structs with closure properties) for lightweight, functional mocking that naturally satisfies `Sendable` requirements. Prefer struct test suites for isolation.

---

## 9. API design for Swift 6 codebases

### `some` vs `any` — start concrete, escalate deliberately

Start with **concrete types**. Move to **`some` (opaque types)** when you need protocol abstraction but type identity is fixed — `some` uses static dispatch with better performance. Use **`any` (existential types)** only when you need heterogeneous storage or dynamic return types. In Swift 6 mode, `any` is required for all existential types (SE-0335).

```swift
func feed(_ animal: some Animal) { }           // ✅ Static dispatch, preferred
var shapes: [any Drawable] = [Circle(), Square()] // ✅ Heterogeneous — any required
```

### Primary associated types and parameter packs

Primary associated types (SE-0346) enable cleaner constraint syntax: `some Collection<String>` instead of explicit generic parameters. Parameter packs (SE-0393/0398/0399, pack iteration SE-0408 in Swift 6.0) enable true variadic generics:

```swift
func printAll<each T>(_ values: repeat each T) {
    repeat print(each values)
}
printAll(1, "hello", true)
```

### The `package` access level fills the gap

`package` (SE-0386) is essential for modular architecture — share implementation details between targets within a Swift Package without making them `public`. The hierarchy: `open` > `public` > `package` > `internal` > `fileprivate` > `private`.

### DocC documentation

DocC supports reference documentation from source comments, articles for conceptual guides, interactive tutorials, extension documentation for types from other frameworks, and deployment to GitHub Pages. Use the swift-docc-plugin for SPM integration: `swift package generate-documentation --target MyLibrary`.

---

## 10. Security benefits from the type system

### Data race elimination as security infrastructure

Swift 6's compile-time data race safety eliminates an entire class of undefined behavior that historically led to memory corruption and security vulnerabilities. Over **43% of Swift packages** had zero data race errors by mid-2024, and adoption continues to grow. Swift 6.2's opt-in strict memory safety (SE-0477) flags all uses of unsafe constructs for projects with the strongest security requirements.

### CryptoKit and Secure Enclave patterns

CryptoKit provides Swift-native APIs for SHA-256/384/512 hashing, AES-GCM and ChaChaPoly symmetric encryption, P256/P384/P521/Ed25519 signing, and HKDF key derivation. The Secure Enclave supports **P256 only** with non-extractable private keys:

```swift
import CryptoKit

let key = SymmetricKey(size: .bits256)
let sealed = try AES.GCM.seal(data, using: key)
let decrypted = try AES.GCM.open(sealed, using: key)

// Secure Enclave — hardware-isolated key management
let enclaveKey = try SecureEnclave.P256.Signing.PrivateKey()
let signature = try enclaveKey.signature(for: data)
```

For cross-platform code, **swift-crypto** re-exports CryptoKit on Apple platforms and provides identical APIs backed by BoringSSL on Linux/Windows.

### Keychain best practices

Use `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` for maximum protection. Never store secrets in `UserDefaults`. Consider the SwiftSecurity community library for a modern Swift wrapper with compile-time checks and CryptoKit integration.

---

## 11. Swift Macros power the modern frameworks

The macro system (Swift 5.9+, SE-0382/0389/0397) provides compile-time code transformations based on SwiftSyntax trees. **Freestanding macros** (`#expression`, `#declaration`) produce values or declarations. **Attached macros** (`@peer`, `@accessor`, `@member`, `@memberAttribute`, `@extension`, `@body`) transform declarations they're attached to. Multiple roles can combine on a single macro.

`@Observable` is itself a multi-role macro combining member, memberAttribute, and extension roles. It replaces each stored property with a computed property calling `registrar.access()` on get and `registrar.withMutation()` on set, adds an `ObservationRegistrar`, and conforms the type to `Observable`.

Write custom macros when eliminating truly repetitive boilerplate that can't be solved with generics, protocols, or extensions. **Prefer alternatives** (protocol extensions, property wrappers, generics) when possible — macro packages depend on SwiftSyntax which adds significant compile time. Test macros with Point-Free's **swift-macro-testing** library, which provides better ergonomics than Apple's built-in `assertMacroExpansion` and avoids known issues with Swift Testing integration.

Key system-provided macros: `@Observable` (Observation), `@Model` (SwiftData), `#Preview` (Xcode previews), `#expect`/`#require` (Swift Testing), `#Predicate` (Foundation), `@Animatable` (SwiftUI, iOS 26+).

---

## 12. Foundation and standard library reach maturity

### Typed NotificationCenter is the biggest Foundation change

Swift 6.2 introduces **typed notifications** that eliminate string-based names and untyped `userInfo` dictionaries:

```swift
struct UserLoggedIn: NotificationCenter.MainActorMessage {
    let username: String
    let timestamp: Date
}

NotificationCenter.default.post(UserLoggedIn(username: "alice", timestamp: .now))

for await notification in NotificationCenter.default.notifications(of: UserLoggedIn.self) {
    print("User \(notification.username) logged in")
}
```

### Foundation Models framework for on-device AI (iOS 26)

A brand-new framework using Apple's on-device language model with `@Generable` and `@Guide` macros for structured output. Runs entirely on-device with privacy preservation.

### Swift Foundation rewrite is production-ready

The pure-Swift Foundation implementation ships on all platforms. `FoundationEssentials` (core types, no ICU dependency) and `FoundationInternationalization` (localized content) provide cross-platform consistency. **JSONDecoder is 2–5× faster** than the Objective-C implementation. Calendar operations are **1.5–18× faster** in benchmarks.

### Standard library additions by version

**Swift 6.0:** `Int128`/`UInt128` (SE-0425), `BitwiseCopyable` marker protocol (SE-0426), `count(where:)` on sequences (SE-0220), `RangeSet` for non-contiguous ranges (SE-0270).

**Swift 6.2:** `InlineArray<N, Element>` for fixed-size stack allocation (SE-0458), `Span<T>`/`MutableSpan<T>`/`RawSpan` for safe memory access (SE-0453), `Duration.attoseconds` as `Int128` (SE-0457), `enumerated()` returns a `Collection` (SE-0459), key paths for methods (SE-0479), string interpolation default values (SE-0477), `Backtrace` for stack trace capture (SE-0419), clock start points (SE-0473).

```swift
// String interpolation defaults (Swift 6.2)
var name: String? = nil
print("Hello, \(name, default: "Anonymous")!")  // "Hello, Anonymous!"

// InlineArray
var buffer: InlineArray<3, Int> = [1, 2, 3]
buffer[0] = 42  // Stack-allocated, no heap allocation
```

---

## 13. Cross-platform, server-side, and embedded Swift

### Server frameworks embrace structured concurrency

**Hummingbird 2** (v2.19, December 2025) is built entirely on structured concurrency with no `EventLoopFuture` — it's `Sendable` throughout and compiles with `StrictConcurrency=complete`. It works on iOS, macOS, Linux, Wasm, and Android. **Vapor 4** uses `swift-tools-version: 6.0` and supports async/await. Vapor 5 is in active development targeting full structured concurrency with no `EventLoopFuture` APIs.

Apple's Password Monitoring Service migration from Java to Swift on Linux achieved **40% performance improvement**, ~50% Kubernetes capacity reduction, and **85% code reduction** with sub-millisecond p99 latencies for billions of daily requests.

### Embedded Swift targets constrained environments

Embedded Swift is a compilation mode (not a dialect) producing minimal binaries for microcontrollers (ARM Cortex-M, ESP32, RISC-V), WebAssembly, and kernel code. Apple uses it in production for the Secure Enclave Processor. Swift 6.3 brings full String APIs, `InlineArray`/`Span`, improved LLDB debugging, and the `@section`/`@used` attributes. Reflection, existential types, and Objective-C interop are unavailable.

### WebAssembly is officially supported since Swift 6.2

Official WASM SDKs, WasmKit runtime included in the toolchain, and JavaScriptKit for DOM/JS interop. Embedded Swift for WASM produces dramatically smaller binaries.

### Platform compilation uses `canImport` over `os`

Prefer `#if canImport(UIKit)` over `#if os(iOS)` for framework availability checks — it's more accurate and future-proof. Organize platform-specific code in guarded extensions in separate files.

---

## 14. C++ and C interop move toward safety

### Swift-C++ interop supports most common patterns

Enable with `.interoperabilityMode(.Cxx)` in SPM. Supported: non-templated and simple templated functions, constructors, operators, copyable and move-only types, enums, namespaces (mapped to Swift enums), and most standard library types (`std::string`, `std::vector`, `std::map`, `std::optional`, `std::shared_ptr`, `std::unique_ptr`). Not yet supported: `std::function`, `std::variant`, class templates directly (requires typealias), and r-value references.

Swift 6.2 adds **safe C++ interop** where C++ APIs using `std::span` automatically get safe Swift overloads using `Span`/`MutableSpan`.

### C interop gains bounds safety

Add `__counted_by` annotations to C headers (from `<ptrcheck.h>`) and Swift generates both the unsafe signature and a safe `Span`-based overload. Enable with `-enable-experimental-feature SafeInteropWrappers`.

```c
// C header
int calculate_sum(const int *__counted_by(len) values, int len);
```
```swift
// Generated safe overload in Swift:
func calculate_sum(_ values: Span<CInt>) -> CInt
```

---

## Future direction from accepted evolution proposals

Several proposals signal Swift's trajectory. **Async calls in `defer` bodies** (SE-0493) is under review. Per-file default actor isolation (SE-0478) received negative feedback. Embedded Swift continues advancing toward stable status, with the `@c` attribute (SE-0495) and `@export` (SE-0497) for linkage control. The Android SDK matures with daily snapshot builds and an official workgroup. More ergonomic noncopyable types, `MutableSpan` expansions, and deeper concurrency refinements are expected in Swift 6.3+.

The overarching direction is clear: Swift is becoming a systems-to-UI language that provides memory safety, concurrency safety, and performance without forcing developers to choose between them. A greenfield project started today on macOS 26+ and iOS 26+ can leverage the cleanest, most powerful version of Swift ever shipped — with `@Observable` eliminating Combine, typed throws replacing untyped error handling, `Span` replacing unsafe pointers, `@concurrent` making parallelism explicit, and the entire concurrency model becoming approachable by default rather than expert-only.
