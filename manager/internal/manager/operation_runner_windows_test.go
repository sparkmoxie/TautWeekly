//go:build windows

package manager

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestWindowsPreviewRunnerUsesFixedHeadlessArgumentsAndFilteredEnvironment(t *testing.T) {
	root := t.TempDir()
	configPath := filepath.Join(t.TempDir(), "operation.config.json")
	if err := os.WriteFile(configPath, []byte(`{"fixture":true}`), 0o600); err != nil {
		t.Fatal(err)
	}
	script := `param(
  [string]$Mode,
  [string]$UserId,
  [string]$ConfigPath,
  [string]$ResultPath,
  [switch]$NoOpen
)
if ($Mode -ne 'PreviewAll') { exit 21 }
if ($UserId -ne '42') { exit 22 }
if (-not $NoOpen) { exit 23 }
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { exit 24 }
if ($env:PLEX_TOKEN -or $env:TAUTWEEKLY_CONFIG -or $env:HTTP_PROXY -or $env:HTTPS_PROXY -or $env:ALL_PROXY -or $env:NO_PROXY) { exit 25 }
$output = Join-Path $PSScriptRoot 'output'
New-Item -ItemType Directory -Path $output -Force | Out-Null
Set-Content -LiteralPath (Join-Path $output 'preview-all-00-INDEX.html') -Value '<!doctype html><title>Fictional runner fixture</title>' -Encoding UTF8
$result = @{
  schemaVersion = 1
  mode = 'PreviewAll'
  outcome = 'succeeded'
  deliveryScope = 'none'
  startedAtUtc = '2031-04-18T16:30:00.0000000Z'
  finishedAtUtc = '2031-04-18T16:30:01.0000000Z'
  durationMs = 1000
  smtpAcceptedCount = 0
  skippedCount = 0
  failedCount = 0
  generatedPreviewFiles = @('preview-all-00-INDEX.html')
}
[IO.File]::WriteAllText($ResultPath, ($result | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
`
	if err := os.WriteFile(filepath.Join(root, "TautWeekly.ps1"), []byte(script), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PLEX_TOKEN", "must-not-reach-fixture")
	t.Setenv("TAUTWEEKLY_CONFIG", "must-not-reach-fixture")
	t.Setenv("HTTP_PROXY", "http://127.0.0.1:1")
	t.Setenv("HTTPS_PROXY", "http://127.0.0.1:1")
	t.Setenv("ALL_PROXY", "http://127.0.0.1:1")
	t.Setenv("NO_PROXY", "localhost")

	resultPath := filepath.Join(t.TempDir(), "operation.result.json")
	exitCode, err := (platformPreviewOperationRunner{}).RunPreviewAll(context.Background(), root, configPath, resultPath, "42")
	if err != nil || exitCode != 0 {
		t.Fatalf("preview runner: exit=%d err=%v", exitCode, err)
	}
	if _, err := os.Stat(filepath.Join(root, "output", "preview-all-00-INDEX.html")); err != nil {
		t.Fatalf("fixture preview was not generated: %v", err)
	}
	if _, err := os.Stat(resultPath); err != nil {
		t.Fatalf("fixture structured result was not generated: %v", err)
	}
}

func TestWindowsPreviewRunnerCancellationStopsPowerShell(t *testing.T) {
	root := t.TempDir()
	configPath := filepath.Join(t.TempDir(), "operation.config.json")
	if err := os.WriteFile(configPath, []byte(`{}`), 0o600); err != nil {
		t.Fatal(err)
	}
	script := `param(
  [string]$Mode,
  [string]$UserId,
  [string]$ConfigPath,
  [string]$ResultPath,
  [switch]$NoOpen
)
Start-Sleep -Seconds 30
Set-Content -LiteralPath (Join-Path $PSScriptRoot 'should-not-exist.txt') -Value 'completed'
`
	if err := os.WriteFile(filepath.Join(root, "TautWeekly.ps1"), []byte(script), 0o600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 350*time.Millisecond)
	defer cancel()
	exitCode, err := (platformPreviewOperationRunner{}).RunPreviewAll(ctx, root, configPath, filepath.Join(t.TempDir(), "operation.result.json"), "42")
	if !errors.Is(err, context.DeadlineExceeded) || exitCode != -1 {
		t.Fatalf("cancelled preview runner: exit=%d err=%v", exitCode, err)
	}
	if _, err := os.Stat(filepath.Join(root, "should-not-exist.txt")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("cancelled PowerShell completed unexpectedly: %v", err)
	}
}

func TestWindowsSendTestAllRunnerUsesFixedArgumentsAndFilteredEnvironment(t *testing.T) {
	root := t.TempDir()
	configPath := filepath.Join(t.TempDir(), "operation.config.json")
	if err := os.WriteFile(configPath, []byte(`{"fixture":true}`), 0o600); err != nil {
		t.Fatal(err)
	}
	script := `param(
  [string]$Mode,
  [string]$UserId,
  [string]$ConfigPath,
  [string]$ResultPath,
  [switch]$NoOpen
)
if ($Mode -ne 'SendTestAll') { exit 31 }
if ($UserId -ne '42') { exit 32 }
if ($NoOpen) { exit 33 }
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { exit 34 }
if ($env:PLEX_TOKEN -or $env:TAUTWEEKLY_CONFIG -or $env:HTTP_PROXY -or $env:HTTPS_PROXY -or $env:ALL_PROXY -or $env:NO_PROXY) { exit 35 }
$result = @{
  schemaVersion = 1
  mode = 'SendTestAll'
  outcome = 'succeeded'
  deliveryScope = 'test'
  startedAtUtc = '2031-04-18T16:30:00.0000000Z'
  finishedAtUtc = '2031-04-18T16:30:02.0000000Z'
  durationMs = 2000
  smtpAcceptedCount = 6
  skippedCount = 0
  failedCount = 0
  generatedPreviewFiles = @()
}
[IO.File]::WriteAllText($ResultPath, ($result | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
`
	if err := os.WriteFile(filepath.Join(root, "TautWeekly.ps1"), []byte(script), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PLEX_TOKEN", "must-not-reach-fixture")
	t.Setenv("TAUTWEEKLY_CONFIG", "must-not-reach-fixture")
	t.Setenv("HTTP_PROXY", "http://127.0.0.1:1")
	t.Setenv("HTTPS_PROXY", "http://127.0.0.1:1")
	t.Setenv("ALL_PROXY", "http://127.0.0.1:1")
	t.Setenv("NO_PROXY", "localhost")

	resultPath := filepath.Join(t.TempDir(), "operation.result.json")
	exitCode, err := (platformPreviewOperationRunner{}).RunSendTestAll(context.Background(), root, configPath, resultPath, "42")
	if err != nil || exitCode != 0 {
		t.Fatalf("test-send runner: exit=%d err=%v", exitCode, err)
	}
	result, err := readRendererResult(resultPath, "SendTestAll")
	if err != nil {
		t.Fatalf("read test-send structured result: %v", err)
	}
	if result.SMTPAcceptedCount != 6 || result.DeliveryScope != "test" || len(result.GeneratedPreviewFiles) != 0 {
		t.Fatalf("unexpected test-send structured result: %+v", result)
	}
}

func TestWindowsSendAllRunnerRequiresFixedProductionConfirmation(t *testing.T) {
	root := t.TempDir()
	configPath := filepath.Join(t.TempDir(), "operation.config.json")
	if err := os.WriteFile(configPath, []byte(`{"fixture":true}`), 0o600); err != nil {
		t.Fatal(err)
	}
	script := `param(
  [string]$Mode,
  [string]$UserId,
  [string]$ConfigPath,
  [string]$ResultPath,
  [switch]$NoOpen,
  [switch]$ConfirmSendAll
)
if ($Mode -ne 'SendAll') { exit 41 }
if (-not [string]::IsNullOrWhiteSpace($UserId)) { exit 42 }
if ($NoOpen) { exit 43 }
if (-not $ConfirmSendAll) { exit 44 }
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { exit 45 }
if ($env:PLEX_TOKEN -or $env:TAUTWEEKLY_CONFIG -or $env:HTTP_PROXY -or $env:HTTPS_PROXY -or $env:ALL_PROXY -or $env:NO_PROXY) { exit 46 }
$result = @{
  schemaVersion = 1
  mode = 'SendAll'
  outcome = 'succeeded'
  deliveryScope = 'production'
  startedAtUtc = '2031-04-18T16:30:00.0000000Z'
  finishedAtUtc = '2031-04-18T16:30:02.0000000Z'
  durationMs = 2000
  smtpAcceptedCount = 4
  skippedCount = 2
  failedCount = 0
  generatedPreviewFiles = @()
}
[IO.File]::WriteAllText($ResultPath, ($result | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
`
	if err := os.WriteFile(filepath.Join(root, "TautWeekly.ps1"), []byte(script), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PLEX_TOKEN", "must-not-reach-fixture")
	t.Setenv("TAUTWEEKLY_CONFIG", "must-not-reach-fixture")
	t.Setenv("HTTP_PROXY", "http://127.0.0.1:1")
	t.Setenv("HTTPS_PROXY", "http://127.0.0.1:1")
	t.Setenv("ALL_PROXY", "http://127.0.0.1:1")
	t.Setenv("NO_PROXY", "localhost")

	resultPath := filepath.Join(t.TempDir(), "operation.result.json")
	exitCode, err := (platformPreviewOperationRunner{}).RunSendAll(context.Background(), root, configPath, resultPath)
	if err != nil || exitCode != 0 {
		t.Fatalf("production-send runner: exit=%d err=%v", exitCode, err)
	}
	result, err := readRendererResult(resultPath, "SendAll")
	if err != nil {
		t.Fatalf("read production structured result: %v", err)
	}
	if result.SMTPAcceptedCount != 4 || result.SkippedCount != 2 || result.DeliveryScope != "production" || len(result.GeneratedPreviewFiles) != 0 {
		t.Fatalf("unexpected production-send structured result: %+v", result)
	}
}

func TestWindowsSendWelcomeRunnerRequiresFixedUserAndConfirmation(t *testing.T) {
	root := t.TempDir()
	configPath := filepath.Join(t.TempDir(), "operation.config.json")
	if err := os.WriteFile(configPath, []byte(`{"fixture":true}`), 0o600); err != nil {
		t.Fatal(err)
	}
	script := `param(
  [string]$Mode,
  [string]$UserId,
  [string]$ConfigPath,
  [string]$ResultPath,
  [switch]$NoOpen,
  [switch]$ConfirmWelcome
)
if ($Mode -ne 'SendWelcome') { exit 51 }
if ($UserId -ne '42') { exit 52 }
if ($NoOpen) { exit 53 }
if (-not $ConfirmWelcome) { exit 54 }
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { exit 55 }
if ($env:PLEX_TOKEN -or $env:TAUTWEEKLY_CONFIG -or $env:HTTP_PROXY -or $env:HTTPS_PROXY -or $env:ALL_PROXY -or $env:NO_PROXY) { exit 56 }
$result = @{
  schemaVersion = 1
  mode = 'SendWelcome'
  outcome = 'succeeded'
  deliveryScope = 'welcome'
  startedAtUtc = '2031-04-18T16:30:00.0000000Z'
  finishedAtUtc = '2031-04-18T16:30:02.0000000Z'
  durationMs = 2000
  smtpAcceptedCount = 1
  skippedCount = 0
  failedCount = 0
  generatedPreviewFiles = @()
}
[IO.File]::WriteAllText($ResultPath, ($result | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
`
	if err := os.WriteFile(filepath.Join(root, "TautWeekly.ps1"), []byte(script), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PLEX_TOKEN", "must-not-reach-fixture")
	t.Setenv("TAUTWEEKLY_CONFIG", "must-not-reach-fixture")
	t.Setenv("HTTP_PROXY", "http://127.0.0.1:1")
	t.Setenv("HTTPS_PROXY", "http://127.0.0.1:1")
	t.Setenv("ALL_PROXY", "http://127.0.0.1:1")
	t.Setenv("NO_PROXY", "localhost")

	resultPath := filepath.Join(t.TempDir(), "operation.result.json")
	exitCode, err := (platformPreviewOperationRunner{}).RunSendWelcome(context.Background(), root, configPath, resultPath, "42")
	if err != nil || exitCode != 0 {
		t.Fatalf("Manual Welcome runner: exit=%d err=%v", exitCode, err)
	}
	result, err := readRendererResult(resultPath, "SendWelcome")
	if err != nil {
		t.Fatalf("read Manual Welcome structured result: %v", err)
	}
	if result.SMTPAcceptedCount != 1 || result.DeliveryScope != "welcome" || len(result.GeneratedPreviewFiles) != 0 {
		t.Fatalf("unexpected Manual Welcome structured result: %+v", result)
	}
}
