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
