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
    private let audioEngine    = AVAudioEngine()
    private let playerNode     = AVAudioPlayerNode()
    private var audioConverter: AVAudioConverter?
    private var outputFormat:   AVAudioFormat!

    private var sps: Data?
    private var pps: Data?
    private var videoFormat: CMVideoFormatDescription?
    private var gotKeyframe = false

    init(peerId: String) {
        self.peerId = peerId
        outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                     sampleRate: 44100, channels: 2, interleaved: false)!
        displayLayer.videoGravity        = .resizeAspectFill
        displayLayer.backgroundColor     = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        displayLayer.controlTimebase     = nil
        _setupAudio()
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
        playerNode.stop()
        audioEngine.stop()
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

    // MARK: - Audio

    private func _setupAudio() {
        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: outputFormat)
        try? audioEngine.start()
        playerNode.play()
    }

    private func _decodeAudio(_ data: Data) {
        // data may be raw AAC or ADTS-wrapped AAC
        // Build AVAudioConverter lazily when we know sample rate + channels
        if audioConverter == nil {
            let settings: [String: Any] = [
                AVFormatIDKey:         kAudioFormatMPEG4AAC,
                AVSampleRateKey:       aacSampleRate,
                AVNumberOfChannelsKey: aacChannels
            ]
            guard let inputFmt = AVAudioFormat(settings: settings) else { return }
            audioConverter = AVAudioConverter(from: inputFmt, to: outputFormat)
        }
        guard let converter = audioConverter,
              let inputFmt  = converter.inputFormat as AVAudioFormat? else { return }

        let inputBuf = AVAudioCompressedBuffer(
            format: inputFmt,
            packetCapacity: 8,
            maximumPacketSize: max(data.count, 1))
        inputBuf.packetCount = 1
        inputBuf.byteLength  = UInt32(data.count)
        data.withUnsafeBytes { memcpy(inputBuf.data, $0.baseAddress!, data.count) }
        inputBuf.packetDescriptions?[0] = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(data.count))

        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096) else { return }
        var err: NSError?
        var done = false
        converter.convert(to: outBuf, error: &err) { _, status in
            if done { status.pointee = .noDataNow; return nil }
            done = true; status.pointee = .haveData; return inputBuf
        }
        if err == nil && outBuf.frameLength > 0 {
            playerNode.scheduleBuffer(outBuf)
        }
    }
}
