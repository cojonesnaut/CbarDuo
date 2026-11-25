import XCTest
@testable import CbarDuo

final class FrenchLocalizationTests: XCTestCase {
    private func strings(_ language: String) throws -> [String: String] {
        let url = try XCTUnwrap(Bundle(for: AppDelegate.self).url(forResource: "Localizable", withExtension: "strings",
                                                                  subdirectory: nil, localization: language))
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
    }

    func testEveryEnglishStringHasAFrenchTranslation() throws {
        let english = try strings("en"), french = try strings("fr")
        let missing = english.keys.filter { (french[$0] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        XCTAssertEqual(missing.sorted(), [])
    }

    func testFormatPlaceholdersMatchEnglish() throws {
        let pattern = try NSRegularExpression(pattern: "%(?:\\d+\\$)?[@dfs]")
        func placeholders(_ s: String) -> [String] {
            pattern.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { (s as NSString).substring(with: $0.range) }.sorted()
        }
        for (key, value) in try strings("fr") {
            XCTAssertEqual(placeholders(key), placeholders(value), "placeholders differ for \(key)")
        }
    }

    func testFrenchIsSelectable() {
        XCTAssertEqual(AppLanguage.french.displayName, "Français")
        XCTAssertNotNil(AppLanguage.french.bundle)
    }
}
