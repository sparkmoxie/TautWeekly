//go:build windows

package main

import (
	"bytes"
	"errors"
	"log"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestCreateShortcutAcceptsPathsWithSpaces(t *testing.T) {
	root := filepath.Join(t.TempDir(), "folder with spaces")
	if err := os.MkdirAll(root, 0o755); err != nil {
		t.Fatal(err)
	}
	destination := filepath.Join(root, "TautWeekly Manager.lnk")
	target := filepath.Join(os.Getenv("SystemRoot"), "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
	arguments := `-NoLogo -NoProfile -WindowStyle Hidden -Command "exit 0"`
	icon := filepath.Join(os.Getenv("SystemRoot"), "System32", "shell32.dll")
	if err := createShortcut(destination, target, arguments, root, icon); err != nil {
		t.Fatal(err)
	}
	if info, err := os.Stat(destination); err != nil || !info.Mode().IsRegular() {
		t.Fatalf("shortcut was not created: %v", err)
	}
}

func TestWindowsSpecialFolderReturnsAbsolutePaths(t *testing.T) {
	for _, name := range []string{"Programs", "Desktop"} {
		path, err := windowsSpecialFolder(name)
		if err != nil {
			t.Fatalf("resolve %s: %v", name, err)
		}
		if !filepath.IsAbs(path) {
			t.Fatalf("%s path is not absolute: %s", name, path)
		}
	}
}

func TestCreateShortcutsUsesRedirectedDesktop(t *testing.T) {
	root := t.TempDir()
	programs := filepath.Join(root, "Programs")
	desktop := filepath.Join(root, "OneDrive", "Desktop")
	if err := os.MkdirAll(desktop, 0o755); err != nil {
		t.Fatal(err)
	}
	originalResolver := resolveWindowsSpecialFolder
	originalWriter := writeWindowsShortcut
	t.Cleanup(func() {
		resolveWindowsSpecialFolder = originalResolver
		writeWindowsShortcut = originalWriter
	})
	resolveWindowsSpecialFolder = func(name string) (string, error) {
		switch name {
		case "Programs":
			return programs, nil
		case "Desktop":
			return desktop, nil
		default:
			return "", errors.New("unexpected shell folder")
		}
	}
	var destinations []string
	writeWindowsShortcut = func(destination, _, _, _, _ string) error {
		destinations = append(destinations, destination)
		return nil
	}
	t.Setenv("SystemRoot", filepath.Join(root, "Windows"))
	logger := log.New(&bytes.Buffer{}, "", 0)
	if err := createShortcuts(options{installDir: filepath.Join(root, "TautWeekly"), dataDir: filepath.Join(root, "data")}, logger); err != nil {
		t.Fatal(err)
	}
	want := filepath.Join(desktop, launcherName)
	if !containsPath(destinations, want) {
		t.Fatalf("redirected Desktop shortcut was not used: got %v, want %s", destinations, want)
	}
}

func TestCreateShortcutsSkipsUnavailableDesktop(t *testing.T) {
	root := t.TempDir()
	programs := filepath.Join(root, "Programs")
	originalResolver := resolveWindowsSpecialFolder
	originalWriter := writeWindowsShortcut
	t.Cleanup(func() {
		resolveWindowsSpecialFolder = originalResolver
		writeWindowsShortcut = originalWriter
	})
	resolveWindowsSpecialFolder = func(name string) (string, error) {
		if name == "Programs" {
			return programs, nil
		}
		return "", errors.New("Desktop is redirected but unavailable")
	}
	var destinations []string
	writeWindowsShortcut = func(destination, _, _, _, _ string) error {
		destinations = append(destinations, destination)
		return nil
	}
	t.Setenv("SystemRoot", filepath.Join(root, "Windows"))
	var output bytes.Buffer
	if err := createShortcuts(options{installDir: filepath.Join(root, "TautWeekly"), dataDir: filepath.Join(root, "data")}, log.New(&output, "", 0)); err != nil {
		t.Fatalf("optional Desktop failure aborted shortcut creation: %v", err)
	}
	if len(destinations) != 2 {
		t.Fatalf("created %d shortcuts, want the two required Start menu shortcuts: %v", len(destinations), destinations)
	}
	if !strings.Contains(output.String(), "desktop shortcut skipped") {
		t.Fatalf("missing Desktop warning: %s", output.String())
	}
}

func TestCreateShortcutsDoesNotFailWhenDesktopShortcutCannotBeWritten(t *testing.T) {
	root := t.TempDir()
	programs := filepath.Join(root, "Programs")
	desktop := filepath.Join(root, "Desktop")
	if err := os.MkdirAll(desktop, 0o755); err != nil {
		t.Fatal(err)
	}
	originalResolver := resolveWindowsSpecialFolder
	originalWriter := writeWindowsShortcut
	t.Cleanup(func() {
		resolveWindowsSpecialFolder = originalResolver
		writeWindowsShortcut = originalWriter
	})
	resolveWindowsSpecialFolder = func(name string) (string, error) {
		if name == "Programs" {
			return programs, nil
		}
		return desktop, nil
	}
	writeWindowsShortcut = func(destination, _, _, _, _ string) error {
		if samePath(filepath.Dir(destination), desktop) {
			return errors.New("Desktop shortcut is unavailable")
		}
		return nil
	}
	t.Setenv("SystemRoot", filepath.Join(root, "Windows"))
	var output bytes.Buffer
	if err := createShortcuts(options{installDir: filepath.Join(root, "TautWeekly"), dataDir: filepath.Join(root, "data")}, log.New(&output, "", 0)); err != nil {
		t.Fatalf("optional Desktop shortcut failure aborted setup: %v", err)
	}
	if !strings.Contains(output.String(), "desktop shortcut skipped") {
		t.Fatalf("missing Desktop warning: %s", output.String())
	}
}

func TestCreateShortcutsRequiresStartMenu(t *testing.T) {
	originalResolver := resolveWindowsSpecialFolder
	t.Cleanup(func() { resolveWindowsSpecialFolder = originalResolver })
	resolveWindowsSpecialFolder = func(string) (string, error) {
		return "", errors.New("Programs unavailable")
	}
	if err := createShortcuts(options{}, log.New(&bytes.Buffer{}, "", 0)); err == nil {
		t.Fatal("missing Start menu was accepted")
	}
}

func TestRemoveShortcutsUsesWindowsShellFolders(t *testing.T) {
	root := t.TempDir()
	programs := filepath.Join(root, "Programs")
	desktop := filepath.Join(root, "Redirected Desktop")
	startMenu := filepath.Join(programs, "TautWeekly")
	if err := os.MkdirAll(startMenu, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(desktop, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(desktop, launcherName), []byte("shortcut"), 0o600); err != nil {
		t.Fatal(err)
	}
	originalResolver := resolveWindowsSpecialFolder
	t.Cleanup(func() { resolveWindowsSpecialFolder = originalResolver })
	resolveWindowsSpecialFolder = func(name string) (string, error) {
		if name == "Programs" {
			return programs, nil
		}
		return desktop, nil
	}
	t.Setenv("USERPROFILE", "")
	if err := removeShortcuts(); err != nil {
		t.Fatal(err)
	}
	for _, removed := range []string{startMenu, filepath.Join(desktop, launcherName)} {
		if _, err := os.Stat(removed); !os.IsNotExist(err) {
			t.Fatalf("shortcut path remains: %s (%v)", removed, err)
		}
	}
}

func containsPath(paths []string, wanted string) bool {
	for _, path := range paths {
		if samePath(path, wanted) {
			return true
		}
	}
	return false
}
