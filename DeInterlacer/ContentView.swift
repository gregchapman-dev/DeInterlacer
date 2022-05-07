//
//  ContentView.swift
//  DeInterlacer
//
//  Created by Greg Chapman on 5/6/22.
//

import SwiftUI
import UniformTypeIdentifiers

struct MyURL: Identifiable {
	let url: URL
	var id: String { url.absoluteString.removingPercentEncoding ?? "" }
	var name: String { url.lastPathComponent.removingPercentEncoding ?? "" }
	var conformsToPublicMovie: Bool {
		if let type = UTType(filenameExtension: url.pathExtension) {
			return type.conforms(to: .movie)
		}
		return false
	}
}

struct ContentView: View {
	@State var message = "Drag a folder of movies to deinterlace onto the app icon"
	@State var movieURLs: [MyURL] = []
	private var sortedMovieURLs: [MyURL] {
		return movieURLs.sorted(by: {return $0.id < $1.id})
	}

	private func gatherMovieURLsFromFolderTree(folderURL: URL) {
		let fm = FileManager()
		let enumerator = fm.enumerator(
							at: folderURL,
							includingPropertiesForKeys: [.isDirectoryKey],
							options: .skipsHiddenFiles)!
		for case let fileURL as URL in enumerator {
			let myFileURL = MyURL(url: fileURL)
			if myFileURL.conformsToPublicMovie {
				movieURLs.append(myFileURL)
			}
		}
	}


	var body: some View {
		VStack {
			Text(message)
				.padding()
				.onOpenURL { (url) in
					// Handle url here
					if url.isFileURL {
						if url.hasDirectoryPath {
							message = "Processing movies..."
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
			List {
				ForEach(sortedMovieURLs) { movieURL in
					Text(movieURL.id)
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
