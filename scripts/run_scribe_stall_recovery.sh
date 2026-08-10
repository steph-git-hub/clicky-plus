#!/bin/bash
#
# run_scribe_stall_recovery.sh — v16r21 (2026-08-10)
#
# Compiles and runs the mock-WebSocket harness for the Scribe streaming
# session. XCTest is unusable in this project (leanring-buddyTests cannot
# link — FluidAudio/FastClusterWrapper clang error; TEST_HOST is stale;
# no shared scheme), so this follows the same standalone-swiftc pattern as
# verify_scribe_fatal_classifier.swift.
#
# The point is that it compiles the SHIPPED provider file. There is no
# transcribed copy of the session that can silently drift from the app.
#
# Usage:  ./scripts/run_scribe_stall_recovery.sh
# Exit:   0 = all checks passed, 1 = a check failed, 2 = build failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2

BUILD_DIR="$(mktemp -d /tmp/scribe-harness.XXXXXX)"
trap 'rm -rf "$BUILD_DIR"' EXIT

# BuddyTranscriptionProvider.swift holds the protocols the session
# conforms to, but its trailing factory enum references half a dozen other
# providers and will not link standalone. Slice off everything from the
# factory down, mechanically, at build time — deriving it here rather than
# keeping a hand-maintained duplicate that could drift.
awk '/^enum BuddyTranscriptionProviderFactory/{exit} {print}' \
    leanring-buddy/BuddyTranscriptionProvider.swift \
    > "$BUILD_DIR/BuddyProtocols.swift"

if ! grep -q "protocol BuddyStreamingTranscriptionSession" "$BUILD_DIR/BuddyProtocols.swift"; then
    echo "❌ Protocol extraction failed — BuddyTranscriptionProvider.swift has been restructured."
    echo "   Fix the awk slice in this script before trusting any result."
    exit 2
fi

echo "Building harness against the shipped provider…"
swiftc -o "$BUILD_DIR/harness" -parse-as-library \
    leanring-buddy/ScribeStreamingTranscriptionProvider.swift \
    leanring-buddy/ScribeFatalMessageClassifier.swift \
    leanring-buddy/BuddyAudioConversionSupport.swift \
    leanring-buddy/VTTLatencyDiag.swift \
    "$BUILD_DIR/BuddyProtocols.swift" \
    scripts/verify_scribe_stall_recovery.swift \
    2>"$BUILD_DIR/build.log"

if [ ! -x "$BUILD_DIR/harness" ]; then
    echo "❌ Build failed:"
    grep -E "error:" "$BUILD_DIR/build.log" | head -40
    exit 2
fi

"$BUILD_DIR/harness"
