import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

final class VideoDecoder {
    private let frameStore: FrameStore
    private var formatDescription: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var sps: Data?
    private var pps: Data?

    init(frameStore: FrameStore) {
        self.frameStore = frameStore
    }

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    func configure(with annexB: Data) {
        for unit in AnnexB.nalUnits(in: annexB) {
            guard let first = unit.first else { continue }
            switch first & 0x1F {
            case 7: sps = unit
            case 8: pps = unit
            default: break
            }
        }
        rebuildSessionIfPossible()
    }

    func decode(_ annexB: Data, isKeyFrame: Bool, presentationTimeUs: UInt64) {
        let units = AnnexB.nalUnits(in: annexB)
        for unit in units {
            guard let first = unit.first else { continue }
            if first & 0x1F == 7 { sps = unit }
            if first & 0x1F == 8 { pps = unit }
        }
        if session == nil { rebuildSessionIfPossible() }
        guard let session, let formatDescription else { return }

        let videoUnits = units.filter {
            guard let first = $0.first else { return false }
            let type = first & 0x1F
            return type != 7 && type != 8 && type != 9
        }
        guard !videoUnits.isEmpty else { return }

        var avcc = Data()
        for unit in videoUnits {
            var length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &length) { avcc.append(contentsOf: $0) }
            avcc.append(unit)
        }

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr, let blockBuffer else { return }

        let copyStatus = avcc.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: avcc.count
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else { return }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(presentationTimeUs), timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = avcc.count
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return }

        if !isKeyFrame,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }

        var outputFlags = VTDecodeInfoFlags()
        VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression, ._1xRealTimePlayback],
            frameRefcon: nil,
            infoFlagsOut: &outputFlags
        )
    }

    private func rebuildSessionIfPossible() {
        guard let sps, let pps else { return }
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        formatDescription = nil

        var description: CMFormatDescription?
        let status = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                let pointers: [UnsafePointer<UInt8>] = [
                    spsBytes.bindMemory(to: UInt8.self).baseAddress!,
                    ppsBytes.bindMemory(to: UInt8.self).baseAddress!
                ]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description
                )
            }
        }
        guard status == noErr, let description else { return }
        formatDescription = description

        let outputCallback: VTDecompressionOutputCallback = { refCon, _, status, _, imageBuffer, _, _ in
            guard status == noErr, let refCon, let imageBuffer else { return }
            let decoder = Unmanaged<VideoDecoder>.fromOpaque(refCon).takeUnretainedValue()
            decoder.frameStore.publish(imageBuffer)
        }
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: outputCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        var newSession: VTDecompressionSession?
        let createStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: description,
            decoderSpecification: [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true] as CFDictionary,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &newSession
        )
        guard createStatus == noErr, let newSession else { return }
        VTSessionSetProperty(newSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = newSession
    }
}

private enum AnnexB {
    static func nalUnits(in data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var starts: [(offset: Int, length: Int)] = []
        var index = 0
        while index + 3 < bytes.count {
            if bytes[index] == 0 && bytes[index + 1] == 0 {
                if bytes[index + 2] == 1 {
                    starts.append((index, 3))
                    index += 3
                    continue
                }
                if bytes[index + 2] == 0 && bytes[index + 3] == 1 {
                    starts.append((index, 4))
                    index += 4
                    continue
                }
            }
            index += 1
        }
        guard !starts.isEmpty else { return data.isEmpty ? [] : [data] }

        return starts.enumerated().compactMap { item in
            let payloadStart = item.element.offset + item.element.length
            let payloadEnd = item.offset + 1 < starts.count ? starts[item.offset + 1].offset : bytes.count
            guard payloadStart < payloadEnd else { return nil }
            return Data(bytes[payloadStart..<payloadEnd])
        }
    }
}
