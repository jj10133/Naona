import AVFoundation
import VideoToolbox
import CoreMedia
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

final class MediaRenderer {

    let peerId: String
    var isAudioMuted = false
    var isVideoMuted = false
    var aacSampleRate: Double = 44100
    var aacChannels:   UInt32 = 2

    private let displayLayer   = AVSampleBufferDisplayLayer()


    private var sps: Data?
    private var pps: Data?
    private var videoFormat: CMVideoFormatDescription?
    private var gotKeyframe = false

    init(peerId: String) {
        self.peerId = peerId
        displayLayer.videoGravity    = .resizeAspectFill
        displayLayer.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)

        // Set a timebase so the layer knows when to display frames
        var timebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: nil,
            sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase)
        if let timebase {
            CMTimebaseSetTime(timebase, time: CMClockGetTime(CMClockGetHostTimeClock()))
            CMTimebaseSetRate(timebase, rate: 1.0)
            displayLayer.controlTimebase = timebase
        }
        _setupAudio()  // AudioFileStream + AudioQueue
    }

    func makeVideoLayer() -> AVSampleBufferDisplayLayer { displayLayer }

    func receiveVideo(_ data: Data) {
        guard !isVideoMuted else { return }
        _parseAnnexB(data)
    }

    func receiveAudio(_ data: Data) {
        guard !isAudioMuted else { return }
        _decodeAudio(data)
    }

    func stop() {
        if let q = audioQueue { AudioQueueStop(q, true); AudioQueueDispose(q, true) }
        if let s = audioFileStream { AudioFileStreamClose(s) }
        audioQueue = nil; audioFileStream = nil; audioStarted = false
    }

    // MARK: - Video

    private func _parseAnnexB(_ data: Data) {
        let bytes = [UInt8](data)
        var nals: [Data] = []
        var i = 0, start = -1

        while i < bytes.count {
            let sc4 = i + 3 < bytes.count && bytes[i]==0 && bytes[i+1]==0 && bytes[i+2]==0 && bytes[i+3]==1
            let sc3 = i + 2 < bytes.count && bytes[i]==0 && bytes[i+1]==0 && bytes[i+2]==1
            if sc4 || sc3 {
                if start >= 0 { nals.append(data.subdata(in: start..<i)) }
                i += sc4 ? 4 : 3; start = i
            } else { i += 1 }
        }
        if start >= 0 { nals.append(data.subdata(in: start..<data.count)) }

        for nal in nals where !nal.isEmpty {
            switch nal[0] & 0x1F {
            case 7: sps = nal; _rebuildFormat()
            case 8: pps = nal; _rebuildFormat()
            case 5: gotKeyframe = true; _enqueue(nal, isIDR: true)
            case 1: if gotKeyframe { _enqueue(nal, isIDR: false) }
            default: break
            }
        }
    }

    private func _rebuildFormat() {
        guard let sps, let pps else { return }
        sps.withUnsafeBytes { spsPtr in
            pps.withUnsafeBytes { ppsPtr in
                let ptrs: [UnsafePointer<UInt8>] = [
                    spsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    ppsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                ]
                let sizes = [sps.count, pps.count]
                var fmt: CMVideoFormatDescription?
                if CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: 2,
                    parameterSetPointers: ptrs, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &fmt
                ) == noErr { videoFormat = fmt }
            }
        }
    }

    private func _enqueue(_ nal: Data, isIDR: Bool) {
        guard let fmt = videoFormat else { return }

        let lenBE = UInt32(nal.count).bigEndian
        var avcc  = withUnsafeBytes(of: lenBE) { Data($0) }
        avcc.append(nal)

        var copy  = avcc
        var block: CMBlockBuffer?
        let len   = copy.count
        copy.withUnsafeMutableBytes { ptr in
            CMBlockBufferCreateWithMemoryBlock(
                allocator: nil, memoryBlock: ptr.baseAddress,
                blockLength: len, blockAllocator: kCFAllocatorNull,
                customBlockSource: nil, offsetToData: 0, dataLength: len,
                flags: 0, blockBufferOut: &block)
        }
        guard let block else { return }

        let now    = CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: now,
            decodeTimeStamp: .invalid)
        var size   = len
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: nil, dataBuffer: block, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil,
            formatDescription: fmt, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sample) == noErr, let sample else { return }

        // Mark display immediately
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(atts) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(atts, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.displayLayer.status == .failed { self.displayLayer.flush() }
            if self.displayLayer.isReadyForMoreMediaData {
                self.displayLayer.enqueue(sample)
            }
        }
    }

    // MARK: - Audio (AudioFileStream handles ADTS parsing automatically)

    private var audioFileStream: AudioFileStreamID?
    private var audioQueue:      AudioQueueRef?
    private var audioStarted     = false

    private func _setupAudio() {
        // Use AudioQueue directly — bypasses AVAudioConverter ADTS issues entirely
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        AudioFileStreamOpen(selfPtr, { userData, _, propertyID, _ in
            let me = Unmanaged<MediaRenderer>.fromOpaque(userData).takeUnretainedValue()
            me._audioStreamProperty(propertyID)
        }, { userData, numBytes, numPackets, inputData, packetDescs in
            let me = Unmanaged<MediaRenderer>.fromOpaque(userData).takeUnretainedValue()
            me._audioPackets(numBytes: numBytes, numPackets: numPackets,
                             inputData: inputData, packetDescs: packetDescs)
        }, kAudioFileAAC_ADTSType, &audioFileStream)
    }

    private func _audioStreamProperty(_ propertyID: AudioFileStreamPropertyID) {
        guard propertyID == kAudioFileStreamProperty_ReadyToProducePackets,
              let stream = audioFileStream else { return }

        var asbd     = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_DataFormat,
                                   &asbdSize, &asbd)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        AudioQueueNewOutput(&asbd, { _, queue, buffer in
            AudioQueueFreeBuffer(queue, buffer)
        }, selfPtr, nil, nil, 0, &audioQueue)

        if let queue = audioQueue {
            AudioQueueStart(queue, nil)
            audioStarted = true
        }
    }

    private func _audioPackets(numBytes: UInt32, numPackets: UInt32,
                                inputData: UnsafeRawPointer,
                                packetDescs: UnsafeMutablePointer<AudioStreamPacketDescription>?) {
        guard let queue = audioQueue, audioStarted else { return }
        var buffer: AudioQueueBufferRef?
        guard AudioQueueAllocateBuffer(queue, numBytes, &buffer) == noErr,
              let buf = buffer else { return }
        memcpy(buf.pointee.mAudioData, inputData, Int(numBytes))
        buf.pointee.mAudioDataByteSize = numBytes
        AudioQueueEnqueueBuffer(queue, buf, numPackets, packetDescs)
    }

    private func _decodeAudio(_ data: Data) {
        guard let stream = audioFileStream else { return }
        data.withUnsafeBytes { ptr in
            AudioFileStreamParseBytes(stream, UInt32(data.count),
                                      ptr.baseAddress!, [])
        }
    }
}
