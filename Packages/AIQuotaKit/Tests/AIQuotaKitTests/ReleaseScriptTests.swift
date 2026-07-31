import Foundation
import XCTest

final class ReleaseScriptTests: XCTestCase {
    func testPublishedArchivesAreImmutableAndBuildSpecific() throws {
        let source = try String(
            contentsOf: repoRoot.appending(path: "scripts/release.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("ZIP_BASENAME=\"AIQuota-${VERSION}-${BUILD}.zip\""))
        XCTAssertTrue(source.contains("DOWNLOAD_URL=\"https://github.com/${REPO}/releases/download/${TAG}/${ZIP_BASENAME}\""))
        XCTAssertTrue(source.contains("Release ${TAG} already exists. Published releases cannot be replaced."))
        XCTAssertFalse(source.contains("gh release upload \"$TAG\" \"$ZIP\" \"$APPCAST\" --clobber"))
        XCTAssertTrue(source.contains("gh release create \"$TAG\" \"$ZIP\" \"$MANUAL_ZIP\" \"$APPCAST\""))
        XCTAssertTrue(source.contains("[ \"$MANUAL_SIG\" = \"$SIGNATURE\" ]"))
    }

    private var repoRoot: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
