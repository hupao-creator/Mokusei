import Foundation

/// Identifies the locally owned runtime service.
/// Credentials are deliberately excluded from textual/debug descriptions.
public struct RuntimeConnection: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let port: Int
    public let token: String
    public let epoch: String
    public let protocolVersion: Int
    public let pid: Int
    public let dataDir: String

    public init(port: Int, token: String, epoch: String, protocolVersion: Int, pid: Int, dataDir: String) {
        self.port = port
        self.token = token
        self.epoch = epoch
        self.protocolVersion = protocolVersion
        self.pid = pid
        self.dataDir = dataDir
    }

    public var description: String { "RuntimeConnection(port: \(port), epoch: \(epoch), pid: \(pid), token: <redacted>)" }
    public var debugDescription: String { description }
}

/// The shared client owns all subscription/receipt behavior. A platform source
/// only acquires the endpoint and performs the host's explicit lifecycle actions.
public protocol RuntimeConnectionSource: Sendable {
    func start() async throws -> RuntimeConnection
    func status() async throws -> RuntimeConnection?
    func stop(expectedEpoch: String?) async throws
    func setOutputLocale(_ locale: String) throws
}
