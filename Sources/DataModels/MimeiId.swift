import Foundation

/// MimeiId is a type alias for String representing a Mimei ID
public typealias MimeiId = String

// MARK: - Extensions

extension String {
    /// Convert string to MimeiId
    var asMimeiId: MimeiId {
        return self
    }
}

extension MimeiId {
    /// Convert to string
    var stringValue: String {
        return self
    }
} 