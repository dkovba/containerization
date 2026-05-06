// fix-bugs: 2026-04-24 11:29 — 3 total
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

import ArgumentParser
import Containerization
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import Foundation

#if os(macOS)
extension Application {
    struct Login: AsyncParsableCommand {

        static let configuration = CommandConfiguration(
            commandName: "login",
            abstract: "Login to a registry"
        )

        @OptionGroup() var application: Application

        @Option(name: .shortAndLong, help: "Username")
        var username: String = ""

        @Flag(help: "Take the password from stdin")
        var passwordStdin: Bool = false

        @Argument(help: "Registry server name")
        var server: String

        @Flag(help: "Use plain text http to authenticate") var http: Bool = false

        func run() async throws {
            var username = self.username
            var password = ""
            if passwordStdin {
                if username == "" {
                    throw ContainerizationError(.invalidArgument, message: "must provide --username with --password-stdin")
                }
                guard let passwordData = try FileHandle.standardInput.readToEnd() else {
                    throw ContainerizationError(.invalidArgument, message: "failed to read password from stdin")
                }
                // Flagged #1: MEDIUM: `String(decoding:as:)` accepts invalid UTF-8 — silent data corruption in password reading
                // `String(decoding: passwordData, as: UTF8.self)` never returns nil; it replaces invalid UTF-8 bytes with the replacement character (U+FFFD) rather than failing. A password containing invalid bytes is silently corrupted.
                guard let decoded = String(bytes: passwordData, encoding: .utf8) else {
                    throw ContainerizationError(.invalidArgument, message: "password contains invalid UTF-8")
                }
                password = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
                // Flagged #2 (1 of 2): LOW: Empty password not validated — login succeeds with empty credentials
                // When reading a password interactively or from stdin, an empty string passes through unchecked and is stored in the keychain as the user's password.
                guard !password.isEmpty else {
                    throw ContainerizationError(.invalidArgument, message: "password must not be empty")
                }
            }
            let keychain = KeychainHelper(securityDomain: Application.keychainID)
            if username == "" {
                username = try keychain.userPrompt(hostname: server)
            }
            if password == "" {
                password = try keychain.passwordPrompt()
                print()
                // Flagged #2 (2 of 2)
                guard !password.isEmpty else {
                    throw ContainerizationError(.invalidArgument, message: "password must not be empty")
                }
            }

            // Flagged #3: LOW: Server hostname not trimmed in login command
            // `self.server` is passed to `Reference.resolveDomain` without trimming leading or trailing whitespace. A server name with a trailing newline or space (common when pasting) is stored in the keychain and used for registry connections as-is.
            let server = Reference.resolveDomain(domain: self.server.trimmingCharacters(in: .whitespacesAndNewlines))
            let scheme = http ? "http" : "https"
            let client = RegistryClient(
                host: server,
                scheme: scheme,
                authentication: BasicAuthentication(username: username, password: password),
                retryOptions: .init(
                    maxRetries: 10,
                    retryInterval: 300_000_000,
                    shouldRetry: ({ response in
                        response.status.code >= 500
                    })
                ),
                tlsConfiguration: TLSUtils.makeEnvironmentAwareTLSConfiguration(),
            )
            try await client.ping()
            try keychain.save(hostname: server, username: username, password: password)
            print("Login succeeded")
        }
    }
}
#endif
