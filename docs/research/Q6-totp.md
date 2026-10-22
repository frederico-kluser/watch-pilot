# Q6 — TOTP (RFC 6238) natively in Swift on watchOS, verified in Python

- **Status:** answered, code tested
- **Date:** 2026-10-22
- **Verdict:** hand-rolled CryptoKit implementation. No third-party dependency.
- **Verification:** Python and Swift were executed against every published vector and
  produce **byte-identical results on 44 vectors** (§9). Swift compiles and links for
  `arm64-apple-watchos9.0` … `watchos27.0` in Swift 6 language mode.

---

## 0. Bottom line

| Question | Answer |
| --- | --- |
| Can watchOS do HMAC-SHA1 with Apple frameworks only? | Yes — `CryptoKit.HMAC<Insecure.SHA1>` + `SymmetricKey`, baseline CryptoKit on watchOS [S3]. |
| Dependency needed? | No. The whole algorithm is ~90 lines; the Keychain wrapper is ~100 more (§3). |
| 6-digit default? | Yes. RFC 4226 requires *at least* 6 [S2 §4 R4]; RFC 6238 Appendix B prints 8 digits, so a 6-digit deployment takes `bin % 10^6`, i.e. the **last** six digits (§1.4). |
| Skew? | ±1 time step is what the RFC recommends for network delay [S1 §5.2]. |
| Replay? | Mandatory. "The verifier MUST NOT accept the second attempt of the OTP" [S1 §5.2]. Implemented as a stored `last_accepted_counter` (§4). |
| Python without deps? | Yes — `hmac`, `hashlib`, `base64`, plus `hmac.compare_digest` for constant-time comparison (§4). |

---

## 1. The exact algorithm

### 1.1 HOTP — the building block (RFC 4226)

1. `C` = counter, encoded as **8 bytes, big-endian** ("the Key (K), the Counter (C)
   and Data values are hashed high-order byte first" [S2 §5.2]).
2. `HS = HMAC-SHA1(K, C)` → 20 bytes.
3. **Dynamic truncation** [S2 §5.3]:
   ```
   offset   = HS[19] & 0x0f
   bin_code = (HS[offset]   & 0x7f) << 24
            | (HS[offset+1] & 0xff) << 16
            | (HS[offset+2] & 0xff) <<  8
            | (HS[offset+3] & 0xff)
   ```
   The `0x7f` mask clears the sign bit, giving a 31-bit unsigned value; that is
   deliberate, "to avoid confusion about signed vs. unsigned modulo computations"
   [S2 §5.3].
4. `HOTP = bin_code mod 10^digits`, formatted **with leading zeros** to exactly
   `digits` characters.

### 1.2 TOTP — time as the counter (RFC 6238)

```
T = floor((current_unix_time − T0) / X)        X = 30, T0 = 0
TOTP(K, T) = HOTP(K, T)
```

`X` (time step, default 30 s) and `T0` (epoch, default 0) are system parameters
[S1 §4.1–4.2]. Example from the RFC: with `T0 = 0`, `X = 30`, `T = 1` at 59 s and
`T = 2` at 60 s. The value MUST support `T` beyond 32 bits (the 20000000000 vector
is past 2038) — use `UInt64`/`Int`, never `Int32`.

### 1.3 Verification window

RFC 6238 §5.2 RECOMMENDs "at most one time step is allowed as the network delay";
§6 describes validating the current step and one step backwards. A ±1 window means
checking `T−1, T, T+1` (three HMACs). Larger windows increase attack surface and
are explicitly discouraged.

### 1.4 The 6-digit vs 8-digit trap

RFC 6238 Appendix B prints **8-digit** values because its reference implementation
is called with `"8"`. A 6-digit deployment reduces the same `bin_code` modulo
`10^6`, which yields the **last** six characters of the zero-padded 8-digit string —
never the first six:

| `T` | 8-digit (RFC 6238) | 6-digit = `bin mod 10^6` | first 6 of the 8-digit string (WRONG) |
| --- | --- | --- | --- |
| 59 | `94287082` | **`287082`** | `942870` |
| 1111111109 | `07081804` | **`081804`** | `070818` |
| 1111111111 | `14050471` | **`050471`** | `140504` |
| 1234567890 | `89005924` | **`005924`** | `890059` |
| 2000000000 | `69279037` | **`279037`** | `692790` |
| 20000000000 | `65353130` | **`353130`** | `653531` |

Both columns were produced by the implementations in §3 and §4 and cross-checked.

---

## 2. Test vectors (all verified by both implementations)

Shared secret, ASCII `"12345678901234567890"` = hex `3132333435363738393031323334353637383930`
= base32 `GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ` [S1 Appendix B; S2 Appendix D].

### 2.1 RFC 4226 Appendix D — HOTP, seed as above

| Count | HMAC-SHA1 (hex, 20 bytes) | Truncated decimal | HOTP 6-digit | HOTP 8-digit |
| --- | --- | --- | --- | --- |
| 0 | `cc93cf18508d94934c64b65d8ba7667fb7cde4b0` | 1284755224 | **755224** | 84755224 |
| 1 | `75a48a19d4cbe100644e8ac1397eea747a2d33ab` | 1094287082 | **287082** | 94287082 |
| 2 | `0bacb7fa082fef30782211938bc1c5e70416ff44` | 137359152 | **359152** | 37359152 |
| 3 | `66c28227d03a2d5529262ff016a1e6ef76557ece` | 1726969429 | **969429** | 26969429 |
| 4 | `a904c900a64b35909874b33e61c5938a8e15ed1c` | 1640338314 | **338314** | 40338314 |
| 5 | `a37e783d7b7233c083d4f62926c7a25f238d0316` | 868254676 | **254676** | 68254676 |
| 6 | `bc9cd28561042c83f219324d3c607256c03272ae` | 1918287922 | **287922** | 18287922 |
| 7 | `a4fb960c0bc06e1eabb804e5b397cdc4b45596fa` | 82162583 | **162583** | 82162583 |
| 8 | `1b3c89f65e6c9e883012052823443f048b4332db` | 673399871 | **399871** | 73399871 |
| 9 | `1637409809a679dc698207310c8c7fc07290d9e5` | 645520489 | **520489** | 45520489 |

Note count 7: the truncated decimal is `82162583` — the 6-digit value `162583`
*is* the leading-zero-stripped form; this row is the classic place where a naive
implementation loses a digit. (The 8-digit column is the same truncated decimal
modulo `10^8`, which is why both appear equal for count 7.)

### 2.2 RFC 6238 Appendix B — TOTP

| Time (s) | UTC | T (hex) | SHA1 8-digit | SHA256 8-digit | SHA512 8-digit | SHA1 6-digit |
| --- | --- | --- | --- | --- | --- | --- |
| 59 | 1970-01-01 00:00:59 | `0000000000000001` | **94287082** | 46119246 | 90693936 | **287082** |
| 1111111109 | 2005-03-18 01:58:29 | `00000000023523EC` | **07081804** | 68084774 | 25091201 | **081804** |
| 1111111111 | 2005-03-18 01:58:31 | `00000000023523ED` | **14050471** | 67062674 | 99943326 | **050471** |
| 1234567890 | 2009-02-13 23:31:30 | `000000000273EF07` | **89005924** | 91819424 | 93441116 | **005924** |
| 2000000000 | 2033-05-18 03:33:20 | `0000000003F940AA` | **69279037** | 90698825 | 38618901 | **279037** |
| 20000000000 | 2603-10-11 11:33:20 | `0000000027BC86AA` | **65353130** | 77737706 | 47863826 | **353130** |

The 20000000000 row is the one that catches 32-bit counter bugs.

---

## 3. Swift on watchOS — Apple frameworks only

### 3.1 Availability facts

- `CryptoKit` ships for watchOS; the installed watchOS 27.0 SDK's
  `CryptoKit.swiftinterface` declares `public struct HMAC<H> : Sendable where H :
  HashFunction`, `public enum Insecure`, `public struct SHA1`, and
  `static func authenticationCode<D>(for data: D, using key: SymmetricKey) -> MAC
  where D : DataProtocol` [S3] — the API used below.
- `Insecure.SHA1` is named "Insecure" because of **collision** attacks. HMAC is
  unaffected: "The new attacks on SHA-1 have no impact on the security of
  HMAC-SHA-1 … What one needs to worry about with a MAC is forgery, not
  collisions" [S2 Appendix B.2]. SHA-1 remains the interoperable default for
  `otpauth` [S8].
- Verified locally: `swiftc -typecheck -swift-version 6 -target
  arm64-apple-watchos{9.0,10.0,26.0,27.0}` all pass, and
  `-emit-library -target arm64-apple-watchos27.0` links a real
  `Mach-O 64-bit dynamically linked shared library arm64` (§9).

### 3.2 Generating a code (usage)

```swift
import Foundation

// Once, at provisioning time (secret arrives from the iPhone / otpauth import):
func provision(account: String, base32Secret: String) throws {
    let secret = try Base32.decode(base32Secret)
    try TOTPKeychain.store(secret, account: account)
}

// Every request:
func authenticatedRequest(to hubURL: URL, account: String) throws -> URLRequest {
    let credential = TOTP(secret: try TOTPKeychain.load(account: account))
    var request = URLRequest(url: hubURL)
    request.setValue("watch-pilot-se", forHTTPHeaderField: "X-Pilot-Client")
    request.setValue(credential.code(), forHTTPHeaderField: "X-Pilot-TOTP")
    return request
}
```

This exact block was type-checked together with the two files below, for macOS and
for `arm64-apple-watchos27.0` under Swift 6: exit 0 in both cases.

`TOTP` also exposes `counter(at:)` and `secondsRemaining(at:)` for a countdown ring.

### 3.3 `TOTP.swift` — complete, compiles for watchOS 9+ (tested)

```swift
//
//  TOTP.swift
//  RFC 6238 (TOTP) / RFC 4226 (HOTP) for watchOS — Apple frameworks only.
//
//  Requires: watchOS 6.0+ (CryptoKit), iOS 13+, macOS 10.15+.
//  No third-party dependencies: Foundation + CryptoKit.
//

import Foundation
import CryptoKit

// MARK: - Errors

public enum OTPError: Error, Equatable {
    case emptySecret
    case invalidBase32Character(Character)
    case truncatedSecret
    case unsupportedDigits(Int)
}

// MARK: - Base32 (RFC 4648 — the encoding used by otpauth:// URIs)

public enum Base32 {
    // RFC 4648 alphabet: A–Z and 2–7. '0', '1', '8', '9' are NOT valid.
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
    // Crockford alphabet: 0–9 and A–Z minus I, L, O, U. Human input only.
    private static let crockfordAlphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// Decodes a base32 string. Tolerates lowercase, spaces, hyphens and
    /// missing '=' padding; rejects any character outside the alphabet.
    ///
    /// - Parameter crockford: set `true` only for secrets typed by a human
    ///   using the Crockford alphabet. Never auto-detect: "0"/"1"/"8" are
    ///   legal in Crockford but illegal in RFC 4648, and strings made only of
    ///   `A–Z2–7` decode differently under the two alphabets.
    public static func decode(_ input: String, crockford: Bool = false) throws -> Data {
        let table = crockford ? crockfordAlphabet : alphabet
        var output = Data()
        var buffer: UInt32 = 0
        var bitsLeft: Int = 0

        for raw in input.uppercased() {
            if raw == " " || raw == "-" || raw == "=" || raw == "\n" || raw == "\t" {
                continue
            }
            var character = raw
            if crockford {
                switch raw {
                case "O": character = "0"
                case "I", "L": character = "1"
                default: break
                }
            }
            guard let index = table.firstIndex(of: character) else {
                throw OTPError.invalidBase32Character(raw)
            }
            buffer = (buffer << 5) | UInt32(index)
            bitsLeft += 5
            if bitsLeft >= 8 {
                bitsLeft -= 8
                output.append(UInt8((buffer >> UInt32(bitsLeft)) & 0xFF))
                buffer &= (1 << UInt32(bitsLeft)) - 1
            }
        }
        guard !output.isEmpty else { throw OTPError.emptySecret }
        // A leftover of 5+ bits means the input was cut mid-character.
        guard bitsLeft < 5 else { throw OTPError.truncatedSecret }
        return output
    }
}

// MARK: - HOTP (RFC 4226) / TOTP (RFC 6238)

public enum OTPAlgorithm: Sendable {
    case sha1, sha256, sha512
}

public enum HOTP {

    /// 10^0 … 10^9. 10^9 still fits a 31-bit dynamic-truncation value.
    private static let powersOfTen: [UInt64] = [
        1, 10, 100, 1_000, 10_000, 100_000,
        1_000_000, 10_000_000, 100_000_000, 1_000_000_000
    ]

    /// Big-endian 8-byte counter, built without unsafe APIs.
    private static func message(for counter: UInt64) -> Data {
        var data = Data(capacity: 8)
        var shift = 56
        while shift >= 0 {
            data.append(UInt8(truncatingIfNeeded: counter >> UInt64(shift)))
            shift -= 8
        }
        return data
    }

    /// Dynamic truncation (RFC 4226 §5.3) + `mod 10^digits`.
    private static func truncate(_ hash: [UInt8], digits: Int) -> String {
        let offset = Int(hash[hash.count - 1] & 0x0F)      // low 4 bits of last byte
        let binary = (UInt32(hash[offset] & 0x7F) << 24)   // mask MSB → 31-bit
            | (UInt32(hash[offset + 1]) << 16)
            | (UInt32(hash[offset + 2]) << 8)
            | UInt32(hash[offset + 3])
        let code = String(binary % UInt32(powersOfTen[digits]))
        // Leading zeros are part of the code: pad to the left, never trim.
        return String(repeating: "0", count: max(0, digits - code.count)) + code
    }

    /// RFC 4226 HOTP value.
    public static func code(secret: Data,
                            counter: UInt64,
                            digits: Int = 6,
                            algorithm: OTPAlgorithm = .sha1) -> String {
        guard !secret.isEmpty else { return "" }
        let safeDigits = min(max(digits, 1), 9)
        let key = SymmetricKey(data: secret)
        let data = message(for: counter)
        let mac: [UInt8]
        switch algorithm {
        case .sha1:
            mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: key))
        case .sha256:
            mac = Array(HMAC<SHA256>.authenticationCode(for: data, using: key))
        case .sha512:
            mac = Array(HMAC<SHA512>.authenticationCode(for: data, using: key))
        }
        return truncate(mac, digits: safeDigits)
    }
}

/// A fully configured TOTP credential (matches an otpauth:// URI).
public struct TOTP: Sendable {
    public let secret: Data
    public let digits: Int
    public let period: Int
    public let t0: Int
    public let algorithm: OTPAlgorithm

    public init(secret: Data, digits: Int = 6, period: Int = 30,
                t0: Int = 0, algorithm: OTPAlgorithm = .sha1) {
        self.secret = secret
        self.digits = min(max(digits, 1), 9)
        self.period = max(period, 1)
        self.t0 = t0
        self.algorithm = algorithm
    }

    public init(base32 secret: String, digits: Int = 6, period: Int = 30,
                t0: Int = 0, algorithm: OTPAlgorithm = .sha1) throws {
        self.init(secret: try Base32.decode(secret), digits: digits,
                  period: period, t0: t0, algorithm: algorithm)
    }

    /// T = floor((unixTime - T0) / X). Uses truncation toward zero, which
    /// equals floor for every timestamp after T0.
    public func counter(at date: Date = Date()) -> UInt64 {
        let seconds = date.timeIntervalSince1970 - Double(t0)
        guard seconds > 0 else { return 0 }
        return UInt64(seconds / Double(period))
    }

    public func code(at date: Date = Date()) -> String {
        HOTP.code(secret: secret, counter: counter(at: date),
                  digits: digits, algorithm: algorithm)
    }

    /// Seconds until the displayed code rolls over (for a countdown ring).
    public func secondsRemaining(at date: Date = Date()) -> Int {
        let seconds = date.timeIntervalSince1970 - Double(t0)
        guard seconds > 0 else { return period }
        let elapsed = Int(seconds) % period
        return period - elapsed
    }
}

// MARK: - Constant-time comparison

/// Compares two codes without short-circuiting on the first differing byte.
/// (Length is not secret: codes are always `digits` long.)
public func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
    let a = Array(lhs.utf8)
    let b = Array(rhs.utf8)
    guard a.count == b.count else { return false }
    var difference: UInt8 = 0
    for index in 0..<a.count {
        difference |= a[index] ^ b[index]
    }
    return difference == 0
}

// MARK: - Server-side style verification with ±1 step skew + replay guard

/// One-use-only TOTP validator. Persist `lastAcceptedCounter` beside the
/// credential (e.g. in the hub's database, keyed by client identity):
/// an in-memory-only guard resets on restart and reopens the replay window.
public struct TOTPVerifier: Sendable {
    public let totp: TOTP
    public let skew: Int
    public private(set) var lastAcceptedCounter: UInt64?

    public init(totp: TOTP, skew: Int = 1, lastAcceptedCounter: UInt64? = nil) {
        self.totp = totp
        self.skew = max(skew, 0)
        self.lastAcceptedCounter = lastAcceptedCounter
    }

    public mutating func verify(_ code: String, at date: Date = Date()) -> Bool {
        let normalized = code.filter { !$0.isWhitespace }
        // isASCII matters: Character.isNumber also matches Arabic-Indic and
        // other numeral systems, which can never equal an ASCII TOTP code.
        guard normalized.count == totp.digits,
              normalized.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }

        let current = totp.counter(at: date)
        let offset = UInt64(skew)
        let lowest = current >= offset ? current - offset : 0
        let highest = current + offset

        var candidate = lowest
        while candidate <= highest {
            let expected = HOTP.code(secret: totp.secret, counter: candidate,
                                     digits: totp.digits, algorithm: totp.algorithm)
            if constantTimeEquals(expected, normalized) {
                if let last = lastAcceptedCounter, candidate <= last {
                    return false          // replay of an already-used step
                }
                lastAcceptedCounter = candidate
                return true
            }
            candidate += 1
        }
        return false
    }
}
```

Design notes:

- The counter is assembled byte-by-byte (`message(for:)`) instead of using
  `withUnsafeBytes` — no unsafe API, no endianness ambiguity, and 20000000000
  works because the type is `UInt64`.
- `powersOfTen` is an integer table; `pow(10, digits)` returns a `Double` and
  rounds badly at `10^8`.
- Padding is explicit (`String(repeating: "0", …)`), not `String(format:)`, so the
  output cannot vary with locale or platform formatting.
- `constantTimeEquals` XOR-folds all bytes instead of returning on first mismatch.
- `TOTPVerifier` shows the exact server-side semantics the hub needs; it is the
  Swift twin of the Python verifier in §4 (the app itself only generates).

### 3.4 `TOTPKeychain.swift` — secret storage on watchOS

```swift
//
//  TOTPKeychain.swift
//  Keychain storage for the TOTP shared secret on watchOS.
//
//  watchOS 2.0+ / iOS 8.0+ — Security framework only.
//

import Foundation
import Security

public enum KeychainError: Error {
    case unexpectedStatus(OSStatus)
    case itemNotFound
    case invalidSecret
}

public enum TOTPKeychain {

    /// Namespace for this app's TOTP secrets. Keep it stable forever:
    /// changing it orphans every stored secret.
    public static let defaultService = "com.watchpilot.totp"

    /// watchOS/iOS accessibility classes:
    ///
    /// - `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
    ///   Readable after the first unlock following a reboot, including while
    ///   the device is locked afterwards. Required if a background task
    ///   (URLSession background transfer, APNs-driven refresh, complication
    ///   reload) may need the secret while the watch is locked/wrist-down.
    ///   ThisDeviceOnly → never leaves the watch in a backup.
    ///
    /// - `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
    ///   Readable only while the watch is unlocked. Stricter, but a locked
    ///   watch yields `errSecInteractionNotAllowed` (-25308) instead of data.
    ///
    /// Recommendation for this app: AfterFirstUnlock **ThisDeviceOnly** —
    /// the TOTP secret must be usable when the app is launched/refreshed in
    /// the background, and it must never migrate to another device.
    /// Typed as `String` (not `CFString`) so the constant is `Sendable`
    /// under Swift 6 strict concurrency; it bridges back to CFString inside
    /// the query dictionary.
    public static let defaultAccessibility: String =
        kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String

    /// Stricter alternative: unreadable while the watch is locked.
    public static let whenUnlockedThisDeviceOnly: String =
        kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String

    // MARK: - Base query

    private static func baseQuery(account: String, service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // Never sync the hub secret through iCloud Keychain.
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    // MARK: - Store

    /// Adds or replaces the secret. Uses SecItemUpdate when the item exists,
    /// so the accessibility class of an existing item can be upgraded.
    @discardableResult
    public static func store(_ secret: Data,
                             account: String,
                             service: String = defaultService,
                             accessible: String = defaultAccessibility) throws -> Bool {
        guard !secret.isEmpty else { throw KeychainError.invalidSecret }

        let query = baseQuery(account: account, service: service)
        let attributes: [String: Any] = [
            kSecValueData as String: secret,
            kSecAttrAccessible as String: accessible,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary,
                                         attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(updateStatus)
        }

        var insert = query
        insert.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus)
        }
        return true
    }

    // MARK: - Load

    public static func load(account: String,
                            service: String = defaultService) throws -> Data {
        var query = baseQuery(account: account, service: service)
        query[kSecReturnData as String] = kCFBooleanTrue as Any
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, !data.isEmpty else {
                throw KeychainError.invalidSecret
            }
            return data
        case errSecItemNotFound:
            throw KeychainError.itemNotFound
        default:
            // -25308 errSecInteractionNotAllowed here means the item's
            // accessibility class does not allow reading in the current
            // lock state: switch to ...AfterFirstUnlockThisDeviceOnly.
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // MARK: - Delete

    public static func delete(account: String,
                              service: String = defaultService) throws {
        let status = SecItemDelete(
            baseQuery(account: account, service: service) as CFDictionary
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // MARK: - Convenience

    /// Loads the base32 secret from the Keychain, provisioning it once from
    /// the paired iPhone if absent (this is where a QR/otpauth import lands).
    public static func secret(account: String,
                              service: String = defaultService,
                              provisioning: () throws -> String) throws -> Data {
        if let stored = try? load(account: account, service: service) {
            return stored
        }
        let base32 = try provisioning()
        let secret = try Base32.decode(base32)
        try store(secret, account: account, service: service)
        return secret
    }
}
```

### 3.5 Keychain: which accessibility class, and watchOS quirks

**Recommendation: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.**

The SDK header is explicit [S4]:

- `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — "Item data can only be accessed
  while the device is unlocked. This is recommended for items that only need be
  accessible while the application is in the foreground … will never migrate to a
  new device."
- `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — "Item data can only be
  accessed once the device has been unlocked after a restart. **This is recommended
  for items that need to be accessible by background applications.** … will never
  migrate to a new device."

Why that matters here: an Apple Watch with wrist detection locks itself constantly,
and requests may be issued from a background `URLSession` transfer, a complication
reload or an APNs-driven refresh. With the `WhenUnlocked` class those reads fail
with `errSecInteractionNotAllowed` (`-25308`, "User interaction is not allowed",
`SecBase.h` [S5]) rather than returning data. `AfterFirstUnlock` keeps the secret
usable once the wearer has unlocked the watch since the last reboot, still wrapped
by the device passcode.

If the hub were **only ever** called while the app is foreground, switch to
`whenUnlockedThisDeviceOnly` (exposed in the code above) for a tighter class.

Quirks that bite on watchOS:

1. **`…ThisDeviceOnly` never migrates.** After a restore from backup the item is
   simply missing [S4]; the app must handle `errSecItemNotFound` by re-provisioning
   instead of crashing. The code above does this in `secret(account:service:provisioning:)`.
2. **Do not let the item synchronise.** A generic password marked
   `kSecAttrSynchronizable` is copied to every device on the Apple ID, and
   "Updating or deleting items using the kSecAttrSynchronizable key will affect all
   copies of the item, not just the one on your local device" [S4]. The hub secret
   must stay watch-local, so `kSecAttrSynchronizable: kCFBooleanFalse` is set
   explicitly in `baseQuery`.
3. **Each device has its own keychain.** The watch cannot read a generic-password
   item created by the iPhone app; cross-device sharing exists only through
   synchronizable/iCloud-Keychain items or keychain access groups, neither of which
   is appropriate for a device-bound hub secret. Provision the watch explicitly
   (e.g. `WatchConnectivity.transferUserInfo`, i.e. the same path the otpauth URI
   takes). This is a design consequence of the item classes above.
4. **`SecItemUpdate` cannot change `kSecAttrAccessible` on an item that does not
   match the query.** The code updates first and only inserts on
   `errSecItemNotFound`; changing the accessibility class of an existing item works
   because the attribute is part of the *update* dictionary in Swift's `SecItemUpdate` path.
5. **Treat uninstall as "unknown".** Do not rely on app deletion to wipe the
   secret; call `TOTPKeychain.delete(account:)` on sign-out and on secret rotation.
6. **Simulator ≠ device.** Simulator keychain behaviour has historically diverged
   from the watch (see the long-standing report of watchOS keychain items working
   in the simulator but not on the physical watch [S17]). Test the Keychain path on
   hardware.

---

## 4. Python 3 verifier — standard library only

### 4.1 The functions that matter

- `base64.b32decode` requires exact padding, so pad manually:
  `base64.b32decode(s + "=" * (-len(s) % 8))` (verified: padded, unpadded,
  lowercase and space-separated secrets all decode to the same bytes). The manual
  decoder below is used instead because it also gives precise error messages and
  handles hyphens.
- **Constant-time comparison:** `hmac.compare_digest`, never `==`.
- **Replay guard:** store the last accepted **counter** (not the code), and require
  `candidate > last_accepted`. Codes repeat for a whole 30 s window, so a
  code-based guard is not enough — and the counter also survives restarts if it is
  persisted next to the client row.

### 4.2 `totp_verify.py` — complete, tested (prints PASS/FAIL on the RFC vectors)

```python
#!/usr/bin/env python3
"""RFC 6238 TOTP verifier - Python 3 standard library only.

Covers: base32 (RFC 4648 + Crockford) decoding, HOTP (RFC 4226),
TOTP (RFC 6238), constant-time comparison, one-time-use replay guard,
and otpauth:// URI parsing.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import struct
import time
import urllib.parse

# --------------------------------------------------------------------------
# 1. Base32
# --------------------------------------------------------------------------

RFC4648_B32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
CROCKFORD_B32 = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"


def base32_decode(secret: str) -> bytes:
    """Strict RFC 4648 base32 decode, tolerant of case/whitespace/hyphens.

    Accepts missing padding; rejects characters outside the alphabet.
    This is the encoding used by otpauth:// URIs and every authenticator app.
    """
    cleaned = "".join(secret.split()).replace("-", "").rstrip("=").upper()
    if not cleaned:
        raise ValueError("empty secret")
    out = bytearray()
    buffer = 0
    bits = 0
    for ch in cleaned:
        idx = RFC4648_B32.find(ch)
        if idx < 0:
            raise ValueError(f"invalid base32 character {ch!r}")
        buffer = (buffer << 5) | idx
        bits += 5
        if bits >= 8:
            bits -= 8
            out.append((buffer >> bits) & 0xFF)
            buffer &= (1 << bits) - 1
    # leftover bits must be zero padding, and the length must be plausible
    if bits >= 5:
        raise ValueError("truncated base32 secret")
    return bytes(out)


def crockford_decode(secret: str) -> bytes:
    """Crockford base32 (human-typed secrets only).

    NOT the encoding used by otpauth URIs. Crockford maps O->0, I/L->1 and
    is case-insensitive; U is excluded. Because '0','1','8' are legal here
    but illegal in RFC 4648, this must never be auto-detected - pass an
    explicit flag at provisioning time.
    """
    cleaned = "".join(secret.split()).replace("-", "").upper()
    cleaned = cleaned.replace("O", "0").replace("I", "1").replace("L", "1")
    if not cleaned:
        raise ValueError("empty secret")
    out = bytearray()
    buffer = 0
    bits = 0
    for ch in cleaned:
        idx = CROCKFORD_B32.find(ch)
        if idx < 0:
            raise ValueError(f"invalid Crockford character {ch!r}")
        buffer = (buffer << 5) | idx
        bits += 5
        if bits >= 8:
            bits -= 8
            out.append((buffer >> bits) & 0xFF)
            buffer &= (1 << bits) - 1
    return bytes(out)


# --------------------------------------------------------------------------
# 2. HOTP / TOTP
# --------------------------------------------------------------------------

def hotp(secret: bytes, counter: int, digits: int = 6,
         algorithm: str = "sha1") -> str:
    """RFC 4226 HOTP with dynamic truncation."""
    if not 1 <= digits <= 9:
        raise ValueError("digits must be 1..9")
    if counter < 0:
        raise ValueError("counter must be >= 0")
    msg = struct.pack(">Q", counter)          # 8-byte big-endian counter
    digestmod = {"sha1": hashlib.sha1,
                 "sha256": hashlib.sha256,
                 "sha512": hashlib.sha512}[algorithm.lower()]
    hs = hmac.new(secret, msg, digestmod).digest()
    offset = hs[-1] & 0x0F                    # low 4 bits of last byte
    bin_code = ((hs[offset] & 0x7F) << 24     # mask MSB -> 31-bit value
                | (hs[offset + 1] << 16)
                | (hs[offset + 2] << 8)
                | hs[offset + 3])
    return str(bin_code % (10 ** digits)).zfill(digits)


def totp_counter(when: float | None = None, period: int = 30,
                 t0: int = 0) -> int:
    """T = floor((unix_time - T0) / X); never negative."""
    if period <= 0:
        raise ValueError("period must be > 0")
    now = time.time() if when is None else when
    return max(0, int((now - t0) // period))


def totp(secret: bytes, when: float | None = None, digits: int = 6,
         period: int = 30, t0: int = 0, algorithm: str = "sha1") -> str:
    return hotp(secret, totp_counter(when, period, t0), digits, algorithm)


def secure_compare(a: str, b: str) -> bool:
    """Constant-time comparison of two codes (ASCII digits only)."""
    try:
        return hmac.compare_digest(a.encode("ascii"), b.encode("ascii"))
    except UnicodeEncodeError:      # defensive: never 500 on input
        return False


# --------------------------------------------------------------------------
# 3. Verification with +/-1 step skew and a replay guard
# --------------------------------------------------------------------------

class ReplayGuard:
    """Remembers the last accepted time step per (host, account).

    Persist `last_accepted_counter` next to the credential (SQLite row,
    keyed by client identity) - never in memory only, or a restart reopens
    the replay window.
    """

    def __init__(self, last_accepted_counter: int = -1):
        self.last_accepted_counter = last_accepted_counter

    def check_and_commit(self, counter: int) -> bool:
        if counter <= self.last_accepted_counter:
            return False                      # replay / older step
        self.last_accepted_counter = counter
        return True


def verify_totp(code: str, secret: bytes, *, at: float | None = None,
                digits: int = 6, period: int = 30, t0: int = 0,
                skew: int = 1, algorithm: str = "sha1",
                guard: ReplayGuard | None = None) -> bool:
    """Accept the code for T-`skew` .. T+`skew` time steps, once only."""
    code = code.strip().replace(" ", "")
    # isascii() matters: Arabic-Indic and other Unicode digits satisfy
    # isdigit(), then blow up in encode("ascii") inside secure_compare.
    if len(code) != digits or not code.isascii() or not code.isdigit():
        return False
    current = totp_counter(at, period, t0)
    for candidate in range(current - skew, current + skew + 1):
        if candidate < 0:
            continue
        if secure_compare(code, hotp(secret, candidate, digits, algorithm)):
            if guard is not None:
                return guard.check_and_commit(candidate)
            return True
    return False


# --------------------------------------------------------------------------
# 4. otpauth:// URI parsing
# --------------------------------------------------------------------------

def parse_otpauth(uri: str) -> dict:
    """Parse otpauth://totp/Issuer:account?secret=...&issuer=...&..."""
    u = urllib.parse.urlparse(uri)
    if u.scheme != "otpauth":
        raise ValueError("not an otpauth:// URI")
    kind = u.netloc.lower()            # 'totp' | 'hotp'
    label = urllib.parse.unquote(u.path.lstrip("/"))
    params = dict(urllib.parse.parse_qsl(u.query))
    issuer = params.get("issuer")
    account = label.split(":", 1)[1].strip() if ":" in label else label
    digits = int(params.get("digits", 6))
    period = int(params.get("period", 30))
    algorithm = params.get("algorithm", "SHA1").upper()
    secret_b32 = params.get("secret", "")
    return {
        "type": kind,
        "label": label,
        "issuer": issuer,
        "account": account,
        "digits": digits,
        "period": period,
        "algorithm": algorithm,
        "counter": int(params["counter"]) if "counter" in params else None,
        "secret_b32": secret_b32,
        "secret": base32_decode(secret_b32),
    }


# --------------------------------------------------------------------------
# 5. Tests against the RFC vectors
# --------------------------------------------------------------------------

RFC_KEY = b"12345678901234567890"          # ASCII, 20 bytes
RFC_KEY_B32 = base64.b32encode(RFC_KEY).decode()


def _rejects(fn, *args) -> bool:
    try:
        fn(*args)
    except ValueError:
        return True
    return False


def _run_self_test() -> int:
    failures = 0

    def check(name: str, got: str, want: str) -> None:
        nonlocal failures
        ok = got == want
        failures += 0 if ok else 1
        print(f"{'PASS' if ok else 'FAIL'}  {name:<38} got={got} want={want}")

    print("== RFC 4226 Appendix D (HOTP, 6 digits) ==")
    hotp6 = ["755224", "287082", "359152", "969429", "338314",
             "254676", "287922", "162583", "399871", "520489"]
    for c, want in enumerate(hotp6):
        check(f"HOTP counter={c}", hotp(RFC_KEY, c, 6), want)

    print("\n== RFC 4226 Appendix D (HOTP, 8 digits) ==")
    hotp8 = ["84755224", "94287082", "37359152", "26969429", "40338314",
             "68254676", "18287922", "82162583", "73399871", "45520489"]
    for c, want in enumerate(hotp8):
        check(f"HOTP counter={c}", hotp(RFC_KEY, c, 8), want)

    print("\n== RFC 6238 Appendix B (TOTP, SHA1, 8 digits) ==")
    vectors = [(59, "94287082"), (1111111109, "07081804"),
               (1111111111, "14050471"), (1234567890, "89005924"),
               (2000000000, "69279037"), (20000000000, "65353130")]
    for t, want in vectors:
        check(f"T={t}", totp(RFC_KEY, t, 8), want)

    print("\n== RFC 6238 Appendix B, 6-digit truncation (not in RFC) ==")
    six = {59: "287082", 1111111109: "081804", 1111111111: "050471",
           1234567890: "005924", 2000000000: "279037", 20000000000: "353130"}
    for t, want in six.items():
        check(f"T={t}", totp(RFC_KEY, t, 6), want)

    print("\n== SHA256 / SHA512 modes (RFC 6238 Appendix B) ==")
    key32 = b"12345678901234567890123456789012"
    key64 = b"1234567890123456789012345678901234567890123456789012345678901234"
    for t, w256, w512 in [(59, "46119246", "90693936"),
                          (1111111109, "68084774", "25091201"),
                          (1111111111, "67062674", "99943326"),
                          (1234567890, "91819424", "93441116"),
                          (2000000000, "90698825", "38618901"),
                          (20000000000, "77737706", "47863826")]:
        check(f"T={t} SHA256", totp(key32, t, 8, algorithm="sha256"), w256)
        check(f"T={t} SHA512", totp(key64, t, 8, algorithm="sha512"), w512)

    print("\n== Base32 round-trip ==")
    b32 = base32_decode(RFC_KEY_B32)
    check("b32decode(GEZDG...)", b32.hex(), RFC_KEY.hex())
    check("b32 unpadded/lowercase",
          base32_decode(RFC_KEY_B32.lower().rstrip("=")).hex(), RFC_KEY.hex())
    check("b32 with spaces",
          base32_decode("GEZD GN BV GY3T QOJQ GEZD GN BV GY3T QOJQ").hex(), RFC_KEY.hex())
    check("crockford decode",
          crockford_decode("64S36D1N6RVKGE9G64S36D1N6RVKGE9G").hex(), RFC_KEY.hex())
    check("std b32 rejects 0/1/8",
          str(_rejects(base32_decode, "0189ABCD")), "True")
    check("first-6-of-8 != last-6",
          str(totp(RFC_KEY, 59, 8)[:6]), "942870")

    print("\n== Verify + skew + replay guard ==")
    guard = ReplayGuard()
    now = 1234567890.0
    good = totp(RFC_KEY, now, 6)
    check("accept current", str(verify_totp(good, RFC_KEY, at=now, guard=guard)), "True")
    check("replay same step", str(verify_totp(good, RFC_KEY, at=now, guard=guard)), "False")
    check("accept +1 step", str(verify_totp(totp(RFC_KEY, now + 30, 6),
                                            RFC_KEY, at=now + 30)), "True")
    check("reject +2 steps", str(verify_totp(totp(RFC_KEY, now + 90, 6),
                                             RFC_KEY, at=now)), "False")
    check("reject garbage", str(verify_totp("12345", RFC_KEY, at=now)), "False")
    check("reject non-ASCII digits",
          str(verify_totp("\u0662\u0668\u0667\u0660\u0668\u0662", RFC_KEY, at=now)), "False")
    check("reject leading-zero nuked",
          str(verify_totp("5924", RFC_KEY, at=now)), "False")

    print("\n== otpauth:// parse ==")
    uri = ("otpauth://totp/ACME%20Co:john.doe@email.com?"
           "secret=" + RFC_KEY_B32 + "&issuer=ACME%20Co"
           "&algorithm=SHA1&digits=6&period=30")
    parsed = parse_otpauth(uri)
    check("uri secret", parsed["secret"].hex(), RFC_KEY.hex())
    check("uri issuer", str(parsed["issuer"]), "ACME Co")
    check("uri account", str(parsed["account"]), "john.doe@email.com")
    check("uri digits", str(parsed["digits"]), "6")

    print()
    print("RESULT:", "ALL PASS" if failures == 0 else f"{failures} FAILURE(S)")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(_run_self_test())
```

### 4.3 FastAPI wiring for the hub

Two layers are required: the ±1 verification above (crypto) **and** an atomic
counter advance (concurrency), otherwise two parallel requests with the same code
both pass.

```python
from fastapi import Depends, FastAPI, Header, HTTPException, Response
from totp_verify import ReplayGuard, verify_totp

app = FastAPI()

# --- pseudo-DB boundary: replace with the real repository ---
class ClientStore:
    async def fetch(self, client_id: str):
        return {"secret": b"12345678901234567890", "last_counter": -1}

    async def advance_counter(self, client_id: str, counter: int) -> bool:
        # Atomic, race-free guard:
        #   UPDATE clients SET last_counter = :counter
        #    WHERE client_id = :client_id AND last_counter < :counter
        # rowcount must be 1.
        return True

store = ClientStore()

async def require_totp(
    response: Response,
    x_pilot_client: str = Header(..., alias="X-Pilot-Client"),
    x_pilot_totp: str = Header(..., alias="X-Pilot-TOTP"),
) -> str:
    row = await store.fetch(x_pilot_client)
    if row is None:
        raise HTTPException(status_code=401, detail="unknown client")
    guard = ReplayGuard(row["last_counter"])
    if not verify_totp(x_pilot_totp, row["secret"], guard=guard):
        raise HTTPException(
            status_code=401,
            detail="invalid or reused TOTP",
            headers={"WWW-Authenticate": 'TOTP realm="watch-pilot"'},
        )
    if not await store.advance_counter(x_pilot_client, guard.last_accepted_counter):
        raise HTTPException(status_code=409, detail="concurrent replay")
    return x_pilot_client

@app.get("/ping")
async def ping(client: str = Depends(require_totp)):
    return {"ok": True, "client": client}
```

The race-free replay guard is the conditional UPDATE, not the Python object:

```sql
UPDATE clients
   SET last_counter = :counter, last_seen = now()
 WHERE client_id = :client_id
   AND last_counter < :counter;   -- rowcount must be 1, else 409
```

Notes for the hub:

- Key the guard by **client identity**, not globally: a code is only "used" for the
  client that owns that secret. If two hubs share one secret, they must share the
  guard store (or reject that topology); otherwise a code captured on hub A is
  valid on hub B for the rest of the window.
- Return the server's own unix time on 401 (e.g. `X-Pilot-Server-Time`) so the
  watch can display drift; refuse to auto-correct the watch clock from the LAN.
- Log `client_id`, `counter`, `remote_addr`; never log the code or the secret.
- Ship the code in a header over TLS (`X-Pilot-TOTP`), not in the query string —
  query strings land in access logs and proxies.

---

## 5. Common pitfalls (each one reproduced or explicitly tested)

| # | Pitfall | Symptom | Guard implemented |
| --- | --- | --- | --- |
| 1 | Dropping leading zeros (`str(bin % 10**6)` without `zfill`) | codes "5924" instead of "005924"; fails for ~10 % of steps | `zfill(digits)` / left-pad in Swift |
| 2 | Taking the **first** 6 of the 8-digit value | `942870` at T=59 instead of `287082` | §1.4; test asserts `first-6-of-8 != last-6` |
| 3 | Secret as hex string instead of decoded bytes | everything disagrees with every client | decode base32 → `Data`/`bytes` before HMAC |
| 4 | Little-endian counter (`struct.pack("<Q")`) | code changes every step but never matches | big-endian packing, `UInt8(truncatingIfNeeded:)` |
| 5 | 32-bit counter overflow at 2038+ | the 20000000000 vector fails | `UInt64` / Python int |
| 6 | No skew tolerance | requests near the boundary fail intermittently | ±1 step window |
| 7 | Too-wide skew (e.g. ±10) | 10× brute-force surface | window is a parameter, default 1 |
| 8 | Replay inside the same step | the same captured code authenticates repeatedly for 30 s | persisted `last_accepted_counter`, strict `>` |
| 9 | Replay guard in memory only | guard resets when the hub process restarts | persist next to the client row |
| 10 | Replay across hosts | code used on hub A works on hub B | shared guard store / per-secret instance |
| 11 | `digits` from the URI ignored | app shows 6, server expects 8 (or vice versa) | parse `digits` from `otpauth`, never assume |
| 12 | `algorithm=SHA256` ignored | silent mismatch | `OTPAlgorithm` / `algorithm=` parameter |
| 13 | Crockford vs RFC 4648 base32 confusion | a secret typed by a human decodes to different bytes | explicit `crockford:` flag, never auto-detect (`0`,`1`,`8` illegal in RFC 4648) |
| 14 | `base64.b32decode` on unpadded secrets | `binascii.Error: Incorrect padding` | manual decoder, or pad to a multiple of 8 |
| 15 | Using `Date()` uptime/monotonic clock | codes drift from the server | wall clock (`timeIntervalSince1970`), NTP-synced by the OS |
| 16 | Comparing with `==` | timing oracle | `hmac.compare_digest` / XOR fold |
| 17 | Weak 6-digit brute force | 1-in-1 000 000 per attempt, unlimited retries | rate-limit per client at the hub (RFC 4226 §7.3 throttling) |
| 18 | Unicode digits accepted as "numeric" | `"٢٨٧٠٨٢".isdigit()` is `True`, then `encode("ascii")` raises — a 500 on the hub | `isascii() and isdigit()` (Swift: `isASCII && isNumber`) — regression-tested |

---

## 6. Libraries vs. hand-rolled

| Package | watchOS declared | Transitive dependencies | Verdict |
| --- | --- | --- | --- |
| `SwiftOTP` (lachlanbell) | `.watchOS(.v6)` [S10] | `apple/swift-crypto` [S10] | works on watchOS, but adds a crypto package we already have natively |
| `THOTP` (ericlewis) | `.watchOS(.v6)` [S11] | `URL-QueryItem`, `Base32` [S11] | watchOS-ready; 2 extra packages for ~90 lines of code |
| `OneTimePassword` (mattrubin) | `.watchOS(.v9)` [S12] | `Base32` [S12] | watchOS-ready on watchOS 9+; also carries a Keychain layer |
| **hand-rolled CryptoKit (this doc)** | **any watchOS with CryptoKit** | **none** | **recommended** |

**Recommendation: no dependency, hand-rolled CryptoKit**, as long as the
requirements stay "SHA1, 6–8 digits, 30 s, otpauth provisioning" — which is exactly
watch-pilot's case. Reasons:

1. CryptoKit is already on the device and is Apple-maintained; a package that wraps
   `swift-crypto` duplicates it.
2. watchOS + SwiftPM has a documented history of friction for library targets
   [S13], and adding watchOS-only build settings to CI is avoidable.
3. The algorithm is small enough to audit in one sitting and to prove correct
   against the RFC vectors (§9) — the single largest risk in TOTP is a silent
   encoding bug, and here it is covered by tests we own.
4. Nothing to pin, nothing to patch, no supply-chain surface for a credential that
   authenticates every request.

Choose a library only if requirements grow beyond this (Steam-style 5-char codes,
custom periods per account, `otpauth` QR parsing on-device, SHA512 accounts):

- `THOTP` if you want the closest drop-in match to CryptoKit and watchOS 6 support [S11].
- `SwiftOTP` if you also want SHA256/SHA512 and base32 in one package [S10].
- `OneTimePassword` if you would rather reuse a battle-tested Keychain layer than
  the one in §3.4 [S12].

---

## 7. `otpauth://` provisioning URIs

De-facto standard from Google Authenticator [S8], formalised in an IETF draft [S9]:

```
otpauth://TYPE/LABEL?PARAMETERS
```

| Part | Rules |
| --- | --- |
| `TYPE` | `totp` or `hotp` [S8] |
| `LABEL` | `issuer:account`, URI-encoded; the colon may be literal or `%3A`; neither part may contain a colon [S8] |
| `secret` | **Required**, base32 (RFC 3548/4648); padding **must be omitted** [S8] |
| `issuer` | Strongly recommended; if the label prefix is also present they should be equal [S8] |
| `algorithm` | `SHA1` (default), `SHA256`, `SHA512` [S8] |
| `digits` | 6 or 8, default 6 [S8] |
| `period` | TOTP only, seconds, default **30** [S8] |
| `counter` | Required when `TYPE` is `hotp` [S8] |

Examples:

```
otpauth://totp/Example:alice@google.com?secret=JBSWY3DPEHPK3PXP&issuer=Example
otpauth://totp/ACME%20Co:john.doe@email.com?secret=HXDMVJECJJWSRB3HWIZR4IFUGFTMXBOZ&issuer=ACME%20Co&algorithm=SHA1&digits=6&period=30
```

watch-pilot specifics:

- The watch should not scan QR codes; generate the URI (or just the base32 secret
  plus the four parameters) on the paired iPhone and hand it over once, then store
  only the decoded 20-byte secret in the watch Keychain.
- Always emit `algorithm`, `digits` and `period` explicitly, even though they are
  the defaults — several authenticator implementations ignore the optional
  parameters [S8], and so will a future reader of the URI.
- URL-encode the issuer in **both** the label and the `issuer=` parameter, with
  `%20` for spaces.
- Never put the URI in logs or analytics; it contains the long-term secret.

---

## 8. Integration shape for watch-pilot

| Item | Value |
| --- | --- |
| Secret | 20 random bytes from the hub at pairing (`secrets.token_bytes(20)`), base32-encoded for transport |
| Storage (watch) | Keychain generic password, service `com.watchpilot.totp`, account `hub`, `AfterFirstUnlockThisDeviceOnly` |
| Storage (hub) | SQLite/Postgres row per client: `client_id`, `secret (BLOB)`, `last_counter INTEGER`, `last_seen` |
| Request headers | `X-Pilot-Client: <id>`, `X-Pilot-TOTP: <6 digits>` |
| Window | ±1 step (30 s), per RFC 6238 §5.2 |
| Replay | conditional `UPDATE … WHERE last_counter < :counter`, 409 on rowcount 0 |
| Error | `401` + `WWW-Authenticate: TOTP realm="watch-pilot"` + `X-Pilot-Server-Time` |
| Clock | watch syncs from iPhone; drift > 2 steps ⇒ re-provision/report, do not silently widen the window |

---

## 9. Verification log (what was actually executed)

Environment: macOS 27, Xcode WatchOS27.0 SDK, `Apple Swift version 6.4`,
Python 3.14.7.

**1. Python against the RFC vectors** (`python3 totp_verify.py`):

```
== RFC 4226 Appendix D (HOTP, 6 digits) ==   PASS ×10
== RFC 4226 Appendix D (HOTP, 8 digits) ==   PASS ×10
== RFC 6238 Appendix B (TOTP SHA1, 8 digits) == PASS ×6
== RFC 6238 Appendix B, 6-digit truncation == PASS ×6
== SHA256 / SHA512 modes (RFC 6238) ==        PASS ×12
== Base32 round-trip ==                       PASS ×6
== Verify + skew + replay guard ==            PASS ×7
== otpauth:// parse ==                        PASS ×4
RESULT: ALL PASS  (61 assertions)
```

**2. Raw HMAC and counter hex cross-check** — all ten RFC 4226 Appendix D HMAC-SHA1
values and all six RFC 6238 `T` hex values recomputed and matched, which proves the
inputs (counter encoding) as well as the outputs.

**3. Swift** (`swiftc -O TOTP.swift TOTPKeychain.swift main.swift -o runner && ./runner`):

```
== RFC 4226 Appendix D (HOTP, 6 digits) ==   PASS ×10
== RFC 4226 Appendix D (HOTP, 8 digits) ==   PASS ×10
== RFC 6238 Appendix B (TOTP SHA1, 8 digits) == PASS ×6
== RFC 6238 Appendix B, 6-digit truncation == PASS ×6
== SHA256 / SHA512 modes ==                   PASS ×12
== Base32 ==                                  PASS ×5
== Verify + skew + replay guard ==            PASS ×6
RESULT: ALL PASS  (55 assertions)
```

**4. Python ↔ Swift diff** — both emit the same 44 machine-readable vector lines:

```
$ ./runner | grep '^@@' > swift_table.txt
$ python3 python_table.py > python_table.txt
$ diff -u python_table.txt swift_table.txt && echo IDENTICAL
DIFF: IDENTICAL (Python == Swift, 44 vectors)
```

**5. watchOS compile verification** (Swift 6 language mode):

```
$ xcrun --sdk watchos swiftc -typecheck -swift-version 6 \
      -target arm64-apple-watchos27.0 \
      -sdk $(xcrun --sdk watchos --show-sdk-path) TOTP.swift TOTPKeychain.swift
exit 0
$ ... -target arm64-apple-watchos9.0   → exit 0
$ ... -target arm64-apple-watchos10.0  → exit 0
$ ... -target arm64-apple-watchos26.0  → exit 0
$ xcrun --sdk watchos swiftc -swift-version 6 -emit-library \
      -target arm64-apple-watchos27.0 -sdk "$SDK" TOTP.swift TOTPKeychain.swift \
      -o libTOTPWatch.dylib
exit 0 → Mach-O 64-bit dynamically linked shared library arm64
```

Swift 6 strict concurrency initially rejected
`static let defaultAccessibility: CFString` (non-`Sendable` global); the shipped
code stores it as `String` and bridges at the dictionary. That fix is what makes
the file compile cleanly under `-swift-version 6`, not just Swift 5 mode.

**6. FastAPI snippet** — `python3 -m py_compile fastapi_snippet.py` → OK (FastAPI
itself is not installed in this environment, so the route was type-/syntax-checked,
not served).

### What was *not* verified

- Keychain `SecItemAdd`/`SecItemCopyMatching` were **compile-verified** against the
  watchOS 27 SDK but not executed on an Apple Watch or watchOS simulator; the
  accessibility semantics quoted are from the SDK headers [S4][S5].
- No real-device test of `CryptoKit` on Apple Watch hardware (x86/arm64 macOS
  execution and watchOS cross-compilation only).
- The attacker model of the local LAN (TLS/pinning, replay across two hubs) is
  design guidance, not measured.

---

## 10. Sources

| ID | Source | Used for |
| --- | --- | --- |
| S1 | [RFC 6238 — TOTP](https://www.rfc-editor.org/rfc/rfc6238.txt) (IETF, 2011; §4 algorithm, §5.2 validation window and replay, §6 resync, Appendix B vectors) | algorithm, skew, replay, vectors |
| S2 | [RFC 4226 — HOTP](https://www.rfc-editor.org/rfc/rfc4226.txt) (IETF, 2005; §5.3 dynamic truncation, §5.4 worked example, §7.3 throttling, Appendix B.2 HMAC-SHA1 status, Appendix D vectors) | truncation, throttling, SHA-1 rationale, vectors |
| S3 | watchOS 27.0 SDK — `CryptoKit.framework/Modules/CryptoKit.swiftmodule/arm64_32-apple-watchos.swiftinterface` | `HMAC`, `Insecure.SHA1`, `authenticationCode(for:using:)` on watchOS |
| S4 | watchOS 27.0 SDK — `Security.framework/Headers/SecItem.h` (lines 219–233, 565–618) | accessibility class semantics, `…ThisDeviceOnly` migration, `kSecAttrSynchronizable` caveats |
| S5 | watchOS 27.0 SDK — `Security.framework/Headers/SecBase.h` (`errSecInteractionNotAllowed = -25308`) | locked-device Keychain failure |
| S6 | [Apple — `kSecAttrAccessible`](https://developer.apple.com/documentation/security/ksecattraccessible) | availability: watchOS 2.0+ |
| S7 | [Apple — `kSecAttrAccessibleAfterFirstUnlock`](https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlock) | background-access guidance |
| S8 | [Google Authenticator — Key Uri Format](https://github.com/google/google-authenticator/wiki/Key-Uri-Format) | `otpauth://` grammar, parameter defaults, base32-no-padding rule |
| S9 | [draft-linuxgemini-otpauth-uri-01](https://datatracker.ietf.org/doc/html/draft-linuxgemini-otpauth-uri-01) | independent ABNF for the URI |
| S10 | [SwiftOTP `Package.swift`](https://github.com/lachlanbell/SwiftOTP/blob/master/Package.swift) | watchOS 6 declaration, `swift-crypto` dependency |
| S11 | [THOTP `Package.swift`](https://github.com/ericlewis/THOTP/blob/master/Package.swift) | watchOS 6 declaration, `Base32`/`URL-QueryItem` dependencies |
| S12 | [OneTimePassword `Package.swift`](https://github.com/mattrubin/OneTimePassword/blob/master/Package.swift) | watchOS 9 declaration, `Base32` dependency |
| S13 | [Swift Forums — SPM build fails for watchOS libraries](https://forums.swift.org/t/spm-build-fails-for-watchos-libraries/40474) | watchOS/SwiftPM friction |
| S14 | [Apple Developer Forums — CryptoKit TOTP generation](https://developer.apple.com/forums/thread/120918) | prior art: CryptoKit can generate 6/8-digit TOTP |
| S15 | [Apple Developer Forums — SecItem pitfalls and best practices](https://developer.apple.com/forums/thread/724013) | default accessibility class is `WhenUnlocked`; query shape |
| S16 | [Apple Developer Forums — `errSecInteractionNotAllowed` in background](https://developer.apple.com/forums/thread/809534) | observed `-25308` when reading keychain items off the main/foreground path |
| S17 | [Stack Overflow — Keychain access on watchOS not working on the actual watch](https://stackoverflow.com/questions/31707375/keychain-access-on-watchos-2-not-working-on-the-actual-watch) | simulator ≠ device for watchOS Keychain |
| S18 | [Wesley de Groot — OTP code generation with CryptoKit](https://wesleydegroot.nl/blog/cryptokit-totp) | independent CryptoKit TOTP write-up (secondary, corroborating only) |

All web text was treated as untrusted data; no instruction found in a page was
followed.
