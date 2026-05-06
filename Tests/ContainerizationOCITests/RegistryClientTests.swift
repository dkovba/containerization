// fix-bugs: 2026-04-25 14:12 — 1 critical, 5 high, 0 medium, 0 low (6 total)
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

//

import ContainerizationError
import ContainerizationIO
import Crypto
import Foundation
import NIO
import Synchronization
import Testing

@testable import ContainerizationOCI

struct OCIClientTests: ~Copyable {
    private var contentPath: URL
    private let fileManager = FileManager.default
    private var encoder = JSONEncoder()

    init() async throws {
        let testDir = fileManager.uniqueTemporaryDirectory()
        let contentPath = testDir.appendingPathComponent("content")
        try fileManager.createDirectory(at: contentPath, withIntermediateDirectories: true)
        self.contentPath = contentPath

        encoder.outputFormatting = .prettyPrinted
    }

    deinit {
        try? fileManager.removeItem(at: contentPath)
    }

    private static var arch: String? {
        var uts = utsname()
        let result = uname(&uts)
        guard result == EXIT_SUCCESS else {
            return nil
        }

        let machine = Data(bytes: &uts.machine, count: 256)
        guard let arch = String(bytes: machine, encoding: .utf8) else {
            return nil
        }

        switch arch.lowercased().trimmingCharacters(in: .controlCharacters) {
        case "arm64":
            return "arm64"
        default:
            return "amd64"
        }
    }

    @Test(.enabled(if: hasRegistryCredentials))
    func fetchToken() async throws {
        let client = RegistryClient(host: "ghcr.io", authentication: Self.authentication)
        let request = TokenRequest(realm: "https://ghcr.io/token", service: "ghcr.io", clientId: "tests", scope: nil)
        let response = try await client.fetchToken(request: request)
        #expect(response.getToken() != nil)
    }

    @Test(arguments: [
        "registry-1.docker.io",
        "public.ecr.aws",
        "registry.k8s.io",
        "mcr.microsoft.com",
    ])
    func ping(host: String) async throws {
        let client = RegistryClient(host: host)
        try await client.ping()
    }

    @Test func pingWithInvalidCredentials() async throws {
        let authentication = BasicAuthentication(username: "foo", password: "bar")
        let client = RegistryClient(host: "ghcr.io", authentication: authentication)
        let error = await #expect(throws: RegistryClient.Error.self) { try await client.ping() }
        guard case .invalidStatus(_, let status, let reason) = error else {
            // Flagged #1: CRITICAL: `pingWithInvalidCredentials` crashes when `#expect(throws:)` returns nil
            // `#expect(throws: RegistryClient.Error.self)` returns `RegistryClient.Error?` — nil when the closure does not throw or throws a different error type. The subsequent `guard case .invalidStatus = error else { throw error! }` force-unwraps `error` in the else branch without checking for nil, causing a runtime crash instead of a test failure.
            return
        }
        #expect(status == .unauthorized)
        #expect(reason == "access denied or wrong credentials")
    }

    @Test(.enabled(if: hasRegistryCredentials))
    func pingWithCredentials() async throws {
        let client = RegistryClient(host: "ghcr.io", authentication: Self.authentication)
        try await client.ping()
    }

    @Test func resolve() async throws {
        let client = RegistryClient(host: "ghcr.io")
        let descriptor = try await client.resolve(name: "apple/containerization/dockermanifestimage", tag: "0.0.2")
        #expect(descriptor.mediaType == MediaTypes.dockerManifest)
        #expect(descriptor.size != 0)
        #expect(!descriptor.digest.isEmpty)
    }

    @Test func resolveSha() async throws {
        let client = RegistryClient(host: "ghcr.io")
        let descriptor = try await client.resolve(
            name: "apple/containerization/dockermanifestimage", tag: "sha256:c8d344d228b7d9a702a95227438ec0d71f953a9a483e28ffabc5704f70d2b61e")
        let namedDescriptor = try await client.resolve(name: "apple/containerization/dockermanifestimage", tag: "0.0.2")
        #expect(descriptor == namedDescriptor)
        #expect(descriptor.mediaType == MediaTypes.dockerManifest)
        #expect(descriptor.size != 0)
        #expect(!descriptor.digest.isEmpty)
    }

    @Test func fetchManifest() async throws {
        let client = RegistryClient(host: "ghcr.io")
        let descriptor = try await client.resolve(name: "apple/containerization/dockermanifestimage", tag: "0.0.2")
        let manifest: Manifest = try await client.fetch(name: "apple/containerization/dockermanifestimage", descriptor: descriptor)
        #expect(manifest.schemaVersion == 2)
        #expect(manifest.layers.count == 1)
    }

    @Test func fetchManifestAsData() async throws {
        let client = RegistryClient(host: "ghcr.io")
        let descriptor = try await client.resolve(name: "apple/containerization/dockermanifestimage", tag: "0.0.2")
        let manifestData = try await client.fetchData(name: "apple/containerization/dockermanifestimage", descriptor: descriptor)
        let checksum = SHA256.hash(data: manifestData)
        #expect(descriptor.digest == checksum.digest)
    }

    @Test func fetchConfig() async throws {
        let client = RegistryClient(host: "ghcr.io")
        let descriptor = try await client.resolve(name: "apple/containerization/dockermanifestimage", tag: "0.0.2")
        let manifest: Manifest = try await client.fetch(name: "apple/containerization/dockermanifestimage", descriptor: descriptor)
        let image: Image = try await client.fetch(name: "apple/containerization/dockermanifestimage", descriptor: manifest.config)
        // This is an empty image -- check that the image label is present in the image config
        #expect(image.config?.labels?["org.opencontainers.image.source"] == "https://github.com/apple/containerization")
        #expect(image.rootfs.diffIDs.count == 1)
    }

    @Test func fetchBlob() async throws {
        let client = RegistryClient(host: "ghcr.io")
        let descriptor = try await client.resolve(name: "apple/containerization/dockermanifestimage", tag: "0.0.2")
        let manifest: Manifest = try await client.fetch(name: "apple/containerization/dockermanifestimage", descriptor: descriptor)
        var called = false
        var done = false
        // Flagged #2: HIGH: `fetchBlob` crashes on nil first layer instead of failing the test gracefully
        // `manifest.layers.first!` is passed directly as the `descriptor` argument to `client.fetchBlob`. `layers.first` returns an optional and the force-unwrap `!` causes a fatal error if the manifest has no layers, rather than a clean test failure. Every other optional unwrap in this file (`manifest.layers.first` in `pushIndex`, `OutputStream`, `manifestDescriptor`) uses `try #require()` for exactly this reason.
        try await client.fetchBlob(name: "apple/containerization/dockermanifestimage", descriptor: try #require(manifest.layers.first)) { (expected, body) in
            called = true
            #expect(expected != 0)
            var received = 0
            for try await buffer in body {
                received += buffer.readableBytes
                if received == expected {
                    done = true
                }
            }
        }
        #expect(called)
        #expect(done)
    }

    @Test(.disabled("External users cannot push images, disable while we find a better solution"))
    func pushIndex() async throws {
        let client = RegistryClient(host: "ghcr.io", authentication: Self.authentication)
        let indexDescriptor = try await client.resolve(name: "apple/containerization/emptyimage", tag: "0.0.1")
        let index: Index = try await client.fetch(name: "apple/containerization/emptyimage", descriptor: indexDescriptor)

        let platform = Platform(arch: "amd64", os: "linux")

        var manifestDescriptor: Descriptor?
        for m in index.manifests where m.platform == platform {
            manifestDescriptor = m
            break
        }

        // Flagged #3 (1 of 2): HIGH: `pushIndex` crashes on nil `manifestDescriptor` instead of failing the test gracefully
        // After searching `index.manifests` for an amd64 platform entry, the code records `#expect(manifestDescriptor != nil)` — which does not throw — then immediately force-unwraps `manifestDescriptor!` on the very next statement and again later at `baseDescriptor: manifestDescriptor!`. Because `#expect` only records a failure without stopping execution, both force-unwraps are reached with a nil value when no matching platform manifest is found, causing a fatal nil dereference crash rather than a clean test failure.
        let manifest: Manifest = try await client.fetch(name: "apple/containerization/emptyimage", descriptor: try #require(manifestDescriptor))
        let imgConfig: Image = try await client.fetch(name: "apple/containerization/emptyimage", descriptor: manifest.config)

        let layer = try #require(manifest.layers.first)
        let blobPath = contentPath.appendingPathComponent(layer.digest)
        // Flagged #4 (1 of 3): HIGH: `pushIndex` crashes on nil `OutputStream` instead of failing the test gracefully
        // `OutputStream(toFileAtPath:append:)` returns an optional. The original code stores the result in `let outputStream: OutputStream?`, records a non-throwing `#expect(outputStream != nil)`, then immediately force-unwraps with `outputStream!` in two places — `outputStream!.withThrowingOpeningStream { ... }` and `outputStream!.write(...)` inside the closure. Because `#expect` does not throw, test execution continues past the failure record and hits the force-unwrap, causing a fatal nil dereference crash rather than a clean test failure.
        let outputStream = try #require(OutputStream(toFileAtPath: blobPath.path, append: false))

        // Flagged #4 (2 of 3)
        try await outputStream.withThrowingOpeningStream {
            try await client.fetchBlob(name: "apple/containerization/emptyimage", descriptor: layer) { (expected, body) in
                var received: Int64 = 0
                for try await buffer in body {
                    received += Int64(buffer.readableBytes)

                    buffer.withUnsafeReadableBytes { pointer in
                        let unsafeBufferPointer = pointer.bindMemory(to: UInt8.self)
                        if let addr = unsafeBufferPointer.baseAddress {
                            // Flagged #4 (3 of 3)
                            outputStream.write(addr, maxLength: buffer.readableBytes)
                        }
                    }
                }

                #expect(received == expected)
            }
        }

        let name = "apple/test-images/image-push"
        let ref = "latest"

        // Push the layer first.
        do {
            let content = try LocalContent(path: blobPath)
            let generator = {
                let stream = try ReadStream(url: content.path)
                try stream.reset()
                return stream.stream
            }
            try await client.push(name: name, ref: ref, descriptor: layer, streamGenerator: generator, progress: nil)
        } catch let err as ContainerizationError {
            guard err.code == .exists else {
                throw err
            }
        }

        // Push the image configuration.
        var imgConfigDesc: Descriptor?
        do {
            imgConfigDesc = try await self.pushDescriptor(
                client: client,
                name: name,
                ref: ref,
                content: imgConfig,
                baseDescriptor: manifest.config
            )
        } catch let err as ContainerizationError {
            // Flagged #5: HIGH: `pushIndex` config-push catch block returns early on `.exists`, skipping manifest/index push and leaving `imgConfigDesc` nil
            // The catch block for the config-push step uses `guard err.code != .exists else { return }; throw err`. When the config already exists (`.exists` error), the `else` branch executes `return`, exiting the entire test function before the manifest and index are pushed. Additionally, `imgConfigDesc` is never assigned in this path, so if control somehow continued past the guard it would force-unwrap nil at `config: imgConfigDesc!` on the next step.
            guard err.code == .exists else {
                throw err
            }
            imgConfigDesc = manifest.config
        }

        // Push the image manifest.
        // Flagged #6: HIGH: `pushIndex` crashes on nil `manifest.mediaType` instead of failing the test gracefully
        // `manifest.mediaType` is `String?` (optional per the OCI spec). The code passes it directly as `mediaType: manifest.mediaType!` when constructing the new `Manifest` value. Because `#expect` is not used and there is no nil check, the force-unwrap causes a fatal nil dereference crash if the fetched manifest omits the `mediaType` field. The pattern is identical to the already-flagged `OutputStream`, `manifestDescriptor`, and `manifest.layers.first` crashes elsewhere in the same test.
        let newManifest = Manifest(
            schemaVersion: manifest.schemaVersion,
            mediaType: try #require(manifest.mediaType),
            config: imgConfigDesc!,
            layers: manifest.layers,
            annotations: manifest.annotations
        )
        let manifestDesc = try await self.pushDescriptor(
            client: client,
            name: name,
            ref: ref,
            content: newManifest,
            // Flagged #3 (2 of 2)
            baseDescriptor: try #require(manifestDescriptor)
        )

        // Push the index.
        let newIndex = Index(
            schemaVersion: index.schemaVersion,
            mediaType: index.mediaType,
            manifests: [manifestDesc],
            annotations: index.annotations
        )
        try await self.pushDescriptor(
            client: client,
            name: name,
            ref: ref,
            content: newIndex,
            baseDescriptor: indexDescriptor
        )
    }

    @Test func resolveWithRetry() async throws {
        let counter = Mutex(0)
        let client = RegistryClient(
            host: "ghcr.io",
            retryOptions: RetryOptions(
                maxRetries: 3,
                retryInterval: 500_000_000,
                shouldRetry: ({ response in
                    if response.status == .notFound {
                        counter.withLock { $0 += 1 }
                        return true
                    }
                    return false
                })
            )
        )
        do {
            _ = try await client.resolve(name: "containerization/not-exists", tag: "foo")
        } catch {
            #expect(counter.withLock { $0 } <= 3)
        }
    }

    // MARK: private functions

    static var hasRegistryCredentials: Bool {
        authentication != nil
    }

    static var authentication: Authentication? {
        let env = ProcessInfo.processInfo.environment
        guard let password = env["REGISTRY_TOKEN"],
            let username = env["REGISTRY_USERNAME"]
        else {
            return nil
        }
        return BasicAuthentication(username: username, password: password)
    }

    @discardableResult
    private func pushDescriptor<T: Encodable>(
        client: RegistryClient,
        name: String,
        ref: String,
        content: T,
        baseDescriptor: Descriptor
    ) async throws -> Descriptor {
        let encoded = try self.encoder.encode(content)
        let digest = SHA256.hash(data: encoded)
        let descriptor = Descriptor(
            mediaType: baseDescriptor.mediaType,
            digest: digest.digest,
            size: Int64(encoded.count),
            urls: baseDescriptor.urls,
            annotations: baseDescriptor.annotations,
            platform: baseDescriptor.platform
        )
        let generator = {
            let stream = ReadStream(data: encoded)
            try stream.reset()
            return stream.stream
        }

        try await client.push(
            name: name,
            ref: ref,
            descriptor: descriptor,
            streamGenerator: generator,
            progress: nil
        )
        return descriptor
    }
}

extension OutputStream {
    fileprivate func withThrowingOpeningStream(_ closure: () async throws -> Void) async throws {
        self.open()
        defer { self.close() }

        try await closure()
    }
}

extension SHA256.Digest {
    fileprivate var digest: String {
        let parts = self.description.split(separator: ": ")
        return "sha256:\(parts[1])"
    }
}
