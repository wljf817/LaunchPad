import CoreMedia
import CoreVideo
import FrameCompare
import Foundation
import ScreenCaptureKit

/// Receives ScreenCaptureKit frames and appends the ones whose content changed
/// to the movie, leaving out those where only the pacer changed (REF-ENV-005).
/// Every mutable property is touched only on `queue`.
final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Buffers the writer may hold for the encoder before frames are dropped.
    static let poolLimit = 16

    let queue = DispatchQueue(label: "frame-record.samples")
    let writer: MovieWriter
    /// The pacer's rectangle in the frame's pixels.
    let pacerRect: CGRect
    private(set) var frameTimes: [Double] = []
    private(set) var dropped = 0
    private(set) var streamError: (any Error)?
    private var stopped = false

    init(writer: MovieWriter, pacerRect: CGRect) {
        self.writer = writer
        self.pacerRect = pacerRect
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !stopped,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let rawStatus = info[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus),
              // .started is the first frame after the stream starts and carries content.
              status == .complete || status == .started,
              let displayTime = info[.displayTime] as? UInt64,
              let source = CMSampleBufferGetImageBuffer(sample)
        else { return }
        // A frame whose only change is the pacer is the same picture as the last one kept; the first frame is
        // always kept, as the baseline.
        let dirty = ((info[.dirtyRects] as? [NSDictionary]) ?? []).compactMap { CGRect(dictionaryRepresentation: $0) }
        if !frameTimes.isEmpty, !dirty.isEmpty, dirty.allSatisfy({ pacerRect.contains($0) }) { return }
        let time = seconds(machTime: displayTime)
        let presentation = frameTimes.isEmpty ? 0 : time - frameTimes[0]
        // Copy into the writer's pool so ScreenCaptureKit's small buffer queue
        // is released at once, whatever the encoder's backlog.
        guard let copy = copyIntoPool(source), writer.append(copy, at: presentation) else {
            dropped += 1
            return
        }
        frameTimes.append(time)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        queue.async { self.streamError = error }
    }

    /// Stops accepting frames; call on `queue`.
    func stop() {
        stopped = true
    }

    private func copyIntoPool(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        guard let pool = writer.pixelBufferPool,
              CVPixelBufferGetWidth(source) == writer.width,
              CVPixelBufferGetHeight(source) == writer.height
        else { return nil }
        var target: CVPixelBuffer?
        let aux = [kCVPixelBufferPoolAllocationThresholdKey as String: Recorder.poolLimit] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, aux, &target) == kCVReturnSuccess,
              let target
        else { return nil }
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(target, [])
        defer {
            CVPixelBufferUnlockBaseAddress(target, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        guard let from = CVPixelBufferGetBaseAddress(source), let to = CVPixelBufferGetBaseAddress(target) else { return nil }
        let fromRow = CVPixelBufferGetBytesPerRow(source)
        let toRow = CVPixelBufferGetBytesPerRow(target)
        let rowBytes = writer.width * 4
        for y in 0..<writer.height {
            (to + y * toRow).copyMemory(from: from + y * fromRow, byteCount: rowBytes)
        }
        CVBufferPropagateAttachments(source, target)
        return target
    }
}
