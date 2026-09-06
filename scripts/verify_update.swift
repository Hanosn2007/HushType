#!/usr/bin/env swift
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import CryptoKit

// Verify the exact archive against the public key embedded in the OLD app.
// Usage: swift scripts/verify_update.swift appcast.xml archive.zip old/Info.plist
final class Feed: NSObject, XMLParserDelegate {
    struct Item {
        var values: [String: String] = [:]
        var enclosure: [String: String] = [:]
    }
    var items: [Item] = []
    private var currentItem: Item?
    var element = ""
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        element = name
        if name == "item" { currentItem = Item() }
        if name == "enclosure" { currentItem?.enclosure = attributes }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentItem?.values[element, default: ""] += string
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "item", let currentItem {
            items.append(currentItem)
            self.currentItem = nil
        }
        element = ""
    }
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
    let archive = try Data(contentsOf: URL(fileURLWithPath: args[2]))
    let archiveName = URL(fileURLWithPath: args[2]).deletingPathExtension().lastPathComponent
    try require(archiveName.hasPrefix("HushType-"), "Archive must be named HushType-<version>.zip")
    let targetShortVersion = String(archiveName.dropFirst("HushType-".count))
    let matchingItems = feed.items.filter {
        $0.values["sparkle:shortVersionString", default: ""].trimmingCharacters(in: .whitespacesAndNewlines) == targetShortVersion
    }
    try require(matchingItems.count == 1, "Expected exactly one matching release item")
    let item = matchingItems[0]
    let allBuilds = feed.items.map {
        $0.values["sparkle:version", default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
    }
    try require(Set(allBuilds).count == allBuilds.count, "Appcast contains duplicate build numbers")
    let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: args[3])), format: nil) as! [String: Any]
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: plist["SUPublicEDKey"] as? String ?? "") ?? Data())
    let signature = Data(base64Encoded: item.enclosure["sparkle:edSignature"] ?? "") ?? Data()
    try require(publicKey.isValidSignature(signature, for: archive), "EdDSA signature does not match installed app's public key")
    try require(Int(item.enclosure["length"] ?? "") == archive.count, "Archive length mismatch")
    let version = item.values["sparkle:version", default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
    let oldVersion = Int(plist["CFBundleVersion"] as? String ?? "") ?? -1
    try require((Int(version) ?? -1) > oldVersion, "Update build must be newer than installed build")
    let shortVersion = item.values["sparkle:shortVersionString", default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
    let expectedURL = "https://github.com/Hanosn2007/HushType/releases/download/v\(shortVersion)/HushType-\(shortVersion).zip"
    try require(item.enclosure["url"] == expectedURL, "Unexpected download URL")
    try require(item.values["sparkle:minimumSystemVersion"]?.trimmingCharacters(in: .whitespacesAndNewlines) == "15.0", "Unexpected minimum macOS")
    let channel = item.values["sparkle:channel", default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
    try require(channel == (shortVersion.contains("-preview.") ? "preview" : ""), "Unexpected update channel")
    let sha = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
    print("Verified build \(oldVersion) → \(version), EdDSA, length, URL, minimum macOS; SHA-256 \(sha)")
} catch {
    fputs("Update verification failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
