//
//  main.swift
//  deinterlace
//
//  Created by Greg Chapman on 2/17/23.
//

import Foundation

private func startMoviesProcessing() async {
    for mproc in await movieProcessors {
        do {
            try await mproc.startMovieProcessing()
        }
        catch {
            // ignore failures and move on to next movie
            print(mproc.inputMovieURL.id, " has failed to start processing.")
        }
    }
}


let argv: [String] = CommandLine.arguments
let argc: Int = argv.count

var inputPath: String? = nil
var outputPath: String? = nil

for i in 1..<argv.count {
    let arg = argv[i]
    if arg.starts(with: "-") {
        // option processing
        continue
    }

    // input folder, output folder
    if inputPath == nil {
        inputPath = arg
        continue
    }
    if outputPath == nil {
        outputPath = arg
        continue
    }

    // too many non-option arguments
}

if inputPath == nil {
    print("Usage: deinterlace <input folder> <optional output folder>")
    exit(1)
}

let inputFolderURL: URL = URL(fileURLWithPath: inputPath!)
var outputFolderURL: URL? = nil
if outputPath != nil {
    outputFolderURL = URL(fileURLWithPath: outputPath!)
}
let folderProcessor = FolderProcessor(inputFolderURL: inputFolderURL, outputFolderURL: outputFolderURL)
var movieProcessors: [MovieProcessor] = [MovieProcessor]()

if folderProcessor.inputMovieURLs.count == 0 {
    exit(1)
}

for i in 0..<folderProcessor.inputMovieURLs.count {
    let inputURL: URL = folderProcessor.inputMovieURLs[i]
    let outputURL: URL = folderProcessor.outputMovieURLs[i]
    movieProcessors.append(MovieProcessor(inputMovieURL: inputURL, outputMovieURL: outputURL))
}

// make processing task cancelable with ctrl-C
let signalCallback: sig_t = { _signal in
    print("Cancelling operations...")
    for mproc in movieProcessors {
        //print("\tcancelling \(mproc.movieStatus.movieURL.id)")
        mproc.cancel()
    }
    signal(SIGINT, signalCallback)
}

signal(SIGINT, signalCallback)

await startMoviesProcessing()

// now kick off the task that waits for all the processing to complete
let waitTask = Task {
    let n: Double = Double(movieProcessors.count)
    var overallProgress: Double = 0.0
    var allDone: Bool = false
    while !allDone {
        print("progress: \(overallProgress * 100.0)%")
        try await Task.sleep(nanoseconds: 1000*1000*1000)
        var totalProgress: Double = 0.0
        allDone = true
        for mproc in movieProcessors {
            totalProgress += mproc.movieStatus.progress
            if !mproc.movieStatus.hasCompleted {
                allDone = false
            }
        }
        overallProgress = totalProgress / n
    }
    print("done waiting in waitTask")
}

// and wait for that wait task to finish waiting...
try await waitTask.value
print("finished waiting in main")
exit(0)

