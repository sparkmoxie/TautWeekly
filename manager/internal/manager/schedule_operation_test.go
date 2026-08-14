package manager

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

type fixtureScheduleRunner struct {
	started  chan struct{}
	release  chan struct{}
	once     sync.Once
	mu       sync.Mutex
	action   string
	revision string
	taskName string
	exitCode int
	err      error
}

func (r *fixtureScheduleRunner) Run(ctx context.Context, _, action, expectedRevision, taskName string) (int, error) {
	r.mu.Lock()
	r.action = action
	r.revision = expectedRevision
	r.taskName = taskName
	r.mu.Unlock()
	if r.started != nil {
		r.once.Do(func() { close(r.started) })
	}
	if r.release != nil {
		select {
		case <-r.release:
		case <-ctx.Done():
			return -1, ctx.Err()
		}
	}
	return r.exitCode, r.err
}

func TestScheduleCoordinatorUsesTypedActionAndStoresOnlySanitizedState(t *testing.T) {
	root := integrationConfigRoot(t, "http://127.0.0.1:8181", "private-api-secret", "", "")
	setFixtureTaskName(t, root, "Private Fixture Task Name")
	data := t.TempDir()
	runner := &fixtureScheduleRunner{started: make(chan struct{}), release: make(chan struct{})}
	coordinator, err := newScheduleCoordinator(Options{DataDir: data, TautWeeklyRoot: root, Now: time.Now, scheduleRunner: runner})
	if err != nil {
		t.Fatal(err)
	}
	request := ScheduleMutationRequest{ExpectedRevision: ReadConfigEditor(root).Revision, Confirm: true}
	started, err := coordinator.Start("install", request)
	if err != nil {
		t.Fatal(err)
	}
	if started.Action != "install" || started.State != "queued" {
		t.Fatalf("unexpected schedule start record: %+v", started)
	}
	select {
	case <-runner.started:
	case <-time.After(3 * time.Second):
		t.Fatal("fixture schedule operation did not start")
	}
	if _, err := coordinator.Start("disable", request); !errors.Is(err, ErrScheduleBusy) {
		t.Fatalf("concurrent schedule operation error: %v", err)
	}
	close(runner.release)
	finished := waitForScheduleState(t, coordinator, "succeeded")
	if finished.ExitCode == nil || *finished.ExitCode != 0 || finished.ErrorCategory != "" {
		t.Fatalf("unexpected schedule completion: %+v", finished)
	}
	runner.mu.Lock()
	if runner.action != "install" || runner.revision != request.ExpectedRevision || runner.taskName != "Private Fixture Task Name" {
		t.Fatalf("typed schedule runner inputs were not preserved: %+v", runner)
	}
	runner.mu.Unlock()
	raw, err := os.ReadFile(filepath.Join(data, "schedule-operation.json"))
	if err != nil {
		t.Fatal(err)
	}
	for _, forbidden := range []string{"Private Fixture Task Name", "private-api-secret", request.ExpectedRevision, "127.0.0.1", "config.json", "powershell"} {
		if strings.Contains(strings.ToLower(string(raw)), strings.ToLower(forbidden)) {
			t.Fatalf("schedule operation state retained private or implementation value %q: %s", forbidden, raw)
		}
	}
}

func TestScheduleCoordinatorRejectsUnsafeRequestsAndMapsSanitizedFailures(t *testing.T) {
	root := integrationConfigRoot(t, "http://127.0.0.1:8181", "fictional-api-key", "", "")
	view := ReadConfigEditor(root)
	for _, test := range []struct {
		name    string
		action  string
		request ScheduleMutationRequest
		want    error
	}{
		{name: "arbitrary action", action: "run-command", request: ScheduleMutationRequest{ExpectedRevision: view.Revision, Confirm: true}, want: ErrScheduleInvalid},
		{name: "missing confirmation", action: "install", request: ScheduleMutationRequest{ExpectedRevision: view.Revision}, want: ErrScheduleConfirmation},
		{name: "stale revision", action: "install", request: ScheduleMutationRequest{ExpectedRevision: "stale", Confirm: true}, want: ErrConfigConflict},
	} {
		t.Run(test.name, func(t *testing.T) {
			coordinator, err := newScheduleCoordinator(Options{DataDir: t.TempDir(), TautWeeklyRoot: root, Now: time.Now, scheduleRunner: &fixtureScheduleRunner{}})
			if err != nil {
				t.Fatal(err)
			}
			if _, err := coordinator.Start(test.action, test.request); !errors.Is(err, test.want) {
				t.Fatalf("got %v, want %v", err, test.want)
			}
		})
	}

	for exitCode, category := range map[int]string{
		10: "elevation-declined",
		21: "configuration-changed",
		22: "task-not-found",
		23: "task-ownership-mismatch",
		24: "schedule-invalid",
		25: "renderer-missing",
		26: "elevation-failed",
		27: "postcondition-failed",
		28: "schedule-configuration-read-failed",
		29: "task-definition-failed",
		30: "task-mutation-failed",
		31: "task-verification-failed",
		32: "task-read-access-failed",
		1:  "schedule-helper-failed",
	} {
		t.Run(category, func(t *testing.T) {
			runner := &fixtureScheduleRunner{exitCode: exitCode, err: errors.New("fixture failure")}
			coordinator, err := newScheduleCoordinator(Options{DataDir: t.TempDir(), TautWeeklyRoot: root, Now: time.Now, scheduleRunner: runner})
			if err != nil {
				t.Fatal(err)
			}
			if _, err := coordinator.Start("install", ScheduleMutationRequest{ExpectedRevision: view.Revision, Confirm: true}); err != nil {
				t.Fatal(err)
			}
			finished := waitForScheduleState(t, coordinator, "failed")
			if finished.ErrorCategory != category || finished.SupportCode == "" {
				t.Fatalf("unexpected sanitized failure: %+v", finished)
			}
		})
	}
}

func TestScheduleCoordinatorAllowsOnlyFourLifecycleActionsAndRecoversRestart(t *testing.T) {
	root := integrationConfigRoot(t, "http://127.0.0.1:8181", "fictional-api-key", "", "")
	view := ReadConfigEditor(root)
	for _, action := range []string{"install", "enable", "disable", "remove"} {
		coordinator, err := newScheduleCoordinator(Options{DataDir: t.TempDir(), TautWeeklyRoot: root, Now: time.Now, scheduleRunner: &fixtureScheduleRunner{}})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := coordinator.Start(action, ScheduleMutationRequest{ExpectedRevision: view.Revision, Confirm: true}); err != nil {
			t.Fatalf("typed action %q was rejected: %v", action, err)
		}
		waitForScheduleState(t, coordinator, "succeeded")
	}

	data := t.TempDir()
	active := ScheduleOperationRecord{
		SchemaVersion: scheduleOperationSchemaVersion,
		ID:            "schedule-restart-fixture",
		Action:        "enable",
		State:         "running",
		StartedAtUTC:  time.Now().Add(-time.Minute).UTC().Format(time.RFC3339),
	}
	if err := writePrivateJSON(filepath.Join(data, "schedule-operation.json"), active); err != nil {
		t.Fatal(err)
	}
	recovered, err := newScheduleCoordinator(Options{DataDir: data, TautWeeklyRoot: root, Now: time.Now, scheduleRunner: &fixtureScheduleRunner{}})
	if err != nil {
		t.Fatal(err)
	}
	current := recovered.Current()
	if current == nil || current.State != "failed" || current.ErrorCategory != "manager-restarted" || current.SupportCode == "" {
		t.Fatalf("unexpected recovered schedule operation: %+v", current)
	}
}

func setFixtureTaskName(t *testing.T, root, taskName string) {
	t.Helper()
	path := filepath.Join(root, "config.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var config map[string]any
	if err := json.Unmarshal(raw, &config); err != nil {
		t.Fatal(err)
	}
	config["ScheduledTaskName"] = taskName
	raw, err = json.Marshal(config)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatal(err)
	}
}

func waitForScheduleState(t *testing.T, coordinator *scheduleCoordinator, expected string) ScheduleOperationRecord {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if current := coordinator.Current(); current != nil && current.State == expected {
			return *current
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("schedule operation did not reach %q: %+v", expected, coordinator.Current())
	return ScheduleOperationRecord{}
}
