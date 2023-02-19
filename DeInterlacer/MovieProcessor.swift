//
//  MovieProcessor.swift
//  DeInterlacer
//
//  Created by Greg Chapman on 2/14/23.
//

import Foundation
import AVFoundation

class MovieStatus {
    let movieURL: URL
    var hasStarted: Bool = false
    var hasCompleted: Bool = false
    var progress: Double = 0.0
    var success: Bool = false // failure is shown as progress=1.0, success=false

    init(movieURL: URL) {
        self.movieURL = movieURL
    }
    
    var isProcessing: Bool {
        return self.hasStarted && !self.hasCompleted
    }
    
    var hasFailed: Bool {
        return self.hasCompleted && !self.success
    }
    
    var hasSucceeded: Bool {
        return self.hasCompleted && self.success
    }
    
}

class MovieProcessor
{
    let inputMovieURL: URL
    let outputMovieURL: URL
    var movieStatus: MovieStatus
    private var writerCompletionQueue: DispatchQueue

    init(inputMovieURL: URL, outputMovieURL: URL) {
        self.inputMovieURL = inputMovieURL
        self.outputMovieURL = outputMovieURL
        self.movieStatus = MovieStatus(movieURL:inputMovieURL)
        self.writerCompletionQueue = DispatchQueue(label: "writerCompletion")
    }
    
    func startMovieProcessing() async throws {
        if movieStatus.hasStarted {
            // only allow one call to processMovie
            print("second call to startMovieProcessing is NOP: \(self.movieStatus.movieURL.id)")
            return
        }
        movieStatus.hasStarted = true
        print("startMovieProcessing called: \(self.movieStatus.movieURL.id)")


        let inputAsset: AVAsset = AVAsset(url: inputMovieURL)
        let inputVideoTracks: [AVAssetTrack]? =
            try? await inputAsset.loadTracks(withMediaType: AVMediaType.video)

        if inputVideoTracks == nil || inputVideoTracks!.count < 1 {
            movieStatus.success = false
            movieStatus.progress = 1.0
            movieStatus.hasCompleted = true
            print("input movie has no video track: \(self.movieStatus.movieURL.id)")
            return
        }

        // assume the first video track is the only one we care about
        let inputVideoTrack: AVAssetTrack = inputVideoTracks![0]
        if !inputVideoTrack.hasFields {
            movieStatus.success = false
            movieStatus.progress = 1.0
            movieStatus.hasCompleted = true
            print("video track doesn't have fields: \(self.movieStatus.movieURL.id)")
            return
        }
        
        let videoTrackEndTime: CMTime = inputVideoTrack.timeRange.end
        let fieldDuration: CMTime = inputVideoTrack.fieldDuration
        let videoDimensions: CMVideoDimensions = inputVideoTrack.videoDimensions!
        let topFieldComesFirst: Bool = inputVideoTrack.topFieldComesFirst

        // try? FileManager().removeItem(at: outputMovieURL)

        let optionalAssetWriter: AVAssetWriter? =
            try? AVAssetWriter(outputURL: outputMovieURL, fileType: AVFileType.mov)
        if optionalAssetWriter == nil {
            movieStatus.success = false
            movieStatus.progress = 1.0
            movieStatus.hasCompleted = true
            print("assetWriter creation failed: \(self.movieStatus.movieURL.id)")
            return
        }

        let assetWriter: AVAssetWriter = optionalAssetWriter!
        assetWriter.shouldOptimizeForNetworkUse = true

        let dispatchGroup = DispatchGroup()

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.proRes422
        ]
        let sourceFormatDesc: CMVideoFormatDescription
            = inputVideoTrack.formatDescriptions[0] as! CMVideoFormatDescription
        let videoWriter: AVAssetWriterInput =
            AVAssetWriterInput(mediaType: AVMediaType.video,
                               outputSettings: videoSettings,
                               sourceFormatHint: sourceFormatDesc)

        let videoWriterAdapter: AVAssetWriterInputPixelBufferAdaptor =
            AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: videoWriter,
                sourcePixelBufferAttributes: nil)
//                sourcePixelBufferAttributes: [
//                    String(kCVPixelBufferPixelFormatTypeKey): NSNumber(value: kCVPixelFormatType_422YpCbCr8),
//                    String(kCVPixelBufferWidthKey): NSNumber(value: videoDimensions.width),
//                    String(kCVPixelBufferHeightKey): NSNumber(value: videoDimensions.height)
//                ])
        assetWriter.add(videoWriter)
        // .pixelFormat_422YpCbCr8
        
        var pixelBufferPool: CVPixelBufferPool? = nil
        CVPixelBufferPoolCreate(nil,
                                nil,
                                [
                                    String(kCVPixelBufferPixelFormatTypeKey): NSNumber(value: kCVPixelFormatType_422YpCbCr8),
                                    String(kCVPixelBufferWidthKey): NSNumber(value: videoDimensions.width),
                                    String(kCVPixelBufferHeightKey): NSNumber(value: videoDimensions.height)
                                ] as CFDictionary,
                                &pixelBufferPool)
        if pixelBufferPool == nil {
            print("pixel buffer pool creation failed: \(self.movieStatus.movieURL.id)")
            movieStatus.success = false
            movieStatus.progress = 1.0
            movieStatus.hasCompleted = true
            return
        }

        let optionalAssetReader: AVAssetReader? = try? AVAssetReader(asset: inputAsset)
        if optionalAssetReader == nil {
            print("assetReader creation failed: \(self.movieStatus.movieURL.id)")
            movieStatus.success = false
            movieStatus.progress = 1.0
            movieStatus.hasCompleted = true
            return
        }
        let assetReader: AVAssetReader = optionalAssetReader!
        let videoReader: AVAssetReaderTrackOutput = AVAssetReaderTrackOutput(
            track: inputVideoTrack,
            outputSettings: [
                String(kCVPixelBufferPixelFormatTypeKey): NSNumber(value: kCVPixelFormatType_422YpCbCr8),
                String(kCVPixelBufferWidthKey): NSNumber(value: videoDimensions.width),
                String(kCVPixelBufferHeightKey): NSNumber(value: videoDimensions.height)
            ])
        assetReader.add(videoReader)

        assetReader.startReading()
        assetWriter.startWriting()
        assetWriter.startSession(atSourceTime: CMTime.zero)
        
        // Sam, what the heck?!?  This assertion fails (and if I comment out the assertion, I crash below
        // when I pass pixelBufferPool: videoWriterAdapter.pixelBufferPool! to self.createFramesFromFields.
        // assert(videoWriterAdapter.pixelBufferPool != nil)

        let videoWriterWantsMoreQueue = DispatchQueue(label: "videoWriterWantsMore")
        // let audioWriterWantsMoreQueue = DispatchQueue(label: "audioWriterWantsMore")

        var pendingFrame2: CVPixelBuffer? = nil
        var pendingFrame2PTS: CMTime = CMTime.invalid
        
        let frameDeinterlacer = FrameDeinterlacer(pixelBufferPool:pixelBufferPool!)

        dispatchGroup.enter()
        videoWriter.requestMediaDataWhenReady(on: videoWriterWantsMoreQueue) {
            while(videoWriter.isReadyForMoreMediaData) {
                if Task.isCancelled {
                    videoWriter.markAsFinished()
                    print("task was cancelled: \(self.movieStatus.movieURL.id)")
                    self.movieStatus.success = false
                    self.movieStatus.progress = 1.0
                    dispatchGroup.leave()
                    break
                }
                if pendingFrame2 != nil {
                    // Append the pending second field (now a frame) to the video track
                    videoWriterAdapter.append(pendingFrame2!, withPresentationTime: pendingFrame2PTS)
                    pendingFrame2 = nil
                    continue
                }

                // Get the next video sample buffer, generate two frames from the two fields,
                // and append the first field (now a frame) to the output video track. Store
                // the second field (now a frame) in pendingFrame2 to hand out the next time
                // the videoWriter wants more data.
                let sample = videoReader.copyNextSampleBuffer()
                if sample == nil {
                    videoWriter.markAsFinished()
                    print("videoWriter successfully wrote all the video: \(self.movieStatus.movieURL.id)")
                    self.movieStatus.success = true
                    self.movieStatus.progress = 1.0
                    dispatchGroup.leave()
                    break
                }

                let samplePTS: CMTime = CMSampleBufferGetOutputPresentationTimeStamp(sample!)
                let frameWithTwoFields: CVPixelBuffer = CMSampleBufferGetImageBuffer(sample!)!
                let frames = frameDeinterlacer.createFramesFromFields(
                                        frameWithTwoFields: frameWithTwoFields,
                                        topFieldComesFirst: topFieldComesFirst)
                videoWriterAdapter.append(frames.firstFrame, withPresentationTime: samplePTS)
                pendingFrame2 = frames.secondFrame
                pendingFrame2PTS = CMTimeAdd(samplePTS, fieldDuration)
                self.movieStatus.progress = CMTimeGetSeconds(samplePTS) / CMTimeGetSeconds(videoTrackEndTime)
            }
        }

//        audioWriter.requestMediaDataWhenReady(on: audioWriterWantsMoreQueue) {
//            while(audioWriter.isReadyForMoreMediaData) {
//            }
//        }


        dispatchGroup.notify(queue: self.writerCompletionQueue, work: DispatchWorkItem {
            let _ = Task {
                await assetWriter.finishWriting()
                assetReader.cancelReading()
                print("assetWriter.finishWriting all done: \(self.movieStatus.movieURL.id)")
                self.movieStatus.hasCompleted = true
            }
        })

        return
    }

}

extension AVAssetTrack {
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
        if fieldDetail == nil {
            return false
        }
        if fieldDetail!.isEqual(kCMFormatDescriptionFieldDetail_TemporalTopFirst) {
            return true
        }
        if fieldDetail!.isEqual(kCMFormatDescriptionFieldDetail_SpatialFirstLineEarly) {
            return true
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

