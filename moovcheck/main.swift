//
//  main.swift
//  moovcheck
//
//  Created by Greg Chapman on 2/26/23.
//

import Foundation

let argv: [String] = CommandLine.arguments
let argc: Int = argv.count

var inputPath: String? = nil

for i in 1..<argv.count {
    let arg = argv[i]
    if arg.starts(with: "-") {
        // option processing
        continue
    }

    // input folder or movie
    if inputPath == nil {
        inputPath = arg
        continue
    }

    // too many non-option arguments
}

if inputPath == nil {
    print("Usage: deinterlace <input folder/file>")
    exit(1)
}

let inputURL: URL = URL(fileURLWithPath: inputPath!)

var inputURLs: [URL] = []

if inputURL.conformsToPublicMovie {
    inputURLs.append(inputURL)
}
else {
    let folderChecker: FolderChecker = FolderChecker(inputFolderURL:inputURL)
    inputURLs = folderChecker.inputMovieURLs
}

for movieURL in inputURLs {
    let movieChecker = MovieChecker(movieURL: movieURL)
    try await movieChecker.check()
}
