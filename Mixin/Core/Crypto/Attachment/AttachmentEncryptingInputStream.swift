import UIKit

class AttachmentEncryptingInputStream: InputStream {
    
    private(set) var key: Data? // available after initialized
    private(set) var digest: Data? // available after closed
    private(set) var contentLength = -1
    
    private let inputStream: InputStream
    private let plainDataSize: Int
    
    private var cryptor: CCCryptorRef!
    private var hmacContext = CCHmacContext()
    private var digestContext = CC_SHA256_CTX()
    private var outputBuffer = Data()
    private var error: Error?
    private var didFinalizedEncryption = false
    
    internal let isLogEnabled: Bool = false
    
    override var delegate: StreamDelegate? {
        get {
            return inputStream.delegate
        }
        set {
            inputStream.delegate = newValue
        }
    }
    
    override var streamStatus: Stream.Status {
        return error != nil ? .error : inputStream.streamStatus
    }
    
    override var streamError: Error? {
        return error ?? inputStream.streamError
    }
    
    override var hasBytesAvailable: Bool {
        let hasBytesAvailable = !didFinalizedEncryption || inputStream.hasBytesAvailable || !outputBuffer.isEmpty
        log("Report hasBytesAvailable: \(hasBytesAvailable)")
        return hasBytesAvailable
    }
    
    public override init(data: Data) {
        inputStream = InputStream(data: data)
        plainDataSize = data.count
        super.init(data: data)
        prepare()
    }
    
    public override init?(url: URL) {
        guard case let fileSize?? = try? url.resourceValues(forKeys: Set([.fileSizeKey])).fileSize, let stream = InputStream(url: url) else {
            return nil
        }
        plainDataSize = fileSize
        inputStream = stream
        super.init(url: url)
        prepare()
    }
    
    override func open() {
        inputStream.open()
    }
    
    override func close() {
        inputStream.close()
    }
    
    override func property(forKey key: Stream.PropertyKey) -> Any? {
        return inputStream.property(forKey: key)
    }
    
    override func setProperty(_ property: Any?, forKey key: Stream.PropertyKey) -> Bool {
        return inputStream.setProperty(property, forKey: key)
    }
    
    override func schedule(in aRunLoop: RunLoop, forMode mode: RunLoopMode) {
        inputStream.schedule(in: aRunLoop, forMode: mode)
    }
    
    override func remove(from aRunLoop: RunLoop, forMode mode: RunLoopMode) {
        inputStream.remove(from: aRunLoop, forMode: mode)
    }
    
    override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        guard outputBuffer.isEmpty else {
            return writeOutputBuffer(to: buffer, maxLength: len)
        }
        while outputBuffer.isEmpty && inputStream.hasBytesAvailable {
            var inputBuffer = Data(count: len)
            inputBuffer.count = inputBuffer.withUnsafeMutableBytes {
                inputStream.read($0, maxLength: len)
            }
            log("input: \(inputBuffer as NSData)")
            if outputBuffer.count == 0 {
                // withUnsafeMutableBytes crashes for zero-counted Data
                outputBuffer.count = inputBuffer.count
            }
            var outputSize = outputBuffer.count
            var status = outputBuffer.withUnsafeMutableBytes {
                CCCryptorUpdate(cryptor, (inputBuffer as NSData).bytes, inputBuffer.count, $0, outputSize, &outputSize)
            }
            if status == .success {
                outputBuffer.count = outputSize
            } else if status == .bufferTooSmall {
                outputSize = CCCryptorGetOutputLength(cryptor, inputBuffer.count, false)
                outputBuffer.count = outputSize
                status = outputBuffer.withUnsafeMutableBytes {
                    CCCryptorUpdate(cryptor, (inputBuffer as NSData).bytes, inputBuffer.count, $0, outputSize, &outputSize)
                }
            }
            if status == .success {
                outputBuffer.withUnsafeBytes { (bytes: UnsafePointer<UInt8>) -> Void in
                    CCHmacUpdate(&hmacContext, bytes, outputSize)
                    CC_SHA256_Update(&digestContext, bytes, CC_LONG(outputSize))
                }
            } else {
                error = AttachmentCryptographyError.encryptorUpdate(status)
            }
        }
        if outputBuffer.isEmpty && !inputStream.hasBytesAvailable {
            finalizeEncryption()
        }
        let numberOfBytesWritten: Int
        if error == nil {
            if !outputBuffer.isEmpty {
                numberOfBytesWritten = writeOutputBuffer(to: buffer, maxLength: len)
            } else {
                numberOfBytesWritten = 0
            }
        } else {
            numberOfBytesWritten = -1
        }
        log("output \(numberOfBytesWritten) bytes of data")
        return numberOfBytesWritten
    }
    
    override func getBuffer(_ buffer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>, length len: UnsafeMutablePointer<Int>) -> Bool {
        return false
    }
    
}

extension AttachmentEncryptingInputStream {
    
    private func prepare() {
        do {
            let iv = try AttachmentCryptography.randomData(length: .aesCbcIv)
            let encryptionKey = try AttachmentCryptography.randomData(length: .aesKey)
            let hmacKey = try AttachmentCryptography.randomData(length: .hmac256Key)
            log("Generated iv: \(iv as NSData)")
            log("Generated encryptionKey: \(encryptionKey as NSData)")
            log("Generated hmacKey: \(hmacKey as NSData)\n")
            
            cryptor = try CCCryptorRef(operation: .encrypt, algorithm: .aes128, options: .pkcs7Padding, key: encryptionKey, iv: iv)
            
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
            
            key = encryptionKey + hmacKey
            outputBuffer = iv
            contentLength = AttachmentCryptography.Length.aesCbcIv.value
                + CCCryptorGetOutputLength(cryptor, plainDataSize, true)
                + AttachmentCryptography.Length.hmac.value
        } catch let error {
            self.error = error
        }
    }
    
    private func finalizeEncryption() {
        var outputSize = CCCryptorGetOutputLength(cryptor, 0, true)
        outputBuffer = Data(count: outputSize)
        let status = outputBuffer.withUnsafeMutableBytes {
            CCCryptorFinal(cryptor, $0, outputSize, &outputSize)
        }
        outputBuffer.count = outputSize
        guard status == .success else {
            error = AttachmentCryptographyError.encryptorUpdate(status)
            return
        }
        outputBuffer.withUnsafeBytes {
            CCHmacUpdate(&hmacContext, $0, outputSize)
        }
        var hmac = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
        hmac.withUnsafeMutableBytes {
            CCHmacFinal(&hmacContext, $0)
        }
        hmac = hmac[0..<AttachmentCryptography.Length.hmac.value]
        log("Generated HMAC: \(hmac as NSData)\n")
        outputBuffer.append(hmac)
        outputSize = outputBuffer.count
        log("HMAC appended to output buffer. output: \(outputBuffer as NSData)\n")
        _ = outputBuffer.withUnsafeBytes {
            CC_SHA256_Update(&digestContext, $0, CC_LONG(outputSize))
        }
        var digest = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
        _ = digest.withUnsafeMutableBytes {
            CC_SHA256_Final($0, &digestContext)
        }
        log("Generated digest: \(digest as NSData)\n")
        self.digest = digest
        didFinalizedEncryption = true
        log("Finalized encryption. Remaining output: \(outputBuffer as NSData)")
    }
    
    private func writeOutputBuffer(to destination: UnsafeMutablePointer<UInt8>, maxLength: Int) -> Int {
        let numberOfBytesToCopy = min(maxLength, outputBuffer.count)
        outputBuffer.copyBytes(to: destination, count: numberOfBytesToCopy)
        let firstUncopiedIndex = outputBuffer.startIndex.advanced(by: numberOfBytesToCopy)
        log("output: \(outputBuffer[outputBuffer.startIndex..<firstUncopiedIndex] as NSData)\n")
        // withUnsafeMutableBytes crash for data slices before Swift 4.1
        // Use outputBuffer = outputBuffer[firstUncopiedIndex...] after upgraded
        outputBuffer = Data(outputBuffer[firstUncopiedIndex...])
        return numberOfBytesToCopy
    }
    
    @inline(__always) private func log(_ item: Any) {
        #if DEBUG
            if isLogEnabled {
                print(item)
            }
        #endif
    }
    
}
