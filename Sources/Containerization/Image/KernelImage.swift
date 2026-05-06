// fix-bugs: 2026-04-24 11:29 — 2 total
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

import ContainerizationError
import ContainerizationOCI
import Foundation

/// A multi-arch kernel image represented by an OCI image.
public struct KernelImage: Sendable {
    /// The media type for a kernel image.
    public static let mediaType = "application/vnd.apple.containerization.kernel"

    /// The name or reference of the image.
    public var name: String { image.reference }

    let image: Image

    public init(image: Image) {
        self.image = image
    }
}

extension KernelImage {
    /// Return the kernel from a multi arch image for a specific system platform.
    public func kernel(for platform: SystemPlatform) async throws -> Kernel {
        let manifest = try await image.manifest(for: platform.ociPlatform())
        guard let descriptor = manifest.layers.first, descriptor.mediaType == Self.mediaType else {
            throw ContainerizationError(.notFound, message: "kernel descriptor for \(platform) not found")
        }
        let content = try await image.getContent(digest: descriptor.digest)
        return Kernel(
            path: content.path,
            platform: platform
        )
    }

    /// Create a new kernel image with the reference as the name.
    /// This will create a multi arch image containing kernel's for each provided architecture.
    public static func create(reference: String, binaries: [Kernel], labels: [String: String] = [:], imageStore: ImageStore, contentStore: ContentStore) async throws -> KernelImage
    {
        let indexDescriptorStore = AsyncStore<Descriptor>()
        try await contentStore.ingest { ingestPath in
            var descriptors = [Descriptor]()
            let writer = try ContentWriter(for: ingestPath)

            for kernel in binaries {
                var result = try writer.create(from: kernel.path)
                let platform = kernel.platform.ociPlatform()
                // Flagged #1: LOW: `KernelImage.create` sets `platform` on layer descriptors
                // The layer descriptor passed `platform: platform` to `Descriptor(...)`. Per the OCI
                //   image spec, the `platform` field belongs on manifest descriptors within an index, not
                //   on layer descriptors within a manifest. Including it on a layer descriptor produces a
                //   non-conformant OCI image that may confuse container runtimes or registry tooling when
                //   inspecting or pulling kernel images.
                // Flagged #2: LOW: `KernelImage` attaches a `platform` field to a layer descriptor
                // The `Descriptor` for the kernel image layer was constructed with `platform: platform`.
                //   Per the OCI image spec, `platform` is only valid on manifest-index entries; layer
                //   descriptors must not carry it. Strict OCI registry clients or validation tools reject
                //   such descriptors.
                let layerDescriptor = Descriptor(
                    mediaType: mediaType,
                    digest: result.digest.digestString,
                    size: result.size)
                let rootfsConfig = ContainerizationOCI.Rootfs(type: "layers", diffIDs: [result.digest.digestString])
                let runtimeConfig = ContainerizationOCI.ImageConfig(labels: labels)
                let imageConfig = ContainerizationOCI.Image(architecture: platform.architecture, os: platform.os, config: runtimeConfig, rootfs: rootfsConfig)

                result = try writer.create(from: imageConfig)
                let configDescriptor = Descriptor(mediaType: ContainerizationOCI.MediaTypes.imageConfig, digest: result.digest.digestString, size: result.size)

                let manifest = Manifest(config: configDescriptor, layers: [layerDescriptor])
                result = try writer.create(from: manifest)
                let manifestDescriptor = Descriptor(
                    mediaType: ContainerizationOCI.MediaTypes.imageManifest, digest: result.digest.digestString, size: result.size, platform: platform)
                descriptors.append(manifestDescriptor)
            }
            let index = ContainerizationOCI.Index(manifests: descriptors)
            let result = try writer.create(from: index)
            let indexDescriptor = Descriptor(mediaType: ContainerizationOCI.MediaTypes.index, digest: result.digest.digestString, size: result.size)
            await indexDescriptorStore.set(indexDescriptor)
        }

        guard let indexDescriptor = await indexDescriptorStore.get() else {
            throw ContainerizationError(.notFound, message: "image for \(reference) not found")
        }

        let description = Image.Description(reference: reference, descriptor: indexDescriptor)
        let image = try await imageStore.create(description: description)
        return KernelImage(image: image)
    }
}
