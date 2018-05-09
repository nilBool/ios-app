import UIKit

class AttachmentDecryptingOutputStream: OutputStream {
    
    private let handle: FileHandle
    private let encryptionKey: Data
    private let hmacKey: Data
    private let digest: Data
    
    private var iv: Data?
    private var cryptor: CCCryptorRef?
    private var hmacContext = CCHmacContext()
    private var digestContext = CC_SHA256_CTX()
    private var inputBuffer = Data()
    private var outputBuffer = Data()
    private var status = Stream.Status.notOpen
    private var error: Error?
    
    internal let isLogEnabled: Bool = false

    override var streamStatus: Stream.Status {
        return status
    }

    override var streamError: Error? {
        return error
    }
    
    override var hasSpaceAvailable: Bool {
        return true
    }
    
    init?(url: URL, key: Data, digest: Data) {
        guard key.count > 0, key.count >= AttachmentCryptography.Length.aesKey.value + AttachmentCryptography.Length.hmac256Key.value else {
            return nil
        }
        guard digest.count > 0 else {
            return nil
        }
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: nil) else {
            return nil
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            return nil
        }
        self.handle = handle
        let encryptionKeyStartIndex = key.startIndex
        let encryptionKeyEndIndex = encryptionKeyStartIndex.advanced(by: AttachmentCryptography.Length.aesKey.value)
        self.encryptionKey = key[encryptionKeyStartIndex..<encryptionKeyEndIndex]
        let hmacKeyStartIndex = encryptionKeyEndIndex
        let hmacKeyEndIndex = hmacKeyStartIndex.advanced(by: AttachmentCryptography.Length.hmac256Key.value)
        self.hmacKey = key[hmacKeyStartIndex..<hmacKeyEndIndex]
        self.digest = digest
        super.init(url: url, append: false)
        log("Using encryptionKey: \(encryptionKey as NSData)")
        log("Using hmacKey: \(hmacKey as NSData)")
        log("Using digest: \(digest as NSData)\n")
    }
    
    override func open() {
        status = .open
    }
    
    override func write(_ buffer: UnsafePointer<UInt8>, maxLength len: Int) -> Int {
        log("input: \(Data(bytes: buffer, count: len) as NSData)")
        inputBuffer.append(buffer, count: len)
        if iv == nil, inputBuffer.count >= AttachmentCryptography.Length.aesCbcIv.value {
            let ivStartIndex = inputBuffer.startIndex
            let ivEndIndex = inputBuffer.startIndex.advanced(by: AttachmentCryptography.Length.aesCbcIv.value)
            let iv = inputBuffer[ivStartIndex..<ivEndIndex]
            inputBuffer = inputBuffer[ivEndIndex...]
            
            hmacKey.withUnsafeBytes {
                CCHmacInit(&hmacContext, .sha256, $0, hmacKey.count)
            }
            iv.withUnsafeBytes {
                CCHmacUpdate(&hmacContext, $0, iv.count)
            }
            CC_SHA256_Init(&digestContext)
            _ = iv.withUnsafeBytes {
                CC_SHA256_Update(&digestContext, $0, CC_LONG(iv.count))
            }
            
            self.iv = iv
            log("Using IV: \(iv as NSData)\n")
        }
        if cryptor == nil, let iv = iv {
            do {
                cryptor = try CCCryptorRef(operation: .decrypt, algorithm: .aes128, options: .pkcs7Padding, key: encryptionKey, iv: iv)
            } catch let error {
                self.error = error
                status = .error
            }
        }
        // InputBuffer(dropping trailing of HMAC's size) -> bufferToDecrypt -> CCCryptor -> outputBuffer -> Write to fileHandle
        if let cryptor = cryptor, inputBuffer.count > AttachmentCryptography.Length.hmac.value {
            var outputSize = inputBuffer.count - AttachmentCryptography.Length.hmac.value
            if outputBuffer.count < outputSize {
                outputBuffer.count = outputSize
            }
            let bufferToDecrypt = inputBuffer[..<inputBuffer.endIndex.advanced(by: -AttachmentCryptography.Length.hmac.value)]
            log("decrypting data: \(bufferToDecrypt as NSData)\n")
            var status = outputBuffer.withUnsafeMutableBytes {
                CCCryptorUpdate(cryptor, (bufferToDecrypt as NSData).bytes, bufferToDecrypt.count, $0, outputSize, &outputSize)
            }
            if status == .bufferTooSmall {
                outputSize = CCCryptorGetOutputLength(cryptor, bufferToDecrypt.count, false)
                outputBuffer.count = outputSize
                status = outputBuffer.withUnsafeMutableBytes {
                    CCCryptorUpdate(cryptor, (bufferToDecrypt as NSData).bytes, bufferToDecrypt.count, $0, outputSize, &outputSize)
                }
            }
            if status == .success {
                bufferToDecrypt.withUnsafeBytes { (bytes: UnsafePointer<UInt8>) -> Void in
                    CCHmacUpdate(&hmacContext, bytes, bufferToDecrypt.count)
                    CC_SHA256_Update(&digestContext, bytes, CC_LONG(bufferToDecrypt.count))
                }
                outputBuffer.count = outputSize
                handle.write(outputBuffer)
                log("Wrote to file. data: \(outputBuffer[outputBuffer.startIndex..<outputBuffer.startIndex.advanced(by: outputSize)] as Data)")
                inputBuffer = inputBuffer[inputBuffer.endIndex.advanced(by: -AttachmentCryptography.Length.hmac.value)...]
            } else {
                self.error = AttachmentCryptographyError.decryptorUpdate(status)
                self.status = .error
            }
        }
        return len
    }

    override func close() {
        defer {
            self.status = .closed
            handle.closeFile()
        }
        guard inputBuffer.count == AttachmentCryptography.Length.hmac.value else {
            self.error = AttachmentCryptographyError.unexpectedEnding
            return
        }
        var outputSize = CCCryptorGetOutputLength(cryptor, 0, true)
        if outputBuffer.count < outputSize {
            outputBuffer.count = outputSize
        }
        outputBuffer.count = outputSize
        let status = outputBuffer.withUnsafeMutableBytes {
            CCCryptorFinal(cryptor, $0, outputSize, &outputSize)
        }
        guard status == .success else {
            self.error = AttachmentCryptographyError.decryptorFinal(status)
            return
        }
        outputBuffer.count = outputSize
        handle.write(outputBuffer)
        
        var ourHMAC = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
        ourHMAC.withUnsafeMutableBytes {
            CCHmacFinal(&hmacContext, $0)
        }
        log("Generated ourHMAC: \(ourHMAC as NSData)\n")
        let hmac = Data(inputBuffer) // Avoiding Swift 4.0.3 Data Slice bug
        log("Using hmac: \(hmac as NSData)\n")
        if hmac.isEqualToDataInConstantTime(ourHMAC) {
            _ = hmac.withUnsafeBytes {
                CC_SHA256_Update(&digestContext, $0, CC_LONG(hmac.count))
            }
            var ourDigest = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
            _ = ourDigest.withUnsafeMutableBytes {
                CC_SHA256_Final($0, &digestContext)
            }
            if !digest.isEqualToDataInConstantTime(ourDigest) {
                self.error = AttachmentCryptographyError.digestInconsistency
            }
        } else {
            self.error = AttachmentCryptographyError.hmacInconsistency
        }
    }
    
    @inline(__always) private func log(_ item: Any) {
        #if DEBUG
            if isLogEnabled {
                print(item)
            }
        #endif
    }
    
}
