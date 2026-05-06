// fix-bugs: 2026-04-24 11:29 — 6 total
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
import Foundation

extension Application {
    struct KernelCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "kernel",
            abstract: "Manage kernel images",
            subcommands: [
                Create.self
            ]
        )

        struct Create: AsyncParsableCommand {
            // Flagged #1: HIGH: `KernelCommand.Create` registered under the wrong subcommand name
            // `Create` has no `CommandConfiguration` with a `commandName`, so ArgumentParser uses the struct name "create" as the command name. The intended name is "add" (`cctl kernel add`).
            static let configuration = CommandConfiguration(commandName: "add")

            @Option(name: .shortAndLong, help: "Name for the kernel image")
            var name: String

            @Option(name: .long, help: "Labels to add to the built image of the form <key1>=<value1>, [<key2>=<value2>,...]")
            var labels: [String] = []

            @Argument var kernels: [String]

            func run() async throws {
                // Flagged #3 (1 of 2): MEDIUM: Empty kernel image name not validated
                // The `--name` option accepts an empty string or a string containing only whitespace. The trimmed name is passed to `Reference.parse`, which may accept it or produce an unexpected reference.
                let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedName.isEmpty else {
                    throw ContainerizationError(.invalidArgument, message: "kernel image name must not be empty")
                }
                // Flagged #4: MEDIUM: Empty kernels list not validated — misleading error from downstream
                // `parseBinaries()` is called even when `kernels` is empty, and the resulting empty `binaries` array is passed to `KernelImage.create`, which may succeed silently or fail with an unhelpful error.
                guard !kernels.isEmpty else {
                    throw ContainerizationError(.invalidArgument, message: "at least one kernel binary must be specified")
                }
                let imageStore = Application.imageStore
                let contentStore = Application.contentStore
                let labels = Application.parseKeyValuePairs(from: labels)
                let binaries = try parseBinaries()
                _ = try await KernelImage.create(
                    // Flagged #3 (2 of 2)
                    reference: trimmedName,
                    binaries: binaries,
                    labels: labels,
                    imageStore: imageStore,
                    contentStore: contentStore
                )
            }

            func parseBinaries() throws -> [Kernel] {
                var binaries = [Kernel]()
                // Flagged #5 (1 of 2): MEDIUM: Duplicate architecture in kernel binary list not detected
                // `parseBinaries()` does not check whether the same architecture appears more than once in the `kernels` list. The last entry silently wins.
                var seenArchitectures = Set<String>()
                for rawBinary in kernels {
                    // Flagged #6: MEDIUM: `parseBinaries()` splits on every `:` — kernel binary paths containing colons are misparsed
                    // `rawBinary.split(separator: ":")` splits on all colons, so a kernel path like `/some:path/vmlinuz:arm64` is split into three parts and fails the `parts.count == 2` guard.
                    guard let colonIndex = rawBinary.lastIndex(of: ":") else {
                        throw ContainerizationError(.invalidArgument, message: "invalid binary format: \(rawBinary)")
                    }
                    let path = String(rawBinary[rawBinary.startIndex..<colonIndex])
                    let arch = String(rawBinary[rawBinary.index(after: colonIndex)...])
                    // Flagged #5 (2 of 2)
                    guard !seenArchitectures.contains(arch) else {
                        throw ContainerizationError(.invalidArgument, message: "duplicate architecture: \(arch)")
                    }
                    seenArchitectures.insert(arch)
                    let platform: SystemPlatform
                    switch arch {
                    case "arm64":
                        platform = .linuxArm
                    case "amd64":
                        platform = .linuxAmd
                    // Flagged #2: HIGH: `fatalError` used for unsupported kernel architecture — crashes instead of throwing
                    // An unrecognized architecture string in `parseBinaries()` calls `fatalError(...)`, which terminates the process unconditionally with no structured error.
                    default:
                        throw ContainerizationError(.invalidArgument, message: "unsupported architecture: \(arch)")
                    }
                    binaries.append(
                        .init(
                            // Flagged #7: MEDIUM: `~` not expanded in path arguments
                            path: URL(fileURLWithPath: (path as NSString).expandingTildeInPath),
                            platform: platform
                        )
                    )
                }
                return binaries
            }
        }
    }
}
