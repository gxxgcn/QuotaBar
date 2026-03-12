import Foundation

protocol CredentialStore: Sendable {
    func save(authData: Data, for accountID: UUID) async throws
    func loadAuthData(for accountID: UUID) async throws -> Data
    func deleteAuthData(for accountID: UUID) async throws
}
