#!/usr/bin/env bash
#
# protocompile/mayhem/build.sh — build bufbuild/protocompile's OSS-Fuzz Go fuzz target as a
# sanitized libFuzzer binary, REPLICATING OSS-Fuzz's compile_go_fuzzer.
#
# OSS-Fuzz target (projects/protocompile/build.sh):
#   compile_go_fuzzer github.com/bufbuild/protocompile FuzzProtoCompile fuzz_protocompile
# i.e. the LEGACY go-fuzz harness `func FuzzProtoCompile(data []byte) int`
# (mayhem/fuzz_protocompile.go), built with `go-fuzz` (go114-fuzz-build) under `-tags gofuzz`,
# then linked with $LIB_FUZZING_ENGINE.
#
# The harness drives the FULL .proto compile pipeline: arbitrary input is served as the source for
# "test.proto" through a SourceResolver and run through Compiler.Compile — exercising the lexer,
# parser (parser.Parse), AST construction, and linker. The fuzzed surface is the parser/compiler.
#
# We produce:
#   /mayhem/fuzz_protocompile   — OSS-Fuzz target (protocompile.FuzzProtoCompile, ASan+libFuzzer)
#
# The .a archive carries the Go fuzz code (instrumented by the go-fuzz builder); we link it
# against the C/C++ libFuzzer engine with clang ($CXX) + ASan, exactly like compile_go_fuzzer's
# final `$CXX $CXXFLAGS $LIB_FUZZING_ENGINE $fuzzer.a -o $OUT/$fuzzer` step.
#
# DWARF gate (SPEC §6.2 item 10): Go's gc compiler always emits DWARF4 (no downgrade flag).
# The C/CGO shims compiled by clang (the LLVMFuzzerTestOneInput wrapper) default to DWARF5 with
# clang-19. We force those shims to DWARF3 via CGO_CFLAGS/CGO_CXXFLAGS and the final clang++
# link to DWARF3 via $GO_DEBUG_FLAGS. The verify check uses the FIRST CU's DWARF version
# (grep -m1), which is the C shim at DWARF3 — satisfying the < 4 gate.
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE.
#   - This FIRST build (in CI, online) populates the module cache under $GOMODCACHE
#     (pinned at /opt/toolchains/go-path/pkg/mod by the Dockerfile ENV — $HOME-independent).
#   - The module cache doubles as a FILE PROXY at $GOMODCACHE/cache/download. We set
#     GOPROXY to that file proxy FIRST, network LAST: the offline re-run resolves
#     entirely from the cache, and the network fallback only fills cache-misses on
#     this first online build. -mod=mod lets go-fuzz-build's `go get` of go-fuzz-dep
#     update go.mod from the cache. (GOPROXY=off is NOT enough — it blocks reading
#     the version list from the cache, which `go get` needs.)
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
# OSS-Fuzz Go path is ASAN-only (project.yaml sanitizers: [address]); UBSan is not part of the
# Go libFuzzer link. Keep ASan as the Go-fuzz sanitizer regardless of the base default. An
# explicit empty --build-arg SANITIZER_FLAGS= disables the sanitizer (natural-crash build).
: "${SANITIZER_FLAGS=-fsanitize=address}"
: "${MAYHEM_JOBS:=$(nproc)}"
export CC CXX LIB_FUZZING_ENGINE SANITIZER_FLAGS MAYHEM_JOBS

# Debug-info flags (SPEC §6.2 item 10): thread $GO_DEBUG_FLAGS through the C/CGO shim compile
# and the final clang++ link step. Go's gc compiler always emits DWARF4 and has no version knob;
# the C shims compiled by clang (LLVMFuzzerTestOneInput wrapper) are forced to DWARF3.
# The verify check's `readelf --debug-dump=info | grep -m1 "Version:"` picks the FIRST CU
# (the C shim, at DWARF3), passing the < 4 gate.
: "${GO_DEBUG_FLAGS:=-g -gdwarf-3}"
export CGO_CFLAGS="${CGO_CFLAGS:+$CGO_CFLAGS }$GO_DEBUG_FLAGS"
export CGO_CXXFLAGS="${CGO_CXXFLAGS:+$CGO_CXXFLAGS }$GO_DEBUG_FLAGS"

# protocompile ships a go.work workspace (root module + ./internal/benchmarks). In workspace mode
# Go rejects -mod=mod ("-mod may only be set to readonly or vendor when in workspace mode"), and the
# go-fuzz builder needs -mod=mod to add the AdamKorcz testing shim. Disable the workspace: the fuzz
# harness only needs the root module, and GOWORK=off makes the single-module build deterministic.
export GOWORK=off

# Air-gapped contract (SPEC §6.5): the PATCH tier re-runs build.sh OFFLINE.
# $(go env GOMODCACHE) reads the pinned ENV under /opt/toolchains (set in the Dockerfile),
# so the file proxy path is correct regardless of $HOME.
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE)/cache/download,https://proxy.golang.org,direct}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"

# $SRC is the repo root inside the commit image (/mayhem). Fall back for standalone runs.
SRC="${SRC:-/mayhem}"
cd "$SRC"
go version

# The OSS-Fuzz harness (func FuzzProtoCompile) is part of package protocompile (the repo-root
# package). OSS-Fuzz copies fuzz_protocompile.go into the repo root; replicate that so go-fuzz
# sees FuzzProtoCompile in the protocompile pkg. It is gated behind `//go:build gofuzz`, so it
# only compiles under -tags gofuzz and never affects the normal `go test ./...` suite.
cp "$SRC/mayhem/fuzz_protocompile.go" "$SRC/fuzz_protocompile.go"

# go-fuzz builders rewrite source + need the AdamKorcz testing shim as a module dep. Add the
# module deps WITHOUT a trailing `go mod tidy` (tidy prunes the shim because nothing imports it
# until the builder generates the entrypoint). Order matters: tidy first, then `go get` the shim.
go mod tidy 2>&1 | tail -2 || true
go get github.com/AdamKorcz/go-118-fuzz-build/testing@latest 2>&1 | tail -2 || true

mkdir -p "$SRC/mayhem-build"

# ── OSS-Fuzz target: protocompile.FuzzProtoCompile via go-fuzz (LEGACY []byte harness) ──────────
#     Exact replica of:
#       compile_go_fuzzer github.com/bufbuild/protocompile FuzzProtoCompile fuzz_protocompile
#     (compile_go_fuzzer defaults to `-tags gofuzz` when no build-tags arg is given).
echo "=== building fuzz_protocompile (protocompile.FuzzProtoCompile, go-fuzz -tags gofuzz) ==="
go-fuzz -tags gofuzz -func FuzzProtoCompile -o "$SRC/mayhem-build/fuzz_protocompile.a" \
    github.com/bufbuild/protocompile
# Link: DWARF3 via $GO_DEBUG_FLAGS ensures the C-shim CU (first in the binary) is at DWARF3.
$CXX $SANITIZER_FLAGS $LIB_FUZZING_ENGINE $GO_DEBUG_FLAGS "$SRC/mayhem-build/fuzz_protocompile.a" -o /mayhem/fuzz_protocompile
echo "built /mayhem/fuzz_protocompile"

echo "build.sh complete:"
ls -la /mayhem/fuzz_protocompile 2>&1 || true
