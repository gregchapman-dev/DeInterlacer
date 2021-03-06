//
//  ContentView.swift
//  DeInterlacer
//
//  Created by Greg Chapman on 5/6/22.
//

import SwiftUI
import AVFoundation
import CoreVideo
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

extension AVAssetTrack {
	var hasFields: Bool {
		if self.mediaType != AVMediaType.video {
			return false
		}
		if self.formatDescriptions.count < 1 {
			return false
		}

		// assume the first formatDescription is the one we're interested in
		let desc: CMVideoFormatDescription = self.formatDescriptions[0] as! CMVideoFormatDescription
		let fieldCountNum: NSNumber? = CMFormatDescriptionGetExtension(
											desc,
											extensionKey: kCMFormatDescriptionExtension_FieldCount)
									   as? NSNumber
		if fieldCountNum != nil && fieldCountNum!.intValue == 2 {
			return true
		}

		if desc.mediaSubType == .dvcNTSC {
			// 'dvc ' is an exception: it doesn't say it has fields, but it always does
			return true
		}

		return false
	}

	var fieldDuration: CMTime {
		if self.hasFields {
			let nfr = self.nominalFrameRate
			if nfr > 29.95 && nfr < 30.0 {
				return CMTimeMake(value: 1001, timescale: 60_000)
			}
			if nfr > 59.90 && nfr < 60.0 {
				return CMTimeMake(value: 1001, timescale: 120_000)
			}
		}
		return CMTime.invalid
	}

	var topFieldComesFirst: Bool {
		if self.mediaType != AVMediaType.video {
			return false
		}
		if self.formatDescriptions.count < 1 {
			return false
		}

		// assume the first formatDescription is the one we're interested in
		let desc: CMVideoFormatDescription = self.formatDescriptions[0] as! CMVideoFormatDescription
		let fieldDetail: NSString? = CMFormatDescriptionGetExtension(
											desc,
											extensionKey: kCMFormatDescriptionExtension_FieldDetail)
									   as? NSString
		if fieldDetail == nil {
			return false
		}
		if fieldDetail!.isEqual(kCMFormatDescriptionFieldDetail_TemporalTopFirst) {
			return true
		}
		if fieldDetail!.isEqual(kCMFormatDescriptionFieldDetail_SpatialFirstLineEarly) {
			return true
		}
		return false
	}

	var videoDimensions: CMVideoDimensions? {
		if self.mediaType != AVMediaType.video {
			return nil
		}
		if self.formatDescriptions.count < 1 {
			return nil
		}

		// assume the first formatDescription is the one we're interested in
		let desc: CMVideoFormatDescription = self.formatDescriptions[0] as! CMVideoFormatDescription
		return CMVideoFormatDescriptionGetDimensions(desc)
	}
}

struct MovieStatus {
	let movieURL: URL
	var isProcessing: Bool = false
	var progress: Double = 0.0
	var success: Bool = false // failure is shown as progress=1.0, success=False
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
									+ "_deinterlaced"
		let outputURL: URL = inputURL.deletingLastPathComponent()
								.appendingPathComponent(fileNameNoExtension)
								.appendingPathExtension("mov")
		return outputURL
	}

	private func copyField(from: CVPixelBuffer, to: CVPixelBuffer, whichField: Int) {
		// Assumptions: from and to are identically sized single plane pixel buffers,
		// with format == kCVPixelFormatType_422YpCbCr8 (actually it will work for
		// any format which has 2 bytes per pixel, but we know it's always
		// kCVPixelFormatType_422YpCbCr8)
		let bytesPerPixel = 2 							 // assumption: two bytes per pixel in from and to
		let height = CVPixelBufferGetHeight(from) 		 // assumption: to's height is the same as from's
		let width = CVPixelBufferGetWidth(from)			 // assumption: to's width is the same as from's
		let rowBytes = CVPixelBufferGetBytesPerRow(from) // assumption: to's rowBytes is the same as from's

		let lineWidthInBytes = width * bytesPerPixel
		let linesPerField = height / 2

		CVPixelBufferLockBaseAddress(from, .readOnly)
		CVPixelBufferLockBaseAddress(to, CVPixelBufferLockFlags(rawValue: 0))

		var fromBase = CVPixelBufferGetBaseAddress(from)
		var toBase = CVPixelBufferGetBaseAddress(to)

		if whichField == 1 {
			// start a line into the frame
			fromBase = fromBase! + rowBytes
			toBase = toBase! + rowBytes
		}

		for _ in 0 ..< linesPerField {
			memcpy(toBase, fromBase, lineWidthInBytes)
			// skip ahead two lines (to next line of field)
			fromBase = fromBase! + rowBytes * 2
			toBase = toBase! + rowBytes * 2
		}

		CVPixelBufferUnlockBaseAddress(from, .readOnly);
		CVPixelBufferUnlockBaseAddress(to, CVPixelBufferLockFlags(rawValue: 0));
	}

	private func loadUInt64(_ ptr: UnsafeMutableRawPointer) -> UInt64 {
		let u64 = ptr.load(as: UInt64.self)
		return u64
	}

	private func storeUInt64(_ ptr: UnsafeMutableRawPointer, value: UInt64) {
		ptr.storeBytes(of: value, as: UInt64.self)
	}

	private func interpolateField(_ fromto: CVPixelBuffer, fromField: Int, toField: Int) {
		let bytesPerPixel: Int = 2	// assumption: two bytes per pixel
		let height: Int = CVPixelBufferGetHeight(fromto)
		let width: Int = CVPixelBufferGetWidth(fromto)
		let rowBytes: Int = CVPixelBufferGetBytesPerRow(fromto)

		let lineWidthInBytes: Int = width * bytesPerPixel
		let linesPerField: Int = height / 2

		CVPixelBufferLockBaseAddress(fromto, CVPixelBufferLockFlags(rawValue: 0))
		let baseAddr: UnsafeMutableRawPointer = CVPixelBufferGetBaseAddress(fromto)!

		// First, copy the one line that has nothing to interpolate against:

		// If we're interpolating from field 1 to field 0, copy the first line
		// of field 1 into the first line of field 0 (because there's no earlier
		// line in field 1 to interpolate against).
		// If we're interpolating from field 0 to field 1, copy the last line
		// of field 0 into the last line of field 1 (because there's no later
		// line in field 0 to interpolate against).

		// Then, do the interpolation for all the other lines in toField:

		// Lets get as close as we can to doing this on SIMD32<UInt8> data
		// (32 bytes at a time, or 4 UInt64's at a time).  We'll do as many
		// vertical swaths of this width as we can, then switch down to
		// SIMD16<UInt8> (swaths that are 16 bytes wide; 2 UInt64's at a
		// time), and then finally a swath that is one UInt64 wide to finish
		// off if necessary.  Note that CVPixelBuffer width is always a multiple
		// of 16 bytes, so we won't overrun buffer width.

		// Four UInt64's at a time is max, since I need two operands and a result,
		// so that's 12 UInt64's that are hopefully being allocated to registers,
		// and there are only 13 general-purpose registers on ARM.  If we were
		// actually using simd instructions here, I could do more at a time.

		let startLinePtr: UnsafeMutableRawPointer
		if toField == 0 {
			// We already produced line 0 (we copied line 1), so skip that, and
			// start writing at line 2
			startLinePtr = baseAddr + (rowBytes * 2)
		}
		else {
			// We already produced line height-1 (we copied line height-2), so
			// so we can go ahead and start writing at line 1, as expected
			startLinePtr = baseAddr + rowBytes
		}

		// In both cases, we have already produced one of the lines, so we only
		// need to produce linesPerField-1 lines.
		let linesToProduce: Int = linesPerField-1

		// First pass, 32 bytes at a time (4 UInt64s)
		var bytesPerGroup: Int = 32
		var numByteGroups = lineWidthInBytes / bytesPerGroup
		var byteGroupOffset: Int = 0
		var groupPtr: UnsafeMutableRawPointer = startLinePtr + byteGroupOffset

		// Read SIMD32<UInt8> (four UInt64 values) from line above
		var eightBytesAbove0: UInt64 = loadUInt64(groupPtr +  0 - rowBytes)
		var eightBytesAbove1: UInt64 = loadUInt64(groupPtr +  8 - rowBytes)
		var eightBytesAbove2: UInt64 = loadUInt64(groupPtr + 16 - rowBytes)
		var eightBytesAbove3: UInt64 = loadUInt64(groupPtr + 24 - rowBytes)

		// Read SIMD32<UInt8> (four UInt64 values) from line below
		var eightBytesBelow0: UInt64 = loadUInt64(groupPtr +  0 + rowBytes)
		var eightBytesBelow1: UInt64 = loadUInt64(groupPtr +  8 + rowBytes)
		var eightBytesBelow2: UInt64 = loadUInt64(groupPtr + 16 + rowBytes)
		var eightBytesBelow3: UInt64 = loadUInt64(groupPtr + 24 + rowBytes)

		for _ in 0 ..< numByteGroups {
			for _ in 0..<linesToProduce {
				// This is kind of fun; we are trying to interpolate each byte of each pixel
				// from the equivalent byte in the line above and the line below:
				// 		pixelByte = (pixelByteAbove + pixelByteBelow) / 2
				// Better to do the divide by two first, so we don't get a temporary
				// overflow (that'll be super important in a minute):
				//		pixelByte = pixelByteAbove/2 + pixelByteBelow/2
				// Right shift is quicker than integer divide:
				//		pixelByte = (pixelByteAbove>>1) + (pixelByteBelow>>1)
				// We can now do 8 bytes (four pixels) at a time:
				//		eightBytes: UInt64 = ((eightBytesAbove>>1) & 0x7f7f7f7f7f7f7f7f)
				//								+ ((eightBytesBelow>>1) & 0x7f7f7f7f7f7f7f7f)
				// Note how we had to mask off the high bit of every byte, since that
				// bit came in unwanted from the byte next door, during the right shift.
				// Then when we add the two together, if there are any carries, they will
				// appropriately land in that cleared bit (and never in the low bit of a
				// neighboring byte).  We might should round (this code truncates), but
				// that ruins the whole "we avoided byte overflow" thing, since you have
				// to increment by 1 before the divide, and that might overflow.  And
				// honestly, the rounding isn't _that_ important.

				// If Swift ever supports SIMD more fully, the closest ARM and X86 simd
				// instruction for this is (ARM) vhaddq_u8 (or vrhaddq_u8 if you want to
				// round), and (X86) _mm_avg_epu8 (which rounds).

				let eightBytes0: UInt64 = ((eightBytesAbove0>>1) & 0x7f7f7f7f7f7f7f7f)
											+ ((eightBytesBelow0>>1) & 0x7f7f7f7f7f7f7f7f)
				let eightBytes1: UInt64 = ((eightBytesAbove1>>1) & 0x7f7f7f7f7f7f7f7f)
											+ ((eightBytesBelow1>>1) & 0x7f7f7f7f7f7f7f7f)
				let eightBytes2: UInt64 = ((eightBytesAbove2>>1) & 0x7f7f7f7f7f7f7f7f)
											+ ((eightBytesBelow2>>1) & 0x7f7f7f7f7f7f7f7f)
				let eightBytes3: UInt64 = ((eightBytesAbove3>>1) & 0x7f7f7f7f7f7f7f7f)
											+ ((eightBytesBelow3>>1) & 0x7f7f7f7f7f7f7f7f)

				storeUInt64(groupPtr +  0, value: eightBytes0)
				storeUInt64(groupPtr +  8, value: eightBytes1)
				storeUInt64(groupPtr + 16, value: eightBytes2)
				storeUInt64(groupPtr + 24, value: eightBytes3)

				// Set up for next line in swath
				groupPtr = groupPtr + (rowBytes * 2)

				// Note how we avoid loading the line above a second time, since we already
				// have it in (hopefully) four registers.
				eightBytesAbove0 = eightBytesBelow0
				eightBytesAbove1 = eightBytesBelow1
				eightBytesAbove2 = eightBytesBelow2
				eightBytesAbove3 = eightBytesBelow3

				eightBytesBelow0 = loadUInt64(groupPtr +  0 + rowBytes)
				eightBytesBelow1 = loadUInt64(groupPtr +  8 + rowBytes)
				eightBytesBelow2 = loadUInt64(groupPtr + 16 + rowBytes)
				eightBytesBelow3 = loadUInt64(groupPtr + 24 + rowBytes)
			}

			// Set up for next swath (groupPtr moves back up to start line, but offset to the next group)
			byteGroupOffset += bytesPerGroup
			groupPtr = startLinePtr + byteGroupOffset
		}

		// Second pass: vertical swaths 16 bytes wide
		var remainingLineWidth = lineWidthInBytes - byteGroupOffset
		bytesPerGroup = 16
		numByteGroups = remainingLineWidth / bytesPerGroup
		groupPtr = startLinePtr + byteGroupOffset

		// Read SIMD16<UInt8> (two UInt64 values) from line above
		eightBytesAbove0 = loadUInt64(groupPtr +  0 - rowBytes)
		eightBytesAbove1 = loadUInt64(groupPtr +  8 - rowBytes)

		// Read SIMD16<UInt8> (two UInt64 values) from line below
		eightBytesBelow0 = loadUInt64(groupPtr +  0 + rowBytes)
		eightBytesBelow1 = loadUInt64(groupPtr +  8 + rowBytes)

		for _ in 0 ..< numByteGroups {
			for _ in 0..<linesToProduce {
				let eightBytes0: UInt64 = ((eightBytesAbove0>>1) & 0x7f7f7f7f7f7f7f7f)
											+ ((eightBytesBelow0>>1) & 0x7f7f7f7f7f7f7f7f)
				let eightBytes1: UInt64 = ((eightBytesAbove1>>1) & 0x7f7f7f7f7f7f7f7f)
											+ ((eightBytesBelow1>>1) & 0x7f7f7f7f7f7f7f7f)

				storeUInt64(groupPtr +  0, value: eightBytes0)
				storeUInt64(groupPtr +  8, value: eightBytes1)

				// Set up for next line in swath
				groupPtr = groupPtr + (rowBytes * 2)

				// Note how we avoid loading the line above a second time, since we already
				// have it in (hopefully) four registers.
				eightBytesAbove0 = eightBytesBelow0
				eightBytesAbove1 = eightBytesBelow1

				eightBytesBelow0 = loadUInt64(groupPtr +  0 + rowBytes)
				eightBytesBelow1 = loadUInt64(groupPtr +  8 + rowBytes)
			}

			// Set up for next swath (groupPtr moves back up to start line, but offset to the next group)
			byteGroupOffset += bytesPerGroup
			groupPtr = startLinePtr + byteGroupOffset
		}

		// Third pass: vertical swaths 8 bytes wide
		remainingLineWidth = lineWidthInBytes - byteGroupOffset
		bytesPerGroup = 8
		numByteGroups = remainingLineWidth / bytesPerGroup
		if numByteGroups == 0 && remainingLineWidth > 0 {
			// Run past the end a bit to get that last skinny swath. It's OK, because we're
			// doing an 8 byte swath, and CVPixelBuffer width is always a multiple of 16.
			numByteGroups = 1
		}
		groupPtr = startLinePtr + byteGroupOffset

		// Read SIMD8<UInt8> (one UInt64 value) from line above
		eightBytesAbove0 = loadUInt64(groupPtr - rowBytes)

		// Read SIMD8<UInt8> (one UInt64 value) from line below
		eightBytesBelow0 = loadUInt64(groupPtr + rowBytes)

		for _ in 0 ..< numByteGroups {
			for _ in 0..<linesToProduce {
				let eightBytes0: UInt64 = ((eightBytesAbove0>>1) & 0x7f7f7f7f7f7f7f7f)
											+ ((eightBytesBelow0>>1) & 0x7f7f7f7f7f7f7f7f)

				storeUInt64(groupPtr, value: eightBytes0)

				// Set up for next line in swath
				groupPtr = groupPtr + (rowBytes * 2)

				// Note how we avoid loading the line above a second time, since we already
				// have it in (hopefully) four registers.
				eightBytesAbove0 = eightBytesBelow0

				eightBytesBelow0 = loadUInt64(groupPtr + rowBytes)
			}

			// Set up for next swath (groupPtr moves back up to start line, but offset to the next group)
			byteGroupOffset += bytesPerGroup
			groupPtr = startLinePtr + byteGroupOffset
		}

		CVPixelBufferUnlockBaseAddress(fromto, CVPixelBufferLockFlags(rawValue: 0));
	}

	private func createFramesFromFields(frameWithTwoFields: CMSampleBuffer,
										topFieldComesFirst: Bool,
										pixelBufferPool: CVPixelBufferPool)
	-> (firstFrame: CVPixelBuffer, secondFrame: CVPixelBuffer) {
		let srcPixels: CVPixelBuffer = CMSampleBufferGetImageBuffer(frameWithTwoFields)!

		var firstFrameOptional: CVPixelBuffer? = nil
		var secondFrameOptional: CVPixelBuffer? = nil

		CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &firstFrameOptional)
		CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &secondFrameOptional)

		let firstFrame = firstFrameOptional!
		let secondFrame = secondFrameOptional!

		// Note: we identify fields by their first line number.  Top field is 0, bottom field is 1.
		let firstTemporalField: Int = topFieldComesFirst ? 0 : 1
		let secondTemporalField: Int = topFieldComesFirst ? 1 : 0

		// Make firstFrame from first temporal field
		copyField(from: srcPixels, to: firstFrame, whichField: firstTemporalField)
		interpolateField(firstFrame, fromField: firstTemporalField, toField: secondTemporalField)

		// Make secondFrame from second temporal field
		copyField(from: srcPixels, to: secondFrame, whichField: secondTemporalField)
		interpolateField(secondFrame, fromField: secondTemporalField, toField: firstTemporalField)

		return (firstFrame: firstFrame, secondFrame: secondFrame)
	}

	private func processMovie(movieURL: URL) async throws {
		var movieStatus: MovieStatus = MovieStatus(movieURL: movieURL)
		movieStatus.isProcessing = true
		status[movieURL.id] = movieStatus

		let inputAsset: AVAsset = AVAsset(url: movieURL)
		let inputVideoTracks: [AVAssetTrack]? =
			try? await inputAsset.loadTracks(withMediaType: AVMediaType.video)
		let movieDuration: CMTime = inputAsset.duration

		if inputVideoTracks == nil || inputVideoTracks!.count < 1 {
			status[movieURL.id]?.success = false
			status[movieURL.id]?.progress = 1.0
			return
		}

		// assume the first video track is the only one we care about
		let inputVideoTrack: AVAssetTrack = inputVideoTracks![0]
		if !inputVideoTrack.hasFields {
			status[movieURL.id]?.success = false
			status[movieURL.id]?.progress = 1.0
			return
		}

		let fieldDuration: CMTime = inputVideoTrack.fieldDuration
		let videoDimensions: CMVideoDimensions = inputVideoTrack.videoDimensions!
		let topFieldComesFirst: Bool = inputVideoTrack.topFieldComesFirst

		let outputMovieURL: URL = makeOutputURLFromInputURL(inputURL: movieURL)
		try? FileManager().removeItem(at: outputMovieURL)

		let optionalAssetWriter: AVAssetWriter? =
			try? AVAssetWriter(outputURL: outputMovieURL, fileType: AVFileType.mov)
		if optionalAssetWriter == nil {
			status[movieURL.id]?.success = false
			status[movieURL.id]?.progress = 1.0
			return
		}

		let assetWriter: AVAssetWriter = optionalAssetWriter!
		assetWriter.shouldOptimizeForNetworkUse = true

		var assetWriterTrackFinishedSemaphores: [AVAssetWriterInput: DispatchSemaphore] = [:]

		let videoSettings: [String: Any] = [
			AVVideoCodecKey: AVVideoCodecType.proRes422
		]
		let sourceFormatDesc: CMVideoFormatDescription
			= inputVideoTrack.formatDescriptions[0] as! CMVideoFormatDescription
		let videoWriter: AVAssetWriterInput =
			AVAssetWriterInput(mediaType: AVMediaType.video,
							   outputSettings: videoSettings,
							   sourceFormatHint: sourceFormatDesc)

		assetWriterTrackFinishedSemaphores[videoWriter] = DispatchSemaphore(value: 0)

		let videoWriterAdapter: AVAssetWriterInputPixelBufferAdaptor =
			AVAssetWriterInputPixelBufferAdaptor(
				assetWriterInput: videoWriter,
				sourcePixelBufferAttributes: [
					String(kCVPixelBufferPixelFormatTypeKey): NSNumber(value: kCVPixelFormatType_422YpCbCr8),
					String(kCVPixelBufferWidthKey): NSNumber(value: videoDimensions.width),
					String(kCVPixelBufferHeightKey): NSNumber(value: videoDimensions.height)
				])
		assetWriter.add(videoWriter)
		// .pixelFormat_422YpCbCr8

		let optionalAssetReader: AVAssetReader? = try? AVAssetReader(asset: inputAsset)
		if optionalAssetReader == nil {
			status[movieURL.id]?.success = false
			status[movieURL.id]?.progress = 1.0
			return
		}
		let assetReader: AVAssetReader = optionalAssetReader!
		let videoReader: AVAssetReaderTrackOutput = AVAssetReaderTrackOutput(
			track: inputVideoTrack,
			outputSettings: [
				String(kCVPixelBufferPixelFormatTypeKey): NSNumber(value: kCVPixelFormatType_422YpCbCr8),
				String(kCVPixelBufferWidthKey): NSNumber(value: videoDimensions.width),
				String(kCVPixelBufferHeightKey): NSNumber(value: videoDimensions.height)
			])
		assetReader.add(videoReader)

		assetReader.startReading()
		assetWriter.startWriting()
		assetWriter.startSession(atSourceTime: CMTime.zero)

		let writerWantsMoreQueue = DispatchQueue(label: "writerWantsMoreQueue")

		var pendingFrame2: CVPixelBuffer? = nil
		var pendingFrame2PTS: CMTime = CMTime.invalid

		videoWriter.requestMediaDataWhenReady(on: writerWantsMoreQueue) {
			while(videoWriter.isReadyForMoreMediaData) {
				if pendingFrame2 != nil {
					// Append the pending second field (now a frame) to the video track
					videoWriterAdapter.append(pendingFrame2!, withPresentationTime: pendingFrame2PTS)
					pendingFrame2 = nil
					status[movieURL.id]?.progress = CMTimeGetSeconds(pendingFrame2PTS)/CMTimeGetSeconds(movieDuration)
					continue
				}

				// Get the next video sample buffer, generate two frames from the two fields,
				// and append the first field (now a frame) to the output video track. Store
				// the second field (now a frame) in pendingFrame2 to hand out the next time
				// the videoWriter wants more data.
				let sample = videoReader.copyNextSampleBuffer()
				if (sample != nil) {
					let frames = createFramesFromFields(
										frameWithTwoFields: sample!,
										topFieldComesFirst: topFieldComesFirst,
										pixelBufferPool: videoWriterAdapter.pixelBufferPool!)
					let samplePTS: CMTime = CMSampleBufferGetOutputPresentationTimeStamp(sample!)
					videoWriterAdapter.append(frames.firstFrame, withPresentationTime: samplePTS)
					pendingFrame2 = frames.secondFrame
					pendingFrame2PTS = CMTimeAdd(samplePTS, fieldDuration)
					continue
				}

				videoWriter.markAsFinished()
				assetWriterTrackFinishedSemaphores[videoWriter]!.signal()
				break
			}
		}

		for sema in assetWriterTrackFinishedSemaphores.values {
			sema.wait()
		}

		await assetWriter.finishWriting()
		assetReader.cancelReading()


//		try await Task.sleep(nanoseconds: 500*1000*1000)
//		status[movieURL.id]?.progress = 0.20
//		try await Task.sleep(nanoseconds: 500*1000*1000)
//		status[movieURL.id]?.progress = 0.40
//		try await Task.sleep(nanoseconds: 500*1000*1000)
//		status[movieURL.id]?.progress = 0.60
//		try await Task.sleep(nanoseconds: 500*1000*1000)
//		status[movieURL.id]?.progress = 0.80
//		try await Task.sleep(nanoseconds: 500*1000*1000)
		status[movieURL.id]?.success = true
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
