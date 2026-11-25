import XCTest
@testable import CbarDuo

final class TurkishLocalizationTests: XCTestCase {
    private func strings(_ language: String) throws -> [String: String] {
        let url = try XCTUnwrap(Bundle(for: AppDelegate.self).url(forResource: "Localizable", withExtension: "strings",
                                                                  subdirectory: nil, localization: language))
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
    }

    func testEveryEnglishStringHasATurkishTranslation() throws {
        let english = try strings("en"), turkish = try strings("tr")
        let missing = english.keys.filter { (turkish[$0] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        XCTAssertEqual(missing.sorted(), [])
    }

    func testFormatPlaceholdersMatchEnglish() throws {
        let turkish = try strings("tr")
        let pattern = try NSRegularExpression(pattern: "%(?:\\d+\\$)?[@dfs]")
        func placeholders(_ s: String) -> [String] {
            pattern.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { (s as NSString).substring(with: $0.range) }.sorted()
        }
        for (key, value) in turkish {
            XCTAssertEqual(placeholders(key), placeholders(value), "placeholders differ for \(key)")
        }
    }

    func testTurkishPercentPutsTheSignFirst() throws {
        let bundle = try XCTUnwrap(Bundle(for: AppDelegate.self).path(forResource: "tr", ofType: "lproj").flatMap(Bundle.init(path:)))
        XCTAssertEqual(String(format: NSLocalizedString("%d%%", bundle: bundle, comment: ""), 50), "%50")
        XCTAssertEqual(AppLanguage.turkish.displayName, "Türkçe")
        XCTAssertNotNil(AppLanguage.turkish.bundle)
    }
}
