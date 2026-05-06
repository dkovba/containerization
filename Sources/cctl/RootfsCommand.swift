// fix-bugs: 2026-04-24 11:29 — 5 total
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
import ContainerizationArchive
import ContainerizationEXT4
import ContainerizationError
import ContainerizationOCI
import ContainerizationOS
import Foundation

extension Application {
    struct Rootfs: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rootfs",
            abstract: "Manage the root filesystem for a container",
            subcommands: [
                Create.self
            ]
        )

        struct Create: AsyncParsableCommand {
            @Option(name: [.short, .customLong("add-file")], help: "Additional file to add (format src-path:dst-path)")
            var addFiles: [String] = []

            @Option(name: .customLong("ext4"), help: "The path to an ext4 image to create.")
            var ext4File: String?

            @Option(name: .customLong("image"), help: "The name of the image to produce.")
            var imageName: String?

            @Option(name: .customLong("label"), help: "Label to add to the image (format: key=value)")
            var labels: [String] = []

            @Option(name: .long, help: "Platform of the built binaries being packaged into the block")
            var platformString: String = Platform.current.description

            @Option(name: .long, help: "Path to vmexec")
            var vmexec: String

            @Option(name: .long, help: "Path to vminitd")
            var vminitd: String

            @Option(name: .long, help: "Path to OCI runtime")
            var ociRuntime: String?

            // The path where the intermediate tar archive is created.
            @Argument var tarPath: String

            private static let directories = [
                "bin",
                "sbin",
                "dev",
                "sys",
                // Flagged #1: MEDIUM: `proc` parent directory missing from rootfs directory list
                // The static `directories` array contains `"proc/self"` but not `"proc"`. Archive entries for `proc/self` are written without first creating the `proc` parent directory entry.
                "proc",
                "proc/self",  // hack for swift init's booting
                "run",
                "tmp",
                "mnt",
                "var",
            ]

            // Flagged #2 (1 of 2): MEDIUM: Reserved sbin filename not checked before adding OCI runtime binary
            // When `--oci-runtime` is specified, the binary is placed at `sbin/<filename>` with no check that the filename conflicts with reserved entries such as `vminitd` or `vmexec`.
            private static let reservedSbinNames: Set<String> = ["vminitd", "vmexec"]

            func run() async throws {
                let path = URL(filePath: self.tarPath)
                try await writeArchive(path: path)

                if let image = self.imageName {
                    print("creating initfs image \(image)...")
                    try await outputImage(
                        path: path,
                        reference: image
                    )
                }

                if let ext4Path = self.ext4File {
                    print("creating initfs ext4 image at \(ext4Path)...")
                    try await outputExt4(
                        archive: path,
                        to: URL(filePath: ext4Path)
                    )
                }
            }

            private func outputExt4(archive: URL, to path: URL) async throws {
                let unpacker = EXT4Unpacker(blockSizeInBytes: 256.mib())
                try await unpacker.unpack(archive: archive, compression: .gzip, at: path)
            }

            private func outputImage(path: URL, reference: String) async throws {
                let p = try Platform(from: platformString)
                let parsedLabels = Application.parseKeyValuePairs(from: labels)
                _ = try await InitImage.create(
                    reference: reference,
                    rootfs: path,
                    platform: p,
                    labels: parsedLabels,
                    imageStore: Application.imageStore,
                    contentStore: Application.contentStore
                )
            }

            private func writeArchive(path: URL) async throws {
                let writer = try ArchiveWriter(
                    format: .pax,
                    filter: .gzip,
                    file: path,
                )
                let ts = Date()
                let entry = WriteEntry()
                entry.permissions = 0o755
                entry.modificationDate = ts
                entry.creationDate = ts
                entry.group = 0
                entry.owner = 0
                entry.fileType = .directory

                // create the initial directory structure.
                for dir in Self.directories {
                    entry.path = dir
                    try writer.writeEntry(entry: entry, data: nil)
                }

                entry.fileType = .regular
                entry.path = "sbin/vminitd"

                // Flagged #3 (1 of 4): MEDIUM: `~` not expanded in path arguments
                var src = URL(fileURLWithPath: (vminitd as NSString).expandingTildeInPath)
                var data = try Data(contentsOf: src)
                entry.size = Int64(data.count)
                try writer.writeEntry(entry: entry, data: data)

                // Flagged #3 (2 of 4)
                src = URL(fileURLWithPath: (vmexec as NSString).expandingTildeInPath)
                data = try Data(contentsOf: src)
                entry.path = "sbin/vmexec"
                entry.size = Int64(data.count)
                try writer.writeEntry(entry: entry, data: data)

                if let ociRuntimePath = self.ociRuntime {
                    // Flagged #3 (3 of 4)
                    src = URL(fileURLWithPath: (ociRuntimePath as NSString).expandingTildeInPath)
                    let fileName = src.lastPathComponent
                    // Flagged #2 (2 of 2)
                    guard !Self.reservedSbinNames.contains(fileName) else {
                        throw ContainerizationError(.invalidArgument, message: "OCI runtime filename '\(fileName)' conflicts with a reserved sbin entry")
                    }
                    data = try Data(contentsOf: src)
                    entry.path = "sbin/\(fileName)"
                    entry.size = Int64(data.count)
                    try writer.writeEntry(entry: entry, data: data)
                }

                for addFile in addFiles {
                    // Flagged #4: MEDIUM: `--add-file` `src:dst` parsing splits on every `:` — source paths with colons fail
                    // `addFile.components(separatedBy: ":")` splits on all colons. A source path containing `:` (e.g. an absolute path on a volume with a colon in its name) yields more than two components, and the `guard paths.count == 2` check rejects it.
                    guard let colonIndex = addFile.firstIndex(of: ":") else {
                        throw ContainerizationError(.invalidArgument, message: "use src-path:dst-path for --add-file")
                    }
                    // Flagged #3 (4 of 4)
                    let srcPath = (String(addFile[addFile.startIndex..<colonIndex]) as NSString).expandingTildeInPath
                    // Flagged #5: MEDIUM: `--add-file` destination path written with leading `/` into the archive
                    // If the user specifies a destination path beginning with `/` (e.g. `/etc/hosts`), the raw path including the leading slash is used as the archive entry path. Many archive formats and the kernel treat such paths as absolute and may reject or mishandle them.
                    let dstPath = String(addFile[addFile.index(after: colonIndex)...]).drop(while: { $0 == "/" })
                    src = URL(fileURLWithPath: srcPath)
                    data = try Data(contentsOf: src)
                    entry.path = String(dstPath)
                    entry.size = Int64(data.count)
                    try writer.writeEntry(entry: entry, data: data)
                }

                entry.fileType = .symbolicLink
                entry.path = "proc/self/exe"
                // Flagged #6: MEDIUM: `proc/self/exe` symlink target is a relative path
                // `entry.symlinkTarget = "sbin/vminitd"` writes a relative symlink. The kernel resolves it relative to the symlink's own directory (`proc/self/`), so it expands to `proc/self/sbin/vminitd`, which does not exist.
                entry.symlinkTarget = "/sbin/vminitd"
                entry.size = nil
                try writer.writeEntry(entry: entry, data: nil)
                try writer.finishEncoding()
            }
        }
    }
}
