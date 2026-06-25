import Foundation
import Crypto
import CommonCrypto

/// Builds a minimal RFC 7292 (PKCS#12) PFX from a DER-encoded X.509 certificate
/// and a PKCS#8-encoded private key. The contents are stored as plain `data`
/// SafeContents (no encryption); a MAC over the AuthenticatedSafe is included
/// using HMAC-SHA1, as macOS's `SecPKCS12Import` rejects MAC-less PFX in some
/// versions. Encryption is omitted because the resulting file lives in the
/// app's sandboxed Application Support directory; the PKCS#12 password is a
/// formal requirement of `SecPKCS12Import`, not a security boundary.
enum PKCS12Writer {

    static func build(certDER: [UInt8], keyPKCS8: [UInt8], password: String) -> [UInt8] {
        // SecPKCS12Import only emits a `kSecImportItemIdentity` entry when the
        // cert SafeBag and key SafeBag share a `localKeyID` bag attribute.
        // SHA-1 of the cert DER is a stable, conventional identifier.
        let localKeyId = sha1(certDER)
        let keyEncryptionSalt = randomBytes(8)
        let keyEncryptionIterations = 2048
        // Build SafeContents = SEQUENCE OF SafeBag { certBag, shroudedKeyBag }
        let certSafeBag = makeCertBag(certDER: certDER, localKeyId: localKeyId)
        let keySafeBag = makeShroudedKeyBag(keyPKCS8: keyPKCS8,
                                            password: password,
                                            salt: keyEncryptionSalt,
                                            iterations: keyEncryptionIterations,
                                            localKeyId: localKeyId)
        let safeContentsBody = certSafeBag + keySafeBag
        let safeContentsDER = tlv(tag: 0x30, content: safeContentsBody)

        // ContentInfo wrapping SafeContents as id-data
        let safeContentsCI = makeDataContentInfo(payload: safeContentsDER)

        // AuthenticatedSafe = SEQUENCE OF ContentInfo
        let authenticatedSafeDER = tlv(tag: 0x30, content: safeContentsCI)

        // Outer ContentInfo wrapping AuthenticatedSafe as id-data
        let outerContentInfo = makeDataContentInfo(payload: authenticatedSafeDER)

        // MAC over the AuthenticatedSafe DER bytes
        let macSalt: [UInt8] = randomBytes(8)
        let iterations = 2048
        let macKey = pkcs12PBKDF(password: password,
                                 salt: macSalt,
                                 iterations: iterations,
                                 id: 3,
                                 keyLength: 20)
        let macValue = hmacSHA1(key: macKey, data: authenticatedSafeDER)
        let macData = makeMacData(mac: macValue, salt: macSalt, iterations: iterations)

        // PFX = SEQUENCE { version=3, ContentInfo, MacData }
        var pfxBody: [UInt8] = []
        pfxBody.append(contentsOf: tlv(tag: 0x02, content: [3]))   // INTEGER 3
        pfxBody.append(contentsOf: outerContentInfo)
        pfxBody.append(contentsOf: macData)
        return tlv(tag: 0x30, content: pfxBody)
    }

    // MARK: - PKCS#12 structures

    private static func makeCertBag(certDER: [UInt8], localKeyId: [UInt8]) -> [UInt8] {
        // CertBag = SEQUENCE { OID x509Cert, [0] EXPLICIT OCTET STRING(certDER) }
        var certBagBody: [UInt8] = []
        certBagBody.append(contentsOf: oid([1, 2, 840, 113549, 1, 9, 22, 1])) // id-x509Certificate
        let octet = tlv(tag: 0x04, content: certDER)
        certBagBody.append(contentsOf: tlv(tag: 0xA0, content: octet))
        let certBag = tlv(tag: 0x30, content: certBagBody)

        // SafeBag = SEQUENCE { OID id-certBag, [0] EXPLICIT CertBag, bagAttributes }
        var safeBagBody: [UInt8] = []
        safeBagBody.append(contentsOf: oid([1, 2, 840, 113549, 1, 12, 10, 1, 3])) // id-certBag
        safeBagBody.append(contentsOf: tlv(tag: 0xA0, content: certBag))
        safeBagBody.append(contentsOf: makeLocalKeyIdAttributes(localKeyId: localKeyId))
        return tlv(tag: 0x30, content: safeBagBody)
    }

    /// Builds a `pkcs8ShroudedKeyBag` SafeBag containing the PKCS#8
    /// PrivateKeyInfo encrypted with `pbeWithSHAAnd3-KeyTripleDES-CBC`.
    /// `SecPKCS12Import` rejects plain (unencrypted) `keyBag` form, so this is
    /// the only way to get the parser to surface a usable identity.
    private static func makeShroudedKeyBag(keyPKCS8: [UInt8],
                                           password: String,
                                           salt: [UInt8],
                                           iterations: Int,
                                           localKeyId: [UInt8]) -> [UInt8] {
        let cipherKey = pkcs12PBKDF(password: password, salt: salt,
                                    iterations: iterations, id: 1, keyLength: 24)
        let iv = pkcs12PBKDF(password: password, salt: salt,
                             iterations: iterations, id: 2, keyLength: 8)
        let ciphertext = tripleDESCBCEncrypt(plaintext: keyPKCS8, key: cipherKey, iv: iv)

        // PBE params: SEQUENCE { salt OCTET STRING, iterations INTEGER }
        var pbeParamsBody: [UInt8] = []
        pbeParamsBody.append(contentsOf: tlv(tag: 0x04, content: salt))
        pbeParamsBody.append(contentsOf: tlv(tag: 0x02, content: encodeInteger(iterations)))
        let pbeParams = tlv(tag: 0x30, content: pbeParamsBody)

        // AlgorithmIdentifier: SEQUENCE { OID pbeWithSHAAnd3-KeyTripleDES-CBC, pbeParams }
        var algIdBody: [UInt8] = []
        algIdBody.append(contentsOf: oid([1, 2, 840, 113549, 1, 12, 1, 3]))
        algIdBody.append(contentsOf: pbeParams)
        let algId = tlv(tag: 0x30, content: algIdBody)

        // EncryptedPrivateKeyInfo: SEQUENCE { AlgorithmIdentifier, OCTET STRING encryptedData }
        var encryptedPKIBody: [UInt8] = []
        encryptedPKIBody.append(contentsOf: algId)
        encryptedPKIBody.append(contentsOf: tlv(tag: 0x04, content: ciphertext))
        let encryptedPKI = tlv(tag: 0x30, content: encryptedPKIBody)

        // SafeBag: SEQUENCE { OID id-pkcs8ShroudedKeyBag, [0] EXPLICIT EncryptedPrivateKeyInfo, bagAttributes }
        var safeBagBody: [UInt8] = []
        safeBagBody.append(contentsOf: oid([1, 2, 840, 113549, 1, 12, 10, 1, 2])) // id-pkcs8ShroudedKeyBag
        safeBagBody.append(contentsOf: tlv(tag: 0xA0, content: encryptedPKI))
        safeBagBody.append(contentsOf: makeLocalKeyIdAttributes(localKeyId: localKeyId))
        return tlv(tag: 0x30, content: safeBagBody)
    }

    private static func tripleDESCBCEncrypt(plaintext: [UInt8], key: [UInt8], iv: [UInt8]) -> [UInt8] {
        let bufferSize = plaintext.count + kCCBlockSize3DES
        var output = [UInt8](repeating: 0, count: bufferSize)
        var bytesEncrypted = 0
        let result = key.withUnsafeBufferPointer { keyPtr -> CCCryptorStatus in
            iv.withUnsafeBufferPointer { ivPtr in
                plaintext.withUnsafeBufferPointer { dataPtr in
                    output.withUnsafeMutableBufferPointer { outPtr in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithm3DES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, key.count,
                            ivPtr.baseAddress,
                            dataPtr.baseAddress, plaintext.count,
                            outPtr.baseAddress, bufferSize,
                            &bytesEncrypted
                        )
                    }
                }
            }
        }
        guard result == kCCSuccess else { return [] }
        return Array(output.prefix(bytesEncrypted))
    }

    /// Builds the `bagAttributes SET OF PKCS12Attribute` portion of a SafeBag
    /// containing a single `localKeyID` (OID 1.2.840.113549.1.9.21) attribute.
    private static func makeLocalKeyIdAttributes(localKeyId: [UInt8]) -> [UInt8] {
        // PKCS12Attribute = SEQUENCE { OID localKeyId, SET { OCTET STRING(value) } }
        var attrBody: [UInt8] = []
        attrBody.append(contentsOf: oid([1, 2, 840, 113549, 1, 9, 21])) // localKeyID
        let valueOctet = tlv(tag: 0x04, content: localKeyId)
        attrBody.append(contentsOf: tlv(tag: 0x31, content: valueOctet)) // SET of attrValues
        let attribute = tlv(tag: 0x30, content: attrBody)
        // bagAttributes SET OF PKCS12Attribute
        return tlv(tag: 0x31, content: attribute)
    }

    private static func makeDataContentInfo(payload: [UInt8]) -> [UInt8] {
        // ContentInfo = SEQUENCE { OID id-data, [0] EXPLICIT OCTET STRING(payload) }
        var body: [UInt8] = []
        body.append(contentsOf: oid([1, 2, 840, 113549, 1, 7, 1])) // id-data
        let octet = tlv(tag: 0x04, content: payload)
        body.append(contentsOf: tlv(tag: 0xA0, content: octet))
        return tlv(tag: 0x30, content: body)
    }

    private static func makeMacData(mac: [UInt8], salt: [UInt8], iterations: Int) -> [UInt8] {
        // DigestInfo = SEQUENCE { AlgorithmIdentifier { OID sha1, NULL }, OCTET STRING(mac) }
        var algorithmId: [UInt8] = []
        algorithmId.append(contentsOf: oid([1, 3, 14, 3, 2, 26])) // sha1
        algorithmId.append(contentsOf: tlv(tag: 0x05, content: []))      // NULL
        let algIdSeq = tlv(tag: 0x30, content: algorithmId)

        var digestInfoBody: [UInt8] = []
        digestInfoBody.append(contentsOf: algIdSeq)
        digestInfoBody.append(contentsOf: tlv(tag: 0x04, content: mac))
        let digestInfo = tlv(tag: 0x30, content: digestInfoBody)

        // MacData = SEQUENCE { DigestInfo, OCTET STRING macSalt, INTEGER iterations }
        var macDataBody: [UInt8] = []
        macDataBody.append(contentsOf: digestInfo)
        macDataBody.append(contentsOf: tlv(tag: 0x04, content: salt))
        macDataBody.append(contentsOf: tlv(tag: 0x02, content: encodeInteger(iterations)))
        return tlv(tag: 0x30, content: macDataBody)
    }

    // MARK: - DER primitives

    private static func tlv(tag: UInt8, content: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [tag]
        out.append(contentsOf: encodeLength(content.count))
        out.append(contentsOf: content)
        return out
    }

    private static func encodeLength(_ length: Int) -> [UInt8] {
        if length < 128 { return [UInt8(length)] }
        var bytes: [UInt8] = []
        var n = length
        while n > 0 {
            bytes.insert(UInt8(n & 0xFF), at: 0)
            n >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    private static func encodeInteger(_ value: Int) -> [UInt8] {
        // Minimal-length DER INTEGER encoding for a non-negative value.
        if value == 0 { return [0x00] }
        var bytes: [UInt8] = []
        var n = value
        while n > 0 {
            bytes.insert(UInt8(n & 0xFF), at: 0)
            n >>= 8
        }
        if bytes.first! & 0x80 != 0 {
            bytes.insert(0x00, at: 0)
        }
        return bytes
    }

    private static func oid(_ arcs: [Int]) -> [UInt8] {
        precondition(arcs.count >= 2)
        var content: [UInt8] = []
        content.append(UInt8(arcs[0] * 40 + arcs[1]))
        for arc in arcs.dropFirst(2) {
            var n = arc
            var part: [UInt8] = []
            repeat {
                part.insert(UInt8(n & 0x7F), at: 0)
                n >>= 7
            } while n > 0
            for i in 0..<(part.count - 1) {
                part[i] |= 0x80
            }
            content.append(contentsOf: part)
        }
        return tlv(tag: 0x06, content: content)
    }

    // MARK: - Crypto

    private static func randomBytes(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return bytes
    }

    private static func hmacSHA1(key: [UInt8], data: [UInt8]) -> [UInt8] {
        let symKey = SymmetricKey(data: key)
        let auth = HMAC<Insecure.SHA1>.authenticationCode(for: data, using: symKey)
        return Array(auth)
    }

    private static func sha1(_ data: [UInt8]) -> [UInt8] {
        Array(Insecure.SHA1.hash(data: data))
    }

    /// PKCS#12 password-based key derivation, RFC 7292 Appendix B.
    /// `id` is 1 (encryption key), 2 (IV), or 3 (MAC key).
    private static func pkcs12PBKDF(password: String,
                                    salt: [UInt8],
                                    iterations: Int,
                                    id: UInt8,
                                    keyLength: Int) -> [UInt8] {
        let v = 64  // SHA-1 block size
        let u = 20  // SHA-1 output size

        // BMPString: each Unicode scalar as UTF-16BE, plus a UTF-16BE null terminator.
        var pwdBytes: [UInt8] = []
        for scalar in password.unicodeScalars {
            let code = scalar.value
            pwdBytes.append(UInt8((code >> 8) & 0xFF))
            pwdBytes.append(UInt8(code & 0xFF))
        }
        pwdBytes.append(0)
        pwdBytes.append(0)

        // D = id repeated v times
        let D = [UInt8](repeating: id, count: v)

        // S = salt repeated to fill a multiple of v
        let sLen = ((salt.count + v - 1) / v) * v
        var S = [UInt8](repeating: 0, count: sLen)
        for i in 0..<sLen { S[i] = salt[i % salt.count] }

        // P = password repeated to fill a multiple of v
        let pLen = ((pwdBytes.count + v - 1) / v) * v
        var P = [UInt8](repeating: 0, count: pLen)
        for i in 0..<pLen { P[i] = pwdBytes[i % pwdBytes.count] }

        var I = S + P

        var output: [UInt8] = []
        let blocks = (keyLength + u - 1) / u

        for _ in 0..<blocks {
            // A = SHA1^iterations(D || I)
            var A = sha1(D + I)
            for _ in 1..<iterations { A = sha1(A) }
            output.append(contentsOf: A)

            // B = A repeated to fill v bytes
            var B = [UInt8](repeating: 0, count: v)
            for i in 0..<v { B[i] = A[i % u] }

            // For each v-byte block I_j: I_j = (I_j + B + 1) mod 2^(v*8)
            let blockCount = I.count / v
            for j in 0..<blockCount {
                var carry: UInt32 = 1
                for k in stride(from: v - 1, through: 0, by: -1) {
                    let sum = UInt32(I[j * v + k]) + UInt32(B[k]) + carry
                    I[j * v + k] = UInt8(sum & 0xFF)
                    carry = sum >> 8
                }
            }
        }

        return Array(output.prefix(keyLength))
    }
}
