package main

import (
	"archive/zip"
	"bytes"
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
