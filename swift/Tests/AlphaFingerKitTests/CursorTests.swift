import XCTest
@testable import AlphaFingerKit

/// The fetch position decides whether a recording is fetched twice or not at all,
/// so it is worth testing that it survives, that it never moves backwards, and
/// above all that it is never applied to the wrong ring.
final class CursorTests: XCTestCase {
  private var suiteName = ""
  private var defaults: UserDefaults!

  private let ringA = UUID(uuidString: "83FA7F67-2ADD-C9AA-75B8-A6493CEE1ABD")!
  private let ringB = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

  override func setUpWithError() throws {
    suiteName = "alphafinger-cursor-\(UUID().uuidString)"
    defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
  }

  override func tearDownWithError() throws {
    defaults.removePersistentDomain(forName: suiteName)
  }

  private func cursor() -> DefaultsCollectionCursor {
    DefaultsCollectionCursor(defaults: defaults)
  }

  // MARK: - Keeping a position

  func testAFreshStoreHasNoPosition() {
    let subject = cursor()
    XCTAssertNil(subject.lastCompletedIndex)
    XCTAssertFalse(subject.hasSeen(0), "nothing has been seen, including index 0")
  }

  /// The whole point of moving this out of a file next to the logs: it has to
  /// outlive the object that wrote it.
  func testAPositionSurvivesIntoANewInstance() throws {
    try cursor().adopt(ring: ringA)
    try cursor().markCompleted(throughIndex: 453)
    XCTAssertEqual(cursor().lastCompletedIndex, 453)
    XCTAssertTrue(cursor().hasSeen(453))
    XCTAssertFalse(cursor().hasSeen(454))
  }

  func testItNeverMovesBackwards() throws {
    let subject = cursor()
    try subject.markCompleted(throughIndex: 453)
    try subject.markCompleted(throughIndex: 12)
    XCTAssertEqual(subject.lastCompletedIndex, 453)
  }

  func testInvalidateForgetsThePositionAndItsRing() throws {
    let subject = cursor()
    try subject.adopt(ring: ringA)
    try subject.markCompleted(throughIndex: 453)
    try subject.invalidate(reason: "the ring reset its numbering")
    XCTAssertNil(cursor().lastCompletedIndex)
    // The ring is forgotten too, so the next one adopted is treated as the first
    // rather than as a different one.
    XCTAssertEqual(try cursor().adopt(ring: ringB), .firstRing)
  }

  // MARK: - Which ring it belongs to

  func testAdoptingTheFirstRingRemembersIt() throws {
    XCTAssertEqual(try cursor().adopt(ring: ringA), .firstRing)
    XCTAssertEqual(try cursor().adopt(ring: ringA), .resumed(fromIndex: nil))
  }

  func testTheSameRingResumes() throws {
    try cursor().adopt(ring: ringA)
    try cursor().markCompleted(throughIndex: 453)
    XCTAssertEqual(try cursor().adopt(ring: ringA), .resumed(fromIndex: 453))
    XCTAssertEqual(cursor().lastCompletedIndex, 453, "unchanged by adopting")
  }

  /// The failure this exists to prevent: another ring's index 453 would make every
  /// one of this ring's first 453 collections read as already handled, and the
  /// client would fetch nothing and say nothing.
  func testADifferentRingStartsFromTheBeginning() throws {
    try cursor().adopt(ring: ringA)
    try cursor().markCompleted(throughIndex: 453)

    XCTAssertEqual(try cursor().adopt(ring: ringB), .differentRing(previous: ringA))
    XCTAssertNil(cursor().lastCompletedIndex)
    XCTAssertFalse(cursor().hasSeen(1), "ring B's first collections are unseen")
    // And it is ring B's position from now on.
    XCTAssertEqual(try cursor().adopt(ring: ringB), .resumed(fromIndex: nil))
  }

  /// A position with no ring beside it cannot be attributed, so it goes.
  func testAnIndexWithNoRingIsDiscardedOnAdoption() throws {
    defaults.set(453, forKey: "cursorIndex")
    XCTAssertEqual(try cursor().adopt(ring: ringA), .firstRing)
    XCTAssertNil(cursor().lastCompletedIndex)
  }

  // MARK: - Carrying the old file across

  func testSeedTakesAPositionOnlyWhenThereIsNoneAlready() throws {
    XCTAssertTrue(cursor().seed(index: 453, ring: ringA))
    XCTAssertEqual(cursor().lastCompletedIndex, 453)
    XCTAssertEqual(try cursor().adopt(ring: ringA), .resumed(fromIndex: 453),
                   "seeding attributes it to the ring, so that ring resumes")

    XCTAssertFalse(cursor().seed(index: 9, ring: ringA),
                   "an existing position is authoritative")
    XCTAssertEqual(cursor().lastCompletedIndex, 453)
  }

  // MARK: - The in-memory cursor follows the same rule

  func testTheInMemoryCursorAdoptsTheSameWay() throws {
    let subject = InMemoryCollectionCursor()
    XCTAssertEqual(try subject.adopt(ring: ringA), .firstRing)
    try subject.markCompleted(throughIndex: 20)
    XCTAssertEqual(try subject.adopt(ring: ringA), .resumed(fromIndex: 20))
    XCTAssertEqual(try subject.adopt(ring: ringB), .differentRing(previous: ringA))
    XCTAssertNil(subject.lastCompletedIndex)
  }
}
