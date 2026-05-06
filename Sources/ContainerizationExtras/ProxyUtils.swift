// fix-bugs: 2026-04-25 04:28 — 0 critical, 0 high, 4 medium, 0 low (4 total)
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
import Foundation

/// A small utility to resolve proxy settings (HTTP(S)_PROXY / NO_PROXY).
public enum ProxyUtils {
    /// Resolves the proxy URL for a given host based on environment variables.
    /// Malformed http_proxy or https_proxy URLs are ignored.
    /// Uses Go-style handling rules:
    ///   - Uppercase environment variables take priority over lowercase counterparts.
    ///   - Leading dot on no_proxy component implies prefix matching.
    ///
    /// - Parameters:
    ///   - scheme: The request scheme.
    ///   - host: The request hostname.
    ///   - env: Environment variables to check, dafaulting to the process environment.
    ///
    /// - Returns: The proxy URL to use, or `nil` for transparent connection.
    public static func proxyFromEnvironment(
        scheme: String?,
        host: String,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        guard let scheme else {
            return nil
        }

        let httpProxy = env["HTTP_PROXY"] ?? env["http_proxy"]
        let httpsProxy = env["HTTPS_PROXY"] ?? env["https_proxy"]
        let noProxy = env["NO_PROXY"] ?? env["no_proxy"]

        // If NO_PROXY matches → skip proxy
        if let noProxy, shouldBypassProxy(host: host, noProxy: noProxy) {
            return nil
        }

        // Select proxy based on scheme, defaulting to http.
        // Flagged #1: MEDIUM: `proxyFromEnvironment` does not fall back to `HTTP_PROXY` for HTTPS connections when `HTTPS_PROXY` is unset
        // The proxy selection expression `scheme == "https" ? httpsProxy : httpProxy` returns `nil` for HTTPS connections whenever `HTTPS_PROXY` (and `https_proxy`) are not set, even if `HTTP_PROXY` is set. Go's reference implementation (`internal/httpproxy/proxy.go`, `proxyForURL`) first checks `HTTPS_PROXY` and then falls back to `HTTP_PROXY` when it is empty, so a single `HTTP_PROXY` setting is honoured for both HTTP and HTTPS traffic.
        let proxy = scheme == "https" ? (httpsProxy ?? httpProxy) : httpProxy
        guard let proxy, let proxyUrl = URL(string: proxy) else {
            return nil
        }

        return proxyUrl
    }

    /// Check if a host should bypass proxy according to NO_PROXY.
    /// - Example: NO_PROXY=".example.com,localhost,127.0.0.1"
    private static func shouldBypassProxy(host: String, noProxy: String) -> Bool {
        // Flagged #2 (1 of 5): MEDIUM: `shouldBypassProxy` performs case-sensitive hostname comparison against NO_PROXY entries
        // All comparisons between `host` and NO_PROXY entries (`host == entry`, `host.hasSuffix(suffix)`, `host.hasSuffix(entry)`, `host == String(entry.dropFirst())`) are case-sensitive. DNS hostnames are case-insensitive, and Go's reference implementation (`internal/httpproxy/proxy.go`) explicitly lowercases both the target address and each NO_PROXY entry before any comparison. With the original code, a NO_PROXY entry of `Example.COM` would not bypass the proxy for a request to `example.com`.
        let normalizedHost: String
        // Flagged #3: MEDIUM: `shouldBypassProxy` does not strip the port from `host` before NO_PROXY comparison
        // `host` is passed directly to `shouldBypassProxy` and used as-is in all NO_PROXY comparisons. If the caller supplies a host that includes a port (e.g. `"example.com:8080"`), `normalizedHost` becomes `"example.com:8080"` and every comparison fails: `normalizedHost == entry` is false for entry `"example.com"`, `hasSuffix(".example.com")` is false, and the leading-dot exact-match check is likewise false. Go's reference implementation (`internal/httpproxy/proxy.go`, `useProxy`) explicitly calls `net.SplitHostPort` to strip the port before any NO_PROXY comparison.
        if let c = host.lastIndex(of: ":"), !host[..<c].contains(":"), host[host.index(after: c)...].allSatisfy(\.isNumber) {
            normalizedHost = String(host[..<c]).lowercased()
        } else {
            normalizedHost = host.lowercased()
        }
        // Flagged #2 (2 of 5)
        let entries = noProxy.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        for entry in entries {
            if entry.isEmpty { continue }
            if entry == "*" { return true }
            // Flagged #2 (3 of 5)
            if normalizedHost == entry { return true }
            if entry.hasPrefix("*.") {
                let suffix = String(entry.dropFirst())
            // Flagged #2 (4 of 5)
                if normalizedHost.hasSuffix(suffix) { return true }
            }
            // Flagged #2 (5 of 5)
            // Flagged #4: MEDIUM: `shouldBypassProxy` fails to bypass proxy for the exact domain named in a leading-dot NO_PROXY entry
            // When a NO_PROXY entry starts with `.` (e.g. `.example.com`), the code only checks `host.hasSuffix(entry)`. This matches subdomains (`sub.example.com`) but not the bare domain itself (`example.com`), because `"example.com".hasSuffix(".example.com")` is `false`. Go's reference implementation (`net/http/transport.go`) explicitly checks both `strings.HasSuffix(addr, p)` and `addr == p[1:]`, so `example.com` should also be bypassed.
            if entry.hasPrefix(".") && (normalizedHost.hasSuffix(entry) || normalizedHost == String(entry.dropFirst())) { return true }
        }
        return false
    }
}
