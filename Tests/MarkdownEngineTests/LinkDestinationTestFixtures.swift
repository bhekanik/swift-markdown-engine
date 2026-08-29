enum LinkDestinationTestFixtures {
    private static let asciiControls = ["\u{0000}", "\u{000B}", "\u{007F}"]
    private static let backslashPrefixes = ["", "\\", "\\\\"]

    static let invalidBareControlLinks = cases { target in
        "[x](\(target))"
    }

    static let invalidBareControlImages = cases { target in
        "![x](\(target))"
    }

    static let invalidBareControlReferences = cases { target in
        "[id]: \(target)\n\n[x][id]"
    }

    static let invalidBareControlDocuments =
        invalidBareControlLinks
        + invalidBareControlImages
        + invalidBareControlReferences

    private static func cases(wrapping target: (String) -> String) -> [String] {
        asciiControls.flatMap { control in
            backslashPrefixes.map { prefix in
                target("https://example.com/a\(prefix)\(control)b")
            }
        }
    }
}
