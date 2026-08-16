//go:build windows

package main

import (
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestWindowsManagerInstanceRejectsDuplicateAndAcceptsShutdownSignal(t *testing.T) {
	root := filepath.Join(t.TempDir(), "TautWeekly")
	address := "127.0.0.1:48788"
	first, primary, err := acquireManagerInstance(address, root)
	if err != nil || !primary {
		t.Fatalf("acquire first Manager instance: primary=%t error=%v", primary, err)
	}
	t.Cleanup(func() { _ = first.Close() })
	second, primary, err := acquireManagerInstance(address, root)
	if err != nil || primary || second != nil {
		t.Fatalf("acquire duplicate Manager instance: instance=%v primary=%t error=%v", second, primary, err)
	}
	if err := signalManagerShutdown(address, root); err != nil {
		t.Fatal(err)
	}
	select {
	case <-first.ShutdownRequested():
	case <-time.After(2 * time.Second):
		t.Fatal("Manager instance did not receive its shutdown signal")
	}
}

func TestTrayStatusDotUsesMostOfTheNativeMenuIconSlot(t *testing.T) {
	left, top, right, bottom := trayStatusDotBounds(16, 16)
	if left != 2 || top != 2 || right != 14 || bottom != 14 {
		t.Fatalf("16-pixel status dot bounds = (%d,%d)-(%d,%d), want (2,2)-(14,14)", left, top, right, bottom)
	}
	left, top, right, bottom = trayStatusDotBounds(20, 24)
	if right-left != 15 || bottom-top != 15 || left < 0 || top < 0 {
		t.Fatalf("scaled status dot bounds = (%d,%d)-(%d,%d), want a centered 15-pixel dot", left, top, right, bottom)
	}
}

func TestTrayTooltipIdentifiesDashboard(t *testing.T) {
	data := (&windowsManagerTray{}).notificationData(trayNIFTip)
	if actual := syscall.UTF16ToString(data.Tip[:]); actual != "TautWeekly Dashboard" {
		t.Fatalf("tray tooltip = %q, want TautWeekly Dashboard", actual)
	}
	if data.Flags&trayNIFShowTip == 0 {
		t.Fatal("tray tooltip is not enabled for NOTIFYICON_VERSION_4")
	}
}

func TestTrayStatusMenuCommandOpensDashboard(t *testing.T) {
	opened := make(chan struct{}, 1)
	tray := &windowsManagerTray{options: trayOptions{Open: func() { opened <- struct{}{} }}}
	tray.handleMenuCommand(trayStatusMenuID)
	select {
	case <-opened:
	case <-time.After(2 * time.Second):
		t.Fatal("status menu command did not open the Dashboard")
	}
}

func TestDashboardActivationUsesHiddenWindowsAccessibilityCommand(t *testing.T) {
	systemRoot := t.TempDir()
	powerShell := filepath.Join(systemRoot, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
	if err := os.MkdirAll(filepath.Dir(powerShell), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(powerShell, []byte("test placeholder"), 0o644); err != nil {
		t.Fatal(err)
	}

	command, err := dashboardActivationCommand(systemRoot)
	if err != nil {
		t.Fatal(err)
	}
	if command.Path != powerShell {
		t.Fatalf("activation executable = %q, want %q", command.Path, powerShell)
	}
	arguments := strings.Join(command.Args[1:], " ")
	for _, expected := range []string{"-NoProfile", "-NonInteractive", "-WindowStyle Hidden", "WScript.Shell", "AppActivate('TautWeekly Manager')"} {
		if !strings.Contains(arguments, expected) {
			t.Errorf("activation arguments %q do not contain %q", arguments, expected)
		}
	}
	if command.SysProcAttr == nil || !command.SysProcAttr.HideWindow || command.SysProcAttr.CreationFlags&windowsCreateNoWindow == 0 {
		t.Fatal("Dashboard activation command is not configured to stay hidden")
	}
}
