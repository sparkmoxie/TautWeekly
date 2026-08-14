//go:build windows

package manager

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestWindowsScheduleRunnerUsesFixedArgumentsFilteredEnvironmentAndVerifiedPostcondition(t *testing.T) {
	root := t.TempDir()
	const revision = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	script := `param(
  [string]$Action,
  [string]$ExpectedRevision
)
if ($Action -ne 'Install') { exit 41 }
if ($ExpectedRevision -cne '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef') { exit 42 }
if ($args.Count -ne 0) { exit 43 }
if ($env:PLEX_TOKEN -or $env:TAUTWEEKLY_CONFIG -or $env:HTTP_PROXY -or $env:HTTPS_PROXY -or $env:ALL_PROXY -or $env:NO_PROXY) { exit 44 }
exit 0
`
	if err := os.WriteFile(filepath.Join(root, "SCHEDULE-HELPER.ps1"), []byte(script), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PLEX_TOKEN", "must-not-reach-fixture")
	t.Setenv("TAUTWEEKLY_CONFIG", "must-not-reach-fixture")
	t.Setenv("HTTP_PROXY", "http://127.0.0.1:1")
	t.Setenv("HTTPS_PROXY", "http://127.0.0.1:1")
	t.Setenv("ALL_PROXY", "http://127.0.0.1:1")
	t.Setenv("NO_PROXY", "localhost")

	probeCalls := 0
	runner := platformScheduleMutationRunner{probe: func(_ context.Context, taskName, probeRoot string) (windowsTaskProbe, error) {
		probeCalls++
		if taskName != "Fictional owned task" || probeRoot != root {
			t.Fatalf("unexpected postcondition probe: task=%q root=%q", taskName, probeRoot)
		}
		return windowsTaskProbe{Installed: true, Enabled: true, Owned: true, Ownership: "verified", State: "Ready"}, nil
	}}
	exitCode, err := runner.Run(context.Background(), root, "install", revision, "Fictional owned task")
	if err != nil || exitCode != 0 {
		t.Fatalf("schedule runner: exit=%d err=%v", exitCode, err)
	}
	if probeCalls != 1 {
		t.Fatalf("postcondition probe calls: got %d, want 1", probeCalls)
	}
}

func TestWindowsScheduleRunnerRejectsInvalidRevisionBeforeLaunchingHelper(t *testing.T) {
	root := t.TempDir()
	marker := filepath.Join(root, "must-not-run.txt")
	script := `Set-Content -LiteralPath '` + strings.ReplaceAll(marker, `'`, `''`) + `' -Value 'unsafe'`
	if err := os.WriteFile(filepath.Join(root, "SCHEDULE-HELPER.ps1"), []byte(script), 0o600); err != nil {
		t.Fatal(err)
	}
	runner := platformScheduleMutationRunner{probe: func(context.Context, string, string) (windowsTaskProbe, error) {
		t.Fatal("postcondition probe ran for an invalid request")
		return windowsTaskProbe{}, nil
	}}
	if _, err := runner.Run(context.Background(), root, "install", strings.Repeat("z", 64), "Fictional task"); err == nil {
		t.Fatal("invalid revision was accepted")
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatalf("helper ran for invalid input: %v", err)
	}
}

func TestSchedulePostconditionsRequireVerifiedOwnership(t *testing.T) {
	cases := []struct {
		action string
		probe  windowsTaskProbe
		want   bool
	}{
		{action: "install", probe: windowsTaskProbe{Installed: true, Enabled: true, Owned: true}, want: true},
		{action: "install", probe: windowsTaskProbe{Installed: true, Enabled: true, Owned: false}, want: false},
		{action: "enable", probe: windowsTaskProbe{Installed: true, Enabled: true, Owned: true}, want: true},
		{action: "disable", probe: windowsTaskProbe{Installed: true, Enabled: false, Owned: true}, want: true},
		{action: "disable", probe: windowsTaskProbe{Installed: true, Enabled: false, Owned: false}, want: false},
		{action: "remove", probe: windowsTaskProbe{Installed: false}, want: true},
		{action: "remove", probe: windowsTaskProbe{Installed: true, Owned: true}, want: false},
	}
	for _, test := range cases {
		if got := schedulePostcondition(test.action, test.probe); got != test.want {
			t.Errorf("schedulePostcondition(%q, %+v) = %v, want %v", test.action, test.probe, got, test.want)
		}
	}
}
