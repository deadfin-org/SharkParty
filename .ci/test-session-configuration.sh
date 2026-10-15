#!/bin/bash
set -euo pipefail

test_root="$(mktemp -d "${TMPDIR:-/tmp}/sharkparty-session-tests.XXXXXX")"
trap 'rm -rf -- "$test_root"' EXIT

swiftc \
  -module-cache-path "$test_root/module-cache" \
  Shared/Services/UserSession/UserSessionConfiguration.swift \
  Tests/UserSessionConfiguration/main.swift \
  -o "$test_root/session-tests"
"$test_root/session-tests"
