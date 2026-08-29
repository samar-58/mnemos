import Foundation
import XCTest
@testable import Mnemos

final class CapturePrivacyTests: XCTestCase {
    private var savedLiterals: [String]?
    private var savedRegexes: [String]?

    override func setUp() {
        super.setUp()
        savedLiterals = UserDefaults.standard.stringArray(forKey: CapturePrivacy.customLiteralDefaultsKey)
        savedRegexes = UserDefaults.standard.stringArray(forKey: CapturePrivacy.customRegexDefaultsKey)
        UserDefaults.standard.removeObject(forKey: CapturePrivacy.customLiteralDefaultsKey)
        UserDefaults.standard.removeObject(forKey: CapturePrivacy.customRegexDefaultsKey)
    }

    override func tearDown() {
        if let savedLiterals {
            UserDefaults.standard.set(savedLiterals, forKey: CapturePrivacy.customLiteralDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: CapturePrivacy.customLiteralDefaultsKey)
        }
        if let savedRegexes {
            UserDefaults.standard.set(savedRegexes, forKey: CapturePrivacy.customRegexDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: CapturePrivacy.customRegexDefaultsKey)
        }
        super.tearDown()
    }

    func testBuiltInSecretsAreRedacted() {
        let input = "Authorization: Bearer abc.def.ghi api_key=supersecret ghp_1234567890abcdefghijkl"
        let output = CapturePrivacy.sanitize(input, maximumLength: 1_000)
        XCTAssertNotNil(output)
        XCTAssertFalse(output?.contains("supersecret") == true)
        XCTAssertFalse(output?.contains("ghp_1234567890abcdefghijkl") == true)
        XCTAssertFalse(output?.contains("abc.def.ghi") == true)
    }

    /// Secret keywords usually appear inside a longer identifier, which is how
    /// every shell export writes them. These all leaked while the pattern
    /// required a word boundary immediately before the keyword.
    func testSecretsInsideLongerIdentifiersAreRedacted() {
        let cases = [
            "AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY",
            "GITHUB_TOKEN=ghs_shortvalue",
            "DB_PASSWORD=hunter2",
            "MY_SECRET=x",
            "service.api-key: abc123",
        ]
        for input in cases {
            let output = CapturePrivacy.sanitize(input, maximumLength: 1_000)
            XCTAssertNotNil(output)
            XCTAssertTrue(
                output?.contains("[REDACTED]") == true,
                "Expected a redaction in \(input), got \(output ?? "nil")"
            )
        }

        let value = CapturePrivacy.sanitize(
            "export AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY", maximumLength: 1_000
        )
        XCTAssertFalse(value?.contains("wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY") == true)
        // The name is kept so the context stays readable.
        XCTAssertTrue(value?.contains("AWS_SECRET_ACCESS_KEY") == true)
    }

    func testOrdinaryTextIsNotOverRedacted() {
        let output = CapturePrivacy.sanitize(
            "git commit -m ship and review the design doc", maximumLength: 1_000
        )
        XCTAssertEqual(output, "git commit -m ship and review the design doc")
    }

    func testBrowserURLStripsCredentialsQueryAndFragment() {
        let value = CapturePrivacy.sanitizedBrowserURL("https://person:secret@example.com/path?token=abc#private")
        XCTAssertEqual(value?.absoluteString, "https://example.com/path")
    }

    func testPrivateAndSecureSourcesAreRecognized() {
        XCTAssertTrue(CapturePrivacy.isPrivateBrowserWindow("Private Browsing"))
        XCTAssertTrue(CapturePrivacy.isSecureElement(role: "AXTextField", subrole: nil, title: "CVV", description: "credit card security code", identifier: nil))
    }

    func testCustomRuleValidationRejectsDangerousRegexFeatures() {
        XCTAssertNotNil(CapturePrivacy.validateCustomRegex("(secret)+"))
        XCTAssertNotNil(CapturePrivacy.validateCustomRegex("(?<=token)abc"))
        XCTAssertNotNil(CapturePrivacy.validateCustomRegex(#"(a)\1"#))
        XCTAssertNotNil(CapturePrivacy.validateCustomRegex("secret-{1,}"))
        XCTAssertNil(CapturePrivacy.validateCustomRegex("secret-[0-9]{1,8}"))
    }

    func testCustomLiteralAndRegexAreApplied() {
        UserDefaults.standard.set(["AcmeSecret"], forKey: CapturePrivacy.customLiteralDefaultsKey)
        UserDefaults.standard.set(["ticket-[0-9]{1,8}"], forKey: CapturePrivacy.customRegexDefaultsKey)
        let output = CapturePrivacy.sanitize("AcmeSecret ticket-1234", maximumLength: 1_000)
        XCTAssertEqual(output, "[REDACTED CUSTOM] [REDACTED CUSTOM]")
    }
}

final class SemanticVectorTests: XCTestCase {
    func testDynamicVectorWidthsDecodeExactly() {
        for values: [Float] in [[1, 2, 3], [1, 2, 3, 4, 5, 6, 7]] {
            let data = values.withUnsafeBytes { Data($0) }
            XCTAssertEqual(AppleSentenceEmbeddingProvider.decode(data, dimension: values.count), values)
            XCTAssertNil(AppleSentenceEmbeddingProvider.decode(data, dimension: values.count + 1))
        }
    }

    func testCosineRequiresCompatibleWidths() {
        XCTAssertEqual(AppleSentenceEmbeddingProvider.cosine([1, 0], [1, 0]), 1)
        XCTAssertNil(AppleSentenceEmbeddingProvider.cosine([1], [1, 0]))
    }
}
