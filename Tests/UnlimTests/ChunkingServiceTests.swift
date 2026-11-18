import XCTest
@testable import Unlim

/// Chunking tests. The 2 GB boundary is exercised with sparse files
/// (truncate, no real bytes written) — splitting a real 2 GB file is
/// deliberately not tested here.
final class ChunkingServiceTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: tempDir)
    }

    func testNeedsChunkingBoundary() throws {
        // Exactly chunk size → split (Android uses >=).
        let exact = try sparseFile(named: "exact.bin", size: ChunkingService.sizeOfChunk)
        XCTAssertTrue(ChunkingService.needsChunking(path: exact.path))
        // One byte under → send whole.
        let under = try sparseFile(named: "under.bin", size: ChunkingService.sizeOfChunk - 1)
        XCTAssertFalse(ChunkingService.needsChunking(path: under.path))
    }

    func testSmallFileSplitAndJoinRoundTrip() throws {
        let data = Data((0..<20_000).map { UInt8($0 % 251) })
        let source = tempDir.appendingPathComponent("small.bin")
        try data.write(to: source)

        let output = tempDir.appendingPathComponent("chunks", isDirectory: true)
        let chunks = try ChunkingService.splitFile(at: source, to: output)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].lastPathComponent, "small.bin")

        let joined = try ChunkingService.joinChunks(chunks, to: tempDir.appendingPathComponent("joined.bin"))
        XCTAssertEqual(try Data(contentsOf: joined), data)
    }

    func testJoinChunksOrdersByName() throws {
        let first = tempDir.appendingPathComponent("0big.zip")
        let second = tempDir.appendingPathComponent("1big.zip")
        try Data("AAAA".utf8).write(to: first)
        try Data("BBBB".utf8).write(to: second)

        // Pass them in reverse order on purpose; join must sort by name.
        let joined = try ChunkingService.joinChunks([second, first], to: tempDir.appendingPathComponent("big.zip"))
        XCTAssertEqual(try Data(contentsOf: joined), Data("AAAABBBB".utf8))
    }

    private func sparseFile(named name: String, size: UInt64) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: size)
        try handle.close()
        return url
    }
}
