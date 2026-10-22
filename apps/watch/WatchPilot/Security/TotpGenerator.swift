import CryptoKit
import Foundation

/// RFC 6238 time-based one-time passwords, with the Google Authenticator defaults
/// (HMAC-SHA1 · 6 digits · 30 s period) that the hub verifies.
///
/// The watch generates a fresh code for *every* request and sends it in the
/// `X-Watch-TOTP` header, so the shared secret never travels after pairing.
struct TotpGenerator {
    enum Failure: LocalizedError {
        case emptySecret
        case invalidBase32

        var errorDescription: String? {
            switch self {
            case .emptySecret: return "Nenhum segredo TOTP configurado no relógio."
            case .invalidBase32: return "O segredo TOTP não é base32 válido."
            }
        }
    }

    let secret: Data
    var digits: Int
    var period: TimeInterval

    init(base32: String, digits: Int = 6, period: TimeInterval = 30) throws {
        let normalised = base32
            .uppercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
        guard !normalised.isEmpty else { throw Failure.emptySecret }
        guard let decoded = Self.base32Decode(normalised) else { throw Failure.invalidBase32 }
        self.secret = decoded
        self.digits = digits
        self.period = period
    }

    init(secret: Data, digits: Int = 6, period: TimeInterval = 30) {
        self.secret = secret
        self.digits = digits
        self.period = period
    }

    /// Current code plus the number of seconds it stays valid.
    func current(at date: Date = Date()) -> (code: String, secondsRemaining: Int) {
        let counter = UInt64(date.timeIntervalSince1970 / period)
        let remaining = Int(period) - Int(date.timeIntervalSince1970.truncatingRemainder(dividingBy: period))
        return (Self.hotp(secret: secret, counter: counter, digits: digits), remaining)
    }

    func code(at date: Date = Date()) -> String {
        current(at: date).code
    }

    // MARK: - Core

    static func hotp(secret: Data, counter: UInt64, digits: Int = 6) -> String {
        var bigEndian = counter.bigEndian
        let message = withUnsafeBytes(of: &bigEndian) { Data($0) }
        let key = SymmetricKey(data: secret)
        let mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        let offset = Int(mac[mac.count - 1] & 0x0F)
        let binary = (UInt32(mac[offset] & 0x7F) << 24)
            | (UInt32(mac[offset + 1]) << 16)
            | (UInt32(mac[offset + 2]) << 8)
            | UInt32(mac[offset + 3])
        let modulus = Self.pow10(digits)
        return String(format: "%0\(digits)d", binary % modulus)
    }

    private static func pow10(_ exponent: Int) -> UInt32 {
        (0..<exponent).reduce(UInt32(1)) { value, _ in value * 10 }
    }

    /// RFC 4648 base32 decoder (the encoding Google Authenticator uses).
    static func base32Decode(_ input: String) -> Data? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var lookup: [Character: UInt8] = [:]
        for (index, character) in alphabet.enumerated() {
            lookup[character] = UInt8(index)
        }
        var buffer: UInt32 = 0
        var bits = 0
        var output = Data()
        for character in input where character != "=" {
            guard let value = lookup[character] else { return nil }
            buffer = (buffer << 5) | UInt32(value)
            bits += 5
            if bits >= 8 {
                bits -= 8
                output.append(UInt8((buffer >> UInt32(bits)) & 0xFF))
            }
        }
        return output.isEmpty ? nil : output
    }
}
