import AVFoundation
import CoreVideo
import Foundation

/// Writes BGRA frames as a variable-frame-rate ProRes 4444 QuickTime movie.
/// Not thread-safe: create it, append and finish from one serial queue.
public final class MovieWriter: @unchecked Sendable {
    public let width: Int
    public let height: Int
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor

    public init(url: URL, width: Int, height: Int) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw InvalidInput("\(url.path) already exists")
        }
        self.width = width
        self.height = height
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes4444,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            // The frames are sRGB: BT.709 primaries with the sRGB transfer function.
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: kCVImageBufferTransferFunction_sRGB as String,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { throw InvalidInput("cannot add a ProRes 4444 track") }
        writer.add(input)
        guard writer.startWriting() else {
            throw InvalidInput("cannot start writing: \(writer.error?.localizedDescription ?? "unknown error")")
        }
        writer.startSession(atSourceTime: .zero)
    }

    /// The writer's own pool of BGRA buffers of the movie's size.
    public var pixelBufferPool: CVPixelBufferPool? { adaptor.pixelBufferPool }

    public var isReady: Bool { input.isReadyForMoreMediaData }

    /// Appends a frame at `time` seconds from the movie start. Returns false
    /// when the encoder cannot take it now (the frame is dropped).
    public func append(_ buffer: CVPixelBuffer, at time: Double) -> Bool {
        guard input.isReadyForMoreMediaData else { return false }
        return adaptor.append(buffer, withPresentationTime: CMTime(seconds: time, preferredTimescale: 1_000_000_000))
    }

    public func finish() async throws {
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            throw InvalidInput("cannot finish the movie: \(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")")
        }
    }
}

public extension FrameImage {
    /// Copies the frame into a new BGRA pixel buffer tagged as sRGB (used by tests).
    func makePixelBuffer() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer
        else { return nil }
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        pixels.withUnsafeBytes { source in
            for y in 0..<height {
                (base + y * rowBytes).copyMemory(from: source.baseAddress! + y * width * 4, byteCount: width * 4)
            }
        }
        return buffer
    }
}

/// One decoded frame of a movie.
public struct MovieFrame: Sendable {
    /// Presentation time in seconds from the movie start.
    public var time: Double
    public var image: FrameImage
}

public enum MovieReader {
    /// Decodes every frame of the movie's video track to BGRA.
    public static func readFrames(_ url: URL) async throws -> [MovieFrame] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw InvalidInput("\(url.path) has no video track")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw InvalidInput("cannot read \(url.path): \(reader.error?.localizedDescription ?? "unknown error")")
        }
        var frames: [MovieFrame] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            frames.append(MovieFrame(time: time, image: frameImage(from: buffer)))
        }
        if reader.status == .failed {
            throw InvalidInput("cannot read \(url.path): \(reader.error?.localizedDescription ?? "unknown error")")
        }
        return frames
    }

    static func frameImage(from buffer: CVPixelBuffer) -> FrameImage {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { target in
            for y in 0..<height {
                (target.baseAddress! + y * width * 4).copyMemory(from: base + y * rowBytes, byteCount: width * 4)
            }
        }
        return FrameImage(width: width, height: height, pixels: pixels)
    }
}
