//
//  MovieChecker.swift
//  moovcheck
//
//  Created by Greg Chapman on 2/26/23.
//

import Foundation
import AVFoundation

class MovieChecker {
    let movieURL: URL
    init(movieURL: URL) {
        self.movieURL = movieURL
    }
    
    func check() async throws {
        let resourceValues = try self.movieURL.resourceValues(forKeys: [.fileSizeKey])
        let fileSize: Int64 = Int64(resourceValues.fileSize!)
        var fileSizeRequired: Int64 = -1
        let asset: AVAsset = AVAsset(url: self.movieURL)
        let tracks = try await asset.load(.tracks)
        for track in tracks {
            let cursor: AVSampleCursor? = track.makeSampleCursorAtLastSampleInDecodeOrder()
            if cursor == nil {
                print("no cursor at last sample")
                continue
            }
            let range: AVSampleCursorStorageRange = cursor!.currentChunkStorageRange
            let fileSizeRequiredForTrack: Int64 = range.offset + range.length
            if fileSizeRequired < fileSizeRequiredForTrack {
                fileSizeRequired = fileSizeRequiredForTrack
            }
        }
        
        if fileSize < fileSizeRequired {
            print("\(movieURL.id) is truncated by \(fileSizeRequired - fileSize) bytes")
        }
        else {
            print("\(movieURL.id) is all there")
        }
    }
}
