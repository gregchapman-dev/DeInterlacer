//
//  main.swift
//  deinterlace
//
//  Created by Greg Chapman on 2/17/23.
//

import Foundation

private func startSomeMoviesProcessing(movieProcessors: [MovieProcessor], numToStart: Int) async {
    var numStarted: Int = 0
    for mproc in movieProcessors {
        if !mproc.movieStatus.hasStarted {
            do {
                try await mproc.startMovieProcessing()
                numStarted += 1
            }
            catch {
                // ignore failures and move on to next movie
                print(mproc.inputMovieURL.id, " has failed to start processing.")
            }
        }
        if numStarted == numToStart {
            break
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
if let outputPath {
    outputFolderURL = URL(fileURLWithPath: outputPath)
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
}

signal(SIGINT, signalCallback)

// now kick off the task that waits for all the processing to complete (feeding new processors into the maw as needed)
let waitTask = Task {
    let pInfo: ProcessInfo = ProcessInfo.processInfo
    let nCPUs: Int = pInfo.activeProcessorCount
    print("nCPUs = \(nCPUs)")
    let maxAtATime: Int = nCPUs / 2  // using all the CPUs seems to slow things down a lot
    let n: Double = Double(movieProcessors.count)
    var overallProgress: Double = 0.0
    var allDone: Bool = false
    var numRunning: Int = 0
    while !allDone {
        var totalProgress: Double = 0.0
        allDone = true
        numRunning = 0
        for mproc in movieProcessors {
            totalProgress += mproc.getProgress()
            if !mproc.movieStatus.hasCompleted {
                allDone = false
                if mproc.movieStatus.hasStarted {
                    // it has started, but has not completed. It's running.
                    numRunning += 1
                }
            }
        }
        if !allDone {
            overallProgress = totalProgress / n
            let numToStart = maxAtATime - numRunning
            if numToStart > 0 {
                await startSomeMoviesProcessing(movieProcessors:movieProcessors, numToStart:numToStart)
            }
            try await Task.sleep(nanoseconds: 2*1000*1000*1000)
        }
        let formattedProgress = String(format: "%.2f", overallProgress * 100.0)
        print("progress: \(formattedProgress)%, numRunning: \(numRunning)")
    }
    print("done waiting in waitTask")
}

// and wait for that wait task to finish waiting...
try await waitTask.value
print("finished waiting in main")
exit(0)

