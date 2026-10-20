import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import InkModel
import XCTest
@testable import InkProviders

final class ClientConfigParsingTests: XCTestCase {
    private func parse(_ xml: String, _ email: String) -> DiscoveryResult? {
        Autodiscovery.parseClientConfig(Data(xml.utf8), email: email)
    }

    func testGmailISPDB() throws {
        let result = try XCTUnwrap(parse(ClientConfigFixtures.gmail, "ada@gmail.com"))
        XCTAssertEqual(result.imap, ServerConfig(host: "imap.gmail.com", port: 993, security: .tls, username: "ada@gmail.com"))
        XCTAssertEqual(result.smtp, ServerConfig(host: "smtp.gmail.com", port: 465, security: .tls, username: "ada@gmail.com"))
        XCTAssertEqual(result.preset, .gmail)
        XCTAssertEqual(result.providerName, "Google Mail")
        XCTAssertEqual(result.source, "clientConfig")
        XCTAssertFalse(result.isGuess)
    }

    func testPrefersImplicitTLSOverSTARTTLSRegardlessOfOrder() throws {
        let result = try XCTUnwrap(parse(ClientConfigFixtures.gmx, "max.mustermann@gmx.de"))
        XCTAssertEqual(result.imap, ServerConfig(host: "imap.gmx.net", port: 993, security: .tls, username: "max.mustermann@gmx.de"))
        XCTAssertEqual(result.smtp, ServerConfig(host: "mail.gmx.net", port: 465, security: .tls, username: "max.mustermann@gmx.de"))
        XCTAssertNil(result.preset)
        XCTAssertEqual(result.providerName, "GMX Freemail")
    }

    func testDomainSubstitutionInHostnames() throws {
        let result = try XCTUnwrap(parse(ClientConfigFixtures.cpanel, "Office@Bakery-Example.co.uk"))
        XCTAssertEqual(result.imap.host, "mail.bakery-example.co.uk")
        XCTAssertEqual(result.smtp.host, "mail.bakery-example.co.uk")
        XCTAssertEqual(result.imap.username, "Office@bakery-example.co.uk")
        XCTAssertEqual(result.imap.port, 993)
        XCTAssertEqual(result.smtp.security, .tls)
    }

    func testLocalPartUsernameAndSTARTTLSOnly() throws {
        let result = try XCTUnwrap(parse(ClientConfigFixtures.comcast, "jsmith@comcast.net"))
        XCTAssertEqual(result.imap.username, "jsmith")
        XCTAssertEqual(result.smtp, ServerConfig(host: "smtp.comcast.net", port: 587, security: .startTLS, username: "jsmith"))
    }

    func testPlainTextServersAreIgnored() {
        XCTAssertNil(parse(ClientConfigFixtures.plainOnly, "a@oldisp.example"))
    }

    func testSkipsOtherProtocolsAndUnusableAuth() throws {
        let result = try XCTUnwrap(parse(ClientConfigFixtures.mixedProtocols, "pat@corp.example"))
        XCTAssertEqual(result.imap.host, "imap2.corp.example")
        XCTAssertEqual(result.smtp, ServerConfig(host: "smtp.corp.example", port: 587, security: .startTLS, username: "pat@corp.example"))
        XCTAssertEqual(result.providerName, "Corp Mail")
    }

    func testUsesServerWithUnusableAuthWhenItIsTheOnlyOne() throws {
        let xml = """
        <clientConfig version="1.1"><emailProvider id="x.example">
          <incomingServer type="imap"><hostname>imap.x.example</hostname><port>993</port><socketType>SSL</socketType>
            <username>%EMAILLOCALPART%@x.example</username><authentication>NTLM</authentication></incomingServer>
          <outgoingServer type="smtp"><hostname>smtp.x.example</hostname><socketType>SSL</socketType></outgoingServer>
        </emailProvider></clientConfig>
        """
        let result = try XCTUnwrap(parse(xml, "lee@x.example"))
        XCTAssertEqual(result.imap.host, "imap.x.example")
        XCTAssertEqual(result.imap.username, "lee@x.example")
        // Missing port: the default for the security.
        XCTAssertEqual(result.smtp.port, 465)
    }

    func testOnlyFirstProviderCounts() throws {
        let result = try XCTUnwrap(parse(ClientConfigFixtures.twoProviders, "a@first.example"))
        XCTAssertEqual(result.imap.host, "imap.first.example")
        XCTAssertEqual(result.providerName, "First")
        // No <username>: the full address.
        XCTAssertEqual(result.smtp.username, "a@first.example")
    }

    func testRejectsBadDocuments() {
        let bad = [
            "",
            "not xml at all",
            "<html><head><title>404 Not Found</title></head><body><h1>Not Found</h1></body></html>",
            "<clientConfig><emailProvider id='x'><incomingServer type='imap'><hostname>imap.x.example</hostname>",   // truncated
            "<clientConfig version=\"1.1\"><emailProvider id=\"x\"></emailProvider></clientConfig>",                  // no servers
            // IMAP but no SMTP.
            "<clientConfig><emailProvider><incomingServer type=\"imap\"><hostname>imap.x.example</hostname><port>993</port><socketType>SSL</socketType></incomingServer></emailProvider></clientConfig>",
            // clientConfig not at the root.
            "<wrapper><clientConfig><emailProvider><incomingServer type=\"imap\"><hostname>i.x.example</hostname><socketType>SSL</socketType><port>993</port></incomingServer><outgoingServer type=\"smtp\"><hostname>s.x.example</hostname><socketType>SSL</socketType><port>465</port></outgoingServer></emailProvider></clientConfig></wrapper>",
        ]
        for xml in bad { XCTAssertNil(parse(xml, "a@x.example"), xml) }
        XCTAssertNil(parse(ClientConfigFixtures.gmail, "not-an-address"))
    }

    func testRejectsHostileHostnamesAndPorts() {
        func config(host: String, port: String) -> String {
            """
            <clientConfig><emailProvider>
              <incomingServer type="imap"><hostname>\(host)</hostname><port>\(port)</port><socketType>SSL</socketType></incomingServer>
              <outgoingServer type="smtp"><hostname>smtp.x.example</hostname><port>465</port><socketType>SSL</socketType></outgoingServer>
            </emailProvider></clientConfig>
            """
        }
        XCTAssertNil(parse(config(host: "evil.example/path", port: "993"), "a@x.example"))
        XCTAssertNil(parse(config(host: "imap.x.example", port: "99999"), "a@x.example"))
        XCTAssertNil(parse(config(host: "imap.x.example", port: "0"), "a@x.example"))
        XCTAssertNil(parse(config(host: "%UNKNOWN%.x.example", port: "993"), "a@x.example"))
        XCTAssertNil(parse(config(host: "localhost", port: "993"), "a@x.example"))
        XCTAssertNotNil(parse(config(host: "  imap.x.example  ", port: " 993 "), "a@x.example"))
    }

    func testEntitiesCDATAAndExternalEntitiesAreSafe() throws {
        let xml = """
        <?xml version="1.0"?>
        <!DOCTYPE clientConfig [ <!ENTITY ext SYSTEM "file:///etc/passwd"> ]>
        <clientConfig version="1.1"><emailProvider id="x">
          <displayName>Caf&#233; &amp; Co &ext;</displayName>
          <incomingServer type="imap"><hostname><![CDATA[imap.x.example]]></hostname><port>993</port><socketType>SSL</socketType></incomingServer>
          <outgoingServer type="smtp"><hostname>smtp.x.example</hostname><port>465</port><socketType>SSL</socketType></outgoingServer>
        </emailProvider></clientConfig>
        """
        if let result = parse(xml, "a@x.example") {
            XCTAssertEqual(result.imap.host, "imap.x.example")
            XCTAssertFalse(result.providerName?.contains("root:") ?? false)
        }
    }

    func testSecurityMapping() {
        XCTAssertEqual(Autodiscovery.security(socketType: "SSL", port: 993), .tls)
        XCTAssertEqual(Autodiscovery.security(socketType: "ssl", port: nil), .tls)
        XCTAssertEqual(Autodiscovery.security(socketType: "STARTTLS", port: 587), .startTLS)
        XCTAssertEqual(Autodiscovery.security(socketType: "TLS", port: 465), .tls)
        XCTAssertEqual(Autodiscovery.security(socketType: "TLS", port: 143), .startTLS)
        XCTAssertNil(Autodiscovery.security(socketType: "plain", port: 143))
        XCTAssertNil(Autodiscovery.security(socketType: "weird", port: 993))
        XCTAssertEqual(Autodiscovery.security(socketType: nil, port: 993), .tls)
        XCTAssertNil(Autodiscovery.security(socketType: nil, port: 143))
    }
}

final class MXAndGuessTests: XCTestCase {
    func testGoogleDoHAnswer() {
        let json = """
        {"Status":0,"TC":false,"RD":true,"RA":true,"AD":false,"CD":false,
         "Question":[{"name":"bakery.example.","type":15}],
         "Answer":[
           {"name":"bakery.example.","type":15,"TTL":3600,"data":"10 alt3.aspmx.l.google.com."},
           {"name":"bakery.example.","type":15,"TTL":3600,"data":"1 aspmx.l.google.com."},
           {"name":"bakery.example.","type":15,"TTL":3600,"data":"5 alt1.aspmx.l.google.com."},
           {"name":"bakery.example.","type":15,"TTL":3600,"data":"5 ALT2.ASPMX.L.GOOGLE.COM."}
         ],
         "Comment":"Response from 216.239.32.10."}
        """
        XCTAssertEqual(Autodiscovery.parseMXResponse(Data(json.utf8)),
                       ["aspmx.l.google.com", "alt1.aspmx.l.google.com", "alt2.aspmx.l.google.com", "alt3.aspmx.l.google.com"])
    }

    func testCloudflareAnswerWithCNAMEAndDuplicates() {
        let json = """
        {"Status":0,"TC":false,"RD":true,"RA":true,"AD":true,"CD":false,"Question":[{"name":"shop.example","type":15}],
         "Answer":[{"name":"shop.example","type":5,"TTL":300,"data":"alias.example."},
                   {"name":"alias.example","type":15,"TTL":300,"data":"0 shop-example.mail.protection.outlook.com."},
                   {"name":"alias.example","type":15,"TTL":300,"data":"0 shop-example.mail.protection.outlook.com."}]}
        """
        XCTAssertEqual(Autodiscovery.parseMXResponse(Data(json.utf8)), ["shop-example.mail.protection.outlook.com"])
    }

    func testEmptyAndBadAnswers() {
        let nxdomain = #"{"Status":3,"TC":false,"Question":[{"name":"nope.example.","type":15}],"Authority":[{"name":"example.","type":6,"TTL":1800,"data":"a.iana-servers.net. hostmaster 1 2 3 4 5"}]}"#
        XCTAssertEqual(Autodiscovery.parseMXResponse(Data(nxdomain.utf8)), [])
        let nullMX = #"{"Status":0,"Answer":[{"name":"nomail.example.","type":15,"TTL":300,"data":"0 ."}]}"#
        XCTAssertEqual(Autodiscovery.parseMXResponse(Data(nullMX.utf8)), [])
        XCTAssertEqual(Autodiscovery.parseMXResponse(Data("garbage".utf8)), [])
        XCTAssertEqual(Autodiscovery.parseMXResponse(Data(#"{"Status":0,"Answer":[{"type":15,"data":"x"},{"type":15,"data":"ten mx.example."},{"type":15}]}"#.utf8)), [])
        XCTAssertEqual(Autodiscovery.parseMXResponse(Data(#"{"Status":0,"Answer":"oops"}"#.utf8)), [])
    }

    func testMXResultsForHostedDomains() throws {
        let workspace = try XCTUnwrap(Autodiscovery.result(forMXHosts: ["aspmx.l.google.com"], email: "owner@bakery.example"))
        XCTAssertEqual(workspace.preset, .gmail)
        XCTAssertEqual(workspace.imap, ServerConfig(host: "imap.gmail.com", port: 993, security: .tls, username: "owner@bakery.example"))
        XCTAssertEqual(workspace.source, "mx")
        XCTAssertEqual(workspace.providerName, "Google Workspace")

        let m365 = try XCTUnwrap(Autodiscovery.result(forMXHosts: ["shop-example.mail.protection.outlook.com"], email: "a@shop.example"))
        XCTAssertEqual(m365.preset, .outlook)
        XCTAssertEqual(m365.imap.host, "outlook.office365.com")
        XCTAssertEqual(m365.smtp, ServerConfig(host: "smtp.office365.com", port: 587, security: .startTLS, username: "a@shop.example"))

        let zohoEU = try XCTUnwrap(Autodiscovery.result(forMXHosts: ["mx.zoho.eu", "mx2.zoho.eu"], email: "a@firma.example"))
        XCTAssertEqual(zohoEU.preset, .zoho)
        XCTAssertEqual(zohoEU.imap.host, "imappro.zoho.eu")
        XCTAssertEqual(zohoEU.smtp.host, "smtppro.zoho.eu")

        let zohoUS = try XCTUnwrap(Autodiscovery.result(forMXHosts: ["mx.zoho.com"], email: "a@firm.example"))
        XCTAssertEqual(zohoUS.imap.host, "imappro.zoho.com")

        let fastmail = try XCTUnwrap(Autodiscovery.result(forMXHosts: ["in1-smtp.messagingengine.com"], email: "me@family.example"))
        XCTAssertEqual(fastmail.preset, .fastmail)
        XCTAssertEqual(fastmail.smtp.host, "smtp.fastmail.com")

        let icloud = try XCTUnwrap(Autodiscovery.result(forMXHosts: ["mx01.mail.icloud.com"], email: "me@custom.example"))
        XCTAssertEqual(icloud.preset, .icloud)
        XCTAssertEqual(icloud.smtp.security, .startTLS)

        XCTAssertNil(Autodiscovery.result(forMXHosts: ["mx00.ionos.de"], email: "a@b.example"))
        XCTAssertNil(Autodiscovery.result(forMXHosts: ["aspmx.l.google.com"], email: "nope"))
    }

    func testGuess() throws {
        let guess = try XCTUnwrap(Autodiscovery.guess(email: "Jo@Example.ORG"))
        XCTAssertEqual(guess.imap, ServerConfig(host: "imap.example.org", port: 993, security: .tls, username: "Jo@example.org"))
        XCTAssertEqual(guess.smtp, ServerConfig(host: "smtp.example.org", port: 465, security: .tls, username: "Jo@example.org"))
        XCTAssertTrue(guess.isGuess)
        XCTAssertNil(guess.preset)

        let idn = try XCTUnwrap(Autodiscovery.guess(email: "info@bücher.example"))
        XCTAssertEqual(idn.imap.host, "imap.xn--bcher-kva.example")
        XCTAssertEqual(idn.imap.username, "info@bücher.example")

        for bad in ["", "plain", "@example.com", "a@", "a@localhost", "a@evil.example/x", "a@ex ample.com", "a b@example.com", "a@exa?mple.com", "a@-bad.example"] {
            XCTAssertNil(Autodiscovery.guess(email: bad), bad)
        }
    }

    func testPunycode() {
        XCTAssertEqual(Punycode.encode("bücher"), "bcher-kva")
        XCTAssertEqual(Punycode.encode("münchen"), "mnchen-3ya")
        XCTAssertEqual(Punycode.encode("日本語"), "wgv71a119e")
        XCTAssertEqual(Punycode.encode("他们为什么不说中文"), "ihqwcrb4cv8a8dqg056pqjye")
        XCTAssertEqual(Punycode.encode("ñ"), "ida")
        XCTAssertEqual(Punycode.idnaDomain("Bücher.Example"), "xn--bcher-kva.example")
        XCTAssertEqual(Punycode.idnaDomain("日本語。jp"), "xn--wgv71a119e.jp")
        XCTAssertEqual(DomainName.ascii("MÜNCHEN.de."), "xn--mnchen-3ya.de")
        XCTAssertEqual(DomainName.ascii("example.com"), "example.com")
        XCTAssertNil(DomainName.ascii("example..com"))
        XCTAssertNil(DomainName.ascii(String(repeating: "a", count: 64) + ".com"))
    }

    func testBaseDomain() {
        XCTAssertEqual(DomainName.baseDomain(of: "mx00.ionos.de"), "ionos.de")
        XCTAssertEqual(DomainName.baseDomain(of: "mx1.mail.example.co.uk"), "example.co.uk")
        XCTAssertEqual(DomainName.baseDomain(of: "example.com"), "example.com")
        XCTAssertEqual(DomainName.baseDomain(of: "a.b.example.com.au"), "example.com.au")
    }

    func testLookupURLs() throws {
        let parts = try XCTUnwrap(EmailParts("first+tag@Bakery.Example"))
        let urls = Autodiscovery.lookupURLs(for: parts)
        XCTAssertEqual(urls.ispdb?.absoluteString, "https://autoconfig.thunderbird.net/v1.1/bakery.example")
        XCTAssertEqual(urls.autoconfig?.absoluteString, "https://autoconfig.bakery.example/mail/config-v1.1.xml?emailaddress=first%2Btag%40bakery.example")
        XCTAssertEqual(urls.wellKnown?.absoluteString, "https://bakery.example/.well-known/autoconfig/mail/config-v1.1.xml?emailaddress=first%2Btag%40bakery.example")
        XCTAssertEqual(urls.dnsGoogle?.absoluteString, "https://dns.google/resolve?name=bakery.example&type=MX")
    }
}

final class DiscoverTests: XCTestCase {
    private let ispdb = "https://autoconfig.thunderbird.net/v1.1/"
    private let dnsGoogle = "https://dns.google/resolve?name="
    private let dnsCloudflare = "https://cloudflare-dns.com/dns-query?name="

    func testKnownProviderNeedsNoNetwork() async throws {
        let server = MockHTTP()
        let result = try await XCTUnwrapAsync(await Autodiscovery.discover(email: "ada@gmail.com", session: server.session))
        XCTAssertEqual(result.preset, .gmail)
        XCTAssertEqual(result.source, "preset")
        XCTAssertEqual(result.imap.host, "imap.gmail.com")
        XCTAssertTrue(server.requests.isEmpty)
    }

    func testISPDBHit() async throws {
        let server = MockHTTP()
        server.route(ispdb + "gmx.de", .ok(ClientConfigFixtures.gmx))
        let result = try await XCTUnwrapAsync(await Autodiscovery.discover(email: "max@gmx.de", session: server.session))
        XCTAssertEqual(result.source, "ispdb")
        XCTAssertEqual(result.imap.host, "imap.gmx.net")
        XCTAssertEqual(result.smtp.port, 465)
    }

    func testAutoconfigWhenISPDBMisses() async throws {
        let server = MockHTTP()
        server.route("https://autoconfig.bakery.example/mail/config-v1.1.xml", .ok(ClientConfigFixtures.cpanel))
        let result = try await XCTUnwrapAsync(await Autodiscovery.discover(email: "orders@bakery.example", session: server.session))
        XCTAssertEqual(result.source, "autoconfig")
        XCTAssertEqual(result.imap.host, "mail.bakery.example")
        XCTAssertTrue(server.requestedURLs.contains("https://autoconfig.bakery.example/mail/config-v1.1.xml?emailaddress=orders%40bakery.example"))
    }

    func testWellKnown() async throws {
        let server = MockHTTP()
        server.route("https://autoconfig.bakery.example/", .failure(.cannotFindHost))
        server.route("https://bakery.example/.well-known/autoconfig/mail/config-v1.1.xml", .ok(ClientConfigFixtures.cpanel))
        let result = try await XCTUnwrapAsync(await Autodiscovery.discover(email: "orders@bakery.example", session: server.session))
        XCTAssertEqual(result.source, "well-known")
    }

    func testHTMLAtWellKnownIsIgnored() async throws {
        let server = MockHTTP()
        server.route("https://bakery.example/", .ok("<!doctype html><html><body>Welcome to our bakery!</body></html>", contentType: "text/html"))
        server.route(dnsGoogle, .json(#"{"Status":0,"Answer":[{"type":15,"data":"1 smtp.google.com."}]}"#))
        let result = try await XCTUnwrapAsync(await Autodiscovery.discover(email: "orders@bakery.example", session: server.session))
        XCTAssertEqual(result.source, "mx")
        XCTAssertEqual(result.preset, .gmail)
        XCTAssertEqual(result.imap.username, "orders@bakery.example")
    }

    func testMicrosoft365ByMX() async throws {
        let server = MockHTTP()
        server.route(dnsGoogle + "contoso.example", .json(#"{"Status":0,"Answer":[{"name":"contoso.example.","type":15,"TTL":3600,"data":"0 contoso-example.mail.protection.outlook.com."}]}"#))
        let result = try await XCTUnwrapAsync(await Autodiscovery.discover(email: "megan@contoso.example", session: server.session))
        XCTAssertEqual(result.preset, .outlook)
        XCTAssertEqual(result.smtp.host, "smtp.office365.com")
    }

    func testCloudflareFallbackWhenGoogleDNSFails() async throws {
        let server = MockHTTP()
        server.route(dnsGoogle, .status(500))
        server.route(dnsCloudflare, .json(#"{"Status":0,"Answer":[{"type":15,"data":"10 in1-smtp.messagingengine.com."}]}"#))
        let result = try await XCTUnwrapAsync(await Autodiscovery.discover(email: "me@family.example", session: server.session))
        XCTAssertEqual(result.preset, .fastmail)
        let cloudflare = try XCTUnwrap(server.requests.first { $0.url.hasPrefix(self.dnsCloudflare) })
        XCTAssertEqual(cloudflare.headers["Accept"], "application/dns-json")
    }

    func testISPDBOfMXDomain() async throws {
        let server = MockHTTP()
        server.route(dnsGoogle + "kanzlei.example", .json(#"{"Status":0,"Answer":[{"type":15,"data":"10 mx00.ionos.de."},{"type":15,"data":"10 mx01.ionos.de."}]}"#))
        let ionos = """
        <clientConfig version="1.1"><emailProvider id="ionos.de"><displayName>IONOS</displayName>
          <incomingServer type="imap"><hostname>imap.ionos.de</hostname><port>993</port><socketType>SSL</socketType><username>%EMAILADDRESS%</username><authentication>password-cleartext</authentication></incomingServer>
          <outgoingServer type="smtp"><hostname>smtp.ionos.de</hostname><port>465</port><socketType>SSL</socketType><username>%EMAILADDRESS%</username><authentication>password-cleartext</authentication></outgoingServer>
        </emailProvider></clientConfig>
        """
        server.route(ispdb + "ionos.de", .ok(ionos))
        let result = try await XCTUnwrapAsync(await Autodiscovery.discover(email: "info@kanzlei.example", session: server.session))
        XCTAssertEqual(result.source, "ispdb-mx")
        XCTAssertEqual(result.imap, ServerConfig(host: "imap.ionos.de", port: 993, security: .tls, username: "info@kanzlei.example"))
    }

    func testFallsBackToGuess() async throws {
        let server = MockHTTP()
        server.route(dnsGoogle, .json(#"{"Status":3}"#))
        let result = try await XCTUnwrapAsync(await Autodiscovery.discover(email: "x@quiet.example", session: server.session))
        XCTAssertEqual(result.source, "guess")
        XCTAssertEqual(result.imap.host, "imap.quiet.example")
        // NXDOMAIN from the first resolver is final.
        XCTAssertFalse(server.requestedURLs.contains { $0.hasPrefix(self.dnsCloudflare) })
    }

    func testEverythingOfflineStillGuesses() async throws {
        let server = MockHTTP()
        server.route("https://", .failure(.notConnectedToInternet))
        let result = try await XCTUnwrapAsync(await Autodiscovery.discover(email: "x@quiet.example", session: server.session))
        XCTAssertEqual(result.source, "guess")
    }

    func testInvalidAddresses() async {
        let server = MockHTTP()
        for email in ["", "nobody", "a@evil.example/../x", "a@", "a@b"] {
            let result = await Autodiscovery.discover(email: email, session: server.session)
            XCTAssertNil(result, email)
        }
        XCTAssertTrue(server.requests.isEmpty)
    }
}

/// `XCTUnwrap` for an already-awaited optional, so async tests read naturally.
func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
