//
//  ContentView.swift
//  DeInterlacer
//
//  Created by Greg Chapman on 5/6/22.
//

import SwiftUI
import AVFoundation
import CoreVideo

struct ContentView: View {
	@State var message = "Drag a folder of movies to deinterlace onto the app icon"
	@State var isProcessing: Bool = false
	@State var isCanceling: Bool = false
	@State var processMoviesTask: Task<Any, Never>? = nil
    @State var folderProcessor: FolderProcessor? = nil
	@State var movieProcessors: [MovieProcessor] = [MovieProcessor]()
	private var sortedMovieStatuses: [MovieStatus] {
		var output = [MovieStatus]()
		for mproc in movieProcessors {
			output.append(mproc.movieStatus)
		}
		return output
	}

	private func processMovies() async {
        if folderProcessor == nil {
            return
        }
        
		for mproc in movieProcessors {
			if Task.isCancelled {
		        break
		    }

			do {
                try await mproc.startMovieProcessing()
			}
			catch {
			    // ignore failures and move on to next movie
			}
		}
	}

	var body: some View {
		VStack {
			Text(message)
			.onOpenURL { (url) in
				// Handle url here
				if url.isFileURL {
					if url.hasDirectoryPath {
                        folderProcessor = FolderProcessor(inputFolderURL: url, outputFolderURL: nil)
                        if folderProcessor!.inputMovieURLs.count > 0 {
                            for i in 0..<folderProcessor!.inputMovieURLs.count {
                                let inputURL: URL = folderProcessor!.inputMovieURLs[i]
                                let outputURL: URL = folderProcessor!.outputMovieURLs[i]
                                movieProcessors.append(MovieProcessor(inputMovieURL: inputURL, outputMovieURL: outputURL))
                            }
                            message = "Movies to Process:"
                        }
                        else {
                            message = "Must be directory with movies (recursively) in it."
                        }
					}
					else {
						message = "Must be directory."
					}
				}
				else {
					message = "Must be file:// url."
				}
			}
			HStack {
				Button("Process movies") {
					isProcessing = true
					message = "Processing movies:"
					processMoviesTask = Task {
						await processMovies()
					}
				}
				.buttonStyle(.bordered)
				.disabled(isProcessing || folderProcessor == nil || movieProcessors.count == 0)
				Button("Cancel processing") {
					message = "Canceling..."
					processMoviesTask?.cancel()
					isCanceling = true
				}
				.buttonStyle(.bordered)
				.disabled(!isProcessing || isCanceling)
			}
			List {
				if !isProcessing {
                    if let folderProcessor {
                        ForEach(folderProcessor.inputMovieURLs, id: \.self.id) { movieURL in
                            Text(movieURL.id)
                        }
                    }
                }
				else {
                    ForEach(sortedMovieStatuses, id: \.self.movieURL.id) { movieStatus in
						HStack {
							ProgressView(
								movieStatus.progress == 1.0 && !movieStatus.success ? "Failed" : "Processing...",
								value:movieStatus.progress)
								.frame(width: 100)
							Text(movieStatus.movieURL.id)
						}
					}
				}
			}
		}
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
