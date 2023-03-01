//
//  MovieProcessor.swift
//  DeInterlacer
//
//  Created by Greg Chapman on 2/14/23.
//

import Foundation
import AVFoundation

extension Date {
    func currentTimeMillis() -> Int64 {
        return Int64(self.timeIntervalSince1970 * 1000)
    }
}

class MovieStatus {
    let movieURL: URL
    var hasStarted: Bool = false
    var hasCompleted: Bool = false
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
    var trackProcessors: [TrackProcessor] = []
    private var writerCompletionQueue: DispatchQueue
    private var isCancelled: Bool
    let startTime: Double = Date().timeIntervalSince1970
    var videoFramesWritten: Int64 = 0

    init(inputMovieURL: URL, outputMovieURL: URL) {
        self.inputMovieURL = inputMovieURL
        self.outputMovieURL = outputMovieURL
        self.movieStatus = MovieStatus(movieURL:inputMovieURL)
        self.writerCompletionQueue = DispatchQueue(label: "writerCompletion: " + self.inputMovieURL.id)
        self.isCancelled = false
    }
    
    func getProgress() -> Double {
        if self.movieStatus.hasCompleted {
            return 1.0
        }
        
        if self.trackProcessors.count == 0 {
            return 0.0
        }

        var progress: Double = 0.0
        for trackProc in self.trackProcessors {
            progress += trackProc.progress
        }
        
        return progress / Double(self.trackProcessors.count)
    }

    func cancel() {
        for trackProc in self.trackProcessors {
            trackProc.isCancelled = true
        }
        self.isCancelled = true
    }

    private func checkForCancellation() -> Bool {
        if self.isCancelled {
            movieStatus.success = false
            print("movie processing canceled: \(self.movieStatus.movieURL.id)")
            return true
        }
        return false
    }
    
    private func elapsedTime() -> String {
        let fElapsedTime: Double =  Date().timeIntervalSince1970 - self.startTime
        return String(format: "%.3f", fElapsedTime)
    }
    
    private func getBestOutputMovieTimeScale() -> CMTimeScale {
        // This got too complicated when I realized that timecode tracks (often) have a timescale of 30000, which I should
        // NOT ignore, but audio tracks have timescales of 44100 or 48000 or whatever, which I _should_ ignore.  Forget it,
        // let's just pick a number that always works, even though it's kinda big.
        return 120000
//        var foundFields: Bool = false
//        var videoTimeScale: CMTimeScale? = nil
//        var otherTimeScale: CMTimeScale = 600
//        for trackProc in self.trackProcessors {
//            if trackProc.track.mediaType == .video {
//                if trackProc.track.hasFields {
//                    if !foundFields {
//                        foundFields = true
//                        videoTimeScale = trackProc.track.fieldDuration.timescale
//                    }
//                    else if videoTimeScale != nil {
//                        videoTimeScale = max(videoTimeScale!, trackProc.track.fieldDuration.timescale)
//                    }
//                    else {
//                        videoTimeScale = trackProc.track.fieldDuration.timescale
//                    }
//                }
//                else {
//                    if !foundFields {
//                        if videoTimeScale != nil {
//                            videoTimeScale = max(videoTimeScale!, trackProc.naturalTimeScale)
//                        }
//                        else {
//                            videoTimeScale = trackProc.naturalTimeScale
//                        }
//                    }
//                }
//            }
//            else {
//                otherTimeScale = max(otherTimeScale, trackProc.naturalTimeScale)
//            }
//        }
//        if let videoTimeScale {
//            return videoTimeScale
//        }
//        return otherTimeScale
    }

    func startMovieProcessing() async throws {
        if movieStatus.hasStarted {
            // only allow one call to processMovie
            print("\(self.elapsedTime()): second call to startMovieProcessing is NOP: \(self.movieStatus.movieURL.id)")
            return
        }
        movieStatus.hasStarted = true
        print("\(self.elapsedTime()): startMovieProcessing called: \(self.movieStatus.movieURL.id)")

        if checkForCancellation() {
            movieStatus.hasCompleted = true
            return
        }

        let inputAsset: AVAsset = AVAsset(url: inputMovieURL)
        let inputTracks: [AVAssetTrack]? = try? await inputAsset.load(.tracks)

        if inputTracks == nil || inputTracks!.count < 1 {
            movieStatus.success = false
            movieStatus.hasCompleted = true
            print("\(self.elapsedTime()): input movie has no tracks: \(self.movieStatus.movieURL.id)")
            return
        }
        
        // try? FileManager().removeItem(at: outputMovieURL)

        let optionalAssetWriter: AVAssetWriter? =
            try? AVAssetWriter(outputURL: outputMovieURL, fileType: AVFileType.mov)
        if optionalAssetWriter == nil {
            movieStatus.success = false
            movieStatus.hasCompleted = true
            print("\(self.elapsedTime()): assetWriter creation failed: \(self.movieStatus.movieURL.id)")
            return
        }

        let assetWriter: AVAssetWriter = optionalAssetWriter!
        assetWriter.shouldOptimizeForNetworkUse = false

        let optionalAssetReader: AVAssetReader? = try? AVAssetReader(asset: inputAsset)
        if optionalAssetReader == nil {
            print("\(self.elapsedTime()): assetReader creation failed: \(self.movieStatus.movieURL.id)")
            movieStatus.success = false
            movieStatus.hasCompleted = true
            return
        }
        let assetReader: AVAssetReader = optionalAssetReader!

        // The track processors enter and leave this dispatch group as they start and end processing.
        // This movie processor will finish things up when the dispatch group has been completely "left".
        let dispatchGroup = DispatchGroup()

        for i in 0..<inputTracks!.count {
            let track = inputTracks![i]
            let trackProc: TrackProcessor = try await TrackProcessor(track:track, dispatchGroup: dispatchGroup, id: movieStatus.movieURL.id + " Track " + String(i))
            self.trackProcessors.append(trackProc)
            if trackProc.isValid && trackProc.trackReader != nil && trackProc.trackWriter != nil {
                assetReader.add(trackProc.trackReader!)
                assetWriter.add(trackProc.trackWriter!)
            }
        }

        assetWriter.movieTimeScale = self.getBestOutputMovieTimeScale()

        assetReader.startReading()
        assetWriter.startWriting()
        assetWriter.startSession(atSourceTime: CMTime.zero)
            
        for trackProc in self.trackProcessors {
            trackProc.postAssetWriterSetup()
        }

        if checkForCancellation() {
            movieStatus.hasCompleted = true
            return
        }
        
        for trackProc in self.trackProcessors {
            trackProc.startProcessing()
        }

        // This DispatchWorkItem will run once all the tracks are complete (dispatchGroup is completely "left")
        dispatchGroup.notify(queue: self.writerCompletionQueue, work: DispatchWorkItem {
            let _ = Task {
                if self.isCancelled {
                    assetWriter.cancelWriting()
                    print("\(self.elapsedTime()): assetWriter CANCELLED: \(self.movieStatus.movieURL.id)")
                }
                else {
                    print("\(self.elapsedTime()): start assetWriter.finishWriting: \(self.movieStatus.movieURL.id)")
                    
                    await assetWriter.finishWriting()
                    
                    let st = assetWriter.status
                    if st == .failed {
                        print("\(self.elapsedTime()): assetWriter.finishWriting FAILED: \(self.movieStatus.movieURL.id)")
                    }
                    else if st == .completed {
                        print("\(self.elapsedTime()): assetWriter.finishWriting completed: \(self.movieStatus.movieURL.id)")
                    }
                    else if st == .cancelled {
                        print("\(self.elapsedTime()): assetWriter.finishWriting unexpectedly cancelled: \(self.movieStatus.movieURL.id)")
                    }
                    else if st == .writing {
                        print("\(self.elapsedTime()): assetWriter.finishWriting finished, but assetWriter is still writing \(self.movieStatus.movieURL.id)")
                    }
                    else {
                        print("\(self.elapsedTime()): assetWriter.finishWriting status unknown: \(self.movieStatus.movieURL.id)")
                    }

                    if let e=assetWriter.error {
                        print("\(self.elapsedTime()): assetWriter error:", e)
                    }

                }
                assetReader.cancelReading()
                self.movieStatus.hasCompleted = true
            }
        })

        return
    }

}

