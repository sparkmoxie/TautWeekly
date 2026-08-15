//go:build windows

package manager

import (
	"errors"
	"path/filepath"
	"testing"
)

type memoryStartupRegistry struct {
	value  string
	exists bool
	err    error
}

func (r *memoryStartupRegistry) Read(string) (string, bool, error) { return r.value, r.exists, r.err }
func (r *memoryStartupRegistry) Write(_, value string) error {
	if r.err != nil {
		return r.err
	}
	r.value, r.exists = value, true
	return nil
}
func (r *memoryStartupRegistry) Delete(string) error {
	if r.err != nil {
		return r.err
	}
	r.value, r.exists = "", false
	return nil
}

func TestWindowsStartupControllerOwnsExactCurrentUserCommand(t *testing.T) {
	registry := &memoryStartupRegistry{}
	controller := &windowsStartupController{
		root:       filepath.Join(`C:\Program Files`, "TautWeekly"),
		dataDir:    filepath.Join(`C:\Users\Example`, "TautWeekly Data"),
		systemRoot: `C:\Windows`,
		registry:   registry,
	}
	status, err := controller.Update(true, false)
	if err != nil || !status.StartManager || status.OpenDashboard || status.State != "enabled" {
		t.Fatalf("enable silent startup: status %+v, error %v", status, err)
	}
	if registry.value != controller.command(false) || registry.value == controller.command(true) {
		t.Fatalf("unexpected owned startup command: %q", registry.value)
	}
	status, err = controller.Update(true, true)
	if err != nil || !status.OpenDashboard || registry.value != controller.command(true) {
		t.Fatalf("enable startup dashboard: status %+v, command %q, error %v", status, registry.value, err)
	}
	status, err = controller.Update(false, false)
	if err != nil || status.StartManager || registry.exists {
		t.Fatalf("disable startup: status %+v, registry %+v, error %v", status, registry, err)
	}
}

func TestWindowsStartupControllerRefusesForeignEntry(t *testing.T) {
	registry := &memoryStartupRegistry{value: `"C:\Windows\System32\not-tautweekly.exe"`, exists: true}
	controller := &windowsStartupController{root: `C:\TautWeekly`, dataDir: `C:\Data`, systemRoot: `C:\Windows`, registry: registry}
	status := controller.Status()
	if status.State != "conflict" || status.ErrorCode != "startup-entry-conflict" {
		t.Fatalf("foreign startup status: %+v", status)
	}
	if _, err := controller.Update(false, false); !errors.Is(err, ErrStartupConflict) {
		t.Fatalf("foreign startup update error: %v", err)
	}
	if !registry.exists || registry.value == "" {
		t.Fatal("foreign startup entry was changed")
	}
}
