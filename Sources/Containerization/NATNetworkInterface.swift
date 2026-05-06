// fix-bugs: 2026-04-24 11:29 — 1 total
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

import vmnet
import Virtualization
import ContainerizationError
import ContainerizationExtras
import Synchronization

/// An interface that uses NAT to provide an IP address for a given
/// container/virtual machine.
@available(macOS 26, *)
public final class NATNetworkInterface: Interface, Sendable {
    public let ipv4Address: CIDRv4
    public let ipv4Gateway: IPv4Address?
    public let macAddress: MACAddress?
    public let mtu: UInt32

    @available(macOS 26, *)
    // Flagged #1 (1 of 2): CRITICAL: `NATNetworkInterface.device()` crashes with a nil dereference when `reference` is unset
    // `reference` is declared as an implicitly-unwrapped optional (`vmnet_network_ref!`). The deprecated
    //   `init(ipv4Address:ipv4Gateway:macAddress:)` sets it to `nil`. `device()` passed `self.reference` directly
    //   to `VZVmnetNetworkDeviceAttachment(network:)`, which force-unwraps it at the call site, crashing when
    //   `reference` is `nil`.
    public nonisolated(unsafe) let reference: vmnet_network_ref?

    @available(macOS 26, *)
    public init(
        ipv4Address: CIDRv4,
        ipv4Gateway: IPv4Address?,
        reference: sending vmnet_network_ref,
        macAddress: MACAddress? = nil,
        mtu: UInt32 = 1500
    ) {
        self.ipv4Address = ipv4Address
        self.ipv4Gateway = ipv4Gateway
        self.macAddress = macAddress
        self.mtu = mtu
        self.reference = reference
    }

    @available(macOS, obsoleted: 26, message: "Use init(ipv4Address:ipv4Gateway:reference:macAddress:) instead")
    public init(
        ipv4Address: CIDRv4,
        ipv4Gateway: IPv4Address?,
        macAddress: MACAddress? = nil,
        mtu: UInt32 = 1500
    ) {
        self.ipv4Address = ipv4Address
        self.ipv4Gateway = ipv4Gateway
        self.macAddress = macAddress
        self.mtu = mtu
        self.reference = nil
    }
}

@available(macOS 26, *)
extension NATNetworkInterface: VZInterface {
    public func device() throws -> VZVirtioNetworkDeviceConfiguration {
        // Flagged #1 (2 of 2)
        guard let ref = self.reference else {
            throw ContainerizationError(.invalidState, message: "NATNetworkInterface has no network reference")
        }
        let config = VZVirtioNetworkDeviceConfiguration()
        if let macAddress = self.macAddress {
            guard let mac = VZMACAddress(string: macAddress.description) else {
                throw ContainerizationError(.invalidArgument, message: "invalid mac address \(macAddress)")
            }
            config.macAddress = mac
        }

        config.attachment = VZVmnetNetworkDeviceAttachment(network: ref)
        return config
    }
}

#endif
