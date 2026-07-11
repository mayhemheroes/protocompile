// Copyright 2024 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// This is the OSS-Fuzz harness for bufbuild/protocompile (OSS-Fuzz project
// "protocompile", target func FuzzProtoCompile). It is a LEGACY go-fuzz harness:
//   func FuzzProtoCompile(data []byte) int   -> built with go114-fuzz-build (`go-fuzz`).
//
// It lives in package protocompile (the repo-root package) and is gated behind the
// `gofuzz` build tag so it only compiles for the fuzz build (matching OSS-Fuzz's
// `compile_go_fuzzer github.com/bufbuild/protocompile FuzzProtoCompile fuzz_protocompile`)
// and never pollutes the normal `go test ./...` suite.
//
// The fuzzed surface is the full .proto compile pipeline: the arbitrary input is
// served as the source for "test.proto" and run through Compiler.Compile, which
// drives the lexer, parser (parser.Parse), AST construction, and linker.

//go:build gofuzz
// +build gofuzz

package protocompile

import (
	"bytes"
	"context"
	"io"
)

func FuzzProtoCompile(data []byte) int {
	compiler := &Compiler{
		Resolver: &SourceResolver{
			Accessor: func(_ string) (closer io.ReadCloser, e error) {
				return io.NopCloser(bytes.NewReader(data)), nil
			},
		},
	}

	_, err := compiler.Compile(context.Background(), "test.proto")
	if err != nil {
		return 0
	}
	return 1
}
