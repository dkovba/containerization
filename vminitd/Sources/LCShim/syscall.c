// fix-bugs: 2026-04-24 10:31 — 0 critical, 0 high, 0 medium, 2 low (2 total)
/*
 * Copyright © 2025-2026 Apple Inc. and the Containerization project authors.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <unistd.h>

#include "syscall.h"

int CZ_pivot_root(const char *new_root, const char *put_old) {
  return syscall(SYS_pivot_root, new_root, put_old);
}

// Flagged #1: `CZ_set_sub_reaper` defined with empty parameter list instead of `void`
// The function was defined as `int CZ_set_sub_reaper()`. In C (unlike C++), an empty parameter list `()` is an old-style K&R declarator meaning the parameter types are *unspecified*, not that the function takes zero arguments. This does not form a proper prototype, so the compiler cannot reject call sites that pass spurious arguments, and the behaviour of such calls is undefined per C11 §6.5.2.2/6.
int CZ_set_sub_reaper(void) { return prctl(PR_SET_CHILD_SUBREAPER, 1); }

int CZ_pidfd_open(pid_t pid, unsigned int flags) {
  // Musl doesn't have pidfd_open.
  return syscall(SYS_pidfd_open, pid, flags);
}

int CZ_pidfd_getfd(int pidfd, int targetfd, unsigned int flags) {
  // Musl doesn't have pidfd_getfd.
  return syscall(SYS_pidfd_getfd, pidfd, targetfd, flags);
}

// Flagged #2: `CZ_prctl_set_no_new_privs` defined with empty parameter list instead of `void`
// The function was defined as `int CZ_prctl_set_no_new_privs()`. The same C-standard issue applies as for `CZ_set_sub_reaper`: `()` means unspecified parameters in C, not zero parameters, and therefore does not constitute a prototype.
int CZ_prctl_set_no_new_privs(void) {
  return prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0);
}

int CZ_setrlimit(int resource, unsigned long long soft,
                 unsigned long long hard) {
  struct rlimit limit;
  limit.rlim_cur = (rlim_t)soft;
  limit.rlim_max = (rlim_t)hard;
  return setrlimit(resource, &limit);
}
