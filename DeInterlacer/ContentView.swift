//
//  ContentView.swift
//  DeInterlacer
//
//  Created by Greg Chapman on 5/6/22.
//

import SwiftUI
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

struct MovieStatus {
	let movieURL: URL
	var isProcessing: Bool = false
	var progress: Double = 0.0
	var id: String { movieURL.id }
}

struct ContentView: View {
	@State var message = "Drag a folder of movies to deinterlace onto the app icon"
	@State var movieURLs: [URL] = []
	@State var isProcessing: Bool = false
	@State var isCanceling: Bool = false
	@State var status: [String: MovieStatus] = [String: MovieStatus]()
	private var sortedMovieURLs: [URL] {
		return movieURLs.sorted(by: {return $0.absoluteString < $1.absoluteString})
	}
	private var sortedMovieStatuses: [MovieStatus] {
		var output = [MovieStatus]()
		for movie in sortedMovieURLs {
			let status: MovieStatus = getMovieStatus(movieURL:movie)
			output.append(status)
		}
		return output
	}

	private func getMovieStatus(movieURL: URL) -> MovieStatus {
		var theStatus: MovieStatus? = status[movieURL.id]
		if theStatus == nil {
			theStatus = MovieStatus(movieURL: movieURL)
		}
		return theStatus!
	}

	private func gatherMovieURLsFromFolderTree(folderURL: URL) {
		let fm = FileManager()
		let enumerator = fm.enumerator(
							at: folderURL,
							includingPropertiesForKeys: [.isDirectoryKey],
							options: .skipsHiddenFiles)!
		for case let fileURL as URL in enumerator {
			if fileURL.conformsToPublicMovie {
				movieURLs.append(fileURL)
			}
		}
	}

	private func processMovie(movie: URL) async throws {
		var movieStatus: MovieStatus = getMovieStatus(movieURL: movie)
		movieStatus.isProcessing = true
		movieStatus.progress = 0.05
		status[movie.id] = movieStatus

		try await Task.sleep(nanoseconds: 2*1000*1000*1000)

		status[movie.id]?.progress = 1.0
	}

	private func processMovies() async {
		for movie in sortedMovieURLs {
		    if isCanceling {
		        break
		    }

			do {
				try await processMovie(movie: movie)
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
						message = "Movies to Process:"
						gatherMovieURLsFromFolderTree(folderURL: url)
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
					Task {
						await processMovies()
					}
				}
				.buttonStyle(.bordered)
				.disabled(isProcessing || movieURLs.count == 0)
				Button("Cancel processing") {
					message = "Canceling..."
					isCanceling = true
				}
				.buttonStyle(.bordered)
				.disabled(!isProcessing || isCanceling)
			}
			List {
				if !isProcessing {
					ForEach(sortedMovieURLs, id: \.self.id) { movieURL in
						Text(movieURL.id)
					}
				}
				else {
					ForEach(sortedMovieStatuses, id: \.self.id) {movieStatus in
						HStack {
							ProgressView(value:movieStatus.progress)
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
