package manager

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestNASCapabilitiesRequireAuthenticationAndEnforceHostPolicy(t *testing.T) {
	t.Parallel()
	server, err := New(Options{
		DataDir:        t.TempDir(),
		TautWeeklyRoot: t.TempDir(),
		RuntimeRoot:    t.TempDir(),
		RuntimeMode:    runtimeModeNAS,
		AllowedHosts:   []string{"weekly.nas.example"},
		SecureCookies:  true,
		Version:        "test",
	})
	if err != nil {
		t.Fatal(err)
	}

	unauthorized := requestForTest(server, http.MethodGet, "/api/v1/capabilities", nil, nil)
	if unauthorized.Code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated capabilities status: got %d, want 401", unauthorized.Code)
	}
	current, err := server.auth.newSession()
	if err != nil {
		t.Fatal(err)
	}
	cookie := &http.Cookie{Name: sessionCookieName, Value: current.Token}
	response := requestForTest(server, http.MethodGet, "/api/v1/capabilities", nil, cookie)
	if response.Code != http.StatusOK {
		t.Fatalf("capabilities status: got %d, body %s", response.Code, response.Body.String())
	}
	var capabilities Capabilities
	if err := json.Unmarshal(response.Body.Bytes(), &capabilities); err != nil {
		t.Fatal(err)
	}
	if capabilities.RuntimeMode != runtimeModeNAS || capabilities.Authentication != "required" ||
		capabilities.SupportsStartup || capabilities.SupportsTray || capabilities.OpensBrowser ||
		capabilities.ScheduleProvider != "embedded-container" || strings.Join(capabilities.ScheduleActions, ",") != "enable,disable" {
		t.Fatalf("unexpected NAS capability boundary: %+v", capabilities)
	}
	startup := requestForTest(server, http.MethodGet, "/api/v1/startup", nil, cookie)
	if startup.Code != http.StatusOK || !strings.Contains(startup.Body.String(), `"supported":false`) || !strings.Contains(startup.Body.String(), `"state":"unsupported"`) {
		t.Fatalf("NAS mode exposed platform startup controls: status=%d body=%s", startup.Code, startup.Body.String())
	}

	for _, host := range []string{"192.0.2.44:8787", "[2001:db8::44]:8787", "weekly.nas.example:8787"} {
		request := httptest.NewRequest(http.MethodGet, "/health/live", nil)
		request.Host = host
		recorder := httptest.NewRecorder()
		server.Handler().ServeHTTP(recorder, request)
		if recorder.Code != http.StatusOK {
			t.Fatalf("allowed NAS Host %q: got %d, body %s", host, recorder.Code, recorder.Body.String())
		}
		if recorder.Header().Get("Strict-Transport-Security") == "" {
			t.Fatalf("forced secure-cookie mode omitted HSTS for %q", host)
		}
	}
	request := httptest.NewRequest(http.MethodGet, "/health/live", nil)
	request.Host = "rebinding.attacker.example"
	recorder := httptest.NewRecorder()
	server.Handler().ServeHTTP(recorder, request)
	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("unlisted DNS Host was accepted: got %d", recorder.Code)
	}

	cookieRecorder := httptest.NewRecorder()
	server.setSessionCookie(cookieRecorder, httptest.NewRequest(http.MethodGet, "http://weekly.nas.example/", nil), current)
	cookies := cookieRecorder.Result().Cookies()
	if len(cookies) != 1 || !cookies[0].Secure || !cookies[0].HttpOnly || cookies[0].SameSite != http.SameSiteStrictMode {
		t.Fatalf("NAS session cookie is not hardened: %+v", cookies)
	}
}

func TestLinuxCapabilitiesRequireAuthenticationAndDescribeNativeService(t *testing.T) {
	t.Parallel()
	capabilities := capabilitiesFor(Options{RuntimeMode: runtimeModeLinux, SecureCookies: true})
	if capabilities.RuntimeMode != runtimeModeLinux || capabilities.Authentication != "required" ||
		capabilities.ScheduleProvider != "embedded-service" ||
		capabilities.LifecycleProvider != "systemd" || capabilities.UpdateProvider != "linux-package" ||
		capabilities.PathStyle != "linux-service" || capabilities.NetworkScope != "host-loopback" ||
		capabilities.SupportsStartup || capabilities.SupportsTray || capabilities.OpensBrowser ||
		strings.Join(capabilities.ScheduleActions, ",") != "enable,disable" || !capabilities.SecureCookies {
		t.Fatalf("unexpected Linux capability boundary: %+v", capabilities)
	}

	runtimeRoot := integrationConfigRoot(t, "http://127.0.0.1:8181", "fixture-api-key", "", "")
	server, err := New(Options{
		DataDir:        t.TempDir(),
		TautWeeklyRoot: t.TempDir(),
		RuntimeRoot:    runtimeRoot,
		RuntimeMode:    runtimeModeLinux,
		AllowedHosts:   []string{"weekly.linux.example"},
		SecureCookies:  true,
		Version:        "test",
	})
	if err != nil {
		t.Fatal(err)
	}
	unauthorized := requestForTest(server, http.MethodGet, "/api/v1/capabilities", nil, nil)
	if unauthorized.Code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated Linux capabilities status: got %d, want 401", unauthorized.Code)
	}
	if _, ok := server.schedule.runner.(containerScheduleMutationRunner); !ok {
		t.Fatalf("Linux Manager did not use the embedded service schedule runner: %T", server.schedule.runner)
	}
	current, err := server.auth.newSession()
	if err != nil {
		t.Fatal(err)
	}
	request := httptest.NewRequest(http.MethodPost, "/api/v1/auth/logout", nil)
	request.Host = "weekly.linux.example"
	request.Header.Set("Origin", "https://weekly.linux.example")
	request.Header.Set("X-CSRF-Token", current.CSRFToken)
	request.AddCookie(&http.Cookie{Name: sessionCookieName, Value: current.Token})
	recorder := httptest.NewRecorder()
	server.Handler().ServeHTTP(recorder, request)
	if recorder.Code != http.StatusNoContent {
		t.Fatalf("native Linux exact-DNS protected mutation: got %d, body %s", recorder.Code, recorder.Body.String())
	}
	snapshot := CollectStatus(t.Context(), Options{
		DataDir:        t.TempDir(),
		TautWeeklyRoot: t.TempDir(),
		RuntimeRoot:    runtimeRoot,
		RuntimeMode:    runtimeModeLinux,
		Version:        "test",
	})
	if snapshot.Schedule.Provider != "embedded-service" || !snapshot.Schedule.Supported || !snapshot.Schedule.Installed || !snapshot.Schedule.Owned {
		t.Fatalf("Linux embedded-service schedule status is not truthful: %+v", snapshot.Schedule)
	}
}

func TestMacCapabilitiesRequireAuthenticationAndDescribeDockerDesktop(t *testing.T) {
	t.Parallel()
	capabilities := capabilitiesFor(Options{RuntimeMode: runtimeModeMac, SecureCookies: true})
	if capabilities.RuntimeMode != runtimeModeMac || capabilities.Platform != "macos-docker" ||
		capabilities.Authentication != "required" || capabilities.ScheduleProvider != "embedded-container" ||
		capabilities.LifecycleProvider != "docker-desktop" || capabilities.UpdateProvider != "mac-package" ||
		capabilities.PathStyle != "mac-bind-mount" || capabilities.NetworkScope != "host-loopback" ||
		capabilities.SupportsStartup || capabilities.SupportsTray || capabilities.OpensBrowser ||
		strings.Join(capabilities.ScheduleActions, ",") != "enable,disable" || !capabilities.SecureCookies {
		t.Fatalf("unexpected macOS capability boundary: %+v", capabilities)
	}
	registryCapabilities := capabilitiesFor(Options{RuntimeMode: runtimeModeMac, PackageKind: packageKindMacRegistry})
	if registryCapabilities.PackageKind != packageKindMacRegistry ||
		registryCapabilities.UpdateProvider != "mac-registry" ||
		registryCapabilities.PathStyle != "container-volume" {
		t.Fatalf("unexpected macOS registry capability boundary: %+v", registryCapabilities)
	}

	server, err := New(Options{
		DataDir:        t.TempDir(),
		TautWeeklyRoot: t.TempDir(),
		RuntimeRoot:    t.TempDir(),
		RuntimeMode:    runtimeModeMac,
		AllowedHosts:   []string{"weekly.mac.example"},
		Version:        "test",
	})
	if err != nil {
		t.Fatal(err)
	}
	unauthorized := requestForTest(server, http.MethodGet, "/api/v1/capabilities", nil, nil)
	if unauthorized.Code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated macOS capabilities status: got %d, want 401", unauthorized.Code)
	}
	if _, ok := server.schedule.runner.(containerScheduleMutationRunner); !ok {
		t.Fatalf("macOS Manager did not use the embedded container schedule runner: %T", server.schedule.runner)
	}
	current, err := server.auth.newSession()
	if err != nil {
		t.Fatal(err)
	}
	cookie := &http.Cookie{Name: sessionCookieName, Value: current.Token}
	editorResponse := requestForTest(server, http.MethodGet, "/api/v1/config/editor", nil, cookie)
	if editorResponse.Code != http.StatusOK || !strings.Contains(editorResponse.Body.String(), `"value":"http://host.docker.internal:8181"`) ||
		!strings.Contains(editorResponse.Body.String(), `"placeholder":"http://host.docker.internal:8181"`) {
		t.Fatalf("macOS first-run editor did not use the Docker Desktop host address: status=%d body=%s", editorResponse.Code, editorResponse.Body.String())
	}
	for _, host := range []string{"127.0.0.1:8787", "192.0.2.55:8787", "weekly.mac.example:8787"} {
		request := httptest.NewRequest(http.MethodGet, "/health/live", nil)
		request.Host = host
		recorder := httptest.NewRecorder()
		server.Handler().ServeHTTP(recorder, request)
		if recorder.Code != http.StatusOK {
			t.Fatalf("allowed macOS Host %q: got %d, body %s", host, recorder.Code, recorder.Body.String())
		}
	}
}

func TestNASManagerReadsPersistentRuntimeRootNotReadOnlyPackageRoot(t *testing.T) {
	t.Parallel()
	packageRoot := t.TempDir()
	runtimeRoot := integrationConfigRoot(t, "http://127.0.0.1:8181", "persistent-secret", "", "")
	server, err := New(Options{
		DataDir:        t.TempDir(),
		TautWeeklyRoot: packageRoot,
		RuntimeRoot:    runtimeRoot,
		RuntimeMode:    runtimeModeNAS,
		Version:        "test",
	})
	if err != nil {
		t.Fatal(err)
	}
	current, err := server.auth.newSession()
	if err != nil {
		t.Fatal(err)
	}
	cookie := &http.Cookie{Name: sessionCookieName, Value: current.Token}
	response := requestForTest(server, http.MethodGet, "/api/v1/config", nil, cookie)
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), `"exists":true`) {
		t.Fatalf("persistent runtime configuration was not read: status=%d body=%s", response.Code, response.Body.String())
	}
	if strings.Contains(response.Body.String(), "persistent-secret") {
		t.Fatal("persistent runtime secret was returned by the redacted API")
	}
	if server.operations.root != packageRoot || server.operations.runtimeRoot != runtimeRoot || server.schedule.runtimeRoot != runtimeRoot {
		t.Fatalf("package/runtime path separation was lost: operations=%+v schedule=%+v", server.operations, server.schedule)
	}
}

func TestEmbeddedScheduleMutationIsTypedRevisionCheckedAndBackedUp(t *testing.T) {
	t.Parallel()
	runtimeRoot := integrationConfigRoot(t, "http://127.0.0.1:8181", "fixture-api-key", "", "")
	view := ReadConfigEditor(runtimeRoot)
	runner := containerScheduleMutationRunner{
		runtimeRoot: runtimeRoot,
		now:         func() time.Time { return time.Date(2032, 2, 3, 4, 5, 6, 0, time.UTC) },
	}
	if exitCode, err := runner.Run(t.Context(), "ignored", "install", view.Revision, "ignored"); err == nil || exitCode != 24 {
		t.Fatalf("unsupported container schedule action: code=%d err=%v", exitCode, err)
	}
	if exitCode, err := runner.Run(t.Context(), "ignored", "enable", "stale", "ignored"); !errors.Is(err, ErrConfigConflict) || exitCode != 21 {
		t.Fatalf("stale container schedule mutation: code=%d err=%v", exitCode, err)
	}
	if exitCode, err := runner.Run(t.Context(), "ignored", "enable", view.Revision, "ignored"); err != nil || exitCode != 0 {
		t.Fatalf("enable container schedule mutation: code=%d err=%v", exitCode, err)
	}
	raw, err := os.ReadFile(filepath.Join(runtimeRoot, "config.json"))
	if err != nil {
		t.Fatal(err)
	}
	var config map[string]any
	if err := json.Unmarshal(raw, &config); err != nil {
		t.Fatal(err)
	}
	if enabled, ok := config["ScheduleEnabled"].(bool); !ok || !enabled {
		t.Fatalf("schedule was not enabled with a JSON boolean: %#v", config["ScheduleEnabled"])
	}
	backups, err := filepath.Glob(filepath.Join(runtimeRoot, "config.backup.*.json"))
	if err != nil || len(backups) != 1 {
		t.Fatalf("schedule mutation backup count=%d err=%v", len(backups), err)
	}
	backup, err := os.ReadFile(backups[0])
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(backup), "fixture-api-key") {
		t.Fatal("schedule mutation backup did not preserve the complete prior configuration")
	}
}

func TestNASStatusUsesEmbeddedSchedulerHeartbeatAndState(t *testing.T) {
	t.Parallel()
	runtimeRoot := integrationConfigRoot(t, "http://127.0.0.1:8181", "fixture-api-key", "", "")
	path := filepath.Join(runtimeRoot, "config.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var config map[string]any
	if err := json.Unmarshal(raw, &config); err != nil {
		t.Fatal(err)
	}
	config["ScheduleEnabled"] = true
	config["ScheduleDay"] = "Friday"
	config["ScheduleTime"] = "09:30"
	raw, err = json.Marshal(config)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	now := time.Date(2032, 2, 3, 4, 5, 6, 0, time.UTC)
	if err := writePrivateJSON(filepath.Join(runtimeRoot, "scheduler-heartbeat.json"), map[string]any{
		"Utc":        now.Format(time.RFC3339),
		"Local":      now.Format(time.RFC3339),
		"TimeZoneId": "Etc/UTC",
	}); err != nil {
		t.Fatal(err)
	}
	lastExit := int64(0)
	if err := writePrivateJSON(filepath.Join(runtimeRoot, "scheduler-state.json"), containerSchedulerState{
		LastAttemptUTC: now.Add(-time.Hour).Format(time.RFC3339),
		LastSuccessUTC: now.Add(-time.Hour).Format(time.RFC3339),
		LastResult:     "Success",
		LastExitCode:   &lastExit,
	}); err != nil {
		t.Fatal(err)
	}
	snapshot := CollectStatus(t.Context(), Options{
		DataDir:        t.TempDir(),
		TautWeeklyRoot: t.TempDir(),
		RuntimeRoot:    runtimeRoot,
		RuntimeMode:    runtimeModeNAS,
		Version:        "test",
		Now:            func() time.Time { return now },
	})
	if snapshot.Schedule.Provider != "embedded-container" || !snapshot.Schedule.Installed ||
		!snapshot.Schedule.Owned || !snapshot.Schedule.Enabled || snapshot.Schedule.State != "running" ||
		snapshot.Runtime.Scheduler != "running" || snapshot.Schedule.NextRunUTC == "" || snapshot.Schedule.NextRunLocal == "" {
		t.Fatalf("embedded scheduler status was not represented truthfully: %+v", snapshot.Schedule)
	}
	if snapshot.Delivery.Evidence != "embedded-scheduler" || snapshot.Delivery.Result != "success" || snapshot.Delivery.ExitCode == nil || *snapshot.Delivery.ExitCode != 0 {
		t.Fatalf("embedded scheduler delivery state was not represented truthfully: %+v", snapshot.Delivery)
	}

	if err := writePrivateJSON(filepath.Join(runtimeRoot, "scheduler-state.json"), containerSchedulerState{
		LastAttemptUTC: now.Format(time.RFC3339),
		LastSuccessUTC: now.Add(-time.Hour).Format(time.RFC3339),
		LastResult:     "running",
	}); err != nil {
		t.Fatal(err)
	}
	if err := writePrivateJSON(filepath.Join(runtimeRoot, "scheduler-heartbeat.json"), map[string]any{
		"Utc":        now.Add(-2 * time.Minute).Format(time.RFC3339),
		"Local":      now.Add(-2 * time.Minute).Format(time.RFC3339),
		"TimeZoneId": "Etc/UTC",
	}); err != nil {
		t.Fatal(err)
	}
	if err := writePrivateJSON(filepath.Join(runtimeRoot, "service-heartbeat.json"), serviceSupervisorHeartbeat{
		UTC: now.Format(time.RFC3339),
	}); err != nil {
		t.Fatal(err)
	}
	writeRendererResultFixture(t, runtimeRoot, rendererResult{
		SchemaVersion:     2,
		Mode:              "SendAll",
		Outcome:           "succeeded",
		DeliveryScope:     "production",
		StartedAtUTC:      now.Add(-time.Hour).Format(time.RFC3339Nano),
		FinishedAtUTC:     now.Add(-50 * time.Minute).Format(time.RFC3339Nano),
		DurationMS:        600000,
		SMTPAcceptedCount: 7,
	})
	snapshot = CollectStatus(t.Context(), Options{
		DataDir:        t.TempDir(),
		TautWeeklyRoot: t.TempDir(),
		RuntimeRoot:    runtimeRoot,
		RuntimeMode:    runtimeModeNAS,
		Version:        "test",
		Now:            func() time.Time { return now },
	})
	if !snapshot.Delivery.Running || snapshot.Delivery.Result != "running" || snapshot.Delivery.Evidence != "embedded-scheduler" || snapshot.Delivery.LastAttemptUTC != now.Format(time.RFC3339) {
		t.Fatalf("active embedded delivery was hidden by stale renderer evidence: %+v", snapshot.Delivery)
	}
	if snapshot.Schedule.State != "running" || snapshot.Runtime.Scheduler != "running" {
		t.Fatalf("fresh supervisor heartbeat did not preserve active scheduler state: schedule=%+v runtime=%+v", snapshot.Schedule, snapshot.Runtime)
	}
	if snapshot.Delivery.SMTPAcceptedCount != 0 || snapshot.Delivery.ExitCode != nil {
		t.Fatalf("active embedded delivery retained stale terminal evidence: %+v", snapshot.Delivery)
	}
}
func TestContainerProfilesReportExplicitHostBoundaries(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name               string
		options            Options
		wantProfile        string
		wantPackage        string
		wantLifecycle      string
		wantNetworkScope   string
		wantUpdateProvider string
	}{
		{"desktop", Options{RuntimeMode: runtimeModeMac, RuntimeProfile: runtimeProfileDesktop, PackageKind: packageKindContainerDesktop}, runtimeProfileDesktop, packageKindContainerDesktop, "docker-desktop", "host-loopback", packageKindContainerDesktop},
		{"server", Options{RuntimeMode: runtimeModeNAS, RuntimeProfile: runtimeProfileServer, PackageKind: packageKindContainerCompose}, runtimeProfileServer, packageKindContainerCompose, "container-host", "trusted-lan", packageKindContainerCompose},
		{"unraid", Options{RuntimeMode: runtimeModeNAS, RuntimeProfile: runtimeProfileUnraid, PackageKind: packageKindUnraid}, runtimeProfileUnraid, packageKindUnraid, "unraid-host", "trusted-lan", packageKindUnraid},
		{"legacy NAS default", Options{RuntimeMode: runtimeModeNAS, PackageKind: packageKindNAS}, runtimeProfileServer, packageKindNAS, "container-host", "trusted-lan", packageKindNAS},
		{"legacy Mac default", Options{RuntimeMode: runtimeModeMac, PackageKind: packageKindMacRegistry}, runtimeProfileDesktop, packageKindMacRegistry, "docker-desktop", "host-loopback", "mac-registry"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got := capabilitiesFor(test.options)
			if got.RuntimeProfile != test.wantProfile || got.PackageKind != test.wantPackage ||
				got.LifecycleProvider != test.wantLifecycle || got.NetworkScope != test.wantNetworkScope ||
				got.UpdateProvider != test.wantUpdateProvider || got.Authentication != "required" {
				t.Fatalf("profile capability boundary: got %+v", got)
			}
		})
	}
}
