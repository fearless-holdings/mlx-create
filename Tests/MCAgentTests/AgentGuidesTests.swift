import Foundation
import Testing

@testable import MCAgent

@Suite("AgentGuides")
struct AgentGuidesTests {
    @Test func shippedFamiliesAndRolesResolve() {
        let guides = AgentGuides.bundled()
        for id in ["qwen-image-2.1-turbo", "krea-2-turbo", "flux2-klein"] {
            let guide = guides.familyGuide(id)
            #expect(guide != nil)
            #expect(guide?.isEmpty == false)
        }
        for role in ["realism", "explicit", "body"] {
            #expect(guides.loraRole(role)?.isEmpty == false)
        }
        #expect(guides.familyGuide("no-such-family") == nil)
        #expect(guides.loraRole("no-such-role") == nil)
    }
}
