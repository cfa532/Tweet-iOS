//
//  AgentTokenManager.swift
//  Tweet
//
//  Manages cryptographic tokens for AI agent authentication.
//  Allows AI agents to post on behalf of users without requiring passwords.
//

import Foundation
import CryptoKit
import Security

/// Represents an agent token that can be exported and used by AI agents
struct AgentToken: Codable {
    let version: Int
    let mimeiId: String
    let privateKey: String  // Base64-encoded Ed25519 private key
    let publicKey: String   // Base64-encoded Ed25519 public key
    let createdAt: Int64    // Unix timestamp in milliseconds
    let scope: [String]     // Allowed actions: ["post", "comment", "like"]
    
    /// Serialize token to a portable string format
    func export() -> String? {
        guard let jsonData = try? JSONEncoder().encode(self) else { return nil }
        return jsonData.base64EncodedString()
    }
    
    /// Deserialize token from portable string format
    static func from(_ tokenString: String) -> AgentToken? {
        guard let data = Data(base64Encoded: tokenString),
              let token = try? JSONDecoder().decode(AgentToken.self, from: data) else {
            return nil
        }
        return token
    }
}

/// Authentication data to include with agent requests
struct AgentAuth: Codable {
    let mimeiId: String
    let timestamp: Int64
    let signature: String  // Base64-encoded signature
}

/// Manages agent token generation, storage, and verification
class AgentTokenManager {
    static let shared = AgentTokenManager()
    
    private let keychainService = "com.tweet.agent-token"
    private let privateKeyTag = "agent-private-key"
    
    private init() {}
    
    // MARK: - Key Generation
    
    /// Generate a new Ed25519 keypair for agent authentication
    func generateKeyPair() -> (privateKey: Curve25519.Signing.PrivateKey, publicKey: Curve25519.Signing.PublicKey) {
        let privateKey = Curve25519.Signing.PrivateKey()
        return (privateKey, privateKey.publicKey)
    }
    
    /// Generate a complete agent token for the given user
    func generateToken(for mimeiId: String, scope: [String] = ["post", "comment"]) -> AgentToken {
        let keyPair = generateKeyPair()
        
        let privateKeyBase64 = keyPair.privateKey.rawRepresentation.base64EncodedString()
        let publicKeyBase64 = keyPair.publicKey.rawRepresentation.base64EncodedString()
        
        return AgentToken(
            version: 1,
            mimeiId: mimeiId,
            privateKey: privateKeyBase64,
            publicKey: publicKeyBase64,
            createdAt: Int64(Date().timeIntervalSince1970 * 1000),
            scope: scope
        )
    }
    
    // MARK: - Keychain Storage
    
    /// Save private key to Keychain for the given user
    func savePrivateKey(_ privateKey: Curve25519.Signing.PrivateKey, for mimeiId: String) -> Bool {
        let keyData = privateKey.rawRepresentation
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "\(privateKeyTag)-\(mimeiId)",
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        
        SecItemDelete(query as CFDictionary)
        
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }
    
    /// Load private key from Keychain for the given user
    func loadPrivateKey(for mimeiId: String) -> Curve25519.Signing.PrivateKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "\(privateKeyTag)-\(mimeiId)",
            kSecReturnData as String: true
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let keyData = result as? Data,
              let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData) else {
            return nil
        }
        
        return privateKey
    }
    
    /// Delete private key from Keychain for the given user
    func deletePrivateKey(for mimeiId: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "\(privateKeyTag)-\(mimeiId)"
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
    
    /// Check if user has an existing agent token
    func hasExistingToken(for mimeiId: String) -> Bool {
        return loadPrivateKey(for: mimeiId) != nil
    }
    
    // MARK: - Request Signing
    
    /// Sign request data with the private key from an agent token
    static func signRequest(data: [String: Any], token: AgentToken) -> AgentAuth? {
        guard let privateKeyData = Data(base64Encoded: token.privateKey),
              let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData) else {
            return nil
        }
        
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        
        var signableData = data
        signableData["mimeiId"] = token.mimeiId
        signableData["timestamp"] = timestamp
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: signableData, options: .sortedKeys),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return nil
        }
        
        guard let signature = try? privateKey.signature(for: Data(jsonString.utf8)) else {
            return nil
        }
        
        return AgentAuth(
            mimeiId: token.mimeiId,
            timestamp: timestamp,
            signature: signature.base64EncodedString()
        )
    }
    
    // MARK: - Signature Verification (for testing)
    
    /// Verify a signature using the public key (for local testing)
    static func verifySignature(data: [String: Any], auth: AgentAuth, publicKeyBase64: String) -> Bool {
        guard let publicKeyData = Data(base64Encoded: publicKeyBase64),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData),
              let signatureData = Data(base64Encoded: auth.signature) else {
            return false
        }
        
        var signableData = data
        signableData["mimeiId"] = auth.mimeiId
        signableData["timestamp"] = auth.timestamp
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: signableData, options: .sortedKeys),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return false
        }
        
        return publicKey.isValidSignature(signatureData, for: Data(jsonString.utf8))
    }
    
    // MARK: - Token Export/Import Helpers
    
    /// Export token as a copyable string for the user
    func exportToken(_ token: AgentToken) -> String? {
        return token.export()
    }
    
    /// Create a new token and return both the exportable string and public key
    func createAndExportToken(for mimeiId: String, scope: [String] = ["post", "comment"]) -> (tokenString: String, publicKey: String)? {
        let token = generateToken(for: mimeiId, scope: scope)
        
        guard let tokenString = token.export() else { return nil }
        
        guard let privateKeyData = Data(base64Encoded: token.privateKey),
              let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData) else {
            return nil
        }
        _ = savePrivateKey(privateKey, for: mimeiId)
        
        return (tokenString, token.publicKey)
    }
    
    /// Regenerate token (revokes old token by creating new keypair)
    func regenerateToken(for mimeiId: String, scope: [String] = ["post", "comment"]) -> (tokenString: String, publicKey: String)? {
        _ = deletePrivateKey(for: mimeiId)
        return createAndExportToken(for: mimeiId, scope: scope)
    }
}
