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

    func setRemote(_ ids: Set<String>, for userId: String) {
        remoteByUser[userId] = ids
    }

    func setFailFetch(_ value: Bool) { failFetch = value }
    func setFailUpsert(_ value: Bool) { failUpsert = value }
    func setFailDelete(_ value: Bool) { failDelete = value }
    func setRequestDelay(_ value: UInt64) { requestDelay = value }
    func snapshot(for userId: String) -> Set<String> { remoteByUser[userId] ?? [] }
    func maximumConcurrency() -> Int { maxConcurrentRequests }

    func waitForRequestToStart() async {
        while currentRequests == 0 {
            await Task.yield()
        }
    }

    private func beginRequest(shouldFail: Bool) async throws {
        currentRequests += 1
        maxConcurrentRequests = max(maxConcurrentRequests, currentRequests)
        if requestDelay > 0 {
            try await Task.sleep(nanoseconds: requestDelay)
        }
        if shouldFail {
            currentRequests -= 1
            throw Failure.requested
        }
    }

    private func endRequest() {
        currentRequests -= 1
    }
}
