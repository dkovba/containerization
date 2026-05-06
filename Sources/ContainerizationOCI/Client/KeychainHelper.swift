// fix-bugs: 2026-04-24 15:58 — 0 critical, 0 high, 2 medium, 0 low (2 total)
//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the Containerization project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

#if os(macOS)
import Foundation
import ContainerizationOS

/// Helper type to lookup registry related values in the macOS keychain.
public struct KeychainHelper: Sendable {
    private let securityDomain: String
    private let accessGroup: String?

    /// Create a new keychain helper.
    /// - Parameters:
    ///   - securityDomain: The security domain used to fetch registry entries in the keychain.
    ///   - accessGroup: If present, the access group used to fetch registry entries in the keychain.
    public init(securityDomain: String, accessGroup: String? = nil) {
        self.securityDomain = securityDomain
        self.accessGroup = accessGroup
    }

    /// Lookup authentication data for a given registry hostname.
    /// - Parameters:
    ///   - hostname: The hostname for the registry.
    /// - Returns: The authentication object for the registry.
    /// - Throws: An error if the keychain query fails.
    public func lookup(hostname: String) throws -> Authentication {
        let kq = KeychainQuery()

        do {
            guard
                let fetched = try kq.get(
                    securityDomain: self.securityDomain,
                    accessGroup: self.accessGroup,
                    hostname: hostname)
            else {
                throw Self.Error.keyNotFound
            }
            return BasicAuthentication(
                username: fetched.username,
                password: fetched.password
            )
        } catch let err as KeychainQuery.Error {
            switch err {
            case .keyNotPresent(_):
                throw Self.Error.keyNotFound
            default:
                throw Self.Error.queryError("query failure: \(String(describing: err))")
            }
        }
    }

    /// Lists all registry entries for this security domain.
    /// - Returns: An array of registry metadata for each matching entry, or an empty array if none are found.
    /// - Throws: An error if the keychain query fails.
    public func list() throws -> [RegistryInfo] {
        let kq = KeychainQuery()
        return try kq.list(securityDomain: self.securityDomain, accessGroup: self.accessGroup)
    }

    /// Delete authorization data for a given hostname from the keychain.
    /// - Parameters:
    ///   - hostname: The hostname for the registry.
    /// - Throws: An error if the keychain query fails.
    public func delete(hostname: String) throws {
        let kq = KeychainQuery()
        try kq.delete(securityDomain: self.securityDomain, accessGroup: self.accessGroup, hostname: hostname)
    }

    /// Save authorization data for a given hostname to the keychain.
    /// - Parameters:
    ///   - hostname: The hostname for the registry.
    ///   - username: The username to present to the registry.
    ///   - password: The password to present to the registry.
    /// - Throws: An error if the keychain query fails or returns unexpected data.
    public func save(hostname: String, username: String, password: String) throws {
        let kq = KeychainQuery()
        try kq.save(
            securityDomain: self.securityDomain,
            accessGroup: self.accessGroup,
            hostname: hostname,
            username: username,
            password: password
        )
    }

    /// Prompt for authorization data for a given hostname to be saved to the keychain.
    /// This will cause the current terminal to enter a password prompt state where
    /// key strokes are hidden.
    public func credentialPrompt(hostname: String) throws -> Authentication {
        let username = try userPrompt(hostname: hostname)
        let password = try passwordPrompt()
        return BasicAuthentication(username: username, password: password)
    }

    /// Prompts the current stdin for a username entry and then returns the value.
    public func userPrompt(hostname: String) throws -> String {
        print("Provide registry username \(hostname): ", terminator: "")
        guard let username = readLine() else {
            throw Self.Error.invalidInput
        }
        // Flagged #1: MEDIUM: `userPrompt()` accepts an empty username
        // `userPrompt()` calls `readLine()` and returns whatever it produces, including an empty string `""` when the user presses Enter without typing anything. No guard against an empty result is present, so the empty string is returned as a valid username.
        guard !username.isEmpty else {
            throw Self.Error.invalidInput
        }
        return username
    }

    /// Prompts the current stdin for a password entry and then returns the value.
    /// This will cause the current stdin (if it is a terminal) to hide keystrokes
    /// by disabling echo.
    public func passwordPrompt() throws -> String {
        print("Provide registry password: ", terminator: "")
        let console = try Terminal.current
        defer { console.tryReset() }
        try console.disableEcho()

        guard let password = readLine() else {
            throw Self.Error.invalidInput
        }
        // Flagged #2: MEDIUM: `passwordPrompt()` leaves terminal cursor on the password line
        // `console.disableEcho()` suppresses all terminal output, including the newline produced when the user presses Enter. After `readLine()` returns, the cursor remains on the same line as the password prompt. Any subsequent output (next prompt, error message, etc.) is rendered on that line, garbling the terminal display.
        print()
        return password
    }
}

extension KeychainHelper {
    /// `KeychainHelper` errors.
    public enum Error: Swift.Error {
        case keyNotFound
        case invalidInput
        case queryError(String)
    }
}
#endif
