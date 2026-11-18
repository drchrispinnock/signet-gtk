import Foundation
import Testing
@testable import Signet

/// Help > Getting Started: upstream's `theAppBundlesTheChapterAndItsPictures`, which reads
/// `Bundle.main` (Signet.app there), for the port's resource bundle.
struct GettingStartedBundleTests {
    @Test @MainActor func thePortBundlesTheChapterAndItsPictures() throws {
        let html = try #require(GettingStartedView.chapterHTML())
        #expect(html.localizedCaseInsensitiveContains("<h1 id=\"ID110-starting_1_Getting\">Getting started</h1>"))
        let resources = try #require(GettingStartedView.resourceDirectory)
        let pictures = html.components(separatedBy: "<img src=\"").dropFirst().compactMap { $0.components(separatedBy: "\"").first }
        #expect(pictures.count >= 10)
        for picture in pictures {
            #expect(FileManager.default.fileExists(atPath: resources.appendingPathComponent(picture).path), "\(picture)")
        }
    }
}

