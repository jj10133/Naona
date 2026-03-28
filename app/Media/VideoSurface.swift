// Media/VideoSurface.swift
// H264 decode + display via AVSampleBufferDisplayLayer.
// Parses Annex-B NAL units, builds CMVideoFormatDescription from SPS/PPS,
// then enqueues VCL NALs as CMSampleBuffers for hardware decode + display.

import AVFoundation
import VideoToolbox
import CoreMedia

#if os(iOS)
import UIKit
typealias PlatformView = UIView
#elseif os(macOS)
import AppKit
typealias PlatformView = NSView
#endif

final class VideoSurface: PlatformView {

    private let displayLayer = AVSampleBufferDisplayLayer()
    private var formatDesc:  CMVideoFormatDescription?
    private var sps:         Data?
    private var pps:         Data?

    override init(frame: CGRect) {
        super.init(frame: frame)
        _setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Public

    func enqueue(h264 pts: UInt32, data: Data) {
        _parseAnnexB(data: data, pts: pts)
    }

    // MARK: - Setup

    private func _setup() {
        #if os(iOS)
        layer.addSublayer(displayLayer)
        backgroundColor = .black
        #elseif os(macOS)
        wantsLayer = true
        layer?.addSublayer(displayLayer)
        layer?.backgroundColor = NSColor.black.cgColor
        #endif
        displayLayer.videoGravity = .resizeAspectFill
    }

    #if os(iOS)
    override func layoutSubviews() {
        super.layoutSubviews()
        displayLayer.frame = bounds
    }
    #elseif os(macOS)
    override func layout() {
        super.layout()
        displayLayer.frame = bounds
    }
    #endif

    // MARK: - Annex-B parser

    private func _parseAnnexB(data: Data, pts: UInt32) {
        var nals: [Data] = []
        let bytes = [UInt8](data)
        var i = 0
        var start = -1

        func startCodeLen(at idx: Int) -> Int {
            if idx + 3 < bytes.count &&
               bytes[idx] == 0 && bytes[idx+1] == 0 && bytes[idx+2] == 0 && bytes[idx+3] == 1 {
                return 4
            }
            if idx + 2 < bytes.count &&
               bytes[idx] == 0 && bytes[idx+1] == 0 && bytes[idx+2] == 1 {
                return 3
            }
            return 0
        }

        while i < bytes.count {
            let scLen = startCodeLen(at: i)
            if scLen > 0 {
                if start >= 0 {
                    nals.append(data.subdata(in: start..<i))
                }
                i += scLen
                start = i
            } else {
                i += 1
            }
        }
        if start >= 0 && start < bytes.count {
            nals.append(data.subdata(in: start..<bytes.count))
        }

        for nal in nals where !nal.isEmpty {
            _processNAL(nal, pts: pts)
        }
    }

    private func _processNAL(_ nal: Data, pts: UInt32) {
        let nalType = nal[0] & 0x1F
        switch nalType {
        case 7: // SPS
            sps = nal
        case 8: // PPS
            pps = nal
            _rebuildFormatDesc()
        case 5, 1: // IDR or non-IDR slice
            _enqueue(nal, pts: pts)
        default:
            break
        }
    }

    private func _rebuildFormatDesc() {
        guard let sps, let pps else { return }
        sps.withUnsafeBytes { spsRaw in
            pps.withUnsafeBytes { ppsRaw in
                let params: [UnsafePointer<UInt8>] = [
                    spsRaw.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    ppsRaw.baseAddress!.assumingMemoryBound(to: UInt8.self)
                ]
                let sizes: [Int] = [sps.count, pps.count]
                var desc: CMVideoFormatDescription?
                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator:              nil,
                    parameterSetCount:      2,
                    parameterSetPointers:   params,
                    parameterSetSizes:      sizes,
                    nalUnitHeaderLength:    4,
                    formatDescriptionOut:   &desc
                )
                if status == noErr { formatDesc = desc }
            }
        }
    }

    private func _enqueue(_ nal: Data, pts: UInt32) {
        guard let formatDesc else { return }

        // Prepend 4-byte AVCC length
        let len = UInt32(nal.count).bigEndian
        var avcc = withUnsafeBytes(of: len) { Data($0) }
        avcc.append(nal)

        var avccCopy   = avcc
        let avccLen    = avccCopy.count
        var blockBuf:  CMBlockBuffer?

        avccCopy.withUnsafeMutableBytes { ptr in
            CMBlockBufferCreateWithMemoryBlock(
                allocator:          nil,
                memoryBlock:        ptr.baseAddress,
                blockLength:        avccLen,
                blockAllocator:     kCFAllocatorNull,
                customBlockSource:  nil,
                offsetToData:       0,
                dataLength:         avccLen,
                flags:              0,
                blockBufferOut:     &blockBuf
            )
        }
        guard let blockBuf else { return }

        let ptsTime = CMTime(value: CMTimeValue(pts), timescale: 1000)
        var timing  = CMSampleTimingInfo(
            duration:               CMTime(value: 1, timescale: 30),
            presentationTimeStamp:  ptsTime,
            decodeTimeStamp:        .invalid
        )
        var sampleSize = avccLen
        var sampleBuf: CMSampleBuffer?
        CMSampleBufferCreate(
            allocator:              nil,
            dataBuffer:             blockBuf,
            dataReady:              true,
            makeDataReadyCallback:  nil,
            refcon:                 nil,
            formatDescription:      formatDesc,
            sampleCount:            1,
            sampleTimingEntryCount: 1,
            sampleTimingArray:      &timing,
            sampleSizeEntryCount:   1,
            sampleSizeArray:        &sampleSize,
            sampleBufferOut:        &sampleBuf
        )
        guard let sampleBuf else { return }

        // Mark for immediate display
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuf, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(
                CFArrayGetValueAtIndex(attachments, 0),
                to: CFMutableDictionary.self
            )
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }

        if displayLayer.isReadyForMoreMediaData {
            displayLayer.enqueue(sampleBuf)
        } else {
            displayLayer.flush()
        }
    }
}
