package manager

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

type updateRoundTripFunc func(*http.Request) (*http.Response, error)

func (f updateRoundTripFunc) RoundTrip(request *http.Request) (*http.Response, error) {
	return f(request)
}

type fixtureUpdateChecker struct {
	mu      sync.Mutex
	release updateRelease
	err     error
	wait    bool
	calls   int
	channel string
	asset   string
}

func (f *fixtureUpdateChecker) Check(ctx context.Context, channel, asset string) (updateRelease, error) {
	f.mu.Lock()
	f.calls++
	f.channel = channel
	f.asset = asset
	wait := f.wait
	release := f.release
	err := f.err
	f.mu.Unlock()
	if wait {
		<-ctx.Done()
		return updateRelease{}, ctx.Err()
	}
	return release, err
}

func (f *fixtureUpdateChecker) callCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.calls
}

type fixtureUpdateInstaller struct {
	supported bool
	started   int
	startErr  error
	result    chan error
}

func (f *fixtureUpdateInstaller) Supported() bool { return f.supported }
func (f *fixtureUpdateInstaller) Start() (<-chan error, error) {
	f.started++
	if f.startErr != nil {
		return nil, f.startErr
	}
	if f.result == nil {
		f.result = make(chan error, 1)
	}
	return f.result, nil
}

func TestSemanticVersionComparisonAndUpdateClassification(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name      string
		status    UpdateStatus
		wantState string
		available bool
	}{
		{name: "current", status: checkedStatus("1.2.3", "1.2.3", "1.2.3"), wantState: "current"},
		{name: "update available", status: checkedStatus("1.2.3", "1.2.3", "1.3.0"), wantState: "update-available", available: true},
		{name: "legacy wrapper", status: func() UpdateStatus {
			value := checkedStatus("1.2.3", "1.2.3", "1.3.0")
			value.HostAdapterState = "legacy"
			return value
		}(), wantState: "legacy", available: true},
		{name: "package and image mismatch", status: checkedStatus("1.2.3", "1.2.2", "1.3.0"), wantState: "mismatched", available: true},
		{name: "newer than stable does not downgrade", status: checkedStatus("2.0.0", "2.0.0", "1.9.9"), wantState: "newer"},
		{name: "prerelease ahead of older stable", status: checkedStatus("2.0.0-rc.1", "2.0.0-rc.1", "1.9.9"), wantState: "newer"},
		{name: "prerelease advances to matching stable", status: checkedStatus("2.0.0-rc.1", "2.0.0-rc.1", "2.0.0"), wantState: "update-available", available: true},
		{name: "unsupported channel", status: func() UpdateStatus {
			value := checkedStatus("1.2.3", "1.2.3", "1.2.3")
			value.UpdateChannel = "unsupported"
			return value
		}(), wantState: "unknown"},
		{name: "no successful check", status: func() UpdateStatus {
			value := checkedStatus("1.2.3", "1.2.3", "1.2.3")
			value.LastSuccessfulCheckUTC = ""
			return value
		}(), wantState: "unknown"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			state, available := classifyUpdateStatus(test.status)
			if state != test.wantState || available != test.available {
				t.Fatalf("classification: got %q available=%v, want %q available=%v", state, available, test.wantState, test.available)
			}
		})
	}

	invalid := []string{"", "1", "1.2", "01.2.3", "1.2.3-01", "1.2.3-", "1.2.3+"}
	for _, value := range invalid {
		if _, ok := parseSemanticVersion(value); ok {
			t.Errorf("invalid semantic version %q was accepted", value)
		}
	}
}

func checkedStatus(application, packaged, latest string) UpdateStatus {
	return UpdateStatus{
		ApplicationVersion:     application,
		PackageVersion:         packaged,
		LatestStableVersion:    latest,
		UpdateChannel:          "stable",
		HostAdapterState:       "current",
		LastSuccessfulCheckUTC: "2031-04-18T16:30:00Z",
	}
}

func TestStableReleaseMetadataRequiresExactStableAssetsAndURLs(t *testing.T) {
	t.Parallel()
	valid := releaseMetadataForTest("1.4.2", false, false, []map[string]string{
		{"name": "SHA256SUMS.txt", "browser_download_url": stableReleaseDownloadURL + "1.4.2/SHA256SUMS.txt"},
		{"name": "TautWeekly-linux.tar.gz", "browser_download_url": stableReleaseDownloadURL + "1.4.2/TautWeekly-linux.tar.gz"},
	})
	release, err := parseStableReleaseMetadata(valid, "TautWeekly-linux.tar.gz")
	if err != nil || release.Version != "1.4.2" || release.ReleaseNotesURL != stableReleaseBaseURL+"1.4.2" {
		t.Fatalf("valid release metadata: release=%+v err=%v", release, err)
	}

	tests := []struct {
		name string
		raw  []byte
	}{
		{name: "malformed", raw: []byte(`{"tag_name":`)},
		{name: "prerelease flag", raw: releaseMetadataForTest("1.5.0-rc.1", false, true, []map[string]string{})},
		{name: "stable tag with build metadata", raw: releaseMetadataForTest("1.5.0+build", false, false, []map[string]string{})},
		{name: "missing checksum", raw: releaseMetadataForTest("1.4.2", false, false, []map[string]string{{"name": "TautWeekly-linux.tar.gz", "browser_download_url": stableReleaseDownloadURL + "1.4.2/TautWeekly-linux.tar.gz"}})},
		{name: "duplicate checksum", raw: releaseMetadataForTest("1.4.2", false, false, []map[string]string{{"name": "SHA256SUMS.txt", "browser_download_url": stableReleaseDownloadURL + "1.4.2/SHA256SUMS.txt"}, {"name": "SHA256SUMS.txt", "browser_download_url": stableReleaseDownloadURL + "1.4.2/SHA256SUMS.txt"}, {"name": "TautWeekly-linux.tar.gz", "browser_download_url": stableReleaseDownloadURL + "1.4.2/TautWeekly-linux.tar.gz"}})},
		{name: "unexpected asset host", raw: releaseMetadataForTest("1.4.2", false, false, []map[string]string{{"name": "SHA256SUMS.txt", "browser_download_url": "https://example.test/SHA256SUMS.txt"}, {"name": "TautWeekly-linux.tar.gz", "browser_download_url": stableReleaseDownloadURL + "1.4.2/TautWeekly-linux.tar.gz"}})},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if _, err := parseStableReleaseMetadata(test.raw, "TautWeekly-linux.tar.gz"); err == nil {
				t.Fatal("invalid release metadata was accepted")
			}
		})
	}
}

func TestGitHubReleaseCheckerUsesFixedBoundedVerifiedResponse(t *testing.T) {
	t.Parallel()
	valid := releaseMetadataForTest("1.4.2", false, false, []map[string]string{
		{"name": "SHA256SUMS.txt", "browser_download_url": stableReleaseDownloadURL + "1.4.2/SHA256SUMS.txt"},
		{"name": "TautWeekly-windows.zip", "browser_download_url": stableReleaseDownloadURL + "1.4.2/TautWeekly-windows.zip"},
	})
	tests := []struct {
		name        string
		status      int
		contentType string
		body        string
		wantCode    string
	}{
		{name: "valid", status: http.StatusOK, contentType: "application/vnd.github+json; charset=utf-8", body: string(valid)},
		{name: "invalid content type", status: http.StatusOK, contentType: "text/html", body: string(valid), wantCode: "invalid-metadata"},
		{name: "oversized response", status: http.StatusOK, contentType: "application/json", body: strings.Repeat(" ", maximumReleaseBytes+1), wantCode: "invalid-metadata"},
		{name: "rate limited", status: http.StatusTooManyRequests, contentType: "application/json", body: `{}`, wantCode: "upstream-rate-limited"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			transport := updateRoundTripFunc(func(request *http.Request) (*http.Response, error) {
				if request.Method != http.MethodGet || request.URL.String() != stableReleaseEndpoint || request.Header.Get("User-Agent") != "TautWeekly-Manager-update-check" {
					t.Fatalf("unexpected release request: %s %s headers=%v", request.Method, request.URL, request.Header)
				}
				return &http.Response{StatusCode: test.status, Header: http.Header{"Content-Type": []string{test.contentType}}, Body: io.NopCloser(strings.NewReader(test.body))}, nil
			})
			checker := githubReleaseChecker{client: &http.Client{Timeout: time.Second, Transport: transport}}
			release, err := checker.Check(context.Background(), "stable", "TautWeekly-windows.zip")
			if test.wantCode == "" {
				if err != nil || release.Version != "1.4.2" {
					t.Fatalf("valid response: release=%+v err=%v", release, err)
				}
				return
			}
			var typed updateCheckError
			if !errors.As(err, &typed) || typed.code != test.wantCode {
				t.Fatalf("error code: got %v, want %s", err, test.wantCode)
			}
		})
	}
	checker := newGitHubReleaseChecker()
	if err := checker.client.CheckRedirect(&http.Request{}, []*http.Request{{}}); err == nil {
		t.Fatal("release metadata redirects were accepted")
	}
}

func releaseMetadataForTest(version string, draft, prerelease bool, assets []map[string]string) []byte {
	payload := map[string]any{
		"tag_name":   "v" + version,
		"html_url":   stableReleaseBaseURL + version,
		"draft":      draft,
		"prerelease": prerelease,
		"assets":     assets,
	}
	raw, _ := json.Marshal(payload)
	return raw
}

func TestUpdateStatusIsLocalAndManualCheckPersistsSanitizedCache(t *testing.T) {
	now := time.Date(2031, 4, 18, 16, 30, 0, 0, time.UTC)
	checker := &fixtureUpdateChecker{release: updateRelease{Version: "1.1.0", ReleaseNotesURL: stableReleaseBaseURL + "1.1.0"}}
	root := t.TempDir()
	data := t.TempDir()
	server, err := New(Options{
		DataDir:                   data,
		TautWeeklyRoot:            root,
		Version:                   "1.0.0",
		RuntimeMode:               runtimeModeLinux,
		PackageVersion:            "1.0.0",
		UpdateChannel:             "stable",
		Now:                       func() time.Time { return now },
		updateChecker:             checker,
		updateMinimumCheckDelay:   time.Second,
		updateMaximumFailureDelay: time.Minute,
	})
	if err != nil {
		t.Fatal(err)
	}
	current, err := server.auth.newSession()
	if err != nil {
		t.Fatal(err)
	}
	cookie := &http.Cookie{Name: sessionCookieName, Value: current.Token}

	local := requestForTest(server, http.MethodGet, "/api/v1/updates", nil, cookie)
	if local.Code != http.StatusOK || checker.callCount() != 0 || !strings.Contains(local.Body.String(), `"state":"unknown"`) {
		t.Fatalf("local status contacted upstream or returned an invalid state: code=%d calls=%d body=%s", local.Code, checker.callCount(), local.Body.String())
	}
	live := requestForTest(server, http.MethodGet, "/health/live", nil, nil)
	if live.Code != http.StatusOK || checker.callCount() != 0 {
		t.Fatalf("liveness depended on update service: code=%d calls=%d", live.Code, checker.callCount())
	}

	checked := mutationRequestForTest(server, http.MethodPost, "/api/v1/updates/check", nil, cookie, current.CSRFToken)
	if checked.Code != http.StatusOK || checker.callCount() != 1 || !strings.Contains(checked.Body.String(), `"state":"update-available"`) || !strings.Contains(checked.Body.String(), `"installSupported":false`) {
		t.Fatalf("manual check: code=%d calls=%d body=%s", checked.Code, checker.callCount(), checked.Body.String())
	}
	if checker.channel != "stable" || checker.asset != "TautWeekly-linux.tar.gz" {
		t.Fatalf("checker capability routing: channel=%q asset=%q", checker.channel, checker.asset)
	}

	restarted, err := New(Options{DataDir: data, TautWeeklyRoot: root, Version: "1.0.0", RuntimeMode: runtimeModeLinux, PackageVersion: "1.0.0", updateChecker: checker})
	if err != nil {
		t.Fatal(err)
	}
	restartedSession, _ := restarted.auth.newSession()
	restartedCookie := &http.Cookie{Name: sessionCookieName, Value: restartedSession.Token}
	persisted := requestForTest(restarted, http.MethodGet, "/api/v1/updates", nil, restartedCookie)
	if persisted.Code != http.StatusOK || !strings.Contains(persisted.Body.String(), `"latestStableVersion":"1.1.0"`) || checker.callCount() != 1 {
		t.Fatalf("persisted local cache: code=%d calls=%d body=%s", persisted.Code, checker.callCount(), persisted.Body.String())
	}
}

func TestBackgroundUpdateCheckRecommendationUsesFreshnessBackoffAndChannel(t *testing.T) {
	now := time.Date(2031, 4, 18, 16, 30, 0, 0, time.UTC)
	currentNow := now
	checker := &fixtureUpdateChecker{release: updateRelease{Version: "1.1.0", ReleaseNotesURL: stableReleaseBaseURL + "1.1.0"}}
	coordinator := newUpdateCoordinator(Options{
		DataDir:                   t.TempDir(),
		TautWeeklyRoot:            t.TempDir(),
		Version:                   "1.0.0",
		RuntimeMode:               runtimeModeLinux,
		PackageVersion:            "1.0.0",
		Now:                       func() time.Time { return currentNow },
		updateChecker:             checker,
		updateMinimumCheckDelay:   time.Minute,
		updateMaximumFailureDelay: time.Hour,
	})
	if status := coordinator.Status(); !status.BackgroundCheckRecommended || status.CheckInProgress {
		t.Fatalf("absent cache did not recommend one background check: %+v", status)
	}
	checked, err := coordinator.CheckNow(context.Background())
	if err != nil || checked.BackgroundCheckRecommended || checker.callCount() != 1 {
		t.Fatalf("fresh successful check recommendation: status=%+v calls=%d err=%v", checked, checker.callCount(), err)
	}
	currentNow = now.Add(updateBackgroundMaxAge - time.Second)
	if status := coordinator.Status(); status.BackgroundCheckRecommended {
		t.Fatalf("fresh cached check was treated as stale: %+v", status)
	}
	currentNow = now.Add(updateBackgroundMaxAge)
	if status := coordinator.Status(); !status.BackgroundCheckRecommended || status.State != "update-available" {
		t.Fatalf("stale cached result did not remain visible while recommending refresh: %+v", status)
	}

	failureNow := now
	failureChecker := &fixtureUpdateChecker{err: errors.New("synthetic offline")}
	failure := newUpdateCoordinator(Options{
		DataDir:                 t.TempDir(),
		TautWeeklyRoot:          t.TempDir(),
		Version:                 "1.0.0",
		RuntimeMode:             runtimeModeLinux,
		PackageVersion:          "1.0.0",
		Now:                     func() time.Time { return failureNow },
		updateChecker:           failureChecker,
		updateMinimumCheckDelay: time.Minute,
	})
	failed, err := failure.CheckNow(context.Background())
	if err != nil || failed.BackgroundCheckRecommended || failed.LastFailure == nil {
		t.Fatalf("failure backoff did not suppress background checks: status=%+v err=%v", failed, err)
	}
	failureNow = now.Add(time.Minute)
	if status := failure.Status(); !status.BackgroundCheckRecommended {
		t.Fatalf("expired failure backoff did not permit a later session check: %+v", status)
	}

	unsupported := newUpdateCoordinator(Options{DataDir: t.TempDir(), TautWeeklyRoot: t.TempDir(), Version: "1.0.0", RuntimeMode: runtimeModeLinux, PackageVersion: "1.0.0", UpdateChannel: "edge", updateChecker: checker})
	if status := unsupported.Status(); status.BackgroundCheckRecommended || status.UpdateChannel != "unsupported" {
		t.Fatalf("unsupported channel recommended a background check: %+v", status)
	}
}

func TestBackgroundUpdateCheckRecommendationSuppressesConcurrentChecks(t *testing.T) {
	checker := &fixtureUpdateChecker{wait: true}
	coordinator := newUpdateCoordinator(Options{DataDir: t.TempDir(), TautWeeklyRoot: t.TempDir(), Version: "1.0.0", RuntimeMode: runtimeModeLinux, PackageVersion: "1.0.0", updateChecker: checker})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		_, _ = coordinator.CheckNow(ctx)
		close(done)
	}()
	deadline := time.Now().Add(time.Second)
	for checker.callCount() == 0 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	status := coordinator.Status()
	if !status.CheckInProgress || status.BackgroundCheckRecommended {
		cancel()
		<-done
		t.Fatalf("active check did not suppress another background recommendation: %+v", status)
	}
	if _, err := coordinator.CheckNow(context.Background()); err == nil || err.Error() != "check-in-progress" || checker.callCount() != 1 {
		cancel()
		<-done
		t.Fatalf("concurrent check was not suppressed: calls=%d err=%v", checker.callCount(), err)
	}
	cancel()
	<-done
}

func TestUpdateCheckTimeoutBackoffAndUnsupportedChannelAreSanitized(t *testing.T) {
	now := time.Date(2031, 4, 18, 16, 30, 0, 0, time.UTC)
	checker := &fixtureUpdateChecker{wait: true}
	coordinator := newUpdateCoordinator(Options{
		DataDir:                   t.TempDir(),
		TautWeeklyRoot:            t.TempDir(),
		Version:                   "1.0.0",
		RuntimeMode:               runtimeModeLinux,
		PackageVersion:            "1.0.0",
		Now:                       func() time.Time { return now },
		updateChecker:             checker,
		updateMinimumCheckDelay:   time.Second,
		updateMaximumFailureDelay: time.Minute,
	})
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Millisecond)
	defer cancel()
	status, err := coordinator.CheckNow(ctx)
	if err != nil || status.LastFailure == nil || status.LastFailure.Code != "timeout" || status.State != "unknown" {
		t.Fatalf("timeout status: status=%+v err=%v", status, err)
	}
	if strings.Contains(strings.ToLower(status.LastFailure.Message), "context") {
		t.Fatalf("timeout exposed raw error: %+v", status.LastFailure)
	}
	if _, err := coordinator.CheckNow(context.Background()); err == nil || err.Error() != "check-backoff" {
		t.Fatalf("backoff did not limit repeated check: %v", err)
	}

	offlineChecker := &fixtureUpdateChecker{err: errors.New("dial failed with private-token-must-not-appear")}
	offline := newUpdateCoordinator(Options{DataDir: t.TempDir(), TautWeeklyRoot: t.TempDir(), Version: "1.0.0", RuntimeMode: runtimeModeLinux, PackageVersion: "1.0.0", Now: func() time.Time { return now }, updateChecker: offlineChecker})
	offlineStatus, err := offline.CheckNow(context.Background())
	if err != nil || offlineStatus.LastFailure == nil || offlineStatus.LastFailure.Code != "offline" || strings.Contains(offlineStatus.LastFailure.Message, "private-token") {
		t.Fatalf("offline failure was not sanitized: status=%+v err=%v", offlineStatus, err)
	}

	unsupportedChecker := &fixtureUpdateChecker{err: updateCheckError{code: "unsupported-channel"}}
	unsupported := newUpdateCoordinator(Options{DataDir: t.TempDir(), TautWeeklyRoot: t.TempDir(), Version: "1.0.0", RuntimeMode: runtimeModeLinux, PackageVersion: "1.0.0", UpdateChannel: "edge", Now: func() time.Time { return now }, updateChecker: unsupportedChecker})
	unsupportedStatus, err := unsupported.CheckNow(context.Background())
	if err != nil || unsupportedStatus.UpdateChannel != "unsupported" || unsupportedStatus.LastFailure == nil || unsupportedStatus.LastFailure.Code != "unsupported-channel" {
		t.Fatalf("unsupported channel status: status=%+v err=%v", unsupportedStatus, err)
	}
}

func TestUpdateEndpointsRequireAuthenticationCSRFOriginAndAllowedHost(t *testing.T) {
	t.Parallel()
	checker := &fixtureUpdateChecker{release: updateRelease{Version: "1.0.0", ReleaseNotesURL: stableReleaseBaseURL + "1.0.0"}}
	server, err := New(Options{
		DataDir:            t.TempDir(),
		TautWeeklyRoot:     t.TempDir(),
		Version:            "1.0.0",
		RuntimeMode:        runtimeModeNAS,
		PackageKind:        packageKindUnraid,
		HostAdapterVersion: currentHostAdapterAPI,
		AllowedHosts:       []string{"weekly.nas.example"},
		updateChecker:      checker,
	})
	if err != nil {
		t.Fatal(err)
	}
	unauthorized := requestForTest(server, http.MethodGet, "/api/v1/updates", nil, nil)
	if unauthorized.Code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated update status: got %d", unauthorized.Code)
	}
	unauthorizedInstall := requestForTest(server, http.MethodPost, "/api/v1/updates/install", nil, nil)
	if unauthorizedInstall.Code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated update install: got %d", unauthorizedInstall.Code)
	}
	current, _ := server.auth.newSession()
	cookie := &http.Cookie{Name: sessionCookieName, Value: current.Token}
	withoutCSRF := requestForTest(server, http.MethodPost, "/api/v1/updates/check", nil, cookie)
	if withoutCSRF.Code != http.StatusForbidden || checker.callCount() != 0 {
		t.Fatalf("check without CSRF: code=%d calls=%d", withoutCSRF.Code, checker.callCount())
	}
	installWithoutCSRF := requestForTest(server, http.MethodPost, "/api/v1/updates/install", nil, cookie)
	if installWithoutCSRF.Code != http.StatusForbidden {
		t.Fatalf("install without CSRF: code=%d", installWithoutCSRF.Code)
	}

	wrongOrigin := httptest.NewRequest(http.MethodPost, "/api/v1/updates/check", nil)
	wrongOrigin.Host = "weekly.nas.example"
	wrongOrigin.Header.Set("Origin", "https://attacker.example")
	wrongOrigin.Header.Set("X-CSRF-Token", current.CSRFToken)
	wrongOrigin.AddCookie(cookie)
	wrongOriginResponse := httptest.NewRecorder()
	server.Handler().ServeHTTP(wrongOriginResponse, wrongOrigin)
	if wrongOriginResponse.Code != http.StatusForbidden || checker.callCount() != 0 {
		t.Fatalf("wrong origin: code=%d calls=%d", wrongOriginResponse.Code, checker.callCount())
	}

	invalidHost := httptest.NewRequest(http.MethodGet, "/api/v1/updates", nil)
	invalidHost.Host = "attacker.example"
	invalidHost.AddCookie(cookie)
	invalidHostResponse := httptest.NewRecorder()
	server.Handler().ServeHTTP(invalidHostResponse, invalidHost)
	if invalidHostResponse.Code != http.StatusBadRequest {
		t.Fatalf("invalid Host: got %d", invalidHostResponse.Code)
	}

	allowed := httptest.NewRequest(http.MethodPost, "/api/v1/updates/check", nil)
	allowed.Host = "weekly.nas.example"
	allowed.Header.Set("Origin", "https://weekly.nas.example")
	allowed.Header.Set("X-CSRF-Token", current.CSRFToken)
	allowed.AddCookie(cookie)
	allowedResponse := httptest.NewRecorder()
	server.Handler().ServeHTTP(allowedResponse, allowed)
	if allowedResponse.Code != http.StatusOK || checker.callCount() != 1 {
		t.Fatalf("allowed reverse-proxy host: code=%d calls=%d body=%s", allowedResponse.Code, checker.callCount(), allowedResponse.Body.String())
	}
}

func TestWindowsInstallActionUsesOnlyInjectedVerifiedUpdaterWhenReady(t *testing.T) {
	now := time.Date(2031, 4, 18, 16, 30, 0, 0, time.UTC)
	currentNow := now
	data := t.TempDir()
	root := t.TempDir()
	checker := &fixtureUpdateChecker{release: updateRelease{Version: "1.1.0", ReleaseNotesURL: stableReleaseBaseURL + "1.1.0"}}
	installer := &fixtureUpdateInstaller{supported: true, result: make(chan error, 1)}
	server, err := New(Options{
		DataDir:                 data,
		TautWeeklyRoot:          root,
		Version:                 "1.0.0",
		RuntimeMode:             runtimeModeWindows,
		PackageKind:             packageKindWindows,
		PackageVersion:          "1.0.0",
		Now:                     func() time.Time { return currentNow },
		updateChecker:           checker,
		updateInstaller:         installer,
		updateMinimumCheckDelay: time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}
	current, _ := server.auth.newSession()
	cookie := &http.Cookie{Name: sessionCookieName, Value: current.Token}
	tooEarly := mutationRequestForTest(server, http.MethodPost, "/api/v1/updates/install", nil, cookie, current.CSRFToken)
	if tooEarly.Code != http.StatusConflict || installer.started != 0 {
		t.Fatalf("install before verified check: code=%d starts=%d body=%s", tooEarly.Code, installer.started, tooEarly.Body.String())
	}
	check := mutationRequestForTest(server, http.MethodPost, "/api/v1/updates/check", nil, cookie, current.CSRFToken)
	if check.Code != http.StatusOK || !strings.Contains(check.Body.String(), `"installSupported":true`) {
		t.Fatalf("ready Windows check: code=%d body=%s", check.Code, check.Body.String())
	}
	currentNow = now.Add(2 * time.Hour)
	stale := mutationRequestForTest(server, http.MethodPost, "/api/v1/updates/install", nil, cookie, current.CSRFToken)
	if stale.Code != http.StatusConflict || installer.started != 0 || !strings.Contains(stale.Body.String(), "install-check-stale") {
		t.Fatalf("install after stale check: code=%d starts=%d body=%s", stale.Code, installer.started, stale.Body.String())
	}
	currentNow = now
	install := mutationRequestForTest(server, http.MethodPost, "/api/v1/updates/install", []byte(`{"ignored":"browser input is never decoded"}`), cookie, current.CSRFToken)
	if install.Code != http.StatusAccepted || installer.started != 1 || !strings.Contains(install.Body.String(), `"installState":"running"`) {
		t.Fatalf("Windows install start: code=%d starts=%d body=%s", install.Code, installer.started, install.Body.String())
	}
	installer.result <- nil
	close(installer.result)
	deadline := time.Now().Add(time.Second)
	for server.updates.Status().InstallState != "completed" && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if state := server.updates.Status().InstallState; state != "completed" {
		t.Fatalf("completed installer state: got %q", state)
	}

	restarted := newUpdateCoordinator(Options{
		DataDir:        data,
		TautWeeklyRoot: root,
		Version:        "1.1.0",
		RuntimeMode:    runtimeModeWindows,
		PackageKind:    packageKindWindows,
		PackageVersion: "1.1.0",
		Now:            func() time.Time { return currentNow },
		updateChecker:  checker,
	})
	afterRestart := restarted.Status()
	if afterRestart.State != "current" || afterRestart.InstallState != "idle" || afterRestart.UpdateAvailable || afterRestart.BackgroundCheckRecommended {
		t.Fatalf("post-update restart status: %+v", afterRestart)
	}
}

func TestUpdateCacheRejectsTamperedPrivateContent(t *testing.T) {
	secret := "private-token-must-not-appear"
	cases := map[string][]byte{
		"invalid version and URL":  []byte(`{"schemaVersion":1,"latestStableVersion":"` + secret + `","releaseNotesUrl":"https://attacker.example/` + secret + `"}`),
		"orphan release URL":       []byte(`{"schemaVersion":1,"releaseNotesUrl":"https://attacker.example/` + secret + `"}`),
		"orphan success timestamp": []byte(`{"schemaVersion":1,"lastSuccessfulCheckUtc":"2026-08-18T12:00:00Z"}`),
		"oversized cache":          append([]byte(`{"schemaVersion":1,"releaseNotesUrl":"https://attacker.example/`+secret+`","padding":"`), append(make([]byte, maximumUpdateCacheBytes), []byte(`"}`)...)...),
	}
	for name, content := range cases {
		t.Run(name, func(t *testing.T) {
			data := t.TempDir()
			if err := os.WriteFile(filepath.Join(data, "update-status.json"), content, 0o600); err != nil {
				t.Fatal(err)
			}
			coordinator := newUpdateCoordinator(Options{DataDir: data, TautWeeklyRoot: t.TempDir(), Version: "1.0.0", RuntimeMode: runtimeModeLinux, PackageVersion: "1.0.0", updateChecker: &fixtureUpdateChecker{}})
			raw, err := json.Marshal(coordinator.Status())
			if err != nil {
				t.Fatal(err)
			}
			if strings.Contains(string(raw), secret) || strings.Contains(string(raw), "attacker.example") || strings.Contains(string(raw), "2026-08-18T12:00:00Z") {
				t.Fatalf("tampered update cache reached API: %s", raw)
			}
		})
	}
}

func TestUpdatePackageLanguageAndLegacyAdapterMatrix(t *testing.T) {
	t.Parallel()
	tests := []struct {
		kind      string
		mode      string
		command   string
		owner     string
		container bool
	}{
		{packageKindWindows, runtimeModeWindows, "", "Windows", false},
		{packageKindLinux, runtimeModeLinux, "sudo tautweekly update", "Linux", false},
		{packageKindMac, runtimeModeMac, "./tautweekly.sh update", "Mac", true},
		{packageKindFreeBSD, runtimeModeNAS, "sudo tautweekly update", "FreeBSD", true},
		{packageKindNAS, runtimeModeNAS, "./tautweekly.sh update", "Docker Compose", true},
		{packageKindQNAP, runtimeModeNAS, "./tautweekly.sh update", "QNAP Container Station", true},
		{packageKindUnraid, runtimeModeNAS, "", "Unraid", true},
		{packageKindCompatibleDocker, runtimeModeNAS, "docker compose pull", "Container host", true},
	}
	for _, test := range tests {
		t.Run(test.kind, func(t *testing.T) {
			guidance := updateGuidance(test.kind)
			if !strings.Contains(guidance.Owner, test.owner) || (test.command != "" && !strings.Contains(guidance.Command, test.command)) {
				t.Fatalf("guidance for %s: %+v", test.kind, guidance)
			}
			status := newUpdateCoordinator(Options{DataDir: t.TempDir(), TautWeeklyRoot: t.TempDir(), Version: "1.0.0", RuntimeMode: test.mode, PackageKind: test.kind, PackageVersion: "1.0.0", HostAdapterVersion: "2", updateChecker: &fixtureUpdateChecker{}}).Status()
			if (status.ImageVersion != "") != test.container {
				t.Fatalf("image version presence for %s: %+v", test.kind, status)
			}
			if requiresHostAdapter(test.kind) && status.HostAdapterState != "legacy" {
				t.Fatalf("legacy adapter was not identified for %s: %+v", test.kind, status)
			}
			if status.SchemaVersion != updateStatusSchemaVersion || !status.BackgroundCheckRecommended {
				t.Fatalf("shared update bootstrap contract for %s: %+v", test.kind, status)
			}
		})
	}
}
