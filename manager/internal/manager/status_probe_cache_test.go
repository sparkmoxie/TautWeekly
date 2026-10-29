package manager

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestWindowsTaskProbeCacheCoalescesAndExpires(t *testing.T) {
	now := time.Date(2031, 4, 18, 16, 30, 0, 0, time.UTC)
	var calls atomic.Int32
	started, release := make(chan struct{}), make(chan struct{})
	cache := newWindowsTaskProbeCache(func() time.Time { return now }, func(ctx context.Context, task, root string) (windowsTaskProbe, error) {
		if task != "fixture" || root != "fixture-root" {
			t.Errorf("unexpected probe key")
		}
		if calls.Add(1) == 1 {
			close(started)
		}
		select {
		case <-release:
		case <-ctx.Done():
			return windowsTaskProbe{}, ctx.Err()
		}
		return windowsTaskProbe{Installed: true, State: "Ready"}, nil
	})
	var callers sync.WaitGroup
	for index := 0; index < 100; index++ {
		callers.Go(func() {
			probe, observed, err := cache.Get(t.Context(), "fixture", "fixture-root", "revision")
			if err != nil || !probe.Installed || !observed.Equal(now) {
				t.Errorf("unexpected shared observation: %+v %v %v", probe, observed, err)
			}
		})
	}
	<-started
	close(release)
	callers.Wait()
	if calls.Load() != 1 {
		t.Fatalf("100 concurrent status requests used %d probes, want 1", calls.Load())
	}
	now = now.Add(windowsTaskProbeTTL - time.Nanosecond)
	if _, _, err := cache.Get(t.Context(), "fixture", "fixture-root", "revision"); err != nil {
		t.Fatal(err)
	}
	if calls.Load() != 1 {
		t.Fatal("unexpired observation was not reused")
	}
	now = now.Add(time.Nanosecond)
	if _, _, err := cache.Get(t.Context(), "fixture", "fixture-root", "revision"); err != nil {
		t.Fatal(err)
	}
	if calls.Load() != 2 {
		t.Fatal("expired observation was reused")
	}
	if _, _, err := cache.Get(t.Context(), "fixture", "fixture-root", "new-revision"); err != nil {
		t.Fatal(err)
	}
	if calls.Load() != 3 {
		t.Fatal("configuration revision change did not refresh the probe")
	}
	cache.Invalidate()
	if _, _, err := cache.Get(t.Context(), "fixture", "fixture-root", "new-revision"); err != nil {
		t.Fatal(err)
	}
	if calls.Load() != 4 {
		t.Fatal("explicit invalidation did not refresh the probe")
	}
	t.Log("100 concurrent requests: 100 uncached probes -> 1 shared probe")
}

func TestWindowsTaskProbeCacheInvalidatesInFlightObservation(t *testing.T) {
	var calls atomic.Int32
	started, release := make(chan struct{}), make(chan struct{})
	cache := newWindowsTaskProbeCache(time.Now, func(ctx context.Context, _, _ string) (windowsTaskProbe, error) {
		if calls.Add(1) == 1 {
			close(started)
			select {
			case <-release:
			case <-ctx.Done():
				return windowsTaskProbe{}, ctx.Err()
			}
			return windowsTaskProbe{State: "BeforeMutation"}, nil
		}
		return windowsTaskProbe{State: "AfterMutation"}, nil
	})
	result := make(chan windowsTaskProbe, 1)
	go func() { probe, _, _ := cache.Get(t.Context(), "fixture", "root", "revision"); result <- probe }()
	<-started
	cache.Invalidate()
	close(release)
	if probe := <-result; probe.State != "AfterMutation" {
		t.Fatalf("invalidated in-flight state escaped: %+v", probe)
	}
	if calls.Load() != 2 {
		t.Fatalf("got %d probes, want one refresh after mutation", calls.Load())
	}
}

func TestWindowsTaskProbeCacheIdleHourProbeCount(t *testing.T) {
	now := time.Date(2031, 4, 18, 16, 30, 0, 0, time.UTC)
	var calls atomic.Int32
	cache := newWindowsTaskProbeCache(func() time.Time { return now }, func(context.Context, string, string) (windowsTaskProbe, error) {
		calls.Add(1)
		return windowsTaskProbe{State: "Ready"}, nil
	})
	for request := 0; request < 720; request++ {
		if _, _, err := cache.Get(t.Context(), "fixture", "root", "revision"); err != nil {
			t.Fatal(err)
		}
		now = now.Add(5 * time.Second)
	}
	if calls.Load() != 240 {
		t.Fatalf("720 idle polls issued %d probes, want 240", calls.Load())
	}
	t.Log("Synthetic idle hour at 5s cadence: 720 uncached probes -> 240 probes with a 15s observation lifetime")
}

func TestWindowsTaskProbeCacheDeadlineAndCallerCancellation(t *testing.T) {
	started := make(chan struct{})
	var calls atomic.Int32
	cache := newWindowsTaskProbeCache(time.Now, func(ctx context.Context, _, _ string) (windowsTaskProbe, error) {
		calls.Add(1)
		close(started)
		<-ctx.Done()
		return windowsTaskProbe{}, ctx.Err()
	})
	cache.timeout = 25 * time.Millisecond
	ctx, cancel := context.WithCancel(t.Context())
	done := make(chan error, 1)
	go func() { _, _, err := cache.Get(ctx, "fixture", "root", "revision"); done <- err }()
	<-started
	cancel()
	if err := <-done; !errors.Is(err, context.Canceled) {
		t.Fatalf("caller cancellation: %v", err)
	}
	_, observed, err := cache.Get(t.Context(), "fixture", "root", "revision")
	if !errors.Is(err, context.DeadlineExceeded) || observed.IsZero() {
		t.Fatalf("bounded probe failed incorrectly: %v %v", observed, err)
	}
	if calls.Load() != 1 {
		t.Fatal("cancelled caller cancelled or duplicated the shared probe")
	}
}

func TestWindowsTaskProbeCacheFailureRecoveryAndIsolation(t *testing.T) {
	now := time.Date(2031, 4, 18, 16, 30, 0, 0, time.UTC)
	var calls atomic.Int32
	cache := newWindowsTaskProbeCache(func() time.Time { return now }, func(context.Context, string, string) (windowsTaskProbe, error) {
		if calls.Add(1) == 1 {
			return windowsTaskProbe{}, errors.New("fixture probe failed")
		}
		value := int64(0)
		return windowsTaskProbe{State: "Ready", LastTaskResult: &value}, nil
	})
	for index := 0; index < 2; index++ {
		if _, _, err := cache.Get(t.Context(), "fixture", "root", "revision"); err == nil {
			t.Fatal("probe failure hidden")
		}
	}
	if calls.Load() != 1 {
		t.Fatal("failure burst was not bounded")
	}
	now = now.Add(time.Second)
	probe, _, err := cache.Get(t.Context(), "fixture", "root", "revision")
	if err != nil {
		t.Fatal(err)
	}
	*probe.LastTaskResult = 42
	probe, _, err = cache.Get(t.Context(), "fixture", "root", "revision")
	if err != nil || *probe.LastTaskResult != 0 {
		t.Fatal("caller mutated shared scheduler evidence")
	}
}

func TestStatusReadinessMatchesEditorWithoutConstructingEditorFields(t *testing.T) {
	for _, ids := range []string{`[9007199254740993,18446744073709551615]`, `[1.5]`, `[1e3]`, `[-1]`, `[null]`, `[18446744073709551616]`} {
		t.Run(ids, func(t *testing.T) {
			root, _ := numericIDListConfig(t, ids, `["1"]`)
			want := ReadConfigEditor(root).State
			status := CollectStatus(t.Context(), Options{TautWeeklyRoot: root, RuntimeMode: "linux", Now: time.Now})
			if status.Readiness.Configuration != want {
				t.Fatalf("status readiness %q != editor %q", status.Readiness.Configuration, want)
			}
		})
	}
	for _, contents := range []string{"", "{broken", "null"} {
		root := t.TempDir()
		if contents != "" {
			if err := os.WriteFile(filepath.Join(root, "config.json"), []byte(contents), 0o600); err != nil {
				t.Fatal(err)
			}
		}
		want := ReadConfigEditor(root).State
		status := CollectStatus(t.Context(), Options{TautWeeklyRoot: root, RuntimeMode: "linux", Now: time.Now})
		if status.Readiness.Configuration != want {
			t.Fatalf("%q status readiness %q != editor %q", contents, status.Readiness.Configuration, want)
		}
	}
}

func TestScheduleMutationInvalidatesProbeAtStartAndCompletion(t *testing.T) {
	root := integrationConfigRoot(t, "http://127.0.0.1:8181", "fixture-key", "", "")
	cache := newWindowsTaskProbeCache(time.Now, func(context.Context, string, string) (windowsTaskProbe, error) { return windowsTaskProbe{}, nil })
	runner := &fixtureScheduleRunner{started: make(chan struct{}), release: make(chan struct{})}
	coordinator, err := newScheduleCoordinator(Options{DataDir: t.TempDir(), TautWeeklyRoot: root, RuntimeMode: "windows", Now: time.Now, scheduleRunner: runner, taskProbeCache: cache})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := coordinator.Start("install", ScheduleMutationRequest{ExpectedRevision: ReadConfigEditor(root).Revision, Confirm: true}); err != nil {
		t.Fatal(err)
	}
	<-runner.started
	cache.mu.Lock()
	first := cache.generation
	cache.mu.Unlock()
	if first != 1 {
		t.Fatal("schedule start did not invalidate the cached observation")
	}
	close(runner.release)
	deadline := time.Now().Add(2 * time.Second)
	for scheduleOperationActive(coordinator.Current().State) {
		if time.Now().After(deadline) {
			t.Fatal("fixture schedule did not complete")
		}
		time.Sleep(time.Millisecond)
	}
	cache.mu.Lock()
	defer cache.mu.Unlock()
	if cache.generation != 2 {
		t.Fatal("schedule completion did not invalidate the cached observation")
	}
}

func TestConfigMutationsInvalidateSharedStatusProbe(t *testing.T) {
	root := integrationConfigRoot(t, "http://127.0.0.1:8181", "fixture-key", "", "")
	var calls atomic.Int32
	cache := newWindowsTaskProbeCache(time.Now, func(context.Context, string, string) (windowsTaskProbe, error) {
		calls.Add(1)
		return windowsTaskProbe{State: "Ready"}, nil
	})
	server, err := New(Options{DataDir: t.TempDir(), TautWeeklyRoot: root, RuntimeMode: "linux", Now: time.Now, taskProbeCache: cache})
	if err != nil {
		t.Fatal(err)
	}
	session, err := server.auth.newSession()
	if err != nil {
		t.Fatal(err)
	}
	cookie := &http.Cookie{Name: sessionCookieName, Value: session.Token}
	probe := func() {
		t.Helper()
		if _, _, err := cache.Get(t.Context(), "fixture", root, "same-key"); err != nil {
			t.Fatal(err)
		}
	}
	probe()
	view := ReadConfigEditor(root)
	request := validConfigSaveRequest(t, view)
	request.Values["FromName"] = json.RawMessage(`"Changed fixture name"`)
	body, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	response := mutationRequestForTest(server, http.MethodPut, "/api/v1/config", body, cookie, session.CSRFToken)
	if response.Code != http.StatusOK {
		t.Fatalf("save returned %d", response.Code)
	}
	probe()
	if calls.Load() != 2 {
		t.Fatal("successful config save retained its old probe")
	}
	backups := ListConfigBackups(root)
	if len(backups.Backups) != 1 {
		t.Fatalf("unexpected fixture backups: %d", len(backups.Backups))
	}
	body, err = json.Marshal(ConfigRestoreRequest{ExpectedRevision: ReadConfigEditor(root).Revision})
	if err != nil {
		t.Fatal(err)
	}
	response = mutationRequestForTest(server, http.MethodPost, "/api/v1/config/backups/"+backups.Backups[0].ID+"/restore", body, cookie, session.CSRFToken)
	if response.Code != http.StatusOK {
		t.Fatalf("restore returned %d", response.Code)
	}
	probe()
	if calls.Load() != 3 {
		t.Fatal("successful config restore retained its old probe")
	}
}
