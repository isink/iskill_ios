# Skiller Multi-Device Favorites Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver offline-first, account-scoped favorites that merge guest and Supabase data, retry safely, remain isolated across accounts, and converge across devices at defined sync triggers.

**Architecture:** Keep the existing `Favorite` model as the guest store, add account-scoped cache and coalesced pending-mutation models, and route every favorite read/write through one `@MainActor` coordinator. A protocol-backed Supabase adapter performs authenticated reads, bulk upserts, and filtered deletes; the coordinator serializes sync, overlays unsent local intent over remote state, and publishes UI status.

**Tech Stack:** iOS 17+, Swift 5.9, SwiftUI, SwiftData, XCTest, XcodeGen 2.44.1, supabase-swift 2.x, PostgreSQL RLS.

**Spec:** `docs/superpowers/specs/2026-08-24-favorites-sync-design.md`

## Global Constraints

- Preserve the existing `Favorite` entity unchanged so installed users' local favorites remain readable as guest favorites.
- Add no package dependency and no Supabase Realtime subscription.
- Do not add background tasks or periodic polling.
- Never place access tokens, user emails, Supabase keys, or raw server responses in logs, SwiftData, tests, commits, or docs.
- `project.yml` is the Xcode project source of truth; regenerate `Skiller.xcodeproj` with XcodeGen after target/source changes.
- The original checkout contains pre-existing dirty changes, including `ProfileView`, `RootTabView`, both localization files, and pipeline enrichment. Do not overwrite, discard, or silently commit them on `master`.
- Execute in an isolated worktree containing an explicit snapshot commit of the current dirty baseline. Never merge or cherry-pick that branch into `master` without a separate user decision.
- Apply `014_favorites_sync.sql` only after the linked migration list proves `001` through `013` are already applied and `014` is the only pending migration.
- Deploy the database migration before releasing an App build that writes `public.favorites`.
- Use test-driven development: run each focused test once while failing for the stated reason, implement the minimum behavior, then run it passing.

---

### Task 0: Create a Safe Implementation Worktree With the Current Baseline

**Files:**
- Read: current tracked working tree under `/Users/wenhandong/Projects/active/Skiller`
- Create outside repository: `/Users/wenhandong/.codex/worktrees/Skiller/favorites-sync`
- Create temporary patch: `/tmp/skiller-favorites-sync-existing.patch`

**Interfaces:**
- Consumes: the committed design/implementation-plan documents plus the current tracked dirty diff.
- Produces: clean branch `feat/favorites-sync` whose first branch-only commit exactly snapshots the existing dirty baseline; the original checkout remains unchanged.

- [ ] **Step 1: Read the worktree safety instructions**

Run:

```bash
sed -n '1,360p' /Users/wenhandong/.codex/plugins/cache/superpowers-marketplace/superpowers/6.3.0/skills/using-git-worktrees/SKILL.md
```

Expected: instructions require a safe location, ignore verification when relevant, dependency setup, and a clean baseline check.

- [ ] **Step 2: Verify the original dirty baseline has no untracked files**

Run:

```bash
cd /Users/wenhandong/Projects/active/Skiller
git status --short --branch
git ls-files --others --exclude-standard
```

Expected: the known tracked modifications/deletion are present and the untracked-file command prints nothing. If untracked files appear, stop before worktree creation so they are not omitted from the snapshot.

- [ ] **Step 3: Capture the tracked baseline and create the feature worktree**

Run:

```bash
cd /Users/wenhandong/Projects/active/Skiller
git diff HEAD --binary > /tmp/skiller-favorites-sync-existing.patch
mkdir -p /Users/wenhandong/.codex/worktrees/Skiller
git worktree add /Users/wenhandong/.codex/worktrees/Skiller/favorites-sync -b feat/favorites-sync
git -C /Users/wenhandong/.codex/worktrees/Skiller/favorites-sync apply --index /tmp/skiller-favorites-sync-existing.patch
```

Expected: the new worktree is on `feat/favorites-sync`; the original checkout still has the same dirty status.

- [ ] **Step 4: Verify the snapshot matches before committing it on the feature branch**

Run:

```bash
cd /Users/wenhandong/Projects/active/Skiller
git diff HEAD --binary > /tmp/skiller-favorites-sync-original.patch
git -C /Users/wenhandong/.codex/worktrees/Skiller/favorites-sync diff --cached HEAD --binary > /tmp/skiller-favorites-sync-worktree.patch
cmp /tmp/skiller-favorites-sync-original.patch /tmp/skiller-favorites-sync-worktree.patch
```

Expected: `cmp` exits 0.

- [ ] **Step 5: Commit only the branch-local baseline snapshot**

Run:

```bash
git -C /Users/wenhandong/.codex/worktrees/Skiller/favorites-sync commit -m "chore: snapshot current Skiller app baseline"
git -C /Users/wenhandong/.codex/worktrees/Skiller/favorites-sync status --short --branch
git -C /Users/wenhandong/Projects/active/Skiller status --short --branch
```

Expected: feature worktree is clean; original checkout retains its pre-existing dirty files unchanged.

- [ ] **Step 6: Seed one pre-upgrade guest favorite on the simulator**

From the clean baseline feature worktree, generate/build/install the current App, open it without clearing simulator data, and favorite one known Skill while signed out. Record only the Skill ID in the task notes.

Expected: the heart remains selected after relaunch. Leave this installed data intact so Task 9 can install the sync build over it and prove the existing `Favorite` store survives the model-container expansion. If the existing `actool`/`ibtoold` blocker prevents the baseline build, record that limitation now and do not later claim upgrade-path verification.

---

### Task 1: Add the Test Target and Account-Scoped Local Persistence

**Files:**
- Modify: `project.yml`
- Modify (generated): `Skiller.xcodeproj/xcshareddata/xcschemes/Skiller.xcscheme`
- Create: `Skiller/Models/AccountFavorite.swift`
- Create: `Skiller/Models/PendingFavoriteMutation.swift`
- Modify: `Skiller/Services/FavoritesStore.swift`
- Create: `SkillerTests/FavoritesStoreTests.swift`

**Interfaces:**
- Consumes: existing guest `Favorite` and SwiftData `ModelContext`.
- Produces: `FavoriteScope`, `PendingFavoriteChange`, account cache CRUD, guest migration, mutation coalescing, remote-snapshot replacement, and account cleanup APIs used by the coordinator.

- [ ] **Step 1: Declare the unit-test target in `project.yml`**

Change the app scheme and add the test target:

```yaml
    scheme:
      testTargets:
        - SkillerTests
      gatherCoverageData: false

  SkillerTests:
    type: bundle.unit-test
    platform: iOS
    deploymentTarget: "17.0"
    sources:
      - path: SkillerTests
    dependencies:
      - target: Skiller
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.iskill.app.tests
        GENERATE_INFOPLIST_FILE: YES
```

- [ ] **Step 2: Write failing persistence tests**

Create `SkillerTests/FavoritesStoreTests.swift` with an in-memory container and these concrete expectations:

```swift
import SwiftData
import XCTest
@testable import Skiller

@MainActor
final class FavoritesStoreTests: XCTestCase {
    private func makeStore() throws -> FavoritesStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Favorite.self,
            AccountFavorite.self,
            PendingFavoriteMutation.self,
            configurations: config
        )
        return FavoritesStore(container.mainContext)
    }

    func testMigrateGuestMovesFavoritesAndQueuesAdds() throws {
        let store = try makeStore()
        _ = try store.toggle("guest-a", in: .guest)
        _ = try store.toggle("guest-b", in: .guest)

        try store.migrateGuest(to: "user-a")

        XCTAssertEqual(try store.favoriteIDs(in: .guest), [])
        XCTAssertEqual(try store.favoriteIDs(in: .account("user-a")), ["guest-a", "guest-b"])
        XCTAssertEqual(
            Set(try store.pendingChanges(for: "user-a").map(\.skillId)),
            ["guest-a", "guest-b"]
        )
    }

    func testAccountsRemainIsolated() throws {
        let store = try makeStore()
        _ = try store.toggle("shared-skill", in: .account("user-a"))
        _ = try store.toggle("other-skill", in: .account("user-b"))

        XCTAssertEqual(try store.favoriteIDs(in: .account("user-a")), ["shared-skill"])
        XCTAssertEqual(try store.favoriteIDs(in: .account("user-b")), ["other-skill"])
    }

    func testRepeatedToggleCoalescesToOneFinalMutation() throws {
        let store = try makeStore()
        _ = try store.toggle("skill-a", in: .account("user-a"))
        _ = try store.toggle("skill-a", in: .account("user-a"))
        _ = try store.toggle("skill-a", in: .account("user-a"))

        let pending = try store.pendingChanges(for: "user-a")
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.desiredFavorite, true)
    }

    func testRemoteReplacementDoesNotTouchAnotherAccount() throws {
        let store = try makeStore()
        try store.replaceAccountFavorites(for: "user-a", with: ["remote-a"])
        try store.replaceAccountFavorites(for: "user-b", with: ["remote-b"])
        try store.replaceAccountFavorites(for: "user-a", with: ["remote-c"])

        XCTAssertEqual(try store.favoriteIDs(in: .account("user-a")), ["remote-c"])
        XCTAssertEqual(try store.favoriteIDs(in: .account("user-b")), ["remote-b"])
    }

    func testClearAccountDataLeavesGuestAndOtherAccountUntouched() throws {
        let store = try makeStore()
        _ = try store.toggle("guest", in: .guest)
        _ = try store.toggle("a", in: .account("user-a"))
        _ = try store.toggle("b", in: .account("user-b"))

        try store.clearAccountData(userId: "user-a")

        XCTAssertEqual(try store.favoriteIDs(in: .guest), ["guest"])
        XCTAssertEqual(try store.favoriteIDs(in: .account("user-a")), [])
        XCTAssertEqual(try store.favoriteIDs(in: .account("user-b")), ["b"])
        XCTAssertTrue(try store.pendingChanges(for: "user-a").isEmpty)
    }
}
```

- [ ] **Step 3: Generate the project and verify the tests fail because the new types do not exist**

Run:

```bash
cd /Users/wenhandong/.codex/worktrees/Skiller/favorites-sync
xcodegen generate
xcodebuild -project Skiller.xcodeproj -scheme Skiller -destination 'platform=iOS Simulator,id=AB8B3F28-88E2-4386-A75E-8437348CED7C' -derivedDataPath /tmp/skiller-favorites-sync-dd test -only-testing:SkillerTests/FavoritesStoreTests
```

Expected: compile failure naming `AccountFavorite`, `PendingFavoriteMutation`, `FavoriteScope`, or the new store methods. A simulator/toolchain failure is not the expected red state and must be diagnosed before continuing.

- [ ] **Step 4: Add the two SwiftData models**

Create `AccountFavorite.swift`:

```swift
import Foundation
import SwiftData

@Model
final class AccountFavorite {
    @Attribute(.unique) var recordKey: String
    var userId: String
    var skillId: String
    var createdAt: Date

    init(userId: String, skillId: String, createdAt: Date = .now) {
        self.recordKey = Self.key(userId: userId, skillId: skillId)
        self.userId = userId
        self.skillId = skillId
        self.createdAt = createdAt
    }

    static func key(userId: String, skillId: String) -> String {
        "\(userId)|\(skillId)"
    }
}
```

Create `PendingFavoriteMutation.swift`:

```swift
import Foundation
import SwiftData

@Model
final class PendingFavoriteMutation {
    @Attribute(.unique) var recordKey: String
    var userId: String
    var skillId: String
    var desiredFavorite: Bool
    var updatedAt: Date
    var attemptCount: Int
    var lastError: String?

    init(userId: String, skillId: String, desiredFavorite: Bool) {
        self.recordKey = AccountFavorite.key(userId: userId, skillId: skillId)
        self.userId = userId
        self.skillId = skillId
        self.desiredFavorite = desiredFavorite
        self.updatedAt = .now
        self.attemptCount = 0
        self.lastError = nil
    }
}

struct PendingFavoriteChange: Equatable, Sendable {
    let recordKey: String
    let userId: String
    let skillId: String
    let desiredFavorite: Bool
}
```

- [ ] **Step 5: Implement the local store contract**

Keep `RecentViewStore` and `LastSeenStore` unchanged. Replace only the favorite portion of `FavoritesStore.swift` with methods matching this contract:

```swift
enum FavoriteScope: Equatable {
    case unknown
    case guest
    case account(String)
}

@MainActor
final class FavoritesStore {
    init(_ context: ModelContext)
    func favoriteIDs(in scope: FavoriteScope) throws -> Set<String>
    @discardableResult func toggle(_ skillId: String, in scope: FavoriteScope) throws -> Bool
    func migrateGuest(to userId: String) throws
    func pendingChanges(for userId: String) throws -> [PendingFavoriteChange]
    func clearPending(recordKeys: Set<String>) throws
    func markPendingFailed(recordKeys: Set<String>, message: String) throws
    func replaceAccountFavorites(for userId: String, with skillIDs: Set<String>) throws
    func clearAccountData(userId: String) throws
}
```

Implementation rules:

```swift
// Unknown scope never writes and reads as empty.
// Guest toggle inserts/deletes Favorite only.
// Account toggle inserts/deletes AccountFavorite and upserts exactly one
// PendingFavoriteMutation with the resulting desired state before one save().
// migrateGuest creates AccountFavorite only when that recordKey is absent,
// queues/upserts desired=true even when the account row already exists,
// deletes all guest Favorite rows, then calls save() once.
// replaceAccountFavorites deletes/inserts only rows matching userId.
// clearAccountData deletes AccountFavorite and PendingFavoriteMutation rows
// matching userId, leaving Favorite and other users untouched.
```

Do not swallow `ModelContext.save()` errors; every mutating method is `throws`.

- [ ] **Step 6: Run the focused persistence tests**

Run the Task 1 test command again.

Expected: all `FavoritesStoreTests` pass.

- [ ] **Step 7: Commit Task 1**

Run:

```bash
git add project.yml Skiller.xcodeproj/xcshareddata/xcschemes/Skiller.xcscheme Skiller/Models/AccountFavorite.swift Skiller/Models/PendingFavoriteMutation.swift Skiller/Services/FavoritesStore.swift SkillerTests/FavoritesStoreTests.swift
git commit -m "feat: add account-scoped favorite persistence"
```

---

### Task 2: Add the Supabase Adapter and Secure Database Migration

**Files:**
- Create: `Skiller/Services/FavoritesRemoteAPI.swift`
- Create: `SkillerTests/FavoritesRemoteAPITests.swift`
- Create: `pipeline/supabase/migrations/014_favorites_sync.sql`
- Modify: `pipeline/supabase/schema.sql`

**Interfaces:**
- Consumes: authenticated Supabase session and existing `public.favorites` composite primary key.
- Produces: `FavoritesRemoteClient` with fetch/upsert/delete methods plus matching RLS/grants for migrated and fresh databases.

- [ ] **Step 1: Write the failing row-encoding test**

Create `SkillerTests/FavoritesRemoteAPITests.swift`:

```swift
import XCTest
@testable import Skiller

final class FavoritesRemoteAPITests: XCTestCase {
    func testInsertRowUsesDatabaseColumnNames() throws {
        let row = RemoteFavoriteInsert(userId: "user-a", skillId: "skill-a")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: String]
        )
        XCTAssertEqual(object, ["user_id": "user-a", "skill_id": "skill-a"])
    }
}
```

- [ ] **Step 2: Verify the test fails because `RemoteFavoriteInsert` is absent**

Run:

```bash
xcodegen generate
xcodebuild -project Skiller.xcodeproj -scheme Skiller -destination 'platform=iOS Simulator,id=AB8B3F28-88E2-4386-A75E-8437348CED7C' -derivedDataPath /tmp/skiller-favorites-sync-dd test -only-testing:SkillerTests/FavoritesRemoteAPITests
```

Expected: test-target compile failure for `RemoteFavoriteInsert`.

- [ ] **Step 3: Implement the remote protocol and Supabase adapter**

Create `FavoritesRemoteAPI.swift` with these types and calls:

```swift
import Foundation
import Supabase

protocol FavoritesRemoteClient: Sendable {
    func fetchSkillIDs(userId: String) async throws -> Set<String>
    func upsert(userId: String, skillIDs: Set<String>) async throws
    func delete(userId: String, skillIDs: Set<String>) async throws
}

struct RemoteFavoriteInsert: Encodable, Sendable {
    let userId: String
    let skillId: String

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case skillId = "skill_id"
    }
}

private struct RemoteFavoriteRow: Decodable {
    let skillId: String
    enum CodingKeys: String, CodingKey { case skillId = "skill_id" }
}

struct FavoritesRemoteAPI: FavoritesRemoteClient {
    func fetchSkillIDs(userId: String) async throws -> Set<String> {
        let rows: [RemoteFavoriteRow] = try await supabase
            .from("favorites")
            .select("skill_id")
            .eq("user_id", value: userId)
            .execute()
            .value
        return Set(rows.map(\.skillId))
    }

    func upsert(userId: String, skillIDs: Set<String>) async throws {
        guard !skillIDs.isEmpty else { return }
        let rows = skillIDs.sorted().map { RemoteFavoriteInsert(userId: userId, skillId: $0) }
        try await supabase
            .from("favorites")
            .upsert(rows, onConflict: "user_id,skill_id")
            .execute()
    }

    func delete(userId: String, skillIDs: Set<String>) async throws {
        guard !skillIDs.isEmpty else { return }
        try await supabase
            .from("favorites")
            .delete()
            .eq("user_id", value: userId)
            .in("skill_id", values: skillIDs.sorted())
            .execute()
    }
}
```

- [ ] **Step 4: Add the idempotent migration**

Create `014_favorites_sync.sql` with this exact security behavior:

```sql
begin;

alter table public.favorites enable row level security;

revoke all on table public.favorites from anon;
grant select, insert, update, delete on table public.favorites to authenticated;

drop policy if exists "favorites owner" on public.favorites;
create policy "favorites owner" on public.favorites
  for all
  to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;
  delete from public.favorites where user_id = uid;
  delete from auth.users where id = uid;
end;
$$;

revoke all on function public.delete_my_account() from public;
grant execute on function public.delete_my_account() to authenticated;

commit;
```

Mirror the same grants, policy, and `delete_my_account()` definition in `pipeline/supabase/schema.sql` so a fresh database behaves like a migrated one.

- [ ] **Step 5: Run focused tests and SQL static checks**

Run:

```bash
xcodegen generate
xcodebuild -project Skiller.xcodeproj -scheme Skiller -destination 'platform=iOS Simulator,id=AB8B3F28-88E2-4386-A75E-8437348CED7C' -derivedDataPath /tmp/skiller-favorites-sync-dd test -only-testing:SkillerTests/FavoritesRemoteAPITests
rg -n 'to authenticated|auth.uid|delete from public.favorites|delete from auth.users' pipeline/supabase/migrations/014_favorites_sync.sql pipeline/supabase/schema.sql
git diff --check
```

Expected: focused test passes; both SQL files contain authenticated policy and favorites-before-user deletion; diff check is clean.

- [ ] **Step 6: Commit Task 2**

Run:

```bash
git add Skiller/Services/FavoritesRemoteAPI.swift SkillerTests/FavoritesRemoteAPITests.swift pipeline/supabase/migrations/014_favorites_sync.sql pipeline/supabase/schema.sql
git commit -m "feat: add secure remote favorites API"
```

---

### Task 3: Implement Scope Activation, Guest Migration, and Immediate Toggle State

**Files:**
- Create: `Skiller/Services/FavoriteSyncCoordinator.swift`
- Create: `SkillerTests/Support/FakeFavoritesRemoteClient.swift`
- Create: `SkillerTests/FavoriteSyncCoordinatorTests.swift`

**Interfaces:**
- Consumes: `FavoritesStore`, `FavoriteScope`, and `FavoritesRemoteClient`.
- Produces: observable active IDs/status and `configure(context:)`, `activate(_:)`, `toggle(_:)`, and `sync()` methods.

- [ ] **Step 1: Create the reusable remote Fake**

Create `SkillerTests/Support/FakeFavoritesRemoteClient.swift`:

```swift
import Foundation
@testable import Skiller

actor FakeFavoritesRemoteClient: FavoritesRemoteClient {
    enum Failure: Error { case requested }

    private var remoteByUser: [String: Set<String>] = [:]
    private var failFetch = false
    private var failUpsert = false
    private var failDelete = false
    private var requestDelay: UInt64 = 0
    private(set) var currentRequests = 0
    private(set) var maxConcurrentRequests = 0

    func fetchSkillIDs(userId: String) async throws -> Set<String> {
        try await beginRequest(shouldFail: failFetch)
        defer { endRequest() }
        return remoteByUser[userId] ?? []
    }

    func upsert(userId: String, skillIDs: Set<String>) async throws {
        try await beginRequest(shouldFail: failUpsert)
        defer { endRequest() }
        remoteByUser[userId, default: []].formUnion(skillIDs)
    }

    func delete(userId: String, skillIDs: Set<String>) async throws {
        try await beginRequest(shouldFail: failDelete)
        defer { endRequest() }
        remoteByUser[userId, default: []].subtract(skillIDs)
    }

    func setRemote(_ ids: Set<String>, for userId: String) { remoteByUser[userId] = ids }
    func setFailFetch(_ value: Bool) { failFetch = value }
    func setFailUpsert(_ value: Bool) { failUpsert = value }
    func setFailDelete(_ value: Bool) { failDelete = value }
    func setRequestDelay(_ value: UInt64) { requestDelay = value }
    func snapshot(for userId: String) -> Set<String> { remoteByUser[userId] ?? [] }
    func maximumConcurrency() -> Int { maxConcurrentRequests }
    func waitForRequestToStart() async {
        while currentRequests == 0 { await Task.yield() }
    }

    private func beginRequest(shouldFail: Bool) async throws {
        currentRequests += 1
        maxConcurrentRequests = max(maxConcurrentRequests, currentRequests)
        if requestDelay > 0 { try await Task.sleep(nanoseconds: requestDelay) }
        if shouldFail {
            currentRequests -= 1
            throw Failure.requested
        }
    }

    private func endRequest() { currentRequests -= 1 }
}
```

- [ ] **Step 2: Write failing coordinator activation/toggle tests**

Add tests that construct an in-memory container, a store, and Fake:

```swift
func testUnknownScopePublishesNoFavorites() async throws {
    let harness = try Harness()
    try harness.store.replaceAccountFavorites(for: "user-a", with: ["private-a"])
    await harness.coordinator.activate(.unknown)
    XCTAssertEqual(harness.coordinator.favoriteIDs, [])
    XCTAssertFalse(harness.coordinator.isReady)
}

func testGuestActivationUsesExistingFavoriteRows() async throws {
    let harness = try Harness()
    _ = try harness.store.toggle("guest-a", in: .guest)
    await harness.coordinator.activate(.guest)
    XCTAssertEqual(harness.coordinator.favoriteIDs, ["guest-a"])
}

func testAccountActivationMigratesGuestBeforeSync() async throws {
    let harness = try Harness()
    _ = try harness.store.toggle("guest-a", in: .guest)
    await harness.remote.setRemote(["remote-a"], for: "user-a")
    await harness.coordinator.activate(.account("user-a"))
    XCTAssertEqual(harness.coordinator.favoriteIDs, ["guest-a", "remote-a"])
    XCTAssertEqual(try harness.store.favoriteIDs(in: .guest), [])
}

func testToggleUpdatesPublishedStateBeforeFailedUploadCanRollbackIt() async throws {
    let harness = try Harness()
    await harness.remote.setFailUpsert(true)
    await harness.coordinator.activate(.account("user-a"))
    harness.coordinator.toggle("skill-a")
    XCTAssertTrue(harness.coordinator.favoriteIDs.contains("skill-a"))
}
```

Define `Harness` in the same test file so its SwiftData container remains alive for each test:

```swift
@MainActor
private struct Harness {
    let container: ModelContainer
    let store: FavoritesStore
    let remote: FakeFavoritesRemoteClient
    let coordinator: FavoriteSyncCoordinator

    init() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: Favorite.self,
            AccountFavorite.self,
            PendingFavoriteMutation.self,
            configurations: config
        )
        store = FavoritesStore(container.mainContext)
        remote = FakeFavoritesRemoteClient()
        coordinator = FavoriteSyncCoordinator(store: store, remote: remote)
    }
}
```

Mark `FavoriteSyncCoordinatorTests` as `@MainActor` so published state assertions and coordinator calls stay on the main executor.

- [ ] **Step 3: Verify coordinator tests fail because the coordinator is absent**

Run:

```bash
xcodegen generate
xcodebuild -project Skiller.xcodeproj -scheme Skiller -destination 'platform=iOS Simulator,id=AB8B3F28-88E2-4386-A75E-8437348CED7C' -derivedDataPath /tmp/skiller-favorites-sync-dd test -only-testing:SkillerTests/FavoriteSyncCoordinatorTests
```

Expected: compile failure for `FavoriteSyncCoordinator`.

- [ ] **Step 4: Implement observable scope activation and immediate toggles**

Create the coordinator with this public surface:

```swift
@MainActor
final class FavoriteSyncCoordinator: ObservableObject {
    @Published private(set) var scope: FavoriteScope = .unknown
    @Published private(set) var favoriteIDs: Set<String> = []
    @Published private(set) var isSyncing = false
    @Published private(set) var pendingCount = 0
    @Published private(set) var lastSyncError: String?

    var isReady: Bool { scope != .unknown }

    init(remote: any FavoritesRemoteClient = FavoritesRemoteAPI())
    init(store: FavoritesStore, remote: any FavoritesRemoteClient)
    func configure(context: ModelContext)
    func activate(_ newScope: FavoriteScope) async
    func toggle(_ skillId: String)
    func sync() async
}
```

At this task, `activate(_:)` must publish the new scope's local IDs before awaiting network work. `activate(.account)` then migrates guest data, reloads published IDs, and calls the sync entry point. Repeated auth events are safe because an empty guest store produces no duplicate migration. `toggle` must synchronously mutate the local store and published set, refresh `pendingCount`, then launch `Task { await sync() }`. If local persistence throws, leave the published set unchanged and expose only a non-sensitive local-save error; do not pretend the toggle succeeded. Leave the sync engine as the smallest implementation required for the account-activation union test: upload pending additions, fetch remote, overlay current pending changes, and replace the account cache.

- [ ] **Step 5: Run the focused coordinator tests**

Expected: the four activation/toggle tests pass.

- [ ] **Step 6: Commit Task 3**

Run:

```bash
git add Skiller/Services/FavoriteSyncCoordinator.swift SkillerTests/Support/FakeFavoritesRemoteClient.swift SkillerTests/FavoriteSyncCoordinatorTests.swift
git commit -m "feat: coordinate scoped favorite state"
```

---

### Task 4: Complete Retry, Overlay, Partial-Success, and Serialization Behavior

**Files:**
- Modify: `Skiller/Services/FavoriteSyncCoordinator.swift`
- Modify: `SkillerTests/FavoriteSyncCoordinatorTests.swift`

**Interfaces:**
- Consumes: coordinator surface from Task 3 and store pending-snapshot APIs.
- Produces: lossless sync loop with independent add/delete outcomes, local overlay, trigger coalescing, and user-facing status values.

- [ ] **Step 1: Add failing sync-behavior tests**

Import `Combine`, then add these cases with exact assertions:

```swift
func testFailedUploadKeepsPendingAndLocalFavorite() async throws {
    let harness = try Harness()
    await harness.coordinator.activate(.account("user-a"))
    await harness.remote.setFailUpsert(true)
    harness.coordinator.toggle("skill-a")
    await harness.coordinator.sync()

    XCTAssertEqual(harness.coordinator.favoriteIDs, ["skill-a"])
    XCTAssertEqual(harness.coordinator.pendingCount, 1)
    XCTAssertNotNil(harness.coordinator.lastSyncError)
}

func testPendingDeleteOverlaysStaleRemoteFetch() async throws {
    let harness = try Harness()
    await harness.remote.setRemote(["skill-a"], for: "user-a")
    await harness.coordinator.activate(.account("user-a"))
    await harness.remote.setFailDelete(true)
    harness.coordinator.toggle("skill-a")
    await harness.coordinator.sync()

    XCTAssertEqual(harness.coordinator.favoriteIDs, [])
    XCTAssertEqual(harness.coordinator.pendingCount, 1)
}

func testSuccessfulRetryClearsOnlySuccessfulMutations() async throws {
    let harness = try Harness()
    await harness.coordinator.activate(.account("user-a"))
    await harness.remote.setFailUpsert(true)
    harness.coordinator.toggle("add-a")
    await harness.coordinator.sync()
    XCTAssertEqual(harness.coordinator.pendingCount, 1)

    await harness.remote.setFailUpsert(false)
    await harness.coordinator.sync()
    let remoteIDs = await harness.remote.snapshot(for: "user-a")
    XCTAssertEqual(harness.coordinator.pendingCount, 0)
    XCTAssertEqual(remoteIDs, ["add-a"])
}

func testAddSuccessAndDeleteFailureClearOnlyAddMutation() async throws {
    let harness = try Harness()
    await harness.remote.setRemote(["remove-a"], for: "user-a")
    await harness.coordinator.activate(.account("user-a"))
    await harness.remote.setFailDelete(true)

    harness.coordinator.toggle("add-a")
    harness.coordinator.toggle("remove-a")
    await harness.coordinator.sync()

    let pending = try harness.store.pendingChanges(for: "user-a")
    let remoteIDs = await harness.remote.snapshot(for: "user-a")
    XCTAssertEqual(Set(pending.map(\.skillId)), ["remove-a"])
    XCTAssertEqual(remoteIDs, ["add-a", "remove-a"])
    XCTAssertEqual(harness.coordinator.favoriteIDs, ["add-a"])
}

func testConcurrentTriggersNeverOverlapRemoteRequests() async throws {
    let harness = try Harness()
    await harness.remote.setRequestDelay(20_000_000)
    await harness.coordinator.activate(.account("user-a"))
    let first = Task { await harness.coordinator.sync() }
    let second = Task { await harness.coordinator.sync() }
    await first.value
    await second.value
    let maximumConcurrency = await harness.remote.maximumConcurrency()
    XCTAssertEqual(maximumConcurrency, 1)
}

func testScopeSwitchDuringRequestNeverPublishesPreviousAccount() async throws {
    let harness = try Harness()
    await harness.remote.setRemote(["remote-a"], for: "user-a")
    await harness.remote.setRemote(["remote-b"], for: "user-b")
    await harness.remote.setRequestDelay(20_000_000)

    let activateA = Task { await harness.coordinator.activate(.account("user-a")) }
    await harness.remote.waitForRequestToStart()
    var publishedAfterSwitch: [Set<String>] = []
    let observation = harness.coordinator.$favoriteIDs.sink {
        publishedAfterSwitch.append($0)
    }
    let activateB = Task { await harness.coordinator.activate(.account("user-b")) }
    await activateA.value
    await activateB.value

    XCTAssertEqual(harness.coordinator.scope, .account("user-b"))
    XCTAssertEqual(harness.coordinator.favoriteIDs, ["remote-b"])
    XCTAssertFalse(publishedAfterSwitch.contains { $0.contains("remote-a") })
    withExtendedLifetime(observation) {}
}
```

- [ ] **Step 2: Run the focused tests and confirm behavioral failures**

Expected: assertions fail for retained pending state, overlay, retry cleanup, or max concurrency; the failure must not be a compile/toolchain error.

- [ ] **Step 3: Implement `sync()` as a serialized rerunnable loop**

Use these rules in `FavoriteSyncCoordinator`:

```swift
// Keep the current loop in syncTask. If sync is already active, set
// rerunRequested = true, await that same task, and only then return.
// The owning task sets isSyncing = true and repeats syncOnce(userId:) until
// no rerun is requested. Every caller awaiting sync() therefore waits until
// the active round and its requested rerun have both finished.
// syncOnce snapshots pending changes, attempts adds and deletes independently,
// clears only each successful group, and calls markPendingFailed with a
// non-sensitive summary for each failed group before fetching remote.
// Before replacing the local account cache, overlay every still-pending change:
// desired=true inserts the skill ID; desired=false removes it.
// A round may update only the cache for the user ID it started with. It may
// publish favoriteIDs/status only if scope is still that same account.
// If scope changes during a request, the loop re-reads scope and runs the new
// account next; no old-account IDs may be published after the switch.
// Any failure sets lastSyncError to a localized, non-sensitive summary.
// A fully successful round with zero pending clears lastSyncError.
// defer always resets isSyncing and refreshes pendingCount/favoriteIDs.
```

Use one helper with this exact contract:

```swift
static func overlay(
    remoteIDs: Set<String>,
    pending: [PendingFavoriteChange]
) -> Set<String>
```

- [ ] **Step 4: Run all local-store and coordinator tests**

Run:

```bash
xcodegen generate
xcodebuild -project Skiller.xcodeproj -scheme Skiller -destination 'platform=iOS Simulator,id=AB8B3F28-88E2-4386-A75E-8437348CED7C' -derivedDataPath /tmp/skiller-favorites-sync-dd test -only-testing:SkillerTests/FavoritesStoreTests -only-testing:SkillerTests/FavoriteSyncCoordinatorTests
```

Expected: all selected tests pass with zero failures.

- [ ] **Step 5: Commit Task 4**

Run:

```bash
git add Skiller/Services/FavoriteSyncCoordinator.swift SkillerTests/FavoriteSyncCoordinatorTests.swift
git commit -m "feat: retry and reconcile favorite sync"
```

---

### Task 5: Bind Auth and App Lifecycle to the Coordinator

**Files:**
- Modify: `Skiller/App/SkillerApp.swift`
- Modify: `Skiller/Services/AuthService.swift`
- Modify: `Skiller/Views/RootTabView.swift`
- Create: `SkillerTests/AuthFavoriteScopeTests.swift`

**Interfaces:**
- Consumes: `AuthService.State`, app `ModelContext`, and `FavoriteSyncCoordinator`.
- Produces: one coordinator environment object configured once; auth state maps to `.unknown`, `.guest`, or `.account(userId)`; foreground activation triggers sync.

- [ ] **Step 1: Write the failing auth-to-scope mapping tests**

Create `AuthFavoriteScopeTests.swift`:

```swift
import XCTest
@testable import Skiller

final class AuthFavoriteScopeTests: XCTestCase {
    func testUnknownMapsToUnknownFavorites() {
        XCTAssertEqual(AuthService.State.unknown.favoriteScope, .unknown)
    }

    func testSignedOutMapsToGuestFavorites() {
        XCTAssertEqual(AuthService.State.signedOut.favoriteScope, .guest)
    }

    func testSignedInMapsToUserUUID() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let identity = AuthService.UserIdentity(
            userId: id,
            provider: .apple,
            displayName: "Test",
            login: "test",
            avatarUrl: nil,
            providerToken: nil
        )
        XCTAssertEqual(AuthService.State.signedIn(identity).favoriteScope, .account(id.uuidString))
    }
}
```

- [ ] **Step 2: Run the test and verify `favoriteScope` is missing**

Run the focused `AuthFavoriteScopeTests`; expect a compile failure for that property.

- [ ] **Step 3: Add the state mapping and environment wiring**

Add to `AuthService.State`:

```swift
var favoriteScope: FavoriteScope {
    switch self {
    case .unknown: return .unknown
    case .signedOut: return .guest
    case .signedIn(let identity): return .account(identity.userId.uuidString)
    }
}
```

In `SkillerApp`:

```swift
@StateObject private var favoriteSync = FavoriteSyncCoordinator()
```

Inject it next to AuthService and extend the model container:

```swift
.environmentObject(favoriteSync)
.modelContainer(for: [
    Favorite.self,
    AccountFavorite.self,
    PendingFavoriteMutation.self,
    LastSeen.self,
    RecentView.self,
])
```

In `RootTabView`, use `@Environment(\.modelContext)`, `@EnvironmentObject var auth`, and `@EnvironmentObject var favoriteSync`. Configure once in `.task`, activate the current scope, and react to `auth.state` changes with `.onChange`.

In `SkillerApp`'s existing `didBecomeActive` notification handler, keep `recordAppOpen()` and additionally call `await favoriteSync.sync()` in the same `Task`. Do not move the existing app-open analytics responsibility into `RootTabView`.

- [ ] **Step 4: Run the mapping tests and app compile**

Run:

```bash
xcodegen generate
xcodebuild -project Skiller.xcodeproj -scheme Skiller -destination 'platform=iOS Simulator,id=AB8B3F28-88E2-4386-A75E-8437348CED7C' -derivedDataPath /tmp/skiller-favorites-sync-dd test -only-testing:SkillerTests/AuthFavoriteScopeTests
```

Expected: mapping tests pass and app target compiles.

- [ ] **Step 5: Commit Task 5 on the isolated branch**

Run:

```bash
git add Skiller/App/SkillerApp.swift Skiller/Services/AuthService.swift Skiller/Views/RootTabView.swift SkillerTests/AuthFavoriteScopeTests.swift
git commit -m "feat: activate favorite sync from auth lifecycle"
```

This commit is safe because the branch-only baseline commit already contains the pre-existing `RootTabView` changes.

---

### Task 6: Route Favorite UI Through the Coordinator

**Files:**
- Modify: `Skiller/Components/SkillCard.swift`
- Modify: `Skiller/Views/SkillDetailView.swift`
- Modify: `Skiller/Views/FavoritesView.swift`
- Modify: `Skiller/Views/ProfileView.swift`
- Modify: `Skiller/Resources/en.lproj/Localizable.strings`
- Modify: `Skiller/Resources/zh-Hans.lproj/Localizable.strings`

**Interfaces:**
- Consumes: coordinator environment object and its published `favoriteIDs`, `isReady`, `isSyncing`, `pendingCount`, and `lastSyncError`.
- Produces: immediate scoped hearts, refreshable favorites, non-destructive sync errors, status/retry UI, and accurate footprint count.

- [ ] **Step 1: Replace direct local queries in cards and detail**

In both views:

```swift
@EnvironmentObject private var favoriteSync: FavoriteSyncCoordinator

private var isFavorited: Bool {
    favoriteSync.favoriteIDs.contains(skill.id) // use skillId in detail
}
```

Replace `FavoritesStore(ctx).toggle(...)` with:

```swift
favoriteSync.toggle(skill.id) // use skillId in detail
```

Remove `@Query [Favorite]` and the query-building initializer code. Keep `modelContext` in `SkillDetailView` because `RecentViewStore.record` still uses it.

- [ ] **Step 2: Make `FavoritesView` scope-aware and refreshable**

Replace its `@Query` source with the coordinator. Drive loading from sorted `favoriteIDs` and add:

```swift
.task(id: favoriteSync.favoriteIDs) { await loadSkills() }
.task { await favoriteSync.sync() }
.refreshable {
    await favoriteSync.sync()
    await loadSkills()
}
```

State order must be:

```swift
if !favoriteSync.isReady { skeletons }
else if loading { skeletons }
else if favoriteSync.favoriteIDs.isEmpty { true empty state }
else { cached/loaded skill cards }
```

When `lastSyncError != nil`, render a compact banner above the list using “Some favorites are waiting to sync” and a “Retry sync” button. A failed sync must not replace a non-empty `skills` list with the empty state.

- [ ] **Step 3: Add profile sync status and use the active count**

Replace the direct favorite query/count with `favoriteSync.favoriteIDs.count`. Inside the signed-in account card add one status row:

```swift
if favoriteSync.isSyncing {
    Label("Syncing favorites…", systemImage: "arrow.triangle.2.circlepath")
} else if favoriteSync.pendingCount > 0 {
    Button { Task { await favoriteSync.sync() } } label: {
        Label(
            String(format: String(localized: "Favorites pending sync: %lld"), favoriteSync.pendingCount),
            systemImage: "exclamationmark.arrow.triangle.2.circlepath"
        )
    }
} else if favoriteSync.lastSyncError != nil {
    Button { Task { await favoriteSync.sync() } } label: {
        Label("Favorite sync failed — retry", systemImage: "exclamationmark.triangle")
    }
} else {
    Label("Favorites synced", systemImage: "checkmark.icloud")
}
```

Use existing colors and 11–12 point typography; do not restructure the account card or reintroduce the removed submission section.

- [ ] **Step 4: Add exact English and Chinese strings**

Add the same keys to both files:

```text
"Favorites synced"
"Syncing favorites…"
"Favorites pending sync: %lld"
"Favorite sync failed — retry"
"Some favorites are waiting to sync"
"Retry sync"
```

Chinese values:

```text
"收藏已同步"
"正在同步收藏…"
"%lld 项收藏待同步"
"收藏同步失败，点此重试"
"部分收藏正在等待同步"
"重试同步"
```

- [ ] **Step 5: Run localization and full unit-test checks**

Run:

```bash
plutil -lint Skiller/Resources/en.lproj/Localizable.strings Skiller/Resources/zh-Hans.lproj/Localizable.strings
xcodegen generate
xcodebuild -project Skiller.xcodeproj -scheme Skiller -destination 'platform=iOS Simulator,id=AB8B3F28-88E2-4386-A75E-8437348CED7C' -derivedDataPath /tmp/skiller-favorites-sync-dd test
```

Expected: both localization files are valid and every unit test passes.

- [ ] **Step 6: Commit Task 6 on the isolated branch**

Run:

```bash
git add Skiller/Components/SkillCard.swift Skiller/Views/SkillDetailView.swift Skiller/Views/FavoritesView.swift Skiller/Views/ProfileView.swift Skiller/Resources/en.lproj/Localizable.strings Skiller/Resources/zh-Hans.lproj/Localizable.strings
git commit -m "feat: expose favorite sync in the app UI"
```

This commit preserves the earlier branch snapshot of the existing profile/localization edits and adds only the sync delta on top.

---

### Task 7: Make Account Deletion Remove Only the Target Account's Favorites

**Files:**
- Modify: `Skiller/Services/AuthService.swift`
- Modify: `Skiller/Services/FavoriteSyncCoordinator.swift`
- Modify: `Skiller/Views/ProfileView.swift`
- Modify: `Skiller/Resources/en.lproj/Localizable.strings`
- Modify: `Skiller/Resources/zh-Hans.lproj/Localizable.strings`
- Modify: `SkillerTests/FavoriteSyncCoordinatorTests.swift`

**Interfaces:**
- Consumes: successful `delete_my_account()` RPC and coordinator account-cleanup method.
- Produces: user ID capture before deletion, a coordinator-owned targeted local cleanup API after RPC success, and copy that accurately describes synced-favorite deletion.

- [ ] **Step 1: Add the failing coordinator cleanup test**

Add to `FavoriteSyncCoordinatorTests`:

```swift
func testClearLocalAccountDataRemovesOnlyTargetUser() async throws {
    let harness = try Harness()
    _ = try harness.store.toggle("guest", in: .guest)
    _ = try harness.store.toggle("a", in: .account("user-a"))
    _ = try harness.store.toggle("b", in: .account("user-b"))

    try harness.coordinator.clearLocalAccountData(userId: "user-a")

    XCTAssertEqual(try harness.store.favoriteIDs(in: .guest), ["guest"])
    XCTAssertEqual(try harness.store.favoriteIDs(in: .account("user-a")), [])
    XCTAssertEqual(try harness.store.favoriteIDs(in: .account("user-b")), ["b"])
    XCTAssertTrue(try harness.store.pendingChanges(for: "user-a").isEmpty)
}
```

Run the focused coordinator test and expect a compile failure because `clearLocalAccountData(userId:)` does not exist yet.

- [ ] **Step 2: Return the deleted identity from AuthService**

Use this contract:

```swift
@discardableResult
func deleteAccount() async throws -> UUID {
    guard case .signedIn(let identity) = state else {
        throw AuthServiceError.notSignedIn
    }
    try await supabase.rpc("delete_my_account").execute()
    try? await supabase.auth.signOut()
    return identity.userId
}
```

Define `AuthServiceError.notSignedIn` locally with a non-sensitive localized description.

- [ ] **Step 3: Add coordinator cleanup and invoke it only after RPC success**

Add this coordinator method:

```swift
func clearLocalAccountData(userId: String) throws {
    try store.clearAccountData(userId: userId)
    if scope == .account(userId) {
        favoriteIDs = []
        pendingCount = 0
        lastSyncError = nil
    }
}
```

In `ProfileView.deleteAccount()`:

```swift
let deletedUserId = try await auth.deleteAccount()
try favoriteSync.clearLocalAccountData(userId: deletedUserId.uuidString)
```

If the RPC throws, retain the existing account cache and pending operations. If local cleanup throws after remote deletion, surface the delete failure text and keep the error visible; the next launch must still hide the deleted account because Auth is signed out.

- [ ] **Step 4: Correct the deletion confirmation copy**

Replace the current key/value with:

```text
English: "Will permanently delete your Skiller account and synced favorites. Guest favorites and other accounts stay on this device. This cannot be undone."
Chinese: "将永久删除你的 Skiller 账号及已同步收藏。本机游客收藏和其他账号数据不受影响。此操作不可撤销。"
```

- [ ] **Step 5: Run focused cleanup tests and localization lint**

Expected: targeted cleanup test passes; both strings files pass `plutil -lint`.

- [ ] **Step 6: Commit Task 7**

Run:

```bash
git add Skiller/Services/AuthService.swift Skiller/Services/FavoriteSyncCoordinator.swift Skiller/Views/ProfileView.swift Skiller/Resources/en.lproj/Localizable.strings Skiller/Resources/zh-Hans.lproj/Localizable.strings SkillerTests/FavoriteSyncCoordinatorTests.swift
git commit -m "feat: delete synced favorites with account"
```

---

### Task 8: Apply and Verify the Linked Supabase Migration

**Files:**
- Read: `pipeline/supabase/migrations/014_favorites_sync.sql`
- External change: linked Supabase schema, only migration `014`.

**Interfaces:**
- Consumes: reviewed SQL from Task 2 and existing Supabase CLI link metadata.
- Produces: authenticated CRUD grants, owner-only RLS, and favorites cleanup in account deletion.

- [ ] **Step 1: Verify CLI and linked migration state without changing the database**

Run:

```bash
cd /Users/wenhandong/.codex/worktrees/Skiller/favorites-sync/pipeline
supabase --version
supabase migration list --linked
```

Expected: local and remote columns show `001` through `013` applied; only `014` is pending locally. If any older migration is pending or any remote-only migration appears, stop without pushing and report the mismatch.

- [ ] **Step 2: Lint the linked database before mutation**

Run:

```bash
supabase db lint --linked --level warning
```

Expected: no error that implicates `public.favorites`, `delete_my_account`, or migration ordering. Preserve the output as pre-change evidence without exposing credentials.

- [ ] **Step 3: Dry-run and then push only the reviewed pending migration**

Run:

```bash
supabase db push --linked --dry-run
supabase db push --linked
```

Expected: the dry run names only `014_favorites_sync.sql`; the real push then applies only that migration successfully. If the dry run lists anything else, stop without pushing.

- [ ] **Step 4: Read back migration state and database lint**

Run:

```bash
supabase migration list --linked
supabase db lint --linked --level warning
```

Expected: local and remote both show `014`; no new database lint error.

- [ ] **Step 5: Verify RLS with two test identities through the App**

Using Apple and GitHub test identities, complete these checks without printing session tokens:

1. Account A favorites one known Skill and refreshes; it remains selected.
2. Sign out, sign into account B; account A's favorite is absent.
3. Account B favorites a different Skill.
4. Return to account A and refresh; only A's server state appears.
5. Record account B's test UUID locally, delete account B, and confirm its favorites do not reappear on a fresh login attempt/new account.
6. In the Supabase SQL editor, query `count(*)` for that captured B UUID in `public.favorites`; verify the count is zero without copying the UUID or query result into repository files or logs.

Expected: no cross-account read/write and the direct database readback proves deletion removed B's remote favorites.

---

### Task 9: Full Verification and Handoff

**Files:**
- Verify all feature files and the original checkout status.
- Do not merge, deploy an App build, or modify the original checkout.

**Interfaces:**
- Consumes: completed feature branch and migrated database.
- Produces: evidence-backed build/test/UI report plus a clean decision point for integration.

- [ ] **Step 1: Read completion-verification instructions**

Run:

```bash
sed -n '1,360p' /Users/wenhandong/.codex/plugins/cache/superpowers-marketplace/superpowers/6.3.0/skills/verification-before-completion/SKILL.md
```

- [ ] **Step 2: Run every automated check fresh**

Run:

```bash
cd /Users/wenhandong/.codex/worktrees/Skiller/favorites-sync
plutil -lint Skiller/Resources/en.lproj/Localizable.strings Skiller/Resources/zh-Hans.lproj/Localizable.strings
xcodegen generate
xcodebuild -project Skiller.xcodeproj -scheme Skiller -destination 'platform=iOS Simulator,id=AB8B3F28-88E2-4386-A75E-8437348CED7C' -derivedDataPath /tmp/skiller-favorites-sync-final test
xcodebuild -project Skiller.xcodeproj -scheme Skiller -configuration Debug -destination 'platform=iOS Simulator,id=AB8B3F28-88E2-4386-A75E-8437348CED7C' -derivedDataPath /tmp/skiller-favorites-sync-final build
git diff --check
```

Expected: two localization passes, all tests pass with zero failures, build exits 0, and diff check prints nothing. If Xcode's `actool`/`ibtoold` hangs as in the prior audit, directly run `actool --version`; report the toolchain blocker and do not claim a full build pass.

- [ ] **Step 3: Run the Chinese simulator golden path**

Install the Debug app and test in `zh-Hans`:

1. Install the feature Debug build over the baseline build from Task 0 without uninstalling or erasing simulator data; the seeded guest favorite remains selected, and a newly toggled guest favorite also survives relaunch.
2. Login migrates the guest favorite and shows `收藏已同步` after success.
3. Disable network; add, remove, and toggle the same Skill three times; verify one final pending state.
4. Restore network and tap retry; pending count reaches zero without heart rollback.
5. Sign out; account favorites disappear and guest range is shown.
6. Sign into the other account; no first-account cache is visible.
7. Bring another signed-in simulator/device to foreground or refresh Favorites; cloud state converges.
8. Trigger a fetch failure; cached favorites remain visible with the retry banner.
9. Delete the test account; local account cache is removed and remote favorites do not return.

Expected: every path matches the design and no empty state appears solely because of a network error.

- [ ] **Step 4: Verify branch boundaries and original-worktree preservation**

Run:

```bash
git status --short --branch
git log --oneline --decorate master..HEAD
git -C /Users/wenhandong/Projects/active/Skiller status --short --branch
```

Expected: feature worktree is clean after task commits; original checkout still contains its pre-existing dirty changes and no feature merge.

- [ ] **Step 5: Request code review before integration**

Read and use `superpowers:requesting-code-review`. Review the complete feature-branch diff against `docs/superpowers/specs/2026-08-24-favorites-sync-design.md`, then fix and re-run verification for any P0/P1 findings.

- [ ] **Step 6: Present integration choices without taking one automatically**

Read and use `superpowers:finishing-a-development-branch`. Report the branch name, worktree path, commits, automated evidence, simulator evidence, database migration state, and any toolchain limitation. Ask the user whether to integrate, keep the branch, or discard it; do not merge or delete the worktree without their choice. State explicitly that discarding the branch does not roll back the already-applied database migration and would require a separately reviewed migration if rollback were desired.
