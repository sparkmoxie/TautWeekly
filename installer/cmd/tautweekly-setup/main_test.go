package main

import (
	"archive/zip"
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPathWithin(t *testing.T) {
	root := t.TempDir()
	if !pathWithin(root, filepath.Join(root, "child", "file")) {
		t.Fatal("expected child path to stay within root")
	}
	if pathWithin(root, filepath.Join(root, "..", "escape")) {
		t.Fatal("escape path was accepted")
	}
}

func TestParseOptionsRejectsOverlappingApplicationAndDataDirectories(t *testing.T) {
	root := t.TempDir()
	cases := [][]string{
		{"--install-dir", filepath.Join(root, "app"), "--data-dir", filepath.Join(root, "app", "data")},
		{"--install-dir", filepath.Join(root, "data", "app"), "--data-dir", filepath.Join(root, "data")},
	}
	for _, arguments := range cases {
		if _, err := parseOptions(arguments); err == nil {
			t.Fatalf("overlapping application and data directories were accepted: %v", arguments)
		}
	}
}

func TestInstalledDataDirectory(t *testing.T) {
	root := t.TempDir()
	expected := filepath.Join(t.TempDir(), "private-data")
	content := "Version=test\r\nDataDirectory=" + expected + "\r\n"
	if err := os.WriteFile(filepath.Join(root, "INSTALL-METADATA.txt"), []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	actual, err := installedDataDirectory(root)
	if err != nil {
		t.Fatal(err)
	}
	if actual != expected {
		t.Fatalf("stored data directory = %q, want %q", actual, expected)
	}
}

func TestParseOptionsReusesInstalledPrivateDataDirectory(t *testing.T) {
	root := t.TempDir()
	expected := filepath.Join(t.TempDir(), "TautWeekly Manager")
	metadata := "Version=test\r\nDataDirectory=" + expected + "\r\n"
	if err := os.WriteFile(filepath.Join(root, "INSTALL-METADATA.txt"), []byte(metadata), 0o600); err != nil {
		t.Fatal(err)
	}

	opts, err := parseOptions([]string{"--install-dir", root})
	if err != nil {
		t.Fatal(err)
	}
	if opts.dataDir != expected {
		t.Fatalf("update data directory = %q, want stored directory %q", opts.dataDir, expected)
	}
}

func TestParseOptionsExplicitPrivateDataDirectoryOverridesInstalledMetadata(t *testing.T) {
	root := t.TempDir()
	stored := filepath.Join(t.TempDir(), "stored-data")
	explicit := filepath.Join(t.TempDir(), "explicit-data")
	metadata := "Version=test\r\nDataDirectory=" + stored + "\r\n"
	if err := os.WriteFile(filepath.Join(root, "INSTALL-METADATA.txt"), []byte(metadata), 0o600); err != nil {
		t.Fatal(err)
	}

	opts, err := parseOptions([]string{"--install-dir", root, "--data-dir", explicit})
	if err != nil {
		t.Fatal(err)
	}
	if opts.dataDir != explicit {
		t.Fatalf("explicit data directory = %q, want %q", opts.dataDir, explicit)
	}
}

func TestInstallDirectorySelectionBypassesValidatedExistingInstall(t *testing.T) {
	installed := t.TempDir()
	if err := os.WriteFile(filepath.Join(installed, "INSTALL-METADATA.txt"), []byte("Version=test\r\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if requiresInstallDirectorySelection(options{installDir: installed}) {
		t.Fatal("validated existing installation still required the legacy folder picker")
	}

	newInstall := filepath.Join(t.TempDir(), "TautWeekly")
	if !requiresInstallDirectorySelection(options{installDir: newInstall}) {
		t.Fatal("new installation did not require application-folder selection")
	}
	if requiresInstallDirectorySelection(options{installDir: newInstall, installDirExplicit: true}) {
		t.Fatal("explicit installation directory still required interactive selection")
	}
	if requiresInstallDirectorySelection(options{installDir: newInstall, testMode: true}) {
		t.Fatal("installer test mode unexpectedly required interactive selection")
	}
}

func TestExtractPayloadRejectsTraversal(t *testing.T) {
	var buffer bytes.Buffer
	writer := zip.NewWriter(&buffer)
	entry, err := writer.Create("../escape.txt")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := entry.Write([]byte("unsafe")); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	original := payload
	payload = buffer.Bytes()
	t.Cleanup(func() { payload = original })
	if err := extractPayload(t.TempDir()); err == nil {
		t.Fatal("traversal payload was accepted")
	}
}

func TestRemoveOwnedInstallPreservesData(t *testing.T) {
	root := filepath.Join(t.TempDir(), "app")
	data := filepath.Join(t.TempDir(), "data")
	if err := os.MkdirAll(root, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(data, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "INSTALL-METADATA.txt"), []byte("owned"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "RELEASE-FILES.txt"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(data, "config.json"), []byte("private"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := removeOwnedInstall(root); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(root); !os.IsNotExist(err) {
		t.Fatalf("application root remains: %v", err)
	}
	if _, err := os.Stat(filepath.Join(data, "config.json")); err != nil {
		t.Fatalf("private data was removed: %v", err)
	}
}

func TestDisableInstalledRemoteAccessUsesOnlyFixedCleanupOperation(t *testing.T) {
	installDir := t.TempDir()
	dataDir := filepath.Join(t.TempDir(), "private-data")
	managerPath := filepath.Join(installDir, "tautweekly-manager.exe")
	if err := os.WriteFile(managerPath, []byte("fixture"), 0o600); err != nil {
		t.Fatal(err)
	}
	original := runInstalledRemoteCleanup
	t.Cleanup(func() { runInstalledRemoteCleanup = original })
	called := false
	runInstalledRemoteCleanup = func(actualManager, actualInstall, actualData string) error {
		called = true
		if actualManager != managerPath || actualInstall != installDir || actualData != dataDir {
			t.Fatalf("cleanup received unexpected paths: %q %q %q", actualManager, actualInstall, actualData)
		}
		return nil
	}
	if err := disableInstalledRemoteAccess(installDir, dataDir); err != nil {
		t.Fatal(err)
	}
	if !called {
		t.Fatal("installed Manager cleanup was not requested")
	}
}

func TestDisableInstalledRemoteAccessFailsClosedWhenVerificationFails(t *testing.T) {
	installDir := t.TempDir()
	managerPath := filepath.Join(installDir, "tautweekly-manager.exe")
	if err := os.WriteFile(managerPath, []byte("fixture"), 0o600); err != nil {
		t.Fatal(err)
	}
	original := runInstalledRemoteCleanup
	t.Cleanup(func() { runInstalledRemoteCleanup = original })
	runInstalledRemoteCleanup = func(string, string, string) error { return errors.New("fixture shutdown failure") }
	err := disableInstalledRemoteAccess(installDir, t.TempDir())
	if err == nil || !strings.Contains(err.Error(), "could not be disabled and verified") {
		t.Fatalf("uninstall did not fail closed: %v", err)
	}
}

func TestDisableInstalledRemoteAccessFailsClosedWhenManagerIsMissingButStateRemains(t *testing.T) {
	installDir := t.TempDir()
	dataDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dataDir, "windows-funnel.json"), []byte(`{"schemaVersion":1,"enabled":true,"hostname":"manager.synthetic-fixture.ts.net"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	err := disableInstalledRemoteAccess(installDir, dataDir)
	if err == nil || !strings.Contains(err.Error(), "reinstall before removal") {
		t.Fatalf("missing cleanup executable allowed saved public state to be orphaned: %v", err)
	}
}

func TestValidateInstallTargetAcceptsVerifiedPortableRelease(t *testing.T) {
	root := t.TempDir()
	for name, content := range map[string]string{
		"TautWeekly.ps1":       "# renderer",
		"RELEASE-METADATA.txt": "Repository version: test",
		"RELEASE-FILES.txt":    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  owned.txt\n",
	} {
		if err := os.WriteFile(filepath.Join(root, name), []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if err := validateInstallTarget(root); err != nil {
		t.Fatalf("verified portable release was rejected: %v", err)
	}
}

func TestValidateInstallTargetRejectsUnownedFolder(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "personal.txt"), []byte("do not overwrite"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := validateInstallTarget(root); err == nil {
		t.Fatal("unowned non-empty directory was accepted")
	}
}

func TestInstalledApplicationRequiresInstallerMetadata(t *testing.T) {
	root := t.TempDir()
	if installedApplication(root) {
		t.Fatal("empty directory was identified as an installed application")
	}
	if err := os.WriteFile(filepath.Join(root, "INSTALL-METADATA.txt"), []byte("Version=test\r\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if !installedApplication(root) {
		t.Fatal("installer-owned application was not identified")
	}
}

func TestInstallationCompletionPointsToManagerShortcut(t *testing.T) {
	message := installationCompletionMessage(false)
	for _, expected := range []string{"Open TautWeekly Manager", "Start menu", "will now open in your browser"} {
		if !strings.Contains(message, expected) {
			t.Fatalf("completion message is missing %q: %s", expected, message)
		}
	}
	if strings.Contains(message, "may be deleted") {
		t.Fatalf("completion message includes unnecessary installer cleanup guidance: %s", message)
	}
	if strings.Contains(installationCompletionMessage(true), "will now open in your browser") {
		t.Fatal("no-launch completion message promises to open the browser")
	}
}

func TestFinishInstallationDismissesCompletionBeforeLaunchingManager(t *testing.T) {
	opts := options{installDir: filepath.Join(t.TempDir(), "TautWeekly")}
	events := []string{}
	err := finishInstallation(opts,
		func(_, message string, suppressed bool) error {
			if suppressed || !strings.Contains(message, "will now open in your browser") {
				t.Fatalf("unexpected completion state: suppressed=%t message=%q", suppressed, message)
			}
			events = append(events, "completion-dismissed")
			return nil
		},
		func(_, workingDirectory string) error {
			if workingDirectory != opts.installDir {
				t.Fatalf("Manager launch used %q instead of %q", workingDirectory, opts.installDir)
			}
			events = append(events, "manager-launch-started")
			return nil
		},
	)
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(events, ","); got != "completion-dismissed,manager-launch-started" {
		t.Fatalf("installer completion and launch order was %q", got)
	}
}

func TestParseOptionsRestrictsExitMarkerToTestMode(t *testing.T) {
	marker := filepath.Join(t.TempDir(), "setup-exited.txt")
	if _, err := parseOptions([]string{"--test-exit-marker", marker}); err == nil {
		t.Fatal("production installer accepted the test-only exit marker")
	}
	opts, err := parseOptions([]string{"--test-mode", "--test-exit-marker", marker})
	if err != nil {
		t.Fatal(err)
	}
	if opts.testExitMarker != marker {
		t.Fatalf("test exit marker = %q, want %q", opts.testExitMarker, marker)
	}
}

func TestFinishInstallationNoLaunchClosesWithoutStartingManager(t *testing.T) {
	opts := options{installDir: t.TempDir(), noLaunch: true}
	launchCalled := false
	err := finishInstallation(opts,
		func(_, message string, suppressed bool) error {
			if suppressed || strings.Contains(message, "will now open in your browser") {
				t.Fatalf("unexpected no-launch completion state: suppressed=%t message=%q", suppressed, message)
			}
			return nil
		},
		func(_, _ string) error {
			launchCalled = true
			return nil
		},
	)
	if err != nil {
		t.Fatal(err)
	}
	if launchCalled {
		t.Fatal("no-launch installation started the Manager")
	}
}

func TestMigrateLegacyManagerDataRejectsConflictingExternalState(t *testing.T) {
	existing := t.TempDir()
	data := t.TempDir()
	legacy := filepath.Join(existing, ".manager-data")
	if err := os.MkdirAll(legacy, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(legacy, "access-state.json"), []byte(`{"source":"legacy"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(data, "access-state.json"), []byte(`{"source":"installed"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := migrateLegacyManagerData(existing, data); err == nil {
		t.Fatal("conflicting Manager state was overwritten during migration")
	}
}

func TestReadOwnedPathsRejectsPrivateRuntimeMaterial(t *testing.T) {
	t.Parallel()
	for _, relative := range []string{
		"config.json",
		"config.backup.20260814.json",
		"last-run.json",
		"scheduler-heartbeat.json",
		"service-heartbeat.json",
		"diagnostics.log.1",
		"output/preview.html",
		".manager-data/auth.json",
	} {
		relative := relative
		t.Run(relative, func(t *testing.T) {
			t.Parallel()
			root := t.TempDir()
			manifest := "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  " + relative + "\n"
			if err := os.WriteFile(filepath.Join(root, "RELEASE-FILES.txt"), []byte(manifest), 0o600); err != nil {
				t.Fatal(err)
			}
			if _, err := readOwnedPaths(root); err == nil {
				t.Fatalf("private runtime path %q was accepted as release-owned material", relative)
			}
		})
	}
}

func TestReplaceDirectoryPreservesPredictableSibling(t *testing.T) {
	t.Parallel()
	parent := t.TempDir()
	destination := filepath.Join(parent, "TautWeekly")
	staged := filepath.Join(parent, "staged")
	sibling := destination + ".previous"
	if err := os.Mkdir(destination, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(staged, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(staged, "owned.txt"), []byte("new application"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(sibling, 0o700); err != nil {
		t.Fatal(err)
	}
	private := filepath.Join(sibling, "user-private.txt")
	if err := os.WriteFile(private, []byte("preserve"), 0o600); err != nil {
		t.Fatal(err)
	}

	if err := replaceDirectory(staged, destination); err != nil {
		t.Fatal(err)
	}
	if content, err := os.ReadFile(private); err != nil || string(content) != "preserve" {
		t.Fatalf("predictable sibling was changed: content=%q err=%v", content, err)
	}
	if content, err := os.ReadFile(filepath.Join(destination, "owned.txt")); err != nil || string(content) != "new application" {
		t.Fatalf("staged application was not activated: content=%q err=%v", content, err)
	}
}
