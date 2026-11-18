import XCTest
@testable import Unlim

/// Round-trips for the caption protocol from ANALYSIS-Storage-Sync.md.
/// These must stay byte-identical to Android's protocol, or files uploaded
/// from iOS will not be readable by the Android/web clients (and vice versa).
final class CaptionBuilderTests: XCTestCase {
    func testFileCaptionRoundTrip() {
        let caption = CaptionBuilder.createFileCaption(path: "0/photo.jpg", chunkId: "")
        let parsed = CaptionBuilder.parseFileCaption(caption)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.path, "0/photo.jpg")
        XCTAssertNil(parsed?.chunkId)
    }

    func testChunkCaptionRoundTrip() {
        let chunkId = CaptionBuilder.createChunkId(uuid: "abc-123", index: 2, totalBytes: 5_000_000_000)
        XCTAssertTrue(chunkId.contains(CaptionBuilder.chunkLabel))
        XCTAssertTrue(chunkId.contains(CaptionBuilder.chunkTotalSizeLabel))

        let caption = CaptionBuilder.createFileCaption(path: "0/big.zip", chunkId: chunkId)
        let parsed = CaptionBuilder.parseFileCaption(caption)
        XCTAssertEqual(parsed?.path, "0/big.zip")
        XCTAssertEqual(parsed?.chunkId, chunkId)

        let chunk = CaptionBuilder.parseChunkCaption(chunkId)
        XCTAssertEqual(chunk?.uuid, "abc-123")
        XCTAssertEqual(chunk?.index, 2)
        XCTAssertEqual(chunk?.totalBytes, 5_000_000_000)
    }

    func testParseFileCaptionRejectsGarbage() {
        XCTAssertNil(CaptionBuilder.parseFileCaption("hello world"))
        XCTAssertNil(CaptionBuilder.parseFileCaption(""))
    }

    func testGroupMessages() {
        let chunk0 = CaptionBuilder.createChunkId(uuid: "u1", index: 0, totalBytes: 3_000_000_000)
        let chunk1 = CaptionBuilder.createChunkId(uuid: "u1", index: 1, totalBytes: 3_000_000_000)
        let messages = [
            ChatMessage(
                id: 1, chatId: 100, date: 1,
                content: .document(
                    RemoteFile(id: 10, size: 100, fileName: "big.zip", localPath: nil, remotePath: nil),
                    caption: CaptionBuilder.createFileCaption(path: "0/big.zip", chunkId: chunk0)
                )
            ),
            ChatMessage(
                id: 2, chatId: 100, date: 2,
                content: .document(
                    RemoteFile(id: 11, size: 100, fileName: "1big.zip", localPath: nil, remotePath: nil),
                    caption: CaptionBuilder.createFileCaption(path: "0/big.zip", chunkId: chunk1)
                )
            ),
            ChatMessage(
                id: 3, chatId: 100, date: 3,
                content: .document(
                    RemoteFile(id: 12, size: 50, fileName: "small.txt", localPath: nil, remotePath: nil),
                    caption: CaptionBuilder.createFileCaption(path: "0/small.txt", chunkId: "")
                )
            ),
        ]

        let groups = CaptionBuilder.groupMessages(messages)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].messages.count, 2)
        XCTAssertEqual(groups[0].messages.map(\.id), [1, 2])
        XCTAssertEqual(groups[0].originalName, "big.zip")
        XCTAssertEqual(groups[1].messages.count, 1)
        XCTAssertEqual(groups[1].originalName, "small.txt")
    }

    func testGalleryCaptionContainsMarkers() {
        let caption = CaptionBuilder.createGalleryCaption(
            originalDate: 1_700_000_000,
            hash: "abc",
            mediaSearchUniqId: "uniq-1",
            durationMs: 5_000,
            labels: ["cat"],
            faceIds: [],
            albumId: "A1",
            location: (37.0, -122.0)
        )
        XCTAssertTrue(caption.contains("-u-t-s-"))
        XCTAssertTrue(caption.contains("-e-n-d-"))
        XCTAssertTrue(caption.contains("uniq-1"))
        XCTAssertTrue(caption.contains("-dr-5000-drn-"))
        XCTAssertTrue(caption.contains("--lbl--"))
        XCTAssertTrue(caption.contains("--latlng[37.0,-122.0]--"))
    }
}
