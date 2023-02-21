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
    private var isCanceled: Bool

    init(inputMovieURL: URL, outputMovieURL: URL) {
        self.inputMovieURL = inputMovieURL
        self.outputMovieURL = outputMovieURL
        self.movieStatus = MovieStatus(movieURL:inputMovieURL)
        self.writerCompletionQueue = DispatchQueue(label: "writerCompletion")
        self.isCanceled = false
    }

    func cancel() {
        self.isCanceled = true
    }

    private func checkForCancellation() -> Bool {
        if self.isCanceled {
            movieStatus.success = false
            movieStatus.progress = 1.0
            print("movie processing canceled: \(self.movieStatus.movieURL.id)")
            return true
        }
        return false
    }

    func startMovieProcessing() async throws {
        if movieStatus.hasStarted {
            // only allow one call to processMovie
            print("second call to startMovieProcessing is NOP: \(self.movieStatus.movieURL.id)")
            return
        }
        movieStatus.hasStarted = true
        print("startMovieProcessing called: \(self.movieStatus.movieURL.id)")

        if checkForCancellation() {
            movieStatus.hasCompleted = true
            return
        }

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
        let sourceVideoFormatDesc: CMVideoFormatDescription
            = inputVideoTrack.formatDescriptions[0] as! CMVideoFormatDescription
        let videoWriter: AVAssetWriterInput =
            AVAssetWriterInput(mediaType: AVMediaType.video,
                               outputSettings: videoSettings,
                               sourceFormatHint: sourceVideoFormatDesc)

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

        var audioWriters: [AVAssetWriterInput] = []
        let inputAudioTracks: [AVAssetTrack]? =
            try? await inputAsset.loadTracks(withMediaType: AVMediaType.audio)
        if let inputAudioTracks {
            for inputAudioTrack in inputAudioTracks {
                let sourceAudioFormatDesc: CMAudioFormatDescription =
                    inputAudioTrack.formatDescriptions[0] as! CMAudioFormatDescription
                let audioWriter: AVAssetWriterInput =
                    AVAssetWriterInput(mediaType: AVMediaType.audio,
                                       outputSettings: nil,  // pass-through
                                       sourceFormatHint: sourceAudioFormatDesc)
                audioWriters.append(audioWriter)
                assetWriter.add(audioWriter)
            }
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

        var audioReaders: [AVAssetReaderTrackOutput] = []
        if let inputAudioTracks {
            for inputAudioTrack in inputAudioTracks {
                let audioReader: AVAssetReaderTrackOutput = AVAssetReaderTrackOutput(
                    track: inputAudioTrack,
                    outputSettings: nil)
                audioReaders.append(audioReader)
                assetReader.add(audioReader)

            }
        }

        assetReader.startReading()
        assetWriter.startWriting()
        assetWriter.startSession(atSourceTime: CMTime.zero)

        // assert(videoWriterAdapter.pixelBufferPool != nil)
        // Sam, what the heck?!?  This assertion fails (and if I comment out the assertion, I crash below
        // when I pass pixelBufferPool: videoWriterAdapter.pixelBufferPool! to self.createFramesFromFields.
        // I'm working around this by creating my own pixelBufferPool.

        let videoWriterWantsMoreQueue = DispatchQueue(label: "videoWriterWantsMore")
        var audioWriterWantsMoreQueues: [DispatchQueue] = []

        var pendingFrame2: CVPixelBuffer? = nil
        var pendingFrame2PTS: CMTime = CMTime.invalid

        let frameDeinterlacer = FrameDeinterlacer(pixelBufferPool:pixelBufferPool!)

        if checkForCancellation() {
            movieStatus.hasCompleted = true
            return
        }

        dispatchGroup.enter()
        videoWriter.requestMediaDataWhenReady(on: videoWriterWantsMoreQueue) {
            while(videoWriter.isReadyForMoreMediaData) {
                if self.checkForCancellation() {
                    videoWriter.markAsFinished()
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

        // kick off processing of all the audio tracks
        for idx in 0..<audioWriters.count {
            audioWriterWantsMoreQueues.append(DispatchQueue(label: "audioWriterWantsMore\(idx)"))

            let audioWriterWantsMoreQueue = audioWriterWantsMoreQueues[idx]
            let audioWriter = audioWriters[idx]
            let audioReader = audioReaders[idx]

            dispatchGroup.enter()
            audioWriter.requestMediaDataWhenReady(on: audioWriterWantsMoreQueue) {
                while(audioWriter.isReadyForMoreMediaData) {
                    if self.checkForCancellation() {
                        audioWriter.markAsFinished()
                        dispatchGroup.leave()
                        break
                    }

                    let sample = audioReader.copyNextSampleBuffer()
                    if sample == nil {
                        audioWriter.markAsFinished()
                        print("audioWriter\(idx) successfully wrote all the audio: \(self.movieStatus.movieURL.id)")
                        dispatchGroup.leave()
                        break
                    }

                    audioWriter.append(sample!)
                }
            }
        }


        dispatchGroup.notify(queue: self.writerCompletionQueue, work: DispatchWorkItem {
            let _ = Task {
                if self.isCanceled {
                    assetWriter.cancelWriting()
                    //print("assetWriter canceled: \(self.movieStatus.movieURL.id)")
                }
                else {
                    await assetWriter.finishWriting()
                    print("assetWriter.finishWriting all done: \(self.movieStatus.movieURL.id)")
                }
                assetReader.cancelReading()
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

