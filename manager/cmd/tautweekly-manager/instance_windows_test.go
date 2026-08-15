//go:build windows

package main

import (
	"path/filepath"
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
