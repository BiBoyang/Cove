import Testing
@testable import Cove

// TEMPORARY CI failure drill: verifies the workflow actually goes red on
// a failing assertion. Reverted immediately after the red run is observed.
// Do not merge.
@Test func ciFailureDrill() {
    #expect(1 == 2, "intentional failure for the CI red-path drill")
}
