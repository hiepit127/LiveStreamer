import Foundation
import AudioToolbox
import AVFoundation

class AudioStreamPlayback {
    static let defaultBufferSize: UInt32 = 128 * 1024
    static let defaultNumberOfBuffers: Int = 128
    static let defaultMaxPacketDescriptions: Int = 1

    var await: Bool = false
    var config: AudioSpecificConfig?
    var runloop: CFRunLoop?
    var numberOfBuffers: Int = AudioStreamPlayback.defaultNumberOfBuffers
    var maxPacketDescriptions: Int = AudioStreamPlayback.defaultMaxPacketDescriptions

    var soundTransform: SoundTransform = SoundTransform() {
        didSet {
            guard let queue: AudioQueueRef = queue, running else { return }
            soundTransform.setParameter(queue)
        }
    }

    private(set) var running: Bool = false
    var formatDescription: AudioStreamBasicDescription?
    var fileTypeHint: AudioFileTypeID? {
        didSet {
            guard let fileTypeHint: AudioFileTypeID = fileTypeHint, fileTypeHint != oldValue else { return }
            var fileStreamID: OpaquePointer?
            if AudioFileStreamOpen(
                unsafeBitCast(self, to: UnsafeMutableRawPointer.self),
                propertyListenerProc,
                packetsProc,
                fileTypeHint,
                &fileStreamID) == noErr {
                self.fileStreamID = fileStreamID
            }
        }
    }
    let lockQueue = DispatchQueue(label: "com.haishinkit.HaishinKit.AudioStreamPlayback.lock")
    private var bufferSize: UInt32 = AudioStreamPlayback.defaultBufferSize
    private var queue: AudioQueueRef? = nil {
        didSet {
            oldValue.map {
                AudioQueueStop($0, true)
                AudioQueueDispose($0, true)
            }
        }
    }
    private var inuse: [Bool] = []
    private var buffers: [AudioQueueBufferRef] = []
    private var current: Int = 0
    private var started: Bool = false
    private var filledBytes: UInt32 = 0
    private var packetDescriptions: [AudioStreamPacketDescription] = []
    private var fileStreamID: AudioFileStreamID? = nil {
        didSet {
            _ = oldValue.map { AudioFileStreamClose($0) }
        }
    }
    private var isPacketDescriptionsFull: Bool {
        return packetDescriptions.count == maxPacketDescriptions
    }

    private var outputCallback: AudioQueueOutputCallback = {(
        inUserData: UnsafeMutableRawPointer?,
        inAQ: AudioQueueRef,
        inBuffer: AudioQueueBufferRef) -> Void in
        let playback: AudioStreamPlayback = unsafeBitCast(inUserData, to: AudioStreamPlayback.self)
        playback.onOutputForQueue(inAQ, inBuffer)
    }

    private var packetsProc: AudioFileStream_PacketsProc = {(
        inClientData: UnsafeMutableRawPointer,
        inNumberBytes: UInt32,
        inNumberPackets: UInt32,
        inInputData: UnsafeRawPointer,
        inPacketDescriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?) -> Void in
        let playback: AudioStreamPlayback = unsafeBitCast(inClientData, to: AudioStreamPlayback.self)
        playback.initializeForAudioQueue()
        if let inPacketDescriptions = inPacketDescriptions {
            playback.onAudioPacketsForFileStream(inNumberBytes, inNumberPackets, inInputData, inPacketDescriptions)
        }
    }

    private var propertyListenerProc: AudioFileStream_PropertyListenerProc = {(
        inClientData: UnsafeMutableRawPointer,
        inAudioFileStream: AudioFileStreamID,
        inPropertyID: AudioFileStreamPropertyID,
        ioFlags: UnsafeMutablePointer<AudioFileStreamPropertyFlags>) -> Void in
        let playback: AudioStreamPlayback = unsafeBitCast(inClientData, to: AudioStreamPlayback.self)
        playback.onPropertyChangeForFileStream(inAudioFileStream, inPropertyID, ioFlags)
    }

    func parseBytes(_ data: Data) {
        guard let fileStreamID: AudioFileStreamID = fileStreamID, running else { return }
        data.withUnsafeBytes { (bytes: UnsafePointer<UInt8>) -> Void in
            AudioFileStreamParseBytes(
                fileStreamID,
                UInt32(data.count),
                bytes,
                []
            )
        }
    }

    func isBufferFull(_ packetSize: UInt32) -> Bool {
        return (bufferSize - filledBytes) < packetSize
    }

    func appendBuffer(_ inInputData: UnsafeRawPointer, inPacketDescription: inout AudioStreamPacketDescription) {
        let offset: Int = Int(inPacketDescription.mStartOffset)
        let packetSize: UInt32 = inPacketDescription.mDataByteSize
        if isBufferFull(packetSize) || isPacketDescriptionsFull {
            enqueueBuffer()
            rotateBuffer()
        }
        let buffer: AudioQueueBufferRef = buffers[current]
        memcpy(buffer.pointee.mAudioData.advanced(by: Int(filledBytes)), inInputData.advanced(by: offset), Int(packetSize))
        inPacketDescription.mStartOffset = Int64(filledBytes)
        packetDescriptions.append(inPacketDescription)
        filledBytes += packetSize
    }

    func rotateBuffer() {
        current += 1
        if numberOfBuffers <= current {
            current = 0
        }
        filledBytes = 0
        packetDescriptions.removeAll()
        var loop: Bool = true
        repeat {
            objc_sync_enter(inuse)
            loop = inuse[current]
            objc_sync_exit(inuse)
        }
        while(loop)
    }

    func enqueueBuffer() {
        guard let queue: AudioQueueRef = queue, running else { return }
        inuse[current] = true
        let buffer: AudioQueueBufferRef = buffers[current]
        buffer.pointee.mAudioDataByteSize = filledBytes
        guard AudioQueueEnqueueBuffer(
            queue,
            buffer,
            UInt32(packetDescriptions.count),
            &packetDescriptions) == noErr else {
            printLog("AudioQueueEnqueueBuffer")
            return
        }
    }

    func startQueueIfNeed() {
        guard let queue: AudioQueueRef = queue, !started else { return }
        started = true
        AudioQueuePrime(queue, 0, nil)
        AudioQueueStart(queue, nil)
    }

    func initializeForAudioQueue() {
        guard formatDescription != nil && self.queue == nil else { return }
        var queue: AudioQueueRef? = nil
        DispatchQueue.global(qos: .background).sync {
            self.runloop = CFRunLoopGetCurrent()
            AudioQueueNewOutput(
                &self.formatDescription!,
                self.outputCallback,
                unsafeBitCast(self, to: UnsafeMutableRawPointer.self),
                self.runloop,
                CFRunLoopMode.commonModes.rawValue,
                0,
                &queue)
        }
        if let cookie: [UInt8] = getMagicCookieForFileStream() {
            _ = setMagicCookieForQueue(cookie)
        }
        soundTransform.setParameter(queue!)
        for _ in 0..<numberOfBuffers {
            var buffer: AudioQueueBufferRef? = nil
            AudioQueueAllocateBuffer(queue!, bufferSize, &buffer)
            if let buffer: AudioQueueBufferRef = buffer {
                buffers.append(buffer)
            }
        }
        self.queue = queue
    }

    final func onOutputForQueue(_ inAQ: AudioQueueRef, _ inBuffer: AudioQueueBufferRef) {
        guard let i: Int = buffers.firstIndex(of: inBuffer) else { return }
        objc_sync_enter(inuse)
        inuse[i] = false
        objc_sync_exit(inuse)
    }

    final func onAudioPacketsForFileStream(_ inNumberBytes: UInt32, _ inNumberPackets: UInt32, _ inInputData: UnsafeRawPointer, _ inPacketDescriptions: UnsafeMutablePointer<AudioStreamPacketDescription>) {
        for i in 0..<Int(inNumberPackets) {
            appendBuffer(inInputData, inPacketDescription: &inPacketDescriptions[i])
        }
    }

    final func onPropertyChangeForFileStream(_ inAudioFileStream: AudioFileStreamID, _ inPropertyID: AudioFileStreamPropertyID, _ ioFlags: UnsafeMutablePointer<AudioFileStreamPropertyFlags>) {
        switch inPropertyID {
        case kAudioFileStreamProperty_ReadyToProducePackets:
            break
        case kAudioFileStreamProperty_DataFormat:
            formatDescription = getFormatDescriptionForFileStream()
        default:
            break
        }
    }

    func setMagicCookieForQueue(_ inData: [UInt8]) -> Bool {
        guard let queue: AudioQueueRef = queue else { return false }
        var status: OSStatus = noErr
        status = AudioQueueSetProperty(queue, kAudioQueueProperty_MagicCookie, inData, UInt32(inData.count))
        guard status == noErr else {
            printLog("status \(status)")
            return false
        }
        return true
    }

    func getFormatDescriptionForFileStream() -> AudioStreamBasicDescription? {
        guard let fileStreamID: AudioFileStreamID = fileStreamID else { return nil }
        var data: AudioStreamBasicDescription = AudioStreamBasicDescription()
        var size: UInt32 = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioFileStreamGetProperty(fileStreamID, kAudioFileStreamProperty_DataFormat, &size, &data) == noErr else {
            printLog("kAudioFileStreamProperty_DataFormat")
            return nil
        }
        return data
    }

    func getMagicCookieForFileStream() -> [UInt8]? {
        guard let fileStreamID: AudioFileStreamID = fileStreamID else {
            return nil
        }
        var size: UInt32 = 0
        var writable: DarwinBoolean = true
        guard AudioFileStreamGetPropertyInfo(fileStreamID, kAudioFileStreamProperty_MagicCookieData, &size, &writable) == noErr else {
            printLog("info kAudioFileStreamProperty_MagicCookieData")
            return nil
        }
        var data: [UInt8] = [UInt8](repeating: 0, count: Int(size))
        guard AudioFileStreamGetProperty(fileStreamID, kAudioFileStreamProperty_MagicCookieData, &size, &data) == noErr else {
            printLog("kAudioFileStreamProperty_MagicCookieData")
            return nil
        }
        return data
    }
}

extension AudioStreamPlayback: Running {
    // MARK: Running
    func startRunning() {
        lockQueue.async {
            guard self.running == false else { return }
            self.inuse = [Bool](repeating: false, count: self.numberOfBuffers)
            self.started = false
            self.current = 0
            self.filledBytes = 0
            self.fileTypeHint = nil
            self.packetDescriptions.removeAll()
            self.running = true
            AudioUtil.startRunning()
        }
    }

    func stopRunning() {
        lockQueue.async {
            guard self.running == true else { return }
            self.queue = nil
            if let runloop: CFRunLoop = self.runloop {
                CFRunLoopStop(runloop)
            }
            self.runloop = nil
            self.inuse.removeAll()
            self.buffers.removeAll()
            self.started = false
            self.fileStreamID = nil
            self.packetDescriptions.removeAll()
            self.running = false
            AudioUtil.stopRunning()
        }
    }
}
