import Foundation

public extension Game {
    static let ballparkProjectRef = "demoprojectrefsample"

    /// Local catalogue entry for the private Ballpark analytics source.
    static let ballpark = Game(
        id: "ballpark",
        slug: "ballpark",
        name: "Ballpark",
        icon: "B",
        description: "Un jeu d’estimation numérique en trois questions, avec Daily et groupes privés.",
        status: "active",
        platforms: ["ios", "android"],
        currentVersion: "0.1.1",
        integrations: .init(
            bundleId: "com.example.ballpark",
            googlePackageName: "com.example.ballpark",
            supabaseProjectRef: ballparkProjectRef,
            analyticsSource: "ballpark"
        )
    )

    static func addingPersonalSources(to catalog: [Game]) -> [Game] {
        guard !catalog.contains(where: { $0.id == ballpark.id || $0.integrations.analyticsSource == "ballpark" }) else { return catalog }
        return catalog + [ballpark]
    }
}
