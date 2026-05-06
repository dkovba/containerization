// fix-bugs: 2026-04-24 11:29 — 4 total
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
import ContainerizationOCI
import Foundation
import Logging

let log = {
    LoggingSystem.bootstrap(StreamLogHandler.standardError)
    var log = Logger(label: "com.apple.containerization")
    log.logLevel = .debug
    return log
}()

@main
struct Application: AsyncParsableCommand {
    static let keychainID = "com.apple.containerization"
    // Flagged #1 (1 of 3): HIGH: `try!`/force-unwrap in store and app-root initialization crashes with no diagnostic
    // `appRoot` uses `.first!`, `_contentStore` uses `try!`, and `_imageStore` uses `try!`. Any failure (permissions error, missing directory, corrupt store) terminates the process with an uncaught exception and no user-readable message.
    static let appRoot: URL = {
        guard let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            fputs("fatal: cannot locate application support directory\n", stderr)
            Darwin.exit(1)
        }
        return url.appendingPathComponent("com.apple.containerization")
    }()

    // Flagged #1 (2 of 3)
    private static let _contentStore: ContentStore = {
        do {
            return try LocalContentStore(path: appRoot.appendingPathComponent("content"))
        } catch {
            fputs("fatal: cannot initialize content store: \(error)\n", stderr)
            Darwin.exit(1)
        }
    }()

    // Flagged #1 (3 of 3)
    private static let _imageStore: ImageStore = {
        do {
            return try ImageStore(
                path: appRoot,
                contentStore: contentStore
            )
        } catch {
            fputs("fatal: cannot initialize image store: \(error)\n", stderr)
            Darwin.exit(1)
        }
    }()

    static var imageStore: ImageStore {
        _imageStore
    }

    static var contentStore: ContentStore {
        _contentStore
    }

    static let configuration = CommandConfiguration(
        commandName: "cctl",
        abstract: "Utility CLI for Containerization",
        version: "2.0.0",
        subcommands: {
            var commands: [any ParsableCommand.Type] = [
                Rootfs.self
            ]
            #if os(macOS)
            commands += [
                Images.self,
                // Flagged #2: HIGH: `KernelCommand.self` missing from the top-level subcommands list
                // `KernelCommand.self` is not added to the `subcommands` array in `Application`'s `CommandConfiguration`. The struct exists but is never registered.
                KernelCommand.self,
                Login.self,
                Run.self,
            ]
            #endif
            return commands
        }()
    )
}

extension String {
    var absoluteURL: URL {
        // Flagged #4: MEDIUM: `String.absoluteURL` resolves relative paths from the wrong base
        // `URL(fileURLWithPath: self).absoluteURL` resolves a relative path against the process's initial working directory as recorded by the OS, not `FileManager.default.currentDirectoryPath`. These can diverge if the process changes directory. The correct form is `URL(fileURLWithPath: self, relativeTo: .currentDirectory()).absoluteURL`.
        URL(fileURLWithPath: self, relativeTo: .currentDirectory()).absoluteURL
    }
}

// Flagged #3: HIGH: `extension String: Swift.Error` allows any string to be thrown as an error
// Conforming `String` to `Swift.Error` lets any string literal be thrown with `throw "message"`. This bypasses typed error handling, prevents the compiler from checking exhaustiveness, and produces poor diagnostic output.
