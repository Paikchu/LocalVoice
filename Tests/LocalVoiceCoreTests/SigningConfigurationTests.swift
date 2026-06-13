import Foundation
import Testing

@Test func developmentBuildsUseStableSigningIdentity() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let project = try String(
        contentsOf: root.appendingPathComponent("project.yml"),
        encoding: .utf8
    )
    let buildScript = try String(
        contentsOf: root.appendingPathComponent("scripts/build-app.sh"),
        encoding: .utf8
    )

    #expect(project.contains("DEVELOPMENT_TEAM: FB4M276Q93"))
    #expect(project.contains("CODE_SIGN_IDENTITY: Apple Development"))
    #expect(
        buildScript.contains(
            "SIGNING_IDENTITY=98F70D2FBDB5468291D95F9A2ED8CE3AC1F770DB"
        )
    )
    #expect(!buildScript.contains("--sign -"))
}
