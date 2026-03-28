// Media/VideoSurface.swift
// Renders VP8 video packets via AVSampleBufferDisplayLayer.
// VP8 is natively supported by Apple's VideoToolbox on macOS 11+ / iOS 14+.
// No NAL parsing needed — VP8 packets feed directly into CMSampleBuffer.

import AVFoundation
import CoreMedia
import VideoToolbox

#if os(iOS)
import UIKit
typealias PlatformView = UIView
#elseif os(macOS)
import AppKit
typealias PlatformView = NSView
#endif

final class VideoSurface: PlatformView {

    private let displayLayer = AVSampleBufferDisplayLayer()
    private var formatDesc:   CMVideoFormatDescription?
    private var frameCount:   Int64 = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        _setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Feed encoded VP8 packet

    func enqueue(h264 pts: UInt32, data: Data) {
        _enqueueVP8(pts: pts, data: data)
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

        // Build format description for VP8 1280x720
        _buildFormatDescription(width: 1280, height: 720)
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

    // MARK: - Format description

    private func _buildFormatDescription(width: Int32, height: Int32) {
        // VP8 format description — kCMVideoCodecType_VP8 = 'vp08'
        let vp8CodecType: CMVideoCodecType = 0x76703038  // 'vp08'
        CMVideoFormatDescriptionCreate(
            allocator: nil,
            codecType: vp8CodecType,
            width: width,
            height: height,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        )
    }

    // MARK: - Enqueue VP8 packet

    private func _enqueueVP8(pts: UInt32, data: Data) {
        guard let formatDesc else { return }
        guard !data.isEmpty else { return }

        var blockBuffer: CMBlockBuffer?
        var dataCopy = data   // local copy for exclusive mutable access
        let dataLen  = dataCopy.count

        dataCopy.withUnsafeMutableBytes { ptr in
            CMBlockBufferCreateWithMemoryBlock(
                allocator:        nil,
                memoryBlock:      ptr.baseAddress,
                blockLength:      dataLen,
                blockAllocator:   kCFAllocatorNull,
                customBlockSource: nil,
                offsetToData:     0,
                dataLength:       dataLen,
                flags:            0,
                blockBufferOut:   &blockBuffer
            )
        }
        guard let blockBuffer else { return }

        let ptsTime = CMTime(value: CMTimeValue(pts), timescale: 1000)
        var timing  = CMSampleTimingInfo(
            duration:               CMTime(value: 1, timescale: CMTimeScale(30)),
            presentationTimeStamp:  ptsTime,
            decodeTimeStamp:        .invalid
        )
        var sampleSize = dataLen
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreate(
            allocator:              nil,
            dataBuffer:             blockBuffer,
            dataReady:              true,
            makeDataReadyCallback:  nil,
            refcon:                 nil,
            formatDescription:      formatDesc,
            sampleCount:            1,
            sampleTimingEntryCount: 1,
            sampleTimingArray:      &timing,
            sampleSizeEntryCount:   1,
            sampleSizeArray:        &sampleSize,
            sampleBufferOut:        &sampleBuffer
        )
        guard let sampleBuffer else { return }

        // Mark as ready to display
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true)
        if let attachments, CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }

        if displayLayer.isReadyForMoreMediaData {
            displayLayer.enqueue(sampleBuffer)
        } else {
            displayLayer.flush()
        }
    }
}
