// RPC/MediaProtocol.swift
// Parses binary media frames from JS — matches lib/protocol.js layout exactly.

import Foundation

let VIDEO_FRAME: UInt8 = 0x01
let AUDIO_FRAME: UInt8 = 0x02

struct VideoFrame {
    let peerId: String
    let pts:    UInt32
    let h264:   Data     // raw H264 NAL unit packet
}

struct AudioFrame {
    let peerId: String
    let pts:    UInt32
    let opus:   Data     // raw Opus packet
}

enum MediaProtocol {

    static func parse(_ data: Data) -> (video: VideoFrame?, audio: AudioFrame?) {
        guard data.count >= 13 else { return (nil, nil) }
        var off = 0

        let type = data[off]; off += 1

        let peerIdLen = Int(data[off..<(off+4)].withUnsafeBytes {
            $0.loadUnaligned(as: UInt32.self).littleEndian }); off += 4
        guard data.count >= off + peerIdLen + 8 else { return (nil, nil) }

        let peerId = String(bytes: data[off..<(off + peerIdLen)], encoding: .utf8) ?? ""
        off += peerIdLen

        let pts = data[off..<(off+4)].withUnsafeBytes {
            $0.loadUnaligned(as: UInt32.self).littleEndian }; off += 4

        let dataLen = Int(data[off..<(off+4)].withUnsafeBytes {
            $0.loadUnaligned(as: UInt32.self).littleEndian }); off += 4
        guard data.count >= off + dataLen else { return (nil, nil) }

        let payload = data.subdata(in: off..<(off + dataLen))

        if type == VIDEO_FRAME {
            return (VideoFrame(peerId: peerId, pts: pts, h264: payload), nil)
        } else {
            return (nil, AudioFrame(peerId: peerId, pts: pts, opus: payload))
        }
    }
}
