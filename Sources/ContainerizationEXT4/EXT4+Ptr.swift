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

import Foundation

extension EXT4 {
    class Ptr<T> {
        let underlying: UnsafeMutablePointer<T>
        private var capacity: Int
        private var initialized: Bool
        private var allocated: Bool

        var pointee: T {
            underlying.pointee
        }

        init(capacity: Int) {
            self.underlying = UnsafeMutablePointer<T>.allocate(capacity: capacity)
            self.capacity = capacity
            self.allocated = true
            self.initialized = false
        }

        static func allocate(capacity: Int) -> Ptr<T> {
            Ptr<T>(capacity: capacity)
        }

        func initialize(to value: T) {
            guard self.allocated else {
                return
            }
            if self.initialized {
                self.underlying.deinitialize(count: self.capacity)
            }
            self.underlying.initialize(to: value)
            self.allocated = true
            self.initialized = true
        }

        // Bug #15 (HIGH, 2 parts): (a) deallocate() called underlying.deallocate() without first calling
        // deinitialize(), leaking ARC-managed values (e.g. FileTreeNode.children Array) held in T.
        // (b) move() had no guard, allowing it to be called on uninitialized or deallocated memory,
        // causing undefined behaviour. Fixed by calling deinitialize in deallocate() and adding
        // an allocated && initialized guard to move().
        // Same fix: sonnet, sonnet-1m, sonnet-fix. All other branches leak ARC values on dealloc.
        func deallocate() {
            guard self.allocated else {
                return
            }
            if self.initialized {
                self.underlying.deinitialize(count: self.capacity)
                self.initialized = false
            }
            self.underlying.deallocate()
            self.allocated = false
        }

        func deinitialize(count: Int) {
            guard self.allocated else {
                return
            }
            guard self.initialized else {
                return
            }
            self.underlying.deinitialize(count: count)
            self.initialized = false
            self.allocated = true
        }

        func move() -> T {
            // Bug #15
            guard self.allocated && self.initialized else {
                fatalError("move() called on an uninitialized or deallocated Ptr")
            }
            self.initialized = false
            return self.underlying.move()
        }

        deinit {
            self.deinitialize(count: self.capacity)
            self.deallocate()
        }
    }
}
