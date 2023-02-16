//
//  FolderProcessor.swift
//  DeInterlacer
//
//  Created by Greg Chapman on 2/14/23.
//

import Foundation
import UniformTypeIdentifiers

extension URL {
    var id: String { self.absoluteString.removingPercentEncoding ?? self.absoluteString }
    var conformsToPublicMovie: Bool {
        if let type = UTType(filenameExtension: self.pathExtension) {
            return type.conforms(to: .movie)
        }
        return false
    }
}

struct FolderProcessor
{
    let inputMovieURLs: [URL]
    let outputMovieURLs: [URL]
    
    init(inputFolderURL: URL, outputFolderURL: URL) {
        var movieURLs: [URL] = []
        let fm = FileManager()
        let enumerator = fm.enumerator(
            at: inputFolderURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles)!
        for case let fileURL as URL in enumerator {
            if fileURL.conformsToPublicMovie {
                movieURLs.append(fileURL)
            }
        }
        
        // sort
        movieURLs = movieURLs.sorted(by: {return $0.absoluteString < $1.absoluteString})
        
        // generate output URL list
        var outputURLs: [URL] = []
        for movieURL in movieURLs {
            outputURLs.append(makeOutputURLFromInputURL(inputURL: movieURL, outputFolderURL: outputFolderURL))
        }
        
        self.inputMovieURLs = movieURLs
        self.outputMovieURLs = outputURLs
    }
}

private func makeOutputURLFromInputURL(inputURL: URL, outputFolderURL: URL) -> URL {
    // returns /output/folder/inputFileNameNoExtension.mov
    let inputFileNameNoExtension: String = inputURL.deletingPathExtension().lastPathComponent
    return outputFolderURL.appendingPathComponent(inputFileNameNoExtension).appendingPathExtension("mov")
}


