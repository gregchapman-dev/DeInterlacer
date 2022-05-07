//
//  ContentView.swift
//  DeInterlacer
//
//  Created by Greg Chapman on 5/6/22.
//

import SwiftUI

struct ContentView: View {
	@State var folder = "Drag a folder of movies to deinterlace onto the dock icon"
    var body: some View {
        Text(folder)
            .padding()
			.onOpenURL{ (url) in
				// Handle url here
				folder = url.absoluteString
			}
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
