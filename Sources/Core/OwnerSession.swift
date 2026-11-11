//
//  OwnerSession.swift
//  Tweet
//
//  The backend writes every object under one application identity, so it cannot
//  tell users apart on its own. What identifies a caller is a Leither login
//  session: the app signs in to the node itself and passes the session it gets
//  as `usersid`; the node resolves it to a Leither user id and performs a write
//  only when that id controls the account being written.
//  See TweetBackendApp/session_entries.go.
//
//  Two kinds of user hold a session in two ways:
//  - An owner has access to the node's machine. `tweet-owner.sh` there issues a
//    Leither key, which this app scans or imports ("pairing") and then signs in
//    with. No username or password is involved.
//  - A guest uses a node by its owner's courtesy and signs in with a username and
//    password that Leither keeps on that node.
//

import CryptoKit
import Foundation
import Security

// MARK: - Owner identity

enum OwnerIdentityError: LocalizedError {
    case invalid
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalid:
            return NSLocalizedString("That is not a valid node identity.", comment: "Owner pairing error")
        case .keychain(let status):
            return String(format: NSLocalizedString("The Keychain refused the identity (%d).", comment: "Owner pairing error"), status)
        }
    }
}

/// The key a node issued to one of its owners, and the passports signed with it.
struct OwnerIdentity: Codable, Sendable {
    let nodeID: String
    /// The Leither user id derived from the key. The node lists it as an owner.
    let uid: String
    let username: String
    /// The key's certificate, as Leither encoded it. It travels in every passport.
    let signerInfo: String
    /// Ed25519 seed.
    let seed: Data
    /// The account this identity controls, known once the node has signed it in.
    var accountID: String?

    /// Reads what `tweet-owner.sh` produced: the identity file, or the compact
    /// text carried by its QR code.
    static func parse(_ data: Data) throws -> OwnerIdentity {
        guard data.count <= 64 * 1024,
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OwnerIdentityError.invalid
        }
        if raw["t"] as? String == "twq" {
            return try parseCompact(raw)
        }
        guard raw["type"] as? String == "tweet-owner-identity",
              raw["version"] as? Int == 1,
              raw["key_type"] as? String == "sodiumv2",
              let nodeID = raw["node_id"] as? String, isIdentifier(nodeID),
              let uid = raw["uid"] as? String, isIdentifier(uid),
              let username = raw["username"] as? String, !username.isEmpty,
              let signerInfo = raw["signer_info"] as? String, !signerInfo.isEmpty,
              let encodedPublic = raw["public_key"] as? String, let publicKey = decodeBase64URL(encodedPublic),
              let encodedPrivate = raw["private_key"] as? String, let secret = decodeBase64URL(encodedPrivate),
              secret.count == 32 || secret.count == 64 else {
            throw OwnerIdentityError.invalid
        }
        // Leither stores the seed followed by the public key; CryptoKit wants the
        // seed alone. A file whose halves disagree would sign passports the node
        // rejects without saying why.
        let seed = Data(secret.prefix(32))
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed),
              key.publicKey.rawRepresentation == publicKey else {
            throw OwnerIdentityError.invalid
        }
        return OwnerIdentity(nodeID: nodeID, uid: uid, username: username, signerInfo: signerInfo, seed: seed)
    }

    /// The QR code leaves out the certificate, which is ~770 characters of Go gob
    /// repeating the user id and public key around constant type metadata. Only
    /// its signature is unique, so the code carries that and the certificate is
    /// rebuilt here.
    private static func parseCompact(_ raw: [String: Any]) throws -> OwnerIdentity {
        guard let nodeID = raw["n"] as? String, isIdentifier(nodeID),
              let uid = raw["u"] as? String, isIdentifier(uid),
              let username = raw["o"] as? String, !username.isEmpty,
              let encodedSeed = raw["s"] as? String, let seed = decodeBase64URL(encodedSeed), seed.count == 32,
              let encodedSignature = raw["g"] as? String, let signature = decodeBase64URL(encodedSignature), signature.count == 64,
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else {
            throw OwnerIdentityError.invalid
        }
        let signerInfo = certificate(signature: signature, uid: uid, publicKey: key.publicKey.rawRepresentation, name: username)
        return OwnerIdentity(nodeID: nodeID, uid: uid, username: username, signerInfo: signerInfo, seed: seed)
    }

    /// Mints the passport `LoginWithPPT` accepts: `CertFor=Self` with a validity
    /// window, signed with the key. It is short-lived because it is only used to
    /// open a session, and a new one costs a signature.
    func passport(validFor minutes: Int = 15) throws -> String {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let signedAt = Date()
        let expiresAt = signedAt.addingTimeInterval(TimeInterval(minutes * 60))
        let payload = "CertFor=Self;EndTime=\(Self.stamp(expiresAt));SignTime=\(Self.stamp(signedAt));"
        let signature = try key.signature(for: Data(payload.utf8))
        let passport: [String: Any] = [
            "Signature": signature.base64EncodedString(),
            "SignerID": uid,
            "SignerInfo": signerInfo,
            "KeyType": "sodiumv2",
            "Version": 1,
            "Data": payload
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: passport), as: UTF8.self)
    }

    private static func stamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02d%02d%02d%02dUTC", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
                      parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    // MARK: Certificate layout
    //
    // Must stay byte-identical to build_signer_info in TweetBackendApp/tweet-owner.sh,
    // which checks that it reproduces Leither's own certificate before printing a QR.

    private static func bytes(_ hex: String) -> Data {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return data
    }

    /// Go gob unsigned integer: one byte below 128, else a byte-count marker and
    /// the big-endian value.
    private static func gobUint(_ value: Int) -> Data {
        if value < 128 { return Data([UInt8(value)]) }
        var digits: [UInt8] = []
        var rest = value
        while rest > 0 { digits.insert(UInt8(rest % 256), at: 0); rest /= 256 }
        return Data([UInt8(256 - digits.count)] + digits)
    }

    private static func certificate(signature: Data, uid: String, publicKey: Data, name: String) -> String {
        let prefix = bytes("307f030101085369676e496e666f01ff80000102010c426173655369676e496e666f01ff8200010444617461010c0000002eff810301010c426173655369676e496e666f01ff82000101010e426173655369676e496e666f563101ff8400000065ff830301010e426173655369676e496e666f563101ff8400010601095369676e6174757265010a0001085369676e65724944010c00010a5369676e6572496e666f010a0001074b657954797065010c00010756657273696f6e0106000102504b010a000000")
        let keyPrefix = bytes("0b0c0008736f6469756d76322f7f0301010f536f6469756d4b657950616972563201ff80000101010d536f6469756d4b65795061697201ff8200000029ff810301010d536f6469756d4b65795061697201ff820001020102536b010a000102506b010a00000027ff80010220")
        let bodyHead = bytes("ff8001010140")
        let afterID = bytes("0208") + Data("sodiumv2".utf8) + bytes("0101000001")

        let keyBlob = keyPrefix + publicKey + Data([0, 0])
        let text = Data("CertPK=\(encodeBase64URL(keyBlob))==;CertPKID=\(uid);name=\(name);".utf8)
        let body = bodyHead + signature + Data([1, 27]) + Data(uid.utf8) + afterID + gobUint(text.count) + text + Data([0])
        return (prefix + gobUint(body.count) + body).base64EncodedString()
    }

    /// A Leither id: 27 base64url characters.
    private static func isIdentifier(_ value: String) -> Bool {
        value.count == 27 && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        var normalized = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        return Data(base64Encoded: normalized)
    }

    private static func encodeBase64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Keychain

/// One Keychain item per kind of secret. Sessions are reopened from background
/// tasks, so items stay readable while the device is locked after first unlock,
/// and never leave this device.
private enum SessionKeychain {
    static func save(_ data: Data, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw OwnerIdentityError.keychain(status) }
    }

    static func load(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(service: String, account: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ] as CFDictionary)
    }
}

/// The owner identity this device was paired with. One at a time: pairing again
/// replaces it, and signing out removes it.
enum OwnerIdentityStore {
    private static let service = "com.tweet.owner-identity"
    private static let account = "paired"

    static func save(_ identity: OwnerIdentity) throws {
        try SessionKeychain.save(try JSONEncoder().encode(identity), service: service, account: account)
    }

    static func load() -> OwnerIdentity? {
        guard let data = SessionKeychain.load(service: service, account: account) else { return nil }
        return try? JSONDecoder().decode(OwnerIdentity.self, from: data)
    }

    static func delete() {
        SessionKeychain.delete(service: service, account: account)
    }
}

/// A guest's username and password.
///
/// A node keeps sessions in memory: one expires after an hour, and all are lost
/// when the node restarts. Signing in again needs the password long after the
/// login screen is gone, so it is kept from a successful login until logout.
enum OwnerCredentialStore {
    struct Credential: Codable, Sendable {
        let username: String
        let password: String
    }

    private static let service = "com.tweet.owner-session"

    static func save(_ credential: Credential, for userID: String) {
        guard let data = try? JSONEncoder().encode(credential) else { return }
        do {
            try SessionKeychain.save(data, service: service, account: userID)
        } catch {
            DiagnosticLog.error("session", "could not store the credential: \(error.localizedDescription)")
        }
    }

    static func load(for userID: String) -> Credential? {
        guard let data = SessionKeychain.load(service: service, account: userID) else { return nil }
        return try? JSONDecoder().decode(Credential.self, from: data)
    }

    static func delete(for userID: String) {
        SessionKeychain.delete(service: service, account: userID)
    }
}

// MARK: - Sessions

/// Leither sessions, one per (account, node), and what is known about each
/// node's support for them.
///
/// A session only means something to the node that issued it, and an account's
/// writes can reach more than one node (its root, or a surviving copy during a
/// root migration), so sessions are keyed by both.
actor UserSessionStore {
    static let shared = UserSessionStore()

    /// A node drops a session after an hour; renewing earlier avoids sending a
    /// write that is certain to be refused.
    private static let renewAfter: TimeInterval = 45 * 60
    /// How long an answer about a node is trusted. A node on an old backend does
    /// not check sessions; asking before every write would double its round trips.
    private static let supportLifetime: TimeInterval = 600

    private var sessions: [String: (sid: String, openedAt: Date)] = [:]
    private var support: [String: (supported: Bool, checkedAt: Date)] = [:]

    private static func key(accountID: String, node: String) -> String {
        accountID + "@" + node
    }

    func session(accountID: String, node: String) -> String? {
        guard let entry = sessions[Self.key(accountID: accountID, node: node)],
              Date().timeIntervalSince(entry.openedAt) < Self.renewAfter else {
            return nil
        }
        return entry.sid
    }

    func setSession(_ sid: String, accountID: String, node: String) {
        sessions[Self.key(accountID: accountID, node: node)] = (sid, Date())
    }

    /// Forget a session the node no longer recognises.
    func discard(accountID: String, node: String) {
        sessions[Self.key(accountID: accountID, node: node)] = nil
    }

    /// Whether the node checks sessions, when that is known and still fresh.
    func knownSupport(node: String) -> Bool? {
        guard let entry = support[node], Date().timeIntervalSince(entry.checkedAt) < Self.supportLifetime else {
            return nil
        }
        return entry.supported
    }

    func setSupport(_ supported: Bool, node: String) {
        support[node] = (supported, Date())
    }

    func clear() {
        sessions.removeAll()
    }
}
