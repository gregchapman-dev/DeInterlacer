//
//  TrackProcessor.swift
//  DeInterlacer
//
//  Created by Greg Chapman on 2/28/23.
//

import Foundation
import AVFoundation

extension AVAssetTrack {
    var isAnyKindOfProRes: Bool {
        if self.mediaType != AVMediaType.video {
            return false
        }
        if self.formatDescriptions.count < 1 {
            return false
        }

        let desc: CMVideoFormatDescription
            = self.formatDescriptions[0] as! CMVideoFormatDescription
        let codecType: CMVideoCodecType = desc.mediaSubType.rawValue
        return codecType == FourCharCode("apcn")   // .proRes
            || codecType == FourCharCode("apch")   // .proRes422HQ
            || codecType == FourCharCode("apcs")   // .proRes422LT
            || codecType == FourCharCode("apco")   // .proRes422Proxy
            || codecType == FourCharCode("ap4h")   // .proRes4444
            || codecType == FourCharCode("ap4x")   // .proRes4444XQ
    }
    
    var hasFields: Bool {
        if self.mediaType != AVMediaType.video {
            return false
        }
        if self.formatDescriptions.count < 1 {
            return false
        }

        // assume the first formatDescription is the one we're interested in
        let desc: CMVideoFormatDescription = self.formatDescriptions[0] as! CMVideoFormatDescription
        let fieldCountNum: NSNumber? = CMFormatDescriptionGetExtension(
                                            desc,
                                            extensionKey: kCMFormatDescriptionExtension_FieldCount)
                                       as? NSNumber
        if fieldCountNum != nil && fieldCountNum!.intValue == 2 {
            return true
        }

        if desc.mediaSubType == .dvcNTSC {
            // 'dvc ' is an exception: it doesn't say it has fields, but it always does
            return true
        }

        return false
    }

    var fieldDuration: CMTime {
        if self.hasFields {
            let nfr = self.nominalFrameRate
            if nfr > 29.95 && nfr < 30.0 {
                return CMTimeMake(value: 1001, timescale: 60_000)
            }
            if nfr > 59.90 && nfr < 60.0 {
                return CMTimeMake(value: 1001, timescale: 120_000)
            }
        }
        return CMTime.invalid
    }

    var topFieldComesFirst: Bool {
        if self.mediaType != AVMediaType.video {
            return false
        }
        if self.formatDescriptions.count < 1 {
            return false
        }

        // assume the first formatDescription is the one we're interested in
        let desc: CMVideoFormatDescription = self.formatDescriptions[0] as! CMVideoFormatDescription
        let fieldDetail: NSString? = CMFormatDescriptionGetExtension(
                                            desc,
                                            extensionKey: kCMFormatDescriptionExtension_FieldDetail)
                                       as? NSString
        if let fieldDetail {
            if fieldDetail.isEqual(kCMFormatDescriptionFieldDetail_TemporalTopFirst) {
                return true
            }
            if fieldDetail.isEqual(kCMFormatDescriptionFieldDetail_SpatialFirstLineEarly) {
                return true
            }
        }
        return false
    }

    var videoDimensions: CMVideoDimensions? {
        if self.mediaType != AVMediaType.video {
            return nil
        }
        if self.formatDescriptions.count < 1 {
            return nil
        }

        // assume the first formatDescription is the one we're interested in
        let desc: CMVideoFormatDescription = self.formatDescriptions[0] as! CMVideoFormatDescription
        return CMVideoFormatDescriptionGetDimensions(desc)
    }
}


class TrackProcessor {
    let id: String
    let track: AVAssetTrack
    let dispatchGroup: DispatchGroup
    let trackEndTime: CMTime
    let naturalTimeScale: CMTimeScale
    var isValid: Bool = true
    var isCancelled: Bool = false
    var progress: Double = 0.0
    let startTime: Double = Date().timeIntervalSince1970

    var trackWriter: AVAssetWriterInput? = nil
    var trackReader: AVAssetReaderTrackOutput? = nil
    var readOutputSettings: [String: Any]? = nil

    var videoFramesWritten: Int64 = 0
    var videoDimensions: CMVideoDimensions? = nil
    var frameDeinterlacer: FrameDeinterlacer? = nil
    var pixelBufferWriterAdapter: AVAssetWriterInputPixelBufferAdaptor? = nil
    var pixelBufferPool: CVPixelBufferPool? = nil
    
    var wantsMoreQueue: DispatchQueue? = nil
    
    
    init(track: AVAssetTrack, dispatchGroup: DispatchGroup, id: String) async throws {
        self.track = track
        self.dispatchGroup = dispatchGroup
        self.id = id

        self.trackEndTime = track.timeRange.end
        self.naturalTimeScale = try await track.load(.naturalTimeScale)
        self.wantsMoreQueue = DispatchQueue(label:"WantsMoreQueue: " + id)
        
        self.setup()
    }
    
    func setup() {
        // Logic here should look the same as in startProcessing()
        if track.mediaType == .video {
            if track.hasFields {
                // decompress, deinterlace, recompress to ProRes422
                setupVideoTrackWithFields()
            }
            else if !track.isAnyKindOfProRes {
                // Any video that is not any kind of ProRes:
                // decompress, recompress to ProRes422
                setupNonProResVideoTrackWithoutFields()
            }
            else {
                // Any video that is ProRes of some sort:
                // just pass through the compressed samples
                setupPassThroughTrack()
            }
        }
        else {
            // Audio, Timecode, Haptics, etc
            setupPassThroughTrack()
        }
    }
    
    func postAssetWriterSetup() {
        if !self.isValid {
            return
        }
        if self.track.mediaType != .video {
            return
        }
        
        // if there is a pixelBufferWriterAdapter, make sure it has a pool.  It should (once assetWriter.startWriting has
        // been called), but sometimes it doesn't...
        // Also, if there is a pixelBufferWriterAdapter, we need a frame deinterlacer (which requires the pool).
        if let pixelBufferWriterAdapter = self.pixelBufferWriterAdapter {
            self.pixelBufferPool = pixelBufferWriterAdapter.pixelBufferPool
            if self.pixelBufferPool == nil {
                CVPixelBufferPoolCreate(nil,
                                        nil,
                                        [
                                            String(kCVPixelBufferPixelFormatTypeKey): NSNumber(value: kCVPixelFormatType_422YpCbCr8),
                                            String(kCVPixelBufferWidthKey): NSNumber(value: self.videoDimensions!.width),
                                            String(kCVPixelBufferHeightKey): NSNumber(value: self.videoDimensions!.height)
                                        ] as CFDictionary,
                                        &self.pixelBufferPool)
                if self.pixelBufferPool == nil {
                    print("\(self.elapsedTime()): pixel buffer pool creation failed: \(self.id)")
                    self.isValid = false
                    return
                }
            }
            
            self.frameDeinterlacer = FrameDeinterlacer(pixelBufferPool:self.pixelBufferPool!)
        }
    }
    
    func setupVideoTrackWithFields() {
        let sourceVideoFormatDesc: CMVideoFormatDescription
        = track.formatDescriptions[0] as! CMVideoFormatDescription
        self.videoDimensions = track.videoDimensions
        let proResVideoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.proRes422
        ]
        self.readOutputSettings = [
            String(kCVPixelBufferPixelFormatTypeKey): NSNumber(value: kCVPixelFormatType_422YpCbCr8),
            String(kCVPixelBufferWidthKey): NSNumber(value: self.videoDimensions!.width),
            String(kCVPixelBufferHeightKey): NSNumber(value: self.videoDimensions!.height)
        ]
        
        self.trackWriter = AVAssetWriterInput(mediaType: AVMediaType.video,
                                              outputSettings: proResVideoSettings,
                                              sourceFormatHint: sourceVideoFormatDesc)
        self.pixelBufferWriterAdapter = AVAssetWriterInputPixelBufferAdaptor(
                                            assetWriterInput: self.trackWriter!,
                                            sourcePixelBufferAttributes: self.readOutputSettings)
                
        self.trackReader = AVAssetReaderTrackOutput(track: track, outputSettings: self.readOutputSettings)
    }
    
    func setupNonProResVideoTrackWithoutFields() {
        // for now, just pass through, we'll implement the recompress-only path later
        setupPassThroughTrack()
    }
    
    func setupPassThroughTrack() {
        self.trackWriter = AVAssetWriterInput(mediaType: track.mediaType,
                                              outputSettings: nil,
                                              sourceFormatHint: nil)
        self.trackReader = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    }
    
    func startProcessing() {
        // Logic here should look the same as in setup()
        if track.mediaType == .video {
            if track.hasFields {
                // decompress, deinterlace, recompress to ProRes422
                startProcessingDeinterlaceAndRecompress()
            }
            else if !track.isAnyKindOfProRes {
                // Any video that is not any kind of ProRes:
                // decompress, recompress to ProRes422
                startProcessingRecompress()
            }
            else {
                // Any video that is ProRes of some sort:
                // just pass through the compressed samples
                startProcessingPassThrough()
            }
        }
        else {
            // Audio, Timecode, Haptics, etc
            startProcessingPassThrough()
        }
    }
    
    func startProcessingDeinterlaceAndRecompress() {
        if self.isValid && self.trackWriter != nil && self.trackReader != nil && !self.isCancelled {
            self.dispatchGroup.enter()
            
            let fieldDuration: CMTime = self.track.fieldDuration
            let topFieldComesFirst: Bool = self.track.topFieldComesFirst
            var pendingFrame2: CVPixelBuffer? = nil
            var pendingFrame2PTS: CMTime = CMTime.invalid
            
            self.trackWriter!.requestMediaDataWhenReady(on: self.wantsMoreQueue!) {
                while(self.trackWriter!.isReadyForMoreMediaData) {
                    if self.isCancelled {
                        self.trackWriter!.markAsFinished()
                        self.dispatchGroup.leave()
                        break
                    }
                    if pendingFrame2 != nil {
                        // Append the pending second field (now a frame) to the video track
                        self.pixelBufferWriterAdapter!.append(pendingFrame2!, withPresentationTime: pendingFrame2PTS)
                        self.videoFramesWritten += 1
                        pendingFrame2 = nil
                        if self.videoFramesWritten % 1800 == 0 {
                            // 1800 frames at 60 fps is 30 seconds
                            print("\(self.elapsedTime()): video frames written == \(self.videoFramesWritten): \(self.id)")
                        }
                        continue
                    }
                    
                    // Get the next video sample buffer, generate two frames from the two fields,
                    // and append the first field (now a frame) to the output video track. Store
                    // the second field (now a frame) in pendingFrame2 to hand out the next time
                    // the trackWriter wants more data.
                    let sample = self.trackReader!.copyNextSampleBuffer()
                    if sample == nil {
                        self.trackWriter!.markAsFinished()
                        print("\(self.elapsedTime()): trackWriter successfully wrote all the video: \(self.id)")
                        self.dispatchGroup.leave()
                        break
                    }
                    
                    let samplePTS: CMTime = CMSampleBufferGetOutputPresentationTimeStamp(sample!)
                    let frameWithTwoFields: CVPixelBuffer = CMSampleBufferGetImageBuffer(sample!)!
                    let frames = self.frameDeinterlacer!.createFramesFromFields(
                        frameWithTwoFields: frameWithTwoFields,
                        topFieldComesFirst: topFieldComesFirst)
                    self.pixelBufferWriterAdapter!.append(frames.firstFrame, withPresentationTime: samplePTS)
                    self.videoFramesWritten += 1
                    pendingFrame2 = frames.secondFrame
                    pendingFrame2PTS = CMTimeAdd(samplePTS, fieldDuration)
                    self.progress = CMTimeGetSeconds(samplePTS) / CMTimeGetSeconds(self.trackEndTime)
                }
            }
        }
    }
    
    func startProcessingRecompress() {
        // for now, just pass through, we'll implement the recompress-only path later
        startProcessingPassThrough()
    }
    
    func startProcessingPassThrough() {
        if self.isValid && self.trackWriter != nil && self.trackReader != nil && !self.isCancelled {
            self.dispatchGroup.enter()
            self.trackWriter!.requestMediaDataWhenReady(on: self.wantsMoreQueue!) {
                while(self.trackWriter!.isReadyForMoreMediaData) {
                    if self.isCancelled {
                        self.trackWriter!.markAsFinished()
                        self.dispatchGroup.leave()
                        break
                    }
                    
                    let sample = self.trackReader!.copyNextSampleBuffer()
                    if sample == nil {
                        self.trackWriter!.markAsFinished()
                        print("\(self.elapsedTime()): trackWriter successfully passed through all the samples: \(self.id)")
                        self.dispatchGroup.leave()
                        break
                    }
                    
                    self.trackWriter!.append(sample!)
                }
            }
        }
    }
        
    private func elapsedTime() -> String {
        let fElapsedTime: Double =  Date().timeIntervalSince1970 - self.startTime
        return String(format: "%.3f", fElapsedTime)
    }

}
