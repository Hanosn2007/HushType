#!/usr/bin/env swift
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import CryptoKit

// Verify the exact archive against the public key embedded in the OLD app.
// Usage: swift scripts/verify_update.swift appcast.xml archive.zip old/Info.plist
final class Feed: NSObject, XMLParserDelegate {
    var values: [String: String] = [:]
    var enclosure: [String: String] = [:]
    var element = ""
    var itemCount = 0
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        element = name
        if name == "item" { itemCount += 1 }
        if name == "enclosure" { enclosure = attributes }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        values[element, default: ""] += string
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { element = "" }
}
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw NSError(domain: "UpdateVerification", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
do {
    try require(CommandLine.arguments.count == 4, "Expected appcast.xml archive.zip old/Info.plist")
    let args = CommandLine.arguments
    let feed = Feed()
    let parser = XMLParser(data: try Data(contentsOf: URL(fileURLWithPath: args[1])))
    parser.delegate = feed
    try require(parser.parse(), "Malformed appcast")
    try require(feed.itemCount == 1, "Expected exactly one release item")
    let archive = try Data(contentsOf: URL(fileURLWithPath: args[2]))
    let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: args[3])), format: nil) as! [String: Any]
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: plist["SUPublicEDKey"] as? String ?? "") ?? Data())
    let signature = Data(base64Encoded: feed.enclosure["sparkle:edSignature"] ?? "") ?? Data()
    try require(publicKey.isValidSignature(signature, for: archive), "EdDSA signature does not match installed app's public key")
    try require(Int(feed.enclosure["length"] ?? "") == archive.count, "Archive length mismatch")
    let version = feed.values["sparkle:version", default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
    let oldVersion = Int(plist["CFBundleVersion"] as? String ?? "") ?? -1
    try require((Int(version) ?? -1) > oldVersion, "Update build must be newer than installed build")
    let shortVersion = feed.values["sparkle:shortVersionString", default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
    let expectedURL = "https://github.com/Hanosn2007/HushType/releases/download/v\(shortVersion)/HushType-\(shortVersion).zip"
    try require(feed.enclosure["url"] == expectedURL, "Unexpected download URL")
    try require(feed.values["sparkle:minimumSystemVersion"]?.trimmingCharacters(in: .whitespacesAndNewlines) == "15.0", "Unexpected minimum macOS")
    let sha = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
    print("Verified build \(oldVersion) → \(version), EdDSA, length, URL, minimum macOS; SHA-256 \(sha)")
} catch {
    fputs("Update verification failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
