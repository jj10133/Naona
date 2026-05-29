import AVFoundation
import VideoToolbox
import CoreMedia
import Foundation

final class MediaRenderer {

    let peerId: String

    var isAudioMuted = false
    var isVideoMuted = false

    private var decomSession:  VTDecompressionSession?
    private var videoFormat:   CMVideoFormatDescription?
    private var sps:           Data?
    private var pps:           Data?

    private let displayLayer   = AVSampleBufferDisplayLayer()
    private let audioEngine    = AVAudioEngine()
    private let playerNode     = AVAudioPlayerNode()
    private var audioConverter: AVAudioConverter?
    private let outputFormat   = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false)!

    init(peerId: String) {
        self.peerId = peerId
        _setupAudio()
        _setupVideo()
    }

    func makeVideoLayer() -> AVSampleBufferDisplayLayer { displayLayer }

    func receiveVideo(_ data: Data) {
        guard !isVideoMuted else { return }
        _parseH264(data)
    }

    func receiveAudio(_ data: Data) {
        guard !isAudioMuted else { return }
        _decodeAAC(data)
    }

    func stop() {
        playerNode.stop()
        audioEngine.stop()
        if let s = decomSession { VTDecompressionSessionInvalidate(s) }
        decomSession = nil
    }

    private func _setupVideo() {
        displayLayer.videoGravity = .resizeAspectFill
        displayLayer.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
    }

    private func _setupAudio() {
        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: outputFormat)
        try? audioEngine.start()
        playerNode.play()
    }

    private func _parseH264(_ data: Data) {
        var nals: [Data] = []
        let bytes = [UInt8](data)
        var i = 0
        var start = -1

        while i < bytes.count {
            let sc4 = i + 3 < bytes.count && bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 0 && bytes[i+3] == 1
            let sc3 = i + 2 < bytes.count && bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 1
            if sc4 || sc3 {
                if start >= 0 { nals.append(data.subdata(in: start..<i)) }
                i += sc4 ? 4 : 3
                start = i
            } else { i += 1 }
        }
        if start >= 0 { nals.append(data.subdata(in: start..<data.count)) }

        for nal in nals where !nal.isEmpty {
            let nalType = nal[0] & 0x1F
            switch nalType {
            case 7: sps = nal
            case 8: pps = nal; _buildFormatAndSession()
            case 1, 5: _enqueue(nal)
            default: break
            }
        }
    }

    private func _buildFormatAndSession() {
        guard let sps, let pps else { return }
        sps.withUnsafeBytes { spsPtr in
            pps.withUnsafeBytes { ppsPtr in
                let params: [UnsafePointer<UInt8>] = [
                    spsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    ppsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                ]
                let sizes: [Int] = [sps.count, pps.count]
                var fmt: CMVideoFormatDescription?
                guard CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: 2,
                    parameterSetPointers: params, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &fmt
                ) == noErr, let fmt else { return }
                videoFormat = fmt

                let attrs = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] as CFDictionary
                var cb   = VTDecompressionOutputCallbackRecord(
                    decompressionOutputCallback: { refcon, _, status, _, imageBuffer, pts, _ in
                        guard status == noErr, let ib = imageBuffer, let ref = refcon else { return }
                        let me = Unmanaged<MediaRenderer>.fromOpaque(ref).takeUnretainedValue()
                        me._displayFrame(ib, pts: pts)
                    },
                    decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
                )
                var session: VTDecompressionSession?
                VTDecompressionSessionCreate(allocator: nil, formatDescription: fmt,
                    decoderSpecification: nil, imageBufferAttributes: attrs,
                    outputCallback: &cb, decompressionSessionOut: &session)
                decomSession = session
            }
        }
    }

    private func _enqueue(_ nal: Data) {
        guard let fmt = videoFormat else { return }
        let lenBE = UInt32(nal.count).bigEndian
        var avcc = withUnsafeBytes(of: lenBE) { Data($0) }
        avcc.append(nal)
        var copy = avcc
        let len  = copy.count
        var block: CMBlockBuffer?
        copy.withUnsafeMutableBytes { ptr in
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: ptr.baseAddress,
                blockLength: len, blockAllocator: kCFAllocatorNull,
                customBlockSource: nil, offsetToData: 0, dataLength: len,
                flags: 0, blockBufferOut: &block)
        }
        guard let block else { return }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var size   = len
        var sample: CMSampleBuffer?
        CMSampleBufferCreate(allocator: nil, dataBuffer: block, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: fmt,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard let sample, let decomSession else { return }
        var flags = VTDecodeInfoFlags(rawValue: 0)
        VTDecompressionSessionDecodeFrame(decomSession, sampleBuffer: sample,
            flags: [._EnableAsynchronousDecompression], frameRefcon: nil, infoFlagsOut: &flags)
    }

    private func _displayFrame(_ imageBuffer: CVImageBuffer, pts: CMTime) {
        var fmt: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: imageBuffer, formatDescriptionOut: &fmt)
        guard let fmt else { return }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: imageBuffer,
            formatDescription: fmt, sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return }
        DispatchQueue.main.async {
            if self.displayLayer.isReadyForMoreMediaData {
                self.displayLayer.enqueue(sample)
            } else {
                self.displayLayer.flush()
            }
        }
    }

    private func _decodeAAC(_ data: Data) {
        if audioConverter == nil {
            let aacSettings: [String: Any] = [
                AVFormatIDKey:         kAudioFormatMPEG4AAC,
                AVSampleRateKey:       44100.0,
                AVNumberOfChannelsKey: 2
            ]
            guard let inputFormat = AVAudioFormat(settings: aacSettings) else { return }
            audioConverter = AVAudioConverter(from: inputFormat, to: outputFormat)
        }
        guard let converter = audioConverter,
              let inputFormat = converter.inputFormat as AVAudioFormat? else { return }

        let inputBuffer = AVAudioCompressedBuffer(
            format: inputFormat,
            packetCapacity: 8,
            maximumPacketSize: max(data.count, 1)
        )
        inputBuffer.packetCount = 1
        inputBuffer.byteLength  = UInt32(data.count)
        data.withUnsafeBytes { memcpy(inputBuffer.data, $0.baseAddress!, data.count) }
        inputBuffer.packetDescriptions?[0] = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(data.count))

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096) else { return }
        var error: NSError?
        var consumed = false
        converter.convert(to: outputBuffer, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return inputBuffer
        }
        if error == nil && outputBuffer.frameLength > 0 {
            playerNode.scheduleBuffer(outputBuffer)
        }
    }
}
