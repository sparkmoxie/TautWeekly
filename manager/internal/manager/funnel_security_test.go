package manager

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type fixturePublicRemoteAccessController struct {
	status         TailscaleRemoteAccessStatus
	allowed        string
	configured     bool
	ensureInactive error
	updates        []bool
}

func (f *fixturePublicRemoteAccessController) Status(context.Context) TailscaleRemoteAccessStatus {
	return f.status
}
func (f *fixturePublicRemoteAccessController) Verify(context.Context) (TailscaleRemoteAccessStatus, error) {
	return f.status, nil
}
func (f *fixturePublicRemoteAccessController) AllowsHost(value string) bool {
	return strings.EqualFold(hostnameOnly(value), f.allowed)
}
func (f *fixturePublicRemoteAccessController) PublicExposureConfigured() bool { return f.configured }
func (f *fixturePublicRemoteAccessController) EnsureInactive(context.Context) (TailscaleRemoteAccessStatus, error) {
	if f.ensureInactive != nil {
		return f.status, f.ensureInactive
	}
	f.configured = false
	f.status.Enabled = false
	f.status.Active = false
	f.status.CleanupRequired = false
	f.status.State = "inactive"
	return f.status, nil
}

type fixturePublicRemoteAccessAdapter struct {
	*fixturePublicRemoteAccessController
}

func (f *fixturePublicRemoteAccessAdapter) Update(_ context.Context, enabled bool, _ string, _ bool) (TailscaleRemoteAccessStatus, error) {
	f.updates = append(f.updates, enabled)
	f.configured = enabled
	f.status.Enabled = enabled
	f.status.Active = enabled
	f.status.CleanupRequired = enabled
	f.status.State = map[bool]string{true: "active", false: "inactive"}[enabled]
	return f.status, nil
}

func newFixturePublicController() *fixturePublicRemoteAccessAdapter {
	return &fixturePublicRemoteAccessAdapter{&fixturePublicRemoteAccessController{
		status: TailscaleRemoteAccessStatus{
			Supported: true, Installed: true, State: "inactive", Provider: "tailscale", NetworkKind: "public-funnel", Management: "integrated",
		},
	}}
}

func TestPublicFunnelRequiresPasswordAndTypedAllowlistedOperation(t *testing.T) {
	remote := newFixturePublicController()
	server, err := New(Options{DataDir: t.TempDir(), TautWeeklyRoot: t.TempDir(), Version: "test", RuntimeMode: runtimeModeWindows, remoteAccessController: remote})
	if err != nil {
		t.Fatal(err)
	}
	current, err := server.auth.newSession()
	if err != nil {
		t.Fatal(err)
	}
	cookie := &http.Cookie{Name: sessionCookieName, Value: current.Token}

	request := mutationRequestForTest(server, http.MethodPut, "/api/v1/remote-access/tailscale", []byte(`{"operation":"enable"}`), cookie, current.CSRFToken)
	if request.Code != http.StatusConflict || !strings.Contains(request.Body.String(), `"code":"manager-password-required"`) || len(remote.updates) != 0 {
		t.Fatalf("passwordless Funnel enable was not blocked: code=%d body=%s updates=%v", request.Code, request.Body.String(), remote.updates)
	}
	for _, body := range []string{
		`{"enabled":true}`,
		`{"operation":"start"}`,
		`{"operation":"enable","url":"https://attacker.invalid"}`,
		`{"operation":"enable","command":"tailscale funnel 9999"}`,
	} {
		response := mutationRequestForTest(server, http.MethodPut, "/api/v1/remote-access/tailscale", []byte(body), cookie, current.CSRFToken)
		if response.Code != http.StatusBadRequest || len(remote.updates) != 0 {
			t.Fatalf("unsafe Funnel request %s reached the controller: code=%d updates=%v body=%s", body, response.Code, remote.updates, response.Body.String())
		}
	}

	password := mutationRequestForTest(server, http.MethodPost, "/api/v1/auth/access/password", []byte(`{"password":"unique public manager password"}`), cookie, current.CSRFToken)
	if password.Code != http.StatusOK {
		t.Fatalf("password setup: code=%d body=%s", password.Code, password.Body.String())
	}
	enabled := mutationRequestForTest(server, http.MethodPut, "/api/v1/remote-access/tailscale", []byte(`{"operation":"enable"}`), cookie, current.CSRFToken)
	if enabled.Code != http.StatusOK || len(remote.updates) != 1 || !remote.updates[0] {
		t.Fatalf("typed Funnel enable did not reach the controller: code=%d updates=%v body=%s", enabled.Code, remote.updates, enabled.Body.String())
	}
}

func TestPublicFunnelHostAdmissionRequiresActivePasswordLock(t *testing.T) {
	const hostname = "public.example-tailnet.ts.net"
	remote := newFixturePublicController()
	remote.allowed = hostname
	remote.configured = true
	remote.status.Enabled = true
	remote.status.Active = true
	remote.status.URL = "https://" + hostname
	server, err := New(Options{DataDir: t.TempDir(), TautWeeklyRoot: t.TempDir(), Version: "test", RuntimeMode: runtimeModeWindows, remoteAccessController: remote})
	if err != nil {
		t.Fatal(err)
	}
	blocked := httptest.NewRequest(http.MethodGet, "/", nil)
	blocked.Host = hostname
	blockedResponse := httptest.NewRecorder()
	server.Handler().ServeHTTP(blockedResponse, blocked)
	if blockedResponse.Code != http.StatusBadRequest || !strings.Contains(blockedResponse.Body.String(), `"code":"invalid-host"`) {
		t.Fatalf("passwordless public Host was admitted: code=%d body=%s", blockedResponse.Code, blockedResponse.Body.String())
	}
	if err := server.auth.setPasswordLock("unique host boundary password"); err != nil {
		t.Fatal(err)
	}
	allowed := httptest.NewRequest(http.MethodGet, "/api/v1/auth/session", nil)
	allowed.Host = hostname
	allowedResponse := httptest.NewRecorder()
	server.Handler().ServeHTTP(allowedResponse, allowed)
	if allowedResponse.Code != http.StatusUnauthorized || allowedResponse.Header().Get("Strict-Transport-Security") == "" {
		t.Fatalf("public login boundary was not enforced over HTTPS: code=%d hsts=%q", allowedResponse.Code, allowedResponse.Header().Get("Strict-Transport-Security"))
	}
	if err := os.Remove(server.auth.credentialPath); err != nil {
		t.Fatal(err)
	}
	missingCredential := httptest.NewRequest(http.MethodGet, "/api/v1/auth/session", nil)
	missingCredential.Host = hostname
	missingCredentialResponse := httptest.NewRecorder()
	server.Handler().ServeHTTP(missingCredentialResponse, missingCredential)
	if missingCredentialResponse.Code != http.StatusBadRequest || !strings.Contains(missingCredentialResponse.Body.String(), `"code":"invalid-host"`) {
		t.Fatalf("public Host remained admitted after credential loss: code=%d body=%s", missingCredentialResponse.Code, missingCredentialResponse.Body.String())
	}
}

func TestPublicFunnelPublishesHardenedSharingMetadataAndWindowsAssets(t *testing.T) {
	const hostname = "public.example-tailnet.ts.net"
	root := t.TempDir()
	assetPath := filepath.Join(root, filepath.FromSlash(windowsManagerSocialImageRelativePath))
	if err := os.MkdirAll(filepath.Dir(assetPath), 0o700); err != nil {
		t.Fatal(err)
	}
	assetBytes := []byte{0xff, 0xd8, 0xff, 0xdb, 0, 2, 0xff, 0xd9}
	if err := os.WriteFile(assetPath, assetBytes, 0o600); err != nil {
		t.Fatal(err)
	}
	remote := newFixturePublicController()
	remote.allowed = hostname
	remote.configured = true
	remote.status.Enabled = true
	remote.status.Active = true
	remote.status.URL = "https://" + hostname
	server, err := New(Options{DataDir: t.TempDir(), TautWeeklyRoot: root, Version: "test", RuntimeMode: runtimeModeWindows, remoteAccessController: remote})
	if err != nil {
		t.Fatal(err)
	}
	if err := server.auth.setPasswordLock("unique metadata boundary password"); err != nil {
		t.Fatal(err)
	}

	request := httptest.NewRequest(http.MethodGet, "/", nil)
	request.Host = hostname
	request.Header.Set("X-Forwarded-Host", "attacker.invalid")
	request.Header.Set("X-Forwarded-Proto", "http")
	response := httptest.NewRecorder()
	server.Handler().ServeHTTP(response, request)
	if response.Code != http.StatusOK || response.Header().Get("Strict-Transport-Security") == "" {
		t.Fatalf("public metadata response: code=%d hsts=%q", response.Code, response.Header().Get("Strict-Transport-Security"))
	}
	document := response.Body.String()
	for _, expected := range []string{
		"<title>" + windowsManagerBrowserTitle + "</title>",
		`<link rel="canonical" href="https://` + hostname + `/">`,
		`<meta property="og:url" content="https://` + hostname + `/">`,
		`<meta property="og:image" content="https://` + hostname + windowsManagerSocialImagePath + `">`,
		`<meta property="og:image:secure_url" content="https://` + hostname + windowsManagerSocialImagePath + `">`,
		`<meta name="twitter:image" content="https://` + hostname + windowsManagerSocialImagePath + `">`,
		`<meta name="robots" content="noindex, nofollow, noarchive">`,
	} {
		if !strings.Contains(document, expected) {
			t.Fatalf("public Manager document omitted hardened sharing metadata: %s", expected)
		}
	}
	if strings.Contains(document, "attacker.invalid") || strings.Contains(document, "http://"+hostname) {
		t.Fatal("public sharing metadata trusted a forwarded header or emitted remote HTTP")
	}

	assetRequest := httptest.NewRequest(http.MethodGet, windowsManagerSocialImagePath, nil)
	assetRequest.Host = hostname
	assetResponse := httptest.NewRecorder()
	server.Handler().ServeHTTP(assetResponse, assetRequest)
	if assetResponse.Code != http.StatusOK || assetResponse.Header().Get("Content-Type") != "image/jpeg" || !bytes.Equal(assetResponse.Body.Bytes(), assetBytes) {
		t.Fatalf("public social image contract failed: status=%d type=%q bytes=%d", assetResponse.Code, assetResponse.Header().Get("Content-Type"), assetResponse.Body.Len())
	}

	faviconRequest := httptest.NewRequest(http.MethodGet, "/favicon.ico", nil)
	faviconRequest.Host = hostname
	faviconResponse := httptest.NewRecorder()
	server.Handler().ServeHTTP(faviconResponse, faviconRequest)
	if faviconResponse.Code != http.StatusOK || faviconResponse.Header().Get("Content-Type") != "image/x-icon" || faviconResponse.Body.Len() == 0 {
		t.Fatalf("public favicon contract failed: status=%d type=%q bytes=%d", faviconResponse.Code, faviconResponse.Header().Get("Content-Type"), faviconResponse.Body.Len())
	}
}

func TestPasswordDisableFailsClosedUntilPublicFunnelShutdownIsVerified(t *testing.T) {
	remote := newFixturePublicController()
	remote.configured = true
	remote.status.Enabled = true
	remote.status.Active = true
	remote.status.CleanupRequired = true
	remote.status.State = "active"
	server, err := New(Options{DataDir: t.TempDir(), TautWeeklyRoot: t.TempDir(), Version: "test", RuntimeMode: runtimeModeWindows, remoteAccessController: remote})
	if err != nil {
		t.Fatal(err)
	}
	if err := server.auth.setPasswordLock("unique shutdown boundary password"); err != nil {
		t.Fatal(err)
	}
	current, err := server.auth.newSession()
	if err != nil {
		t.Fatal(err)
	}
	cookie := &http.Cookie{Name: sessionCookieName, Value: current.Token}
	remote.ensureInactive = ErrTailscaleDisableIncomplete
	blocked := mutationRequestForTest(server, http.MethodPost, "/api/v1/auth/access/disable", []byte(`{}`), cookie, current.CSRFToken)
	if blocked.Code != http.StatusConflict || !server.auth.localPasswordLockEnabled() || !strings.Contains(blocked.Body.String(), `"code":"funnel-shutdown-required"`) {
		t.Fatalf("password lock was not preserved after failed Funnel shutdown: code=%d body=%s", blocked.Code, blocked.Body.String())
	}
	remote.ensureInactive = nil
	disabled := mutationRequestForTest(server, http.MethodPost, "/api/v1/auth/access/disable", []byte(`{}`), cookie, current.CSRFToken)
	if disabled.Code != http.StatusOK || server.auth.localPasswordLockEnabled() || remote.configured {
		t.Fatalf("verified Funnel shutdown did not allow lock disable: code=%d body=%s", disabled.Code, disabled.Body.String())
	}
}

func TestPasswordChangeKeepsFunnelAndCurrentSessionButRevokesOthers(t *testing.T) {
	remote := newFixturePublicController()
	remote.configured = true
	remote.status.Enabled = true
	remote.status.Active = true
	server, err := New(Options{DataDir: t.TempDir(), TautWeeklyRoot: t.TempDir(), Version: "test", RuntimeMode: runtimeModeWindows, remoteAccessController: remote})
	if err != nil {
		t.Fatal(err)
	}
	if err := server.auth.setPasswordLock("original unique manager password"); err != nil {
		t.Fatal(err)
	}
	current, _ := server.auth.newSession()
	other, _ := server.auth.newSession()
	cookie := &http.Cookie{Name: sessionCookieName, Value: current.Token}
	changed := mutationRequestForTest(server, http.MethodPost, "/api/v1/auth/access/password", []byte(`{"password":"replacement unique manager password"}`), cookie, current.CSRFToken)
	if changed.Code != http.StatusOK {
		t.Fatalf("password change: code=%d body=%s", changed.Code, changed.Body.String())
	}
	if _, ok := server.auth.authenticate(current.Token); !ok {
		t.Fatal("the initiating session was unnecessarily dropped")
	}
	if _, ok := server.auth.authenticate(other.Token); ok {
		t.Fatal("a session established under the old password remained valid")
	}
	if !remote.configured || len(remote.updates) != 0 {
		t.Fatal("password change unnecessarily stopped or reconfigured Funnel")
	}
}

func TestPublicFunnelMutationsStillRequireAuthenticationCSRFAndExactOrigin(t *testing.T) {
	const hostname = "public.example-tailnet.ts.net"
	remote := newFixturePublicController()
	remote.allowed = hostname
	server, err := New(Options{DataDir: t.TempDir(), TautWeeklyRoot: t.TempDir(), Version: "test", RuntimeMode: runtimeModeWindows, remoteAccessController: remote})
	if err != nil {
		t.Fatal(err)
	}
	if err := server.auth.setPasswordLock("unique endpoint boundary password"); err != nil {
		t.Fatal(err)
	}
	unauthorized := httptest.NewRequest(http.MethodPut, "/api/v1/remote-access/tailscale", strings.NewReader(`{"operation":"enable"}`))
	unauthorized.Host = hostname
	unauthorized.Header.Set("Origin", "https://"+hostname)
	unauthorizedResponse := httptest.NewRecorder()
	server.Handler().ServeHTTP(unauthorizedResponse, unauthorized)
	if unauthorizedResponse.Code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated Funnel mutation: %d", unauthorizedResponse.Code)
	}
	current, _ := server.auth.newSession()
	cookie := &http.Cookie{Name: sessionCookieName, Value: current.Token}
	for _, test := range []struct {
		origin string
		csrf   string
		code   int
	}{
		{origin: "https://attacker.invalid", csrf: current.CSRFToken, code: http.StatusForbidden},
		{origin: "https://" + hostname, csrf: "wrong", code: http.StatusForbidden},
		{origin: "https://" + hostname, csrf: current.CSRFToken, code: http.StatusOK},
	} {
		request := httptest.NewRequest(http.MethodPut, "/api/v1/remote-access/tailscale", strings.NewReader(`{"operation":"enable"}`))
		request.Host = hostname
		request.Header.Set("Content-Type", "application/json")
		request.Header.Set("Origin", test.origin)
		request.Header.Set("X-CSRF-Token", test.csrf)
		request.AddCookie(cookie)
		response := httptest.NewRecorder()
		server.Handler().ServeHTTP(response, request)
		if response.Code != test.code {
			t.Fatalf("origin=%q csrf=%q: got %d, want %d, body=%s", test.origin, test.csrf, response.Code, test.code, response.Body.String())
		}
	}
	if len(remote.updates) != 1 {
		t.Fatalf("rejected mutations reached the typed controller: %v", remote.updates)
	}
	for _, event := range server.diagnostics.History().Events {
		if strings.Contains(event.Summary, hostname) || strings.Contains(event.Summary, "attacker") {
			t.Fatalf("diagnostic leaked remote identity: %+v", event)
		}
	}
}

var _ publicRemoteAccessSafety = (*fixturePublicRemoteAccessAdapter)(nil)
