//go:build windows

package main

import (
	"bytes"
	"errors"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestHiddenChildProcessesDoNotInheritSetupHandles(t *testing.T) {
	command := exec.Command("cmd.exe", "/d", "/c", "exit 0")
	hideProcessWindow(command)
	if command.SysProcAttr == nil || !command.SysProcAttr.HideWindow {
		t.Fatal("hidden child process does not retain the Windows hidden-window contract")
	}
	if !command.SysProcAttr.NoInheritHandles {
		t.Fatal("detached child process may inherit and retain a handle to Setup")
	}
}

func TestElevatedUpdateLauncherWaitsForHelperProcessOnly(t *testing.T) {
	if strings.Contains(elevatedUpdateLauncherScript, "-PassThru -Wait") {
		t.Fatal("elevated update launcher waits for the helper process tree, which includes the restarted Manager")
	}
	if !strings.Contains(elevatedUpdateLauncherScript, "-PassThru;$process.WaitForExit()") {
		t.Fatal("elevated update launcher does not wait explicitly for the finite update helper process")
	}
}

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

func TestWindowsSpecialFolderFallsBackToPerUserPaths(t *testing.T) {
	root := t.TempDir()
	appData := filepath.Join(root, "AppData", "Roaming")
	profile := filepath.Join(root, "Profile")
	originalQuery := queryWindowsSpecialFolder
	t.Cleanup(func() { queryWindowsSpecialFolder = originalQuery })
	queryWindowsSpecialFolder = func(string) (string, error) {
		return "", errors.New("shell folder unavailable")
	}
	t.Setenv("APPDATA", appData)
	t.Setenv("USERPROFILE", profile)

	tests := map[string]string{
		"Programs": filepath.Join(appData, "Microsoft", "Windows", "Start Menu", "Programs"),
		"Desktop":  filepath.Join(profile, "Desktop"),
	}
	for name, want := range tests {
		got, err := windowsSpecialFolder(name)
		if err != nil {
			t.Fatalf("resolve %s through fallback: %v", name, err)
		}
		if !samePath(got, want) {
			t.Fatalf("%s fallback = %s, want %s", name, got, want)
		}
	}
}

func TestWindowsSpecialFolderRejectsInvalidNativeAndFallbackPaths(t *testing.T) {
	originalQuery := queryWindowsSpecialFolder
	t.Cleanup(func() { queryWindowsSpecialFolder = originalQuery })
	queryWindowsSpecialFolder = func(string) (string, error) {
		return "relative", nil
	}
	t.Setenv("APPDATA", "")
	t.Setenv("USERPROFILE", "")
	if _, err := windowsSpecialFolder("Programs"); err == nil {
		t.Fatal("invalid native and fallback paths were accepted")
	}
}

func TestPreferredInstallDirectoryUsesValidatedInstallLocation(t *testing.T) {
	installed := filepath.Join(t.TempDir(), "Custom TautWeekly")
	writeInstallerMarker(t, installed)
	stubWindowsUninstallValues(t, map[string]string{"InstallLocation": installed})

	if got := preferredInstallDirectory(filepath.Join(t.TempDir(), "fallback")); !samePath(got, installed) {
		t.Fatalf("preferred install directory = %s, want %s", got, installed)
	}
}

func TestPreferredInstallDirectoryRecoversFromRegisteredUninstaller(t *testing.T) {
	installed := filepath.Join(t.TempDir(), "Custom TautWeekly With Spaces")
	writeInstallerMarker(t, installed)
	stubWindowsUninstallValues(t, map[string]string{
		"InstallLocation": filepath.Join(t.TempDir(), "missing"),
		"UninstallString": windowsQuote(filepath.Join(installed, "TautWeekly-Uninstall.exe")) + " --uninstall",
	})

	if got := preferredInstallDirectory(filepath.Join(t.TempDir(), "fallback")); !samePath(got, installed) {
		t.Fatalf("recovered install directory = %s, want %s", got, installed)
	}
}

func TestPreferredInstallDirectoryRecoversFromRegisteredIcon(t *testing.T) {
	installed := filepath.Join(t.TempDir(), "Custom TautWeekly")
	writeInstallerMarker(t, installed)
	stubWindowsUninstallValues(t, map[string]string{
		"DisplayIcon": windowsQuote(filepath.Join(installed, "tautweekly.ico")) + ",0",
	})

	if got := preferredInstallDirectory(filepath.Join(t.TempDir(), "fallback")); !samePath(got, installed) {
		t.Fatalf("icon-derived install directory = %s, want %s", got, installed)
	}
}

func TestPreferredInstallDirectoryRejectsUnownedRegistryPaths(t *testing.T) {
	fallback := filepath.Join(t.TempDir(), "Programs", "TautWeekly")
	stubWindowsUninstallValues(t, map[string]string{
		"InstallLocation": t.TempDir(),
		"UninstallString": windowsQuote(filepath.Join(t.TempDir(), "TautWeekly-Uninstall.exe")),
		"DisplayIcon":     filepath.Join(t.TempDir(), "tautweekly.ico"),
	})

	if got := preferredInstallDirectory(fallback); !samePath(got, fallback) {
		t.Fatalf("unowned registry path was accepted: got %s, want %s", got, fallback)
	}
}

func stubWindowsUninstallValues(t *testing.T, values map[string]string) {
	t.Helper()
	original := readWindowsUninstallValue
	t.Cleanup(func() { readWindowsUninstallValue = original })
	readWindowsUninstallValue = func(name string) (string, error) {
		value, ok := values[name]
		if !ok {
			return "", errors.New("registry value unavailable")
		}
		return value, nil
	}
}

func writeInstallerMarker(t *testing.T, root string) {
	t.Helper()
	if err := os.MkdirAll(root, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "INSTALL-METADATA.txt"), []byte("Version=test\r\n"), 0o600); err != nil {
		t.Fatal(err)
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

func TestManagerStartupCommandRoundTripsAndMigratesPaths(t *testing.T) {
	t.Setenv("SystemRoot", `C:\Windows`)
	oldRoot := filepath.Join(t.TempDir(), "Old TautWeekly")
	oldData := filepath.Join(t.TempDir(), "Old Manager Data")
	command, err := managerStartupCommand(oldRoot, oldData, true)
	if err != nil {
		t.Fatal(err)
	}
	preference, owned := parseManagerStartupCommand(command)
	if !owned || !preference.Enabled || !preference.OpenDashboard || !samePath(preference.InstallRoot, oldRoot) || !samePath(preference.DataRoot, oldData) {
		t.Fatalf("startup command did not round-trip: owned=%t preference=%+v command=%q", owned, preference, command)
	}

	var value = command
	var exists = true
	originalRead := readManagerStartupValue
	originalWrite := writeManagerStartupValue
	originalDelete := deleteManagerStartupValue
	t.Cleanup(func() {
		readManagerStartupValue = originalRead
		writeManagerStartupValue = originalWrite
		deleteManagerStartupValue = originalDelete
	})
	readManagerStartupValue = func() (string, bool, error) { return value, exists, nil }
	writeManagerStartupValue = func(next string) error { value, exists = next, true; return nil }
	deleteManagerStartupValue = func() error { value, exists = "", false; return nil }
	captured, err := captureManagerStartup(false)
	if err != nil {
		t.Fatal(err)
	}
	newRoot := filepath.Join(t.TempDir(), "New TautWeekly")
	newData := filepath.Join(t.TempDir(), "New Manager Data")
	if err := reconcileManagerStartup(captured, options{installDir: newRoot, dataDir: newData}, false); err != nil {
		t.Fatal(err)
	}
	migrated, owned := parseManagerStartupCommand(value)
	if !owned || !migrated.OpenDashboard || !samePath(migrated.InstallRoot, newRoot) || !samePath(migrated.DataRoot, newData) {
		t.Fatalf("startup entry retained a stale path: %+v, value %q", migrated, value)
	}
	if err := removeManagerStartup(newRoot, false); err != nil {
		t.Fatal(err)
	}
	if exists {
		t.Fatal("uninstall retained the owned Manager startup entry")
	}
}

func TestManagerStartupParserRejectsUnownedCommands(t *testing.T) {
	t.Setenv("SystemRoot", `C:\Windows`)
	for _, command := range []string{
		`"C:\Windows\System32\cmd.exe" /c calc.exe`,
		`"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -File "C:\Other\script.ps1"`,
		`"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\TautWeekly\START-MANAGER.ps1" -DataRoot "C:\Data" -Startup -Unexpected`,
	} {
		if _, owned := parseManagerStartupCommand(command); owned {
			t.Fatalf("unowned startup command was accepted: %q", command)
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
