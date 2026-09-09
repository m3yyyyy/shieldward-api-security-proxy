package main

import (
	"bytes"
	"strings"
	"testing"
)

func TestVersionCommandReportsInjectedBuildVersion(t *testing.T) {
	originalVersion := version
	version = "1.2.3-test"
	t.Cleanup(func() {
		version = originalVersion
	})

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	if err := run(
		[]string{"version"},
		&stdout,
		&stderr,
	); err != nil {
		t.Fatalf("run(version) returned unexpected error: %v", err)
	}

	if actual := strings.TrimSpace(stdout.String()); actual != version {
		t.Fatalf(
			"run(version) output = %q; expected %q",
			actual,
			version,
		)
	}
	if stderr.Len() != 0 {
		t.Fatalf("run(version) stderr = %q; expected empty", stderr.String())
	}
}
