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

    private let sessionBlockFailureCount = 2

    /// Process-local failure guard. This resets when the app process restarts.
    private var sessionFailureCounts: [MimeiId: Int] = [:]
    private var sessionBlockedResources: Set<MimeiId> = []
    private var lastFailureRecordedAt: [MimeiId: TimeInterval] = [:]
    private let failureDedupWindow: TimeInterval = 20
    
    // MARK: - Public Methods
    
    /// Check if a resource is blacklisted
    func isBlacklisted(_ mimeiId: MimeiId) -> Bool {
        queue.sync {
            sessionBlockedResources.contains(mimeiId) || blacklist.contains(mimeiId)
        }
    }
    
    /// Record a successful access to a resource
    func recordSuccess(_ mimeiId: MimeiId) {
        queue.sync(flags: .barrier) {
            let wasInCandidates = candidates.removeValue(forKey: mimeiId) != nil
            sessionFailureCounts.removeValue(forKey: mimeiId)
            sessionBlockedResources.remove(mimeiId)
            lastFailureRecordedAt.removeValue(forKey: mimeiId)
            
            if wasInCandidates {
                print("[BlackList] Removed \(mimeiId) from candidates after successful access")
            }
            
            // Note: Blacklisted resources are never tried, so they can never succeed
            // The blacklist is permanent - once a resource fails 14+ times over 1+ week, it's permanently ignored
            
            saveToStorageLocked()
        }
    }
    
    /// Record a failed access to a resource
    func recordFailure(_ mimeiId: MimeiId) {
        queue.sync(flags: .barrier) {
            let now = Date().timeIntervalSince1970
            if let lastFailure = lastFailureRecordedAt[mimeiId],
               now - lastFailure < failureDedupWindow {
                return
            }
            lastFailureRecordedAt[mimeiId] = now

            let sessionFailureCount = (sessionFailureCounts[mimeiId] ?? 0) + 1
            sessionFailureCounts[mimeiId] = sessionFailureCount
            if sessionFailureCount >= sessionBlockFailureCount,
               !sessionBlockedResources.contains(mimeiId) {
                sessionBlockedResources.insert(mimeiId)
                print("[BlackList] Temporarily blocked \(mimeiId) for this session after \(sessionFailureCount) failures")
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
    
    // MARK: - Private Methods
    
    /// Check if a candidate should be moved to blacklist
    private func shouldMoveToBlacklist(_ entry: CandidateEntry) -> Bool {
        let oneWeekAgo = Date().timeIntervalSince1970 - (7 * 24 * 60 * 60)
        
        // Move to blacklist if:
        // 1. More than 1 week old AND
        // 2. 14 or more failures
        return entry.firstFailureTimestamp < oneWeekAgo && entry.failureCount >= 14
    }
    
    /// Move a resource from candidates to blacklist (permanent - never tried again)
    private func moveToBlacklist(_ mimeiId: MimeiId) {
        candidates.removeValue(forKey: mimeiId)
        sessionFailureCounts.removeValue(forKey: mimeiId)
        sessionBlockedResources.remove(mimeiId)
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
    }
    
    /// Save blacklist data to UserDefaults first, then mirror to iCloud as backup
    /// UserDefaults is the authoritative store; iCloud is best-effort backup
    private func saveToStorageLocked() {
        let blacklistArray = Array(blacklist).map { $0 }
        let candidatesArray = Array(candidates.values)
        
        // Encode data
        guard let blacklistData = try? JSONEncoder().encode(blacklistArray),
              let candidatesData = try? JSONEncoder().encode(candidatesArray) else {
            print("[BlackList] Failed to encode data for storage")
            return
        }
        
        // Save to UserDefaults first (authoritative)
        let localStore = UserDefaults.standard
        localStore.set(blacklistData, forKey: "BlackList.blacklist")
        localStore.set(candidatesData, forKey: "BlackList.candidates")
        
        // Mirror to iCloud as backup (best-effort; survives reinstallation)
        guard let iCloudStore = iCloudStoreIfAvailable() else { return }
        iCloudStore.set(blacklistData, forKey: "BlackList.blacklist")
        iCloudStore.set(candidatesData, forKey: "BlackList.candidates")
        iCloudStore.synchronize()
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
