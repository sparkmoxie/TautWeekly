//go:build windows

package main

import (
	"os"
	"path/filepath"
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

func TestRemoveShortcutsRequiresAbsoluteProfileRoots(t *testing.T) {
	t.Setenv("APPDATA", "")
	t.Setenv("USERPROFILE", "")
	if err := removeShortcuts(); err == nil {
		t.Fatal("removeShortcuts accepted missing Windows profile roots")
	}
}
