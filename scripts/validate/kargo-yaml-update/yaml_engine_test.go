// Package kargoyamlupdate proves — against the ACTUAL pinned Kargo module
// version — that a Kargo `yaml-update` promotion step applied to our real
// checked-in fleet row mutates only the intended scalar and leaves the
// HUMAN-owned `values:` block byte-for-byte intact.
//
// # Why this is the real engine, not an imitation
//
// At the pinned version github.com/akuity/kargo v1.9.10, the promotion runner's
// yaml-update step (pkg/promotion/runner/builtin/yaml_updater.go) does this,
// verbatim:
//
//	func (y *yamlUpdater) run(...) {
//	    updates := make([]yaml.Update, len(cfg.Updates))
//	    for i, update := range cfg.Updates {
//	        updates[i] = yaml.Update{Key: update.Key, Value: update.Value}   // (1)
//	    }
//	    ... y.updateFile(stepCtx.WorkDir, cfg.Path, updates) ...
//	}
//
//	func (y *yamlUpdater) updateFile(workDir, path string, updates []yaml.Update) error {
//	    absValuesFile, _ := securejoin.SecureJoin(workDir, path)
//	    return yaml.SetValuesInFile(absValuesFile, updates)                   // (2)
//	}
//
// And in pkg/yaml/yaml.go, SetValuesInFile is a thin file wrapper:
//
//	func SetValuesInFile(file string, updates []Update) error {
//	    inBytes, _ := os.ReadFile(file)
//	    outBytes, _ := SetValuesInBytes(inBytes, updates)                    // (3)
//	    return os.WriteFile(file, outBytes, 0600)
//	}
//
// So the full delegation chain the controller actually executes is:
//
//	yamlUpdater.Run
//	  -> yamlUpdater.run        // builds []yaml.Update{Key, Value}   (1)
//	    -> yamlUpdater.updateFile
//	      -> yaml.SetValuesInFile // reads file bytes, writes result  (2)
//	        -> yaml.SetValuesInBytes // the pure mutation engine      (3)
//
// This test imports the same pinned module and drives the same public engine
// (`yaml.SetValuesInBytes` with `yaml.Update{Key: "pin.tag", ...}`) on the same
// row bytes. `SetValuesInBytes` is intentionally line-based: it locates the
// target scalar's line/column via findScalarNode, rewrites ONLY that one line,
// and streams every other line through a bufio.Scanner untouched. That is the
// mechanism our byte-for-byte `values:` guarantee relies on, and testing it at
// v1.9.10 tests the exact code a live promotion would run.
//
// The test never writes to the checked-in row; it operates purely on in-memory
// bytes via SetValuesInBytes (the pure engine that SetValuesInFile delegates
// to), so it is safe to run anywhere and mutates no repository state.
package kargoyamlupdate

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/akuity/kargo/pkg/yaml"
)

// rowRelPath is the real checked-in fleet row, relative to this package
// directory (scripts/validate/kargo-yaml-update -> repo root is three up).
const rowRelPath = "../../../platforms/canary/landscapes/raichu/dummy.yaml"

// readRow returns the raw bytes of the real row exactly as checked in.
func readRow(t *testing.T) []byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Clean(rowRelPath))
	if err != nil {
		t.Fatalf("reading real row %q: %v", rowRelPath, err)
	}
	if !bytes.Contains(b, []byte("\nvalues:")) {
		t.Fatalf("real row %q is missing the top-level values: block; test fixture drifted", rowRelPath)
	}
	return b
}

// rawTopLevelBlock captures a top-level YAML block (its key line plus every
// indented / blank / comment continuation line) byte-for-byte, preserving the
// exact original newlines. It is deliberately independent of the Kargo engine
// so it can act as an external byte-level oracle over the `values:` block.
func rawTopLevelBlock(src []byte, key string) []byte {
	prefix := []byte(key + ":")
	lines := bytes.SplitAfter(src, []byte("\n")) // keeps the trailing "\n" on each line
	var out bytes.Buffer
	inBlock := false
	for _, ln := range lines {
		if len(ln) == 0 {
			continue
		}
		firstCh := ln[0]
		isTopLevelKey := firstCh != ' ' && firstCh != '\t' && firstCh != '\n' &&
			firstCh != '\r' && firstCh != '#'
		if !inBlock {
			if bytes.HasPrefix(ln, prefix) {
				inBlock = true
				out.Write(ln)
			}
			continue
		}
		// Inside the block: a new top-level key (not our key, not a comment,
		// not blank) ends it. Indented lines, blank lines and comments belong.
		if isTopLevelKey && !bytes.HasPrefix(ln, prefix) {
			break
		}
		out.Write(ln)
	}
	return out.Bytes()
}

// lineDiffIndices returns the indices of lines that differ between a and b.
// It fails the test if the two inputs do not have the same number of lines,
// which by itself already proves no lines were inserted or removed.
func lineDiffIndices(t *testing.T, a, b []byte) []int {
	t.Helper()
	al := strings.Split(string(a), "\n")
	bl := strings.Split(string(b), "\n")
	if len(al) != len(bl) {
		t.Fatalf("line count changed: before=%d after=%d (engine must not add or drop lines)", len(al), len(bl))
	}
	var diffs []int
	for i := range al {
		if al[i] != bl[i] {
			diffs = append(diffs, i)
		}
	}
	return diffs
}

// TestPinTagUpdate_PreservesValuesBlockByteForByte is the positive proof: apply
// ONLY pin.tag through the real Kargo engine and show (a) the tag actually
// changed, (b) the raw values: block is byte-identical, and (c) exactly one
// line — the intended scalar line — differs, so all comments and style
// elsewhere survive verbatim.
func TestPinTagUpdate_PreservesValuesBlockByteForByte(t *testing.T) {
	orig := readRow(t)

	// Capture the HUMAN-owned values: block byte-for-byte BEFORE mutation.
	valuesBefore := rawTopLevelBlock(orig, "values")
	if len(valuesBefore) == 0 {
		t.Fatal("failed to capture the values: block from the real row")
	}
	if !bytes.Contains(valuesBefore, []byte("workload:")) ||
		!bytes.Contains(valuesBefore, []byte("replicas: 3")) {
		t.Fatalf("captured values: block does not look like the real fixture:\n%s", valuesBefore)
	}

	const newTag = "1.2.3"

	// This is exactly what the runner builds at (1) above.
	got, err := yaml.SetValuesInBytes(orig, []yaml.Update{
		{Key: "pin.tag", Value: newTag},
	})
	if err != nil {
		t.Fatalf("SetValuesInBytes(pin.tag) returned error: %v", err)
	}

	// (a) The tag must actually have changed.
	if bytes.Equal(orig, got) {
		t.Fatal("engine produced identical bytes; pin.tag was not applied")
	}
	if !bytes.Contains(got, []byte("tag: "+newTag)) {
		t.Fatalf("expected updated tag %q in output; got:\n%s", newTag, got)
	}
	if bytes.Contains(got, []byte("tag: 0.1.0")) {
		t.Fatal("old tag 0.1.0 still present after update")
	}

	// (b) The raw values: block must be byte-for-byte identical.
	valuesAfter := rawTopLevelBlock(got, "values")
	if !bytes.Equal(valuesBefore, valuesAfter) {
		t.Fatalf("values: block changed after a pin.tag update.\n--- before ---\n%q\n--- after ---\n%q",
			valuesBefore, valuesAfter)
	}

	// (c) Exactly one line changed, and it is the pin.tag scalar line. This
	// simultaneously proves every comment, the valuesMeta block, and all style
	// choices outside the target line are preserved verbatim.
	diffs := lineDiffIndices(t, orig, got)
	if len(diffs) != 1 {
		t.Fatalf("expected exactly 1 changed line, got %d (indices %v)", len(diffs), diffs)
	}
	changed := strings.Split(string(got), "\n")[diffs[0]]
	if strings.TrimSpace(changed) != "tag: "+newTag {
		t.Fatalf("the single changed line is not the pin.tag scalar: %q", changed)
	}

	// The row is nested `pin:\n  tag:`, so the changed line must be indented
	// (style of the surrounding document preserved).
	if !strings.HasPrefix(changed, "  ") {
		t.Fatalf("changed line lost its indentation: %q", changed)
	}
}

// TestReplicasUpdate_ByteGuardDetectsValuesChange is the negative proof: the
// SAME engine is used to update values.workload.replicas — a field INSIDE the
// human-owned block — and the byte-for-byte guard must flag the block as
// changed. This confirms the guard is real and not vacuously passing.
func TestReplicasUpdate_ByteGuardDetectsValuesChange(t *testing.T) {
	orig := readRow(t)
	valuesBefore := rawTopLevelBlock(orig, "values")

	got, err := yaml.SetValuesInBytes(orig, []yaml.Update{
		{Key: "values.workload.replicas", Value: 7},
	})
	if err != nil {
		t.Fatalf("SetValuesInBytes(values.workload.replicas) returned error: %v", err)
	}

	if !bytes.Contains(got, []byte("replicas: 7")) {
		t.Fatalf("expected replicas: 7 in output; got:\n%s", got)
	}

	valuesAfter := rawTopLevelBlock(got, "values")
	if bytes.Equal(valuesBefore, valuesAfter) {
		t.Fatal("byte guard FAILED to detect a change to the values: block; the guard is vacuous")
	}

	// The change must be confined to the values: block: pin.tag is untouched.
	if !bytes.Contains(got, []byte("tag: 0.1.0")) {
		t.Fatal("a values.* update unexpectedly disturbed the pin.tag scalar")
	}

	// And it must be a single-line change, just inside the guarded block.
	diffs := lineDiffIndices(t, orig, got)
	if len(diffs) != 1 {
		t.Fatalf("expected exactly 1 changed line, got %d (indices %v)", len(diffs), diffs)
	}
	if strings.TrimSpace(strings.Split(string(got), "\n")[diffs[0]]) != "replicas: 7" {
		t.Fatalf("unexpected changed line: %q", strings.Split(string(got), "\n")[diffs[0]])
	}
}

// TestInvalidUpdates_EngineRejects covers the cheap, high-value negatives that
// the real engine (findScalarNode) enforces: an update whose key does not
// exist, and one that addresses a non-scalar (mapping) node. In both cases the
// engine must return an error and the input bytes must be left untouched.
func TestInvalidUpdates_EngineRejects(t *testing.T) {
	orig := readRow(t)

	cases := []struct {
		name    string
		key     string
		wantSub string // substring the engine's error is expected to contain
	}{
		{
			name:    "missing key",
			key:     "pin.doesNotExist",
			wantSub: "key path not found",
		},
		{
			name:    "non-scalar node",
			key:     "pin", // addresses the mapping, not a scalar
			wantSub: "does not address a scalar node",
		},
		{
			name:    "descend past scalar",
			key:     "pin.tag.deeper",
			wantSub: "key path not found",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := yaml.SetValuesInBytes(orig, []yaml.Update{
				{Key: tc.key, Value: "irrelevant"},
			})
			if err == nil {
				t.Fatalf("expected error for key %q, got none (output:\n%s)", tc.key, got)
			}
			if !strings.Contains(err.Error(), tc.wantSub) {
				t.Fatalf("error for key %q = %q; want substring %q", tc.key, err.Error(), tc.wantSub)
			}
			if got != nil {
				t.Fatalf("engine returned non-nil bytes alongside an error for key %q", tc.key)
			}
		})
	}
}
