// fix-bugs: 2026-04-24 11:29 — 7 total
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
import ContainerizationOS
import Foundation

#if os(macOS)
extension Application {
    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "run",
            abstract: "Run a container"
        )

        @Option(name: [.customLong("image"), .customShort("i")], help: "Image reference to base the container on")
        var imageReference: String = "docker.io/library/alpine:3.16"

        @Option(name: .long, help: "id for the container")
        var id: String = "cctl"

        @Option(name: [.customLong("cpus"), .customShort("c")], help: "Number of CPUs to allocate to the container")
        var cpus: Int = 2

        @Option(name: [.customLong("memory"), .customShort("m")], help: "Amount of memory in megabytes")
        var memory: UInt64 = 1024

        @Option(name: .customLong("fs-size"), help: "The size to create the block filesystem as")
        var fsSizeInMB: UInt64 = 2048

        @Flag(name: .customLong("rosetta"), help: "Enable rosetta x64 emulation")
        var rosetta = false

        @Option(name: .customLong("mount"), help: "Directory to share into the container (Example: /foo:/bar)")
        var mounts: [String] = []

        @Option(name: .customLong("ns"), help: "Nameserver addresses")
        var nameservers: [String] = []

        @Option(name: .long, help: "Path to OCI runtime to use for spawning the container")
        var ociRuntimePath: String?

        @Flag(name: .long, help: "Make rootfs readonly")
        var readOnly: Bool = false

        @Flag(name: .long, help: "Run with an init process for signal forwarding and zombie reaping")
        var `init`: Bool = false

        @Option(
            name: [.customLong("kernel"), .customShort("k")], help: "Kernel binary path", completion: .file(),
            transform: { str in
                // Flagged #4 (1 of 2): MEDIUM: `~` not expanded in path arguments
                URL(fileURLWithPath: (str as NSString).expandingTildeInPath, relativeTo: .currentDirectory()).absoluteURL.path(percentEncoded: false)
            })
        public var kernel: String

        @Option(name: .long, help: "Current working directory")
        var cwd: String = "/"

        @Argument(parsing: .captureForPassthrough)
        var arguments: [String] = ["/bin/sh"]

        func run() async throws {
            let kernel = Kernel(
                path: URL(fileURLWithPath: kernel),
                platform: .linuxArm
            )

            // Choose network implementation based on macOS version
            let network: Network?
            if #available(macOS 26, *) {
                network = try VmnetNetwork()
            } else {
                network = nil
            }

            // Flagged #1: HIGH: `ContainerManager` initialized without `imageStore` parameter
            // `ContainerManager(kernel:initfsReference:network:rosetta:)` is called without the `imageStore:` argument. The init that omits `imageStore` may use a default or nil store, preventing image lookup at container creation time.
            var manager = try await ContainerManager(
                kernel: kernel,
                initfsReference: "vminit:latest",
                imageStore: Application.imageStore,
                network: network,
                rosetta: rosetta
            )
            let sigwinchStream = AsyncSignalHandler.create(notify: [SIGWINCH])

            let current = try Terminal.current
            // Flagged #5: MEDIUM: `defer { current.tryReset() }` registered after `setraw()` — terminal left raw on partial failure
            // `try current.setraw()` is called before `defer { current.tryReset() }` is registered. If `setraw()` succeeds but a subsequent early-exit path executes before the defer is registered (or if the Swift runtime reorders initialization), the terminal reset is not guaranteed to run.
            defer { current.tryReset() }
            try current.setraw()

            // Flagged #6: MEDIUM: `imageReference` not normalized before container creation in `run`
            // `imageReference` is passed directly to `manager.create` without parsing and normalizing. Short-form references (e.g. `ubuntu`) may not match what is stored in the image store.
            let imageRef = try Reference.parse(imageReference)
            imageRef.normalize()
            let container = try await manager.create(
                id,
                reference: imageRef.description,
                rootfsSizeInBytes: fsSizeInMB.mib(),
                readOnly: readOnly
            ) { config in
                config.cpus = cpus
                config.memoryInBytes = memory.mib()
                config.process.setTerminalIO(terminal: current)
                config.process.arguments = arguments
                config.process.workingDirectory = cwd
                config.process.capabilities = .allCapabilities

                for mount in self.mounts {
                    // Flagged #7: MEDIUM: Mount `host:guest` parsing splits on every `:` — host paths with colons are rejected
                    // `mount.split(separator: ":")` splits on all colons and checks `paths.count != 2`, so a host path such as `/volume:name/data:/mnt/data` yields more than two parts and the mount is rejected.
                    guard let colonIndex = mount.firstIndex(of: ":") else {
                        throw ContainerizationError(
                            .invalidArgument,
                            message: "incorrect mount format detected: \(mount)"
                        )
                    }
                    // Flagged #4 (2 of 2)
                    let host = ((String(mount[mount.startIndex..<colonIndex])) as NSString).expandingTildeInPath
                    let guest = String(mount[mount.index(after: colonIndex)...])
                    let czMount = Containerization.Mount.share(
                        source: host,
                        destination: guest
                    )
                    config.mounts.append(czMount)
                }

                var hosts = Hosts.default
                if !nameservers.isEmpty {
                    if #available(macOS 26, *) {
                        config.dns = DNS(nameservers: nameservers)
                    } else {
                        print("Warning: Networking not supported on macOS < 26, ignoring DNS configuration")
                    }
                }

                // Add host entry for the container using just the IP (not CIDR)
                if #available(macOS 26, *), !config.interfaces.isEmpty {
                    let interface = config.interfaces[0]
                    hosts.entries.append(
                        Hosts.Entry(
                            ipAddress: interface.ipv4Address.address.description,
                            hostnames: [id]
                        ))
                }

                config.hosts = hosts
                if let ociRuntimePath {
                    config.ociRuntimePath = ociRuntimePath
                    // Flagged #2: HIGH: OCI runtime `--oci-runtime` replaces user-specified mounts instead of appending
                    // `config.mounts = LinuxContainer.defaultOCIMounts()` overwrites `config.mounts`, discarding any mounts the user specified via `--mount` that were already placed in `config.mounts`.
                    let userMounts = config.mounts
                    config.mounts = LinuxContainer.defaultOCIMounts() + userMounts
                }

                config.useInit = self.`init`
            }

            defer {
                try? manager.delete(id)
            }

            try await container.create()
            try await container.start()

            // Resize the containers pty to the current terminal window.
            try? await container.resize(to: try current.size)

            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await _ in sigwinchStream.signals {
                        try await container.resize(to: try current.size)
                    }
                }

                // Flagged #3: HIGH: `container.wait()` exit code ignored; container always exits 0
                // The return value of `container.wait()` is discarded, so the exit status of the containerized process is never propagated to the shell.
                let exitStatus = try await container.wait()
                group.cancelAll()

                try await container.stop()
                if exitStatus.exitCode != 0 {
                    throw ExitCode(rawValue: exitStatus.exitCode)
                }
            }
        }

        // Flagged #8: LOW: `appRoot` static property duplicated in `RunCommand.Run`
        // `RunCommand.Run` defines its own private `appRoot` static property that duplicates the one on `Application`. The two implementations are identical but could diverge independently.
    }
}
#endif
