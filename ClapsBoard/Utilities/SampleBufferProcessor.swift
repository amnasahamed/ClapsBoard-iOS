//
//  SampleBufferProcessor.swift
//  ClapsBoard
//
//  Center-crops camera frames to a target aspect ratio for PiP display.
//

import AVFoundation
import CoreImage
import CoreVideo

enum SampleBufferProcessor {
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private static var pixelBufferPool: CVPixelBufferPool?
    private static var poolWidth = 0
    private static var poolHeight = 0
    private static let aspectTolerance: CGFloat = 0.02
    private static var hasLoggedDiagnostics = false
    private static var cropFailureLogged = false

    /// Returns a center-cropped copy of `sampleBuffer` matching `targetAspect` (width / height).
    static func centerCropped(
        _ sampleBuffer: CMSampleBuffer,
        toAspectRatio targetAspect: CGFloat
    ) -> CMSampleBuffer? {
        guard targetAspect > 0 else { return sampleBuffer }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return sampleBuffer }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return sampleBuffer }

        let sourceAspect = CGFloat(width) / CGFloat(height)

        #if DEBUG
        if !hasLoggedDiagnostics {
            hasLoggedDiagnostics = true
            print(
                "📐 SampleBufferProcessor: buffer=\(width)x\(height) " +
                "aspect=\(String(format: "%.3f", sourceAspect)) " +
                "target=\(String(format: "%.3f", targetAspect))"
            )
        }
        #endif

        if abs(sourceAspect - targetAspect) <= aspectTolerance {
            return sampleBuffer
        }

        let cropRect = centerCropRect(sourceWidth: width, sourceHeight: height, targetAspect: targetAspect)
        let outputWidth = Int(cropRect.width.rounded())
        let outputHeight = Int(cropRect.height.rounded())
        guard outputWidth > 0, outputHeight > 0 else { return sampleBuffer }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let cropped = ciImage.cropped(to: cropRect)
        let normalized = cropped.transformed(
            by: CGAffineTransform(translationX: -cropped.extent.origin.x, y: -cropped.extent.origin.y)
        )

        guard let outputBuffer = makePixelBuffer(width: outputWidth, height: outputHeight) else {
            logCropFailureOnce("pixel buffer pool allocation failed")
            return sampleBuffer
        }

        ciContext.render(normalized, to: outputBuffer)

        guard let outputSampleBuffer = makeSampleBuffer(from: outputBuffer, timing: sampleBuffer) else {
            logCropFailureOnce("CMSampleBuffer creation failed")
            return sampleBuffer
        }

        return outputSampleBuffer
    }

    static func resetDiagnostics() {
        hasLoggedDiagnostics = false
        cropFailureLogged = false
    }

    static func resetPool() {
        pixelBufferPool = nil
        poolWidth = 0
        poolHeight = 0
    }

    // MARK: - Private

    private static func centerCropRect(sourceWidth: Int, sourceHeight: Int, targetAspect: CGFloat) -> CGRect {
        let width = CGFloat(sourceWidth)
        let height = CGFloat(sourceHeight)
        let sourceAspect = width / height

        if sourceAspect > targetAspect {
            let cropWidth = height * targetAspect
            let x = (width - cropWidth) / 2
            return CGRect(x: x, y: 0, width: cropWidth, height: height)
        }

        let cropHeight = width / targetAspect
        let y = (height - cropHeight) / 2
        return CGRect(x: 0, y: y, width: width, height: cropHeight)
    }

    private static func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if poolWidth != width || poolHeight != height || pixelBufferPool == nil {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            var pool: CVPixelBufferPool?
            let status = CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
            guard status == kCVReturnSuccess, let pool else { return nil }
            pixelBufferPool = pool
            poolWidth = width
            poolHeight = height
        }

        var pixelBuffer: CVPixelBuffer?
        guard let pool = pixelBufferPool,
              CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess else {
            return nil
        }
        return pixelBuffer
    }

    private static func makeSampleBuffer(from pixelBuffer: CVPixelBuffer, timing source: CMSampleBuffer) -> CMSampleBuffer? {
        var formatDescription: CMFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let formatDescription else { return nil }

        var timingInfo = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(source),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(source),
            decodeTimeStamp: CMSampleBufferGetDecodeTimeStamp(source)
        )

        var sampleBuffer: CMSampleBuffer?
        let createStatus = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )
        guard createStatus == noErr else { return nil }
        return sampleBuffer
    }

    private static func logCropFailureOnce(_ message: String) {
        guard !cropFailureLogged else { return }
        cropFailureLogged = true
        print("⚠️ SampleBufferProcessor: \(message) — using uncropped frame")
    }
}
