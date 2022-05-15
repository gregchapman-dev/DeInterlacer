//
//  ContentView.swift
//  DeInterlacer
//
//  Created by Greg Chapman on 5/6/22.
//

import SwiftUI
import AVFoundation
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
	@State var processMoviesTask: Task<Any, Never>? = nil
	@State var status: [String: MovieStatus] = [String: MovieStatus]()
	private var sortedMovieURLs: [URL] {
		return movieURLs.sorted(by: {return $0.absoluteString < $1.absoluteString})
	}
	private var sortedMovieStatuses: [MovieStatus] {
		var output = [MovieStatus]()
		for movie in sortedMovieURLs {
			var stat: MovieStatus? = status[movie.id]
			if stat == nil {
				// report a simple "haven't started yet" status
				stat = MovieStatus(movieURL: movie)
			}
			output.append(stat!)
		}
		return output
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

	private func makeOutputURLFromInputURL(inputURL: URL) -> URL {
		let fileNameNoExtension: String = inputURL.deletingPathExtension().lastPathComponent
		let outputURL: URL = inputURL.deletingLastPathComponent()
								.appendingPathComponent(fileNameNoExtension)
								.appendingPathExtension(".mov")
		return outputURL
	}

	private func hasFields(track: AVAssetTrack) -> Bool {
		if track.mediaType != AVMediaType.video {
			return false
		}

		for desc in track.formatDescriptions {
			let fieldCountNum: NSNumber? =
				CMFormatDescriptionGetExtension(
					desc as! CMFormatDescription,
					extensionKey: kCMFormatDescriptionExtension_FieldCount)
					as? NSNumber
			if fieldCountNum != nil {
				if fieldCountNum!.intValue == 2 {
					return true
				}
			}
		}

		return false
	}

	private func processMovie(movieURL: URL) async throws {
		var movieStatus: MovieStatus = MovieStatus(movieURL: movieURL)
		movieStatus.isProcessing = true
		status[movieURL.id] = movieStatus

//		let outputMovieURL: URL = makeOutputURLFromInputURL(inputURL: movieURL)
		let inputAsset: AVAsset = AVAsset(url: movieURL)
		let assetReader: AVAssetReader? = try? AVAssetReader(asset: inputAsset)
		if assetReader == nil {
			status[movieURL.id]?.progress = 100.0
			return
		}

		let inputVideoTracks: [AVAssetTrack]? =
			try? await inputAsset.loadTracks(withMediaType: AVMediaType.video)

		if inputVideoTracks == nil || inputVideoTracks!.count < 1 {
			status[movieURL.id]?.progress = 100.0
			return
		}

		var inputVideoTrackHasFields: [Bool] = []
		for vtrack in inputVideoTracks! {
			inputVideoTrackHasFields.append(hasFields(track: vtrack))
		}
//		try await Task.sleep(nanoseconds: 500*1000*1000)
//		status[movieURL.id]?.progress = 0.20
//		try await Task.sleep(nanoseconds: 500*1000*1000)
//		status[movieURL.id]?.progress = 0.40
//		try await Task.sleep(nanoseconds: 500*1000*1000)
//		status[movieURL.id]?.progress = 0.60
//		try await Task.sleep(nanoseconds: 500*1000*1000)
//		status[movieURL.id]?.progress = 0.80
//		try await Task.sleep(nanoseconds: 500*1000*1000)
		status[movieURL.id]?.progress = 1.0
		return
	}

	private func processMovies() async {
		for movieURL in sortedMovieURLs {
			if Task.isCancelled {
		        break
		    }

			do {
				try await processMovie(movieURL: movieURL)
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
					processMoviesTask = Task {
						await processMovies()
					}
				}
				.buttonStyle(.bordered)
				.disabled(isProcessing || movieURLs.count == 0)
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
