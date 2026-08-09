import XCTest
@testable import PUnderclass

final class DocumentationDemoTests: XCTestCase {
    func testParsesEachDocumentationDemoMode() {
        for mode in DocumentationDemoMode.allCases {
            XCTAssertEqual(
                DocumentationDemoMode.requested(
                    in: ["punderclass", "--documentation-demo=\(mode.rawValue)"]
                ),
                mode
            )
        }
    }

    func testIgnoresMissingAndUnknownDocumentationDemoArguments() {
        XCTAssertNil(DocumentationDemoMode.requested(in: ["punderclass"]))
        XCTAssertNil(
            DocumentationDemoMode.requested(
                in: ["punderclass", "--documentation-demo=unknown"]
            )
        )
    }

    func testDocumentationDemoKeepsASyntheticCompanionAddress() {
        let controller = MeetingController.documentationDemo(.meeting)

        XCTAssertEqual(
            controller.companionGatewayEndpoint?.preferredLANURL?.absoluteString,
            "http://192.168.1.42:\(CompanionGateway.preferredPort)"
        )

        controller.refreshCompanionGatewayEndpoint()

        XCTAssertEqual(
            controller.companionGatewayEndpoint?.preferredLANURL?.absoluteString,
            "http://192.168.1.42:\(CompanionGateway.preferredPort)"
        )
    }
}
