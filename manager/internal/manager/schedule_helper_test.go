package manager

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestPackagedScheduleHelperRemainsTypedRevisionCheckedAndOwnershipGuarded(t *testing.T) {
	_, currentFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("locate schedule helper test")
	}
	helperPath := filepath.Clean(filepath.Join(filepath.Dir(currentFile), "..", "..", "..", "platforms", "windows", "SCHEDULE-HELPER.ps1"))
	raw, err := os.ReadFile(helperPath)
	if err != nil {
		t.Fatal(err)
	}
	script := string(raw)
	for _, required := range []string{
		`[ValidateSet("Install", "Enable", "Disable", "Remove")]`,
		`[ValidatePattern("^[0-9a-fA-F]{64}$")]`,
		`[ValidatePattern("^S-\d-\d+(-\d+)+$")]`,
		"Get-FileSha256",
		"Test-OwnedTask",
		"Grant-TaskReadAccess",
		`"D:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;GR;;;$ReaderSid)"`,
		"-Verb RunAs",
		`"-File", $helperPathArgument`,
		"$helperPathArgument = [char]34 + $PSCommandPath + [char]34",
		"-WorkingDirectory $PSScriptRoot",
		"$process.WaitForExit()",
		"$process.Refresh()",
		"$childExitCode = [int]$process.ExitCode",
		"$failureExitCode = 28",
		"$failureExitCode = 29",
		"$failureExitCode = 30",
		"$failureExitCode = 31",
		"$failureExitCode = 32",
		"ExpectedRevision",
		"Exit-ScheduleHelper 23",
	} {
		if !strings.Contains(script, required) {
			t.Fatalf("schedule helper is missing safety contract %q", required)
		}
	}
	for _, forbidden := range []string{"Invoke-Expression", "cmd.exe", ".bat", "-EncodedCommand", "$quotedScript"} {
		if strings.Contains(strings.ToLower(script), strings.ToLower(forbidden)) {
			t.Fatalf("schedule helper contains forbidden dynamic execution surface %q", forbidden)
		}
	}
}
