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

    private let displayLayer    = AVSampleBufferDisplayLayer()
    private let renderSync      = AVSampleBufferRenderSynchronizer()


    private var sps: Data?
    private var pps: Data?
    private var videoFormat: CMVideoFormatDescription?
    private var gotKeyframe = false

    init(peerId: String) {
        self.peerId = peerId
        displayLayer.videoGravity    = .resizeAspectFill
        displayLayer.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)

        // Wire renderer to synchronizer and start playback at rate 1
        renderSync.addRenderer(displayLayer.sampleBufferRenderer)
        renderSync.rate = 1.0
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
        playerNode.stop()
        audioEngine.stop()
        audioConverter = nil
    }

    // MARK: - Video

    // VTCompressionSession outputs AVCC: [4B length BE][NAL data][4B length BE][NAL data]...
    private func _parseAnnexB(_ data: Data) {
        let bytes = [UInt8](data)
        var i = 0
        var nals: [(type: UInt8, data: Data)] = []

        // Try AVCC first (4-byte length prefix)
        var isAVCC = false
        if bytes.count > 4 {
            let len = Int(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 |
                         UInt32(bytes[2]) << 8  | UInt32(bytes[3]))
            if len > 0 && len < bytes.count { isAVCC = true }
        }

        if isAVCC {
            while i + 4 <= bytes.count {
                let len = Int(UInt32(bytes[i]) << 24 | UInt32(bytes[i+1]) << 16 |
                              UInt32(bytes[i+2]) << 8  | UInt32(bytes[i+3]))
                i += 4
                guard len > 0, i + len <= bytes.count else { break }
                let nal = data.subdata(in: i..<(i + len))
                if !nal.isEmpty { nals.append((nal[0] & 0x1F, nal)) }
                i += len
            }
        } else {
            // Annex-B fallback
            var start = -1
            while i < bytes.count {
                let sc4 = i+3 < bytes.count && bytes[i]==0 && bytes[i+1]==0 && bytes[i+2]==0 && bytes[i+3]==1
                let sc3 = i+2 < bytes.count && bytes[i]==0 && bytes[i+1]==0 && bytes[i+2]==1
                if sc4 || sc3 {
                    if start >= 0 {
                        let nal = data.subdata(in: start..<i)
                        if !nal.isEmpty { nals.append((nal[0] & 0x1F, nal)) }
                    }
                    i += sc4 ? 4 : 3; start = i
                } else { i += 1 }
            }
            if start >= 0 {
                let nal = data.subdata(in: start..<data.count)
                if !nal.isEmpty { nals.append((nal[0] & 0x1F, nal)) }
            }
        }

        for (nalType, nal) in nals {
            switch nalType {
            case 7:
                sps = nal
                print("[Renderer] SPS \(nal.count)B")
                if pps != nil { _rebuildFormat() }
            case 8:
                pps = nal
                print("[Renderer] PPS \(nal.count)B fmt:\(videoFormat != nil)")
                if sps != nil { _rebuildFormat() }
            case 5:
                gotKeyframe = true
                print("[Renderer] IDR fmt:\(videoFormat != nil)")
                _enqueue(nal, isIDR: true)
            case 1:
                if gotKeyframe { _enqueue(nal, isIDR: false) }
            default:
                break
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

        // Prepend 4-byte AVCC length then NAL bytes
        let totalLen = 4 + nal.count
        // malloc so CMBlockBuffer owns lifetime — avoids use-after-free on local Data
        guard let mem = malloc(totalLen) else { return }
        var lenBE = UInt32(nal.count).bigEndian
        memcpy(mem, &lenBE, 4)
        nal.withUnsafeBytes { memcpy(mem.advanced(by: 4), $0.baseAddress!, nal.count) }

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: mem,
            blockLength: totalLen, blockAllocator: kCFAllocatorMalloc,
            customBlockSource: nil, offsetToData: 0, dataLength: totalLen,
            flags: 0, blockBufferOut: &block) == noErr, let block else {
            free(mem); return
        }

        let now    = CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: now,
            decodeTimeStamp: .invalid)
        var size   = totalLen
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: nil, dataBuffer: block, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil,
            formatDescription: fmt, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sample) == noErr, let sample else { return }

        if let atts = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(atts) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(atts, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let renderer = self.displayLayer.sampleBufferRenderer
            if renderer.status == .failed { renderer.flush() }
            if renderer.isReadyForMoreMediaData {
                renderer.enqueue(sample)
            } else {
                print("[Renderer] layer not ready status:\(renderer.status.rawValue)")
            }
        }
    }

    // MARK: - Audio

    private var audioEngine    = AVAudioEngine()
    private var playerNode     = AVAudioPlayerNode()
    private var audioConverter: AVAudioConverter?
    private var audioSetupDone = false

    private func _setupAudio() {
        let outputFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: 44100, channels: 2, interleaved: false)!
        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: outputFmt)
        try? audioEngine.start()
        playerNode.play()
        print("[Audio] engine started")
    }

    private func _decodeAudio(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count > 7 else { return }

        // Parse ADTS header to get actual channel count and sample rate
        // ADTS sync: 0xFFF in first 12 bits
        guard bytes[0] == 0xFF && (bytes[1] & 0xF0) == 0xF0 else {
            print("[Audio] not ADTS: \(bytes[0]) \(bytes[1])"); return
        }

        // Extract channel config from ADTS header bits
        // byte2: [2:profile][4:sampleRateIdx][1:privateBit][1:channelHigh]
        // byte3: [2:channelLow][1:originality][1:home][1:copyBit][1:copyStart][13:frameLength high]
        let sampleRateIdx = Int((bytes[2] >> 2) & 0x0F)
        let channelConf   = Int(((bytes[2] & 0x01) << 2) | ((bytes[3] >> 6) & 0x03))
        let hasCRC        = (bytes[1] & 0x01) == 0
        let headerLen     = hasCRC ? 9 : 7

        let sampleRates   = [96000.0, 88200, 64000, 48000, 44100, 32000, 24000, 22050,
                              16000, 12000, 11025, 8000, 7350]
        guard sampleRateIdx < sampleRates.count, channelConf > 0 else {
            print("[Audio] bad ADTS header sr:\(sampleRateIdx) ch:\(channelConf)"); return
        }
        let sr = sampleRates[sampleRateIdx]
        let ch = channelConf > 6 ? 8 : channelConf // channel_config maps directly to count

        // Build converter lazily or rebuild if format changed
        if audioConverter == nil ||
           audioConverter!.inputFormat.sampleRate != sr ||
           audioConverter!.inputFormat.channelCount != AVAudioChannelCount(ch) {

            let aacSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sr,
                AVNumberOfChannelsKey: ch
            ]
            let outputFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: sr,
                                          channels: AVAudioChannelCount(ch),
                                          interleaved: false)!
            guard let inputFmt = AVAudioFormat(settings: aacSettings) else {
                print("[Audio] bad input format"); return
            }
            audioConverter = AVAudioConverter(from: inputFmt, to: outputFmt)
            // Reconnect engine with correct format
            audioEngine.stop()
            audioEngine.disconnectNodeOutput(playerNode)
            audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: outputFmt)
            try? audioEngine.start()
            playerNode.play()
            print("[Audio] converter built sr:\(sr) ch:\(ch)")
        }

        guard let converter = audioConverter else { return }

        // Strip ADTS header, feed raw AAC to converter
        guard data.count > headerLen else { return }
        let rawAAC = data.subdata(in: headerLen..<data.count)

        let inputFmt = converter.inputFormat
        let inputBuf = AVAudioCompressedBuffer(format: inputFmt,
                                               packetCapacity: 1,
                                               maximumPacketSize: rawAAC.count)
        inputBuf.packetCount = 1
        inputBuf.byteLength  = UInt32(rawAAC.count)
        rawAAC.withUnsafeBytes { memcpy(inputBuf.data, $0.baseAddress!, rawAAC.count) }
        inputBuf.packetDescriptions?[0] = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0,
            mDataByteSize: UInt32(rawAAC.count))

        let frameCount = AVAudioFrameCount(inputFmt.sampleRate * 0.025) // ~25ms
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: converter.outputFormat,
                                             frameCapacity: frameCount) else { return }
        var convErr: NSError?
        var inputDone = false
        let status = converter.convert(to: outBuf, error: &convErr) { _, outStatus in
            if inputDone { outStatus.pointee = .noDataNow; return nil }
            inputDone = true
            outStatus.pointee = .haveData
            return inputBuf
        }
        if status != .error && outBuf.frameLength > 0 {
            playerNode.scheduleBuffer(outBuf)
        }
    }
}
