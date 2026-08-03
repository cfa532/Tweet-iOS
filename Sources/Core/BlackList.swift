import Foundation

/// Manages blacklisted resources to avoid repeated failed access attempts
/// Once a resource fails 14+ times over 1+ week, it's permanently blacklisted and never tried again
final class BlackList: @unchecked Sendable {
    static let shared = BlackList()
    private let queue = DispatchQueue(label: "com.zz.BlackList", attributes: .concurrent)
    
    private init() {
        loadFromStorage()
    }
    
    // MARK: - Data Structures
    
    /// Entry in the candidate list with failure tracking
    struct CandidateEntry: Sendable {
        let mimeiId: MimeiId
        let failureCount: Int
        let firstFailureTimestamp: TimeInterval
        
        init(mimeiId: MimeiId, failureCount: Int = 1, firstFailureTimestamp: TimeInterval = Date().timeIntervalSince1970) {
            self.mimeiId = mimeiId
            self.failureCount = failureCount
            self.firstFailureTimestamp = firstFailureTimestamp
        }
    }
    
    // MARK: - Properties
    
    /// Resources that have failed but are still candidates for retry
    private var candidates: [MimeiId: CandidateEntry] = [:]
    
    /// Resources that are permanently blacklisted
    private var blacklist: Set<MimeiId> = []
    /// Failure-streak starts retained for relationship cleanup and race checks.
    /// This is separate from candidates because promotion removes the candidate
    /// before a follower/following screen can observe it.
    private var permanentFailureStarts: [MimeiId: TimeInterval] = [:]

    private let sessionBlockFailureCount = 2
    /// How long a 2-strike session block lasts before the resource is retried.
    private let sessionBlockDuration: TimeInterval = 30

    /// Process-local failure guard. This resets when the app process restarts.
    private var sessionFailureCounts: [MimeiId: Int] = [:]
    /// Resources temporarily blocked this session, keyed by the time they were blocked.
    /// Auto-expires after `sessionBlockDuration` (checked in isBlacklisted).
    private var sessionBlockedResources: [MimeiId: Date] = [:]
    private var lastFailureRecordedAt: [MimeiId: TimeInterval] = [:]
    private let failureDedupWindow: TimeInterval = 20
    private let permanentFailureCount = 14
    private let permanentFailureAge: TimeInterval = 7 * 24 * 60 * 60

    // MARK: - Public Methods

    /// Check if a resource is blacklisted
    func isBlacklisted(_ mimeiId: MimeiId) -> Bool {
        queue.sync {
            if blacklist.contains(mimeiId) { return true }
            // Session block auto-expires after `sessionBlockDuration`. Expired entries
            // are left in place (harmless — they read as not-blocked) and get overwritten
            // on the next block or cleared by recordSuccess.
            if let blockedAt = sessionBlockedResources[mimeiId],
               Date().timeIntervalSince(blockedAt) < sessionBlockDuration {
                return true
            }
            return false
        }
    }
    
    /// Record a successful access to a resource
    func recordSuccess(_ mimeiId: MimeiId) {
        queue.sync(flags: .barrier) {
            let wasInCandidates = candidates.removeValue(forKey: mimeiId) != nil
            sessionFailureCounts.removeValue(forKey: mimeiId)
            sessionBlockedResources.removeValue(forKey: mimeiId)
            lastFailureRecordedAt.removeValue(forKey: mimeiId)
            
            if wasInCandidates {
                print("[BlackList] Removed \(mimeiId) from candidates after successful access")
            }
            
            // Note: Blacklisted resources are never tried, so they can never succeed
            // The blacklist is permanent - once a resource fails 14+ times over 1+ week, it's permanently ignored
            
            saveToStorageLocked()
        }
    }
    
    /// Records a failed access. Returns the uninterrupted streak's start time
    /// only when this call newly promotes the resource to the permanent list.
    @discardableResult
    func recordFailure(_ mimeiId: MimeiId) -> TimeInterval? {
        queue.sync(flags: .barrier) {
            guard !blacklist.contains(mimeiId) else { return nil }

            let now = Date().timeIntervalSince1970
            if let lastFailure = lastFailureRecordedAt[mimeiId],
               now - lastFailure < failureDedupWindow {
                return nil
            }
            lastFailureRecordedAt[mimeiId] = now

            let sessionFailureCount = (sessionFailureCounts[mimeiId] ?? 0) + 1
            sessionFailureCounts[mimeiId] = sessionFailureCount
            if sessionFailureCount >= sessionBlockFailureCount {
                // (Re)start the 30s session-block window. Each subsequent failure refreshes it.
                sessionBlockedResources[mimeiId] = Date()
                print("[BlackList] Temporarily blocked \(mimeiId) for \(Int(sessionBlockDuration))s after \(sessionFailureCount) failures")
            }
            
            if let existingEntry = candidates[mimeiId] {
                // Update existing candidate entry
                let newFailureCount = existingEntry.failureCount + 1
                let newEntry = CandidateEntry(
                    mimeiId: mimeiId,
                    failureCount: newFailureCount,
                    firstFailureTimestamp: existingEntry.firstFailureTimestamp
                )
                candidates[mimeiId] = newEntry
                
                print("[BlackList] Resource \(mimeiId) failed \(newFailureCount) times since \(Date(timeIntervalSince1970: existingEntry.firstFailureTimestamp))")
                
                // Check if it should be moved to blacklist (14+ failures over 1+ week)
                if shouldMoveToBlacklist(newEntry) {
                    moveToBlacklist(mimeiId)
                    saveToStorageLocked()
                    return newEntry.firstFailureTimestamp
                }
            } else {
                // Create new candidate entry
                let newEntry = CandidateEntry(
                    mimeiId: mimeiId,
                    failureCount: 1,
                    firstFailureTimestamp: now
                )
                candidates[mimeiId] = newEntry
                print("[BlackList] Added \(mimeiId) to candidates after first failure")
            }
            
            saveToStorageLocked()
            return nil
        }
    }
    
    /// Process candidates and move eligible ones to blacklist
    /// A candidate is moved to blacklist if it has failed 14+ times over 1+ week
    /// This should be called periodically to check if candidates should be moved to blacklist
    func processCandidates() {
        queue.sync(flags: .barrier) {
            let candidatesToProcess = Array(candidates.values)
            
            for entry in candidatesToProcess {
                if shouldMoveToBlacklist(entry) {
                    print("[BlackList] Moving \(entry.mimeiId) to blacklist after \(entry.failureCount) failures over \(Date().timeIntervalSince1970 - entry.firstFailureTimestamp) seconds")
                    moveToBlacklist(entry.mimeiId)
                }
            }
            
            saveToStorageLocked()
        }
    }
    
    /// Get statistics for monitoring
    func getStats() -> (candidates: Int, blacklisted: Int) {
        queue.sync {
            (candidates: candidates.count, blacklisted: blacklist.count)
        }
    }

    func permanentFailureStartedAt(_ mimeiId: MimeiId) -> TimeInterval? {
        queue.sync {
            permanentFailureStarts[mimeiId]
        }
    }

    /// A relationship newer than the failure streak proves that the server row
    /// is not the stale row this blacklist decision was based on.
    func restoreAfterNewerRelationship(_ mimeiId: MimeiId) {
        queue.sync(flags: .barrier) {
            blacklist.remove(mimeiId)
            candidates.removeValue(forKey: mimeiId)
            permanentFailureStarts.removeValue(forKey: mimeiId)
            sessionFailureCounts.removeValue(forKey: mimeiId)
            sessionBlockedResources.removeValue(forKey: mimeiId)
            lastFailureRecordedAt.removeValue(forKey: mimeiId)
            saveToStorageLocked()
        }
    }
    
    // MARK: - Private Methods
    
    /// Check if a candidate should be moved to blacklist
    private func shouldMoveToBlacklist(_ entry: CandidateEntry) -> Bool {
        let failureAge = Date().timeIntervalSince1970 - entry.firstFailureTimestamp
        return failureAge >= permanentFailureAge &&
            entry.failureCount >= permanentFailureCount
    }
    
    /// Move a resource from candidates to blacklist (permanent - never tried again)
    private func moveToBlacklist(_ mimeiId: MimeiId) {
        if let failureStartedAt = candidates[mimeiId]?.firstFailureTimestamp {
            permanentFailureStarts[mimeiId] = failureStartedAt
        }
        candidates.removeValue(forKey: mimeiId)
        sessionFailureCounts.removeValue(forKey: mimeiId)
        sessionBlockedResources.removeValue(forKey: mimeiId)
        lastFailureRecordedAt.removeValue(forKey: mimeiId)
        blacklist.insert(mimeiId)
        print("[BlackList] Permanently blacklisted \(mimeiId) - will never be tried again")
    }
    
    // MARK: - Persistence

    private func iCloudStoreIfAvailable() -> NSUbiquitousKeyValueStore? {
        // The target currently has no KVS entitlement. Initializing
        // NSUbiquitousKeyValueStore without it logs a client bug during launch.
        nil
    }
    
    /// Load blacklist data preferring UserDefaults, with iCloud as backup
    /// UserDefaults is the source of truth; iCloud is only a secondary backup
    private func loadFromStorage() {
        let localStore = UserDefaults.standard
        let iCloudStore = iCloudStoreIfAvailable()
        
        // Sync iCloud in background; we still read local first
        iCloudStore?.synchronize()
        
        // Load blacklist - prefer UserDefaults, fallback to iCloud
        if let blacklistData = localStore.data(forKey: "BlackList.blacklist"),
           let blacklistArray = try? JSONDecoder().decode([String].self, from: blacklistData) {
            queue.sync(flags: .barrier) {
                blacklist = Set(blacklistArray.map { MimeiId($0) })
                print("[BlackList] Loaded \(blacklist.count) blacklisted items from UserDefaults")
            }
        } else if let blacklistData = iCloudStore?.data(forKey: "BlackList.blacklist"),
                  let blacklistArray = try? JSONDecoder().decode([String].self, from: blacklistData) {
            queue.sync(flags: .barrier) {
                blacklist = Set(blacklistArray.map { MimeiId($0) })
                print("[BlackList] Loaded \(blacklist.count) blacklisted items from iCloud (local missing)")
            }
        }
        
        // Load candidates - prefer UserDefaults, fallback to iCloud
        if let candidatesData = localStore.data(forKey: "BlackList.candidates"),
           let candidatesArray = try? JSONDecoder().decode([CandidateEntry].self, from: candidatesData) {
            queue.sync(flags: .barrier) {
                candidates = Dictionary(uniqueKeysWithValues: candidatesArray.map { ($0.mimeiId, $0) })
                print("[BlackList] Loaded \(candidates.count) candidates from UserDefaults")
            }
        } else if let candidatesData = iCloudStore?.data(forKey: "BlackList.candidates"),
                  let candidatesArray = try? JSONDecoder().decode([CandidateEntry].self, from: candidatesData) {
            queue.sync(flags: .barrier) {
                candidates = Dictionary(uniqueKeysWithValues: candidatesArray.map { ($0.mimeiId, $0) })
                print("[BlackList] Loaded \(candidates.count) candidates from iCloud (local missing)")
            }
        }

        if let cleanupData = localStore.data(forKey: "BlackList.permanentFailureStarts"),
           let cleanupEntries = try? JSONDecoder().decode([String: TimeInterval].self, from: cleanupData) {
            queue.sync(flags: .barrier) {
                permanentFailureStarts = cleanupEntries
            }
        }
    }
    
    /// Save blacklist data to UserDefaults first, then mirror to iCloud as backup.
    /// UserDefaults is the authoritative store; iCloud is best-effort backup.
    ///
    /// Snapshots are taken under the caller's barrier (cheap, consistent), then the
    /// encode + UserDefaults write run on a utility queue. Previously the encode and
    /// UserDefaults.set ran synchronously while holding the reader/writer barrier;
    /// once the UI stopped freezing, video/image loads began firing recordFailure
    /// from many threads at once, contending that lock and trapping
    /// (EXC_BREAKPOINT) inside UserDefaults.set.
    /// Persist blacklist + candidates to UserDefaults.
    ///
    /// The encode + write MUST run on the main thread. A previous version ran them on a
    /// background `@Sendable` `DispatchQueue.global` queue; once the feed stopped freezing
    /// and video/image loads began firing `recordFailure` from many threads, that
    /// background write trapped with `EXC_BREAKPOINT` inside `UserDefaults.set`. This was
    /// not heap corruption (Address/Thread Sanitizer found nothing; disabling persistence
    /// fully fixed the app with no other crashes) — empirically a background-thread
    /// `UserDefaults` write in this Swift 6 target. Main-thread writes are stable and are
    /// the canonical pattern. Snapshots are still taken under the caller's reader/writer
    /// barrier so the encoded view is consistent.
    private func saveToStorageLocked() {
        let blacklistArray = Array(blacklist).map { $0 }
        let candidatesArray = Array(candidates.values)
        let cleanupEntries = permanentFailureStarts

        DispatchQueue.main.async {
            guard let blacklistData = try? JSONEncoder().encode(blacklistArray),
                  let candidatesData = try? JSONEncoder().encode(candidatesArray),
                  let cleanupData = try? JSONEncoder().encode(cleanupEntries) else {
                print("[BlackList] Failed to encode data for storage")
                return
            }
            UserDefaults.standard.set(blacklistData, forKey: "BlackList.blacklist")
            UserDefaults.standard.set(candidatesData, forKey: "BlackList.candidates")
            UserDefaults.standard.set(cleanupData, forKey: "BlackList.permanentFailureStarts")
        }
    }
}

// MARK: - Codable Extensions

extension BlackList.CandidateEntry: Codable {
    enum CodingKeys: String, CodingKey {
        case mimeiId, failureCount, firstFailureTimestamp
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let mimeiIdString = try container.decode(String.self, forKey: .mimeiId)
        mimeiId = MimeiId(mimeiIdString)
        failureCount = try container.decode(Int.self, forKey: .failureCount)
        firstFailureTimestamp = try container.decode(TimeInterval.self, forKey: .firstFailureTimestamp)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mimeiId, forKey: .mimeiId)
        try container.encode(failureCount, forKey: .failureCount)
        try container.encode(firstFailureTimestamp, forKey: .firstFailureTimestamp)
    }
}
