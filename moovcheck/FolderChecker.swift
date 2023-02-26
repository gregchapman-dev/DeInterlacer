//
//  FolderChecker.swift
//  moovcheck
//
//  Created by Greg Chapman on 2/26/23.
//

import Foundation
import UniformTypeIdentifiers

extension URL {
    var id: String { self.absoluteString.removingPercentEncoding ?? self.absoluteString }
    var conformsToPublicMovie: Bool {
        // public movie (public.movie) represents media formats that may contain both video and audio.
        // It corresponds to what users would label a “movie”.  So any file with extension .mov, .dv,
        // .mp4 (not .mp3), .avi (not .wav), .m4v (not .m4a), etc.
        if let type = UTType(filenameExtension: self.pathExtension) {
            return type.conforms(to: .movie)
        }
        return false
    }
}


struct FolderChecker
{
    let inputMovieURLs: [URL]
    
    init(inputFolderURL: URL) {
        var movieURLs: [URL] = []
        let enumerator = FileManager.default.enumerator(
            at: inputFolderURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles)!
        for case let fileURL as URL in enumerator {
            if fileURL.conformsToPublicMovie {
                movieURLs.append(fileURL)
            }
        }
        
        if movieURLs.count == 0 {
            print("Input folder must have movies (recursively) in it.")
            self.inputMovieURLs = []
            return
        }
        
        // return sorted by full (absolute) path string
        self.inputMovieURLs = movieURLs.sorted(by: {return $0.absoluteString < $1.absoluteString})
    }
}
