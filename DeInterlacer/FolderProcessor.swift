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
        // public movie (public.movie) represents media formats that may contain both video and audio.
        // It corresponds to what users would label a “movie”.  So any file with extension .mov, .dv,
        // .mp4 (not .mp3), .avi (not .wav), .m4v (not .m4a), etc.
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
    
    init(inputFolderURL: URL, outputFolderURL: URL?) {
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
        
        // make sure output folder is NOT present, then create it
        let actualOutputFolderURL: URL = outputFolderURL ?? makeOutputFolderURLFromInputFolderURL(inputFolderURL: inputFolderURL)

        // generate output URL list (and create any output folders necessary)
        var outputURLs: [URL] = []
        for movieURL in movieURLs {
            outputURLs.append(makeOutputMovieURLFromInputMovieURL(inputURL: movieURL, inputFolderURL: inputFolderURL, outputFolderURL: actualOutputFolderURL))
        }
        
        self.inputMovieURLs = movieURLs
        self.outputMovieURLs = outputURLs
    }
}

private func makeOutputMovieURLFromInputMovieURL(inputURL: URL, inputFolderURL: URL, outputFolderURL: URL) -> URL {
    // returns /output/folder/inputFileNameNoExtension.mov
    let inputFolderComponents = inputFolderURL.pathComponents
    let inputComponents = inputURL.pathComponents
    
    // gather up all the folders from inputComponents that are after the folders from inputFolderComponents
    // Note that the slice goes to ..< count - 1, so we don't take the last input component (the filename)
    let trailingInputFolders = inputComponents[inputFolderComponents.count ..< inputComponents.count - 1]
    
    // Construct outputMovieURL as outputFolder URL + trailingInputFolders
    var outputMovieFolderURL: URL = outputFolderURL
    for trailingFolder in trailingInputFolders {
        outputMovieFolderURL = outputMovieFolderURL.appendingPathComponent(trailingFolder, isDirectory: true)
    }
    
    // Create that folder if it doesn't already exist (and any parent folders as well)
    let fm = FileManager.default
    try! fm.createDirectory(at: outputMovieFolderURL, withIntermediateDirectories: true)

    // And then append the filename (but replace input extension with ".mov")
    let inputFileNameNoExtension: String = inputURL.deletingPathExtension().lastPathComponent
    return outputMovieFolderURL.appendingPathComponent(inputFileNameNoExtension, isDirectory: false).appendingPathExtension("mov")
}

private func makeOutputFolderURLFromInputFolderURL(inputFolderURL: URL) -> URL
{
    let parentFolder: URL = inputFolderURL.deletingLastPathComponent()
    let outputLastPathComponent: String = inputFolderURL.lastPathComponent + "_deinterlaced"
    let outputFolderURL = parentFolder.appendingPathComponent(outputLastPathComponent)
    return outputFolderURL
}
