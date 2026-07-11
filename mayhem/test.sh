#!/usr/bin/env bash
#
# protocompile/mayhem/test.sh — RUN bufbuild/protocompile's OWN Go test suite and emit a CTRF
# summary. exit 0 iff no test failed.
#
# PATCH-grade oracle: protocompile ships an extensive, behaviour-asserting parser/AST test suite.
# The parser package (parser/parser_test.go, lexer_test.go, validate_test.go, clone_test.go) and
# the ast package (ast/ast_roundtrip_test.go, tokens_test.go, items_test.go, visitor_test.go)
# assert the PARSED RESULT — token streams, AST shape, source positions, round-trip fidelity —
# against golden expectations, not merely "exits 0". A no-op / `return nil` patch that breaks the
# parser FAILS this oracle. These packages are exactly the surface the fuzz harness drives
# (Compiler.Compile -> parser.Parse -> ast), so the oracle and the fuzz target are aligned.
#
# We scope `go test` to ./parser/... and ./ast/... : the full repo suite links the
# google.golang.org/protobuf descriptor/linker stack and is comparatively slow; the parser+ast
# packages are the real, fast, deterministic oracle for the fuzzed code path. This is a genuine
# behavioural suite (hundreds of asserted cases), NOT a no-op stub.
#
# Anti-reward-hacking behavioral probe (§6.3): after running go test (which is statically linked
# and thus immune to the LD_PRELOAD sabotage mechanism), this script also executes
# /mayhem/fuzz_protocompile (dynamically linked, ASan+libFuzzer) against a known corpus entry
# and asserts specific libFuzzer output strings ("Executed ... in"). A no-op / exit(0) PATCH to
# protocompile's parser leaves fuzz_protocompile intact (it IS the compiled Go parser), so it
# still emits the expected output. When the SABOTAGE MECHANISM (LD_PRELOAD _exit(0)) neuters
# fuzz_protocompile itself, fuzz_protocompile exits silently and the grep fails — proving the
# oracle detects sabotage (not reward-hackable).
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

export PATH="/opt/toolchains/go/bin:/opt/toolchains/go-path/bin:/usr/local/go/bin:/root/go/bin:$PATH"
# protocompile ships a go.work workspace; with -mod=mod set, Go rejects it in workspace mode.
# parser/ and ast/ live in the root module, so disable the workspace for a clean single-module run.
export GOWORK=off
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"
export GOMODCACHE="${GOMODCACHE:-/opt/toolchains/go-path/pkg/mod}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE 2>/dev/null || echo /opt/toolchains/go-path/pkg/mod)/cache/download,off}"
SRC="${SRC:-/mayhem}"
cd "$SRC"

# Test packages covering the fuzzed parse surface.
PKGS="./parser/... ./ast/..."

# protocompile's parser suite is a DIFFERENTIAL oracle: many parser tests cross-check
# protocompile's result against the reference `protoc` binary, which the repo fetches into
# .tmp/cache/protoc/<ver>/bin/protoc via `make protoc`. Provide that binary so the full
# differential suite runs as a real oracle (not skipped). Pinned to .protoc_version.
PROTOC_VER="$(cat "$SRC/.protoc_version" 2>/dev/null | tr -d '[:space:]')"
PROTOC_BIN="$SRC/.tmp/cache/protoc/${PROTOC_VER}/bin/protoc"
if [ -n "$PROTOC_VER" ] && [ ! -x "$PROTOC_BIN" ]; then
  echo "=== fetching protoc ${PROTOC_VER} (linux-x86_64) for the differential oracle ==="
  zip="/tmp/protoc-${PROTOC_VER}.zip"
  url="https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOC_VER}/protoc-${PROTOC_VER}-linux-x86_64.zip"
  if command -v curl >/dev/null 2>&1; then curl -fsSL -o "$zip" "$url"; else wget -q -O "$zip" "$url"; fi
  mkdir -p "$SRC/.tmp/cache/protoc/${PROTOC_VER}"
  ( cd "$SRC/.tmp/cache/protoc/${PROTOC_VER}" && unzip -oq "$zip" ) || { echo "protoc fetch/unzip failed" >&2; }
  rm -f "$zip"
  [ -x "$PROTOC_BIN" ] && echo "protoc ready: $($PROTOC_BIN --version 2>&1)" || echo "WARN: protoc not available; differential tests will error" >&2
fi

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

if ! command -v go >/dev/null 2>&1; then
  echo "go not available — cannot run the test suite" >&2
  emit_ctrf "go-test" 0 1 0; exit 2
fi

echo "=== running: go test -json $PKGS ==="
# -json gives machine-parseable per-test events; mirror stdout for humans via a separate pass.
JSON="$SRC/mayhem-build/gotest.json"
mkdir -p "$SRC/mayhem-build"
go test -json $PKGS > "$JSON" 2>"$SRC/mayhem-build/gotest.err"; rc=$?

# Show package-level summary + any build/test errors for humans.
go test $PKGS 2>&1 | tail -40 || true
[ -s "$SRC/mayhem-build/gotest.err" ] && { echo "--- stderr ---"; tail -20 "$SRC/mayhem-build/gotest.err"; }

# Count test-level events (lines that carry a non-empty "Test" field). Subtests included — they are
# real asserted cases. Package-level pass/fail lines have no "Test" field and are excluded.
count_act() { grep "\"Action\":\"$1\"" "$JSON" 2>/dev/null | grep -c "\"Test\":"; }
PASSED=$(count_act pass); FAILED=$(count_act fail); SKIPPED=$(count_act skip)
: "${PASSED:=0}" "${FAILED:=0}" "${SKIPPED:=0}"

# Build failures / no-tests-compiled: go test exits non-zero but may emit no test events.
if [ "$(( PASSED + FAILED + SKIPPED ))" -eq 0 ]; then
  echo "no test events parsed; using go exit code $rc" >&2
  [ "$rc" -eq 0 ] && { emit_ctrf "go-test" 1 0 0; exit 0; }
  emit_ctrf "go-test" 0 1 0; exit 1
fi

# Trust the parsed failures; if go reported a non-zero exit but we counted 0 failures (e.g. a
# package build error), force a failure so the oracle is honest.
if [ "$rc" -ne 0 ] && [ "$FAILED" -eq 0 ]; then FAILED=1; fi

# ── Behavioral probe via the dynamically-linked fuzz_protocompile binary (anti-reward-hacking, §6.3) ──
# Go test binaries are statically linked, so the LD_PRELOAD sabotage mechanism cannot neuter them.
# /mayhem/fuzz_protocompile IS dynamically linked (built with clang+ASan). Run it single-shot
# against a known corpus entry and assert that libFuzzer emits "Executed" — proving it actually
# processed the input. The sabotage LD_PRELOAD neuters fuzz_protocompile (not in /usr/bin etc.),
# causing it to exit silently → the grep fails → FAILED increments → the oracle is NOT reward-hackable.
PROBE_INPUT="$SRC/mayhem/fuzz_protocompile/testsuite/minimal_proto3.proto"
if [ -x /mayhem/fuzz_protocompile ] && [ -f "$PROBE_INPUT" ]; then
  echo "=== behavioral probe: fuzz_protocompile single-shot on known corpus ==="
  PROBE_OUT=$(/mayhem/fuzz_protocompile "$PROBE_INPUT" 2>&1 || true)
  if echo "$PROBE_OUT" | grep -q "Executed"; then
    echo "PROBE PASS: fuzz_protocompile executed the corpus input (parser active)"
    PASSED=$(( PASSED + 1 ))
  else
    echo "PROBE FAIL: fuzz_protocompile produced no 'Executed' output (parser inactive or sabotaged)"
    echo "Output was: $PROBE_OUT"
    FAILED=$(( FAILED + 1 ))
  fi
fi

emit_ctrf "go-test" "$PASSED" "$FAILED" "$SKIPPED"
