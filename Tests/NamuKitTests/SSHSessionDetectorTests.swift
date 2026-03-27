import XCTest
@testable import Namu

final class SSHSessionDetectorTests: XCTestCase {

    // MARK: - SSHConfigParser

    func testParseEmptyConfig() {
        let parser = SSHConfigParser(contents: "")
        XCTAssertTrue(parser.entries.isEmpty)
    }

    func testParseSingleHostBlock() {
        let config = """
        Host myserver
            HostName 192.168.1.100
            User admin
            Port 2222
        """
        let parser = SSHConfigParser(contents: config)
        let entry = parser.resolveConfig(hostname: "myserver")
        XCTAssertEqual(entry.hostname, "192.168.1.100")
        XCTAssertEqual(entry.user, "admin")
        XCTAssertEqual(entry.port, 2222)
    }

    func testParseMultipleHostBlocks() {
        let config = """
        Host server1
            HostName 10.0.0.1
            User root

        Host server2
            HostName 10.0.0.2
            Port 22
        """
        let parser = SSHConfigParser(contents: config)
        let e1 = parser.resolveConfig(hostname: "server1")
        let e2 = parser.resolveConfig(hostname: "server2")
        XCTAssertEqual(e1.hostname, "10.0.0.1")
        XCTAssertEqual(e2.hostname, "10.0.0.2")
        XCTAssertEqual(e2.port, 22)
    }

    func testWildcardPatternMatchesAll() {
        let config = """
        Host *
            User defaultuser
        """
        let parser = SSHConfigParser(contents: config)
        let entry = parser.resolveConfig(hostname: "anything.example.com")
        XCTAssertEqual(entry.user, "defaultuser")
    }

    func testWildcardPatternWithPrefix() {
        let config = """
        Host prod-*
            User deploy

        Host *
            User defaultuser
        """
        let parser = SSHConfigParser(contents: config)
        let prod = parser.resolveConfig(hostname: "prod-web")
        XCTAssertEqual(prod.user, "deploy")

        let other = parser.resolveConfig(hostname: "dev-web")
        XCTAssertEqual(other.user, "defaultuser")
    }

    func testFirstMatchWins() {
        let config = """
        Host myserver
            User specific

        Host *
            User wildcard
        """
        let parser = SSHConfigParser(contents: config)
        let entry = parser.resolveConfig(hostname: "myserver")
        XCTAssertEqual(entry.user, "specific")
    }

    func testProxyJumpField() {
        let config = """
        Host internal
            HostName 192.168.0.5
            ProxyJump bastion.example.com
        """
        let parser = SSHConfigParser(contents: config)
        let entry = parser.resolveConfig(hostname: "internal")
        XCTAssertEqual(entry.proxyJump, "bastion.example.com")
    }

    func testNoMatchReturnsEmptyEntry() {
        let config = """
        Host myhost
            HostName 10.1.1.1
            Port 22
        """
        let parser = SSHConfigParser(contents: config)
        let entry = parser.resolveConfig(hostname: "other")
        XCTAssertNil(entry.hostname)
        XCTAssertNil(entry.port)
    }

    // MARK: - DetectedSSHSession.scpArguments

    func testScpArgumentsBasic() {
        let session = DetectedSSHSession(
            destination: "user@host",
            port: nil,
            identityFile: nil,
            configFile: nil,
            jumpHost: nil,
            controlPath: nil,
            useIPv4: false,
            useIPv6: false,
            forwardAgent: false,
            compressionEnabled: false,
            sshOptions: []
        )
        let args = session.scpArguments(localPath: "/local/file.txt", remotePath: "/remote/file.txt")
        XCTAssertTrue(args.contains("-q"))
        XCTAssertTrue(args.contains("/local/file.txt"))
        XCTAssertTrue(args.last?.contains("file.txt") ?? false)
    }

    func testScpArgumentsWithPort() {
        let session = DetectedSSHSession(
            destination: "host",
            port: 2222,
            identityFile: nil,
            configFile: nil,
            jumpHost: nil,
            controlPath: nil,
            useIPv4: false,
            useIPv6: false,
            forwardAgent: false,
            compressionEnabled: false,
            sshOptions: []
        )
        let args = session.scpArguments(localPath: "/f", remotePath: "/r")
        let pIdx = args.firstIndex(of: "-P")
        XCTAssertNotNil(pIdx)
        if let pIdx {
            XCTAssertEqual(args[pIdx + 1], "2222")
        }
    }

    func testScpArgumentsWithIPv4() {
        let session = DetectedSSHSession(
            destination: "host",
            port: nil,
            identityFile: nil,
            configFile: nil,
            jumpHost: nil,
            controlPath: nil,
            useIPv4: true,
            useIPv6: false,
            forwardAgent: false,
            compressionEnabled: false,
            sshOptions: []
        )
        let args = session.scpArguments(localPath: "/f", remotePath: "/r")
        XCTAssertTrue(args.contains("-4"))
        XCTAssertFalse(args.contains("-6"))
    }

    func testScpArgumentsWithJumpHost() {
        let session = DetectedSSHSession(
            destination: "host",
            port: nil,
            identityFile: "/home/user/.ssh/id_rsa",
            configFile: nil,
            jumpHost: "bastion.example.com",
            controlPath: nil,
            useIPv4: false,
            useIPv6: false,
            forwardAgent: true,
            compressionEnabled: false,
            sshOptions: []
        )
        let args = session.scpArguments(localPath: "/f", remotePath: "/r")
        XCTAssertTrue(args.contains("-J"))
        XCTAssertTrue(args.contains("bastion.example.com"))
        XCTAssertTrue(args.contains("-A"))
        XCTAssertTrue(args.contains("-i"))
        XCTAssertTrue(args.contains("/home/user/.ssh/id_rsa"))
    }

    func testScpArgumentsWithCompression() {
        let session = DetectedSSHSession(
            destination: "host",
            port: nil,
            identityFile: nil,
            configFile: nil,
            jumpHost: nil,
            controlPath: nil,
            useIPv4: false,
            useIPv6: false,
            forwardAgent: false,
            compressionEnabled: true,
            sshOptions: []
        )
        let args = session.scpArguments(localPath: "/f", remotePath: "/r")
        XCTAssertTrue(args.contains("-C"))
    }
}
