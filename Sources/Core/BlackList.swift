import Foundation

/// Manages blacklisted resources to avoid repeated failed access attempts
/// Once a resource fails 14+ times over 1+ week, it's permanently blacklisted and never tried again
class BlackList {
    static let shared = BlackList()
    
    private init() {
        loadFromStorage()
    }
    
    // MARK: - Data Structures
    
    /// Entry in the candidate list with failure tracking
    struct CandidateEntry {
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
    
    // MARK: - Public Methods
    
    /// Check if a resource is blacklisted
    func isBlacklisted(_ mimeiId: MimeiId) -> Bool {
        return blacklist.contains(mimeiId)
    }
    
    /// Record a successful access to a resource
    func recordSuccess(_ mimeiId: MimeiId) {
        let wasInCandidates = candidates.removeValue(forKey: mimeiId) != nil
        
        if wasInCandidates {
            print("[BlackList] Removed \(mimeiId) from candidates after successful access")
        }
        
        // Note: Blacklisted resources are never tried, so they can never succeed
        // The blacklist is permanent - once a resource fails 14+ times over 1+ week, it's permanently ignored
        
        saveToStorage()
    }
    
    /// Record a failed access to a resource
    func recordFailure(_ mimeiId: MimeiId) {
        let now = Date().timeIntervalSince1970
        
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
        
        saveToStorage()
    }
    
    /// Process candidates and move eligible ones to blacklist
    /// A candidate is moved to blacklist if it has failed 14+ times over 1+ week
    /// This should be called periodically to check if candidates should be moved to blacklist
    func processCandidates() {
        let candidatesToProcess = Array(candidates.values)
        
        for entry in candidatesToProcess {
            if shouldMoveToBlacklist(entry) {
                print("[BlackList] Moving \(entry.mimeiId) to blacklist after \(entry.failureCount) failures over \(Date().timeIntervalSince1970 - entry.firstFailureTimestamp) seconds")
                moveToBlacklist(entry.mimeiId)
            }
        }
        
        saveToStorage()
    }
    
    /// Get statistics for monitoring
    func getStats() -> (candidates: Int, blacklisted: Int) {
        return (candidates: candidates.count, blacklisted: blacklist.count)
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
        blacklist.insert(mimeiId)
        print("[BlackList] Permanently blacklisted \(mimeiId) - will never be tried again")
    }
    
    // MARK: - Persistence
    
    /// Load blacklist data from UserDefaults
    private func loadFromStorage() {
        let defaults = UserDefaults.standard
        
        // Load blacklist
        if let blacklistData = defaults.data(forKey: "BlackList.blacklist"),
           let blacklistArray = try? JSONDecoder().decode([String].self, from: blacklistData) {
            blacklist = Set(blacklistArray.map { MimeiId($0) })
        }
        
        // Load candidates
        if let candidatesData = defaults.data(forKey: "BlackList.candidates"),
           let candidatesArray = try? JSONDecoder().decode([CandidateEntry].self, from: candidatesData) {
            candidates = Dictionary(uniqueKeysWithValues: candidatesArray.map { ($0.mimeiId, $0) })
        }
        
        print("[BlackList] Loaded \(blacklist.count) blacklisted items and \(candidates.count) candidates")
    }
    
    /// Save blacklist data to UserDefaults
    private func saveToStorage() {
        let defaults = UserDefaults.standard
        
        // Save blacklist
        let blacklistArray = Array(blacklist).map { $0 }
        if let blacklistData = try? JSONEncoder().encode(blacklistArray) {
            defaults.set(blacklistData, forKey: "BlackList.blacklist")
        }
        
        // Save candidates
        let candidatesArray = Array(candidates.values)
        if let candidatesData = try? JSONEncoder().encode(candidatesArray) {
            defaults.set(candidatesData, forKey: "BlackList.candidates")
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