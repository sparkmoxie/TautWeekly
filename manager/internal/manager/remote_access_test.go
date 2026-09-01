package manager

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestTailscaleProviderApprovalURLIsPinnedToOfficialHTTPSHost(t *testing.T) {
	for _, value := range []string{
		"https://login.tailscale.com/admin/feature/example",
		"https://login.tailscale.com/a/example?next=funnel",
	} {
		if !validTailscaleProviderURL(value) {
			t.Errorf("official Tailscale approval URL was rejected: %q", value)
		}
	}
	for _, value := range []string{
		"http://login.tailscale.com/admin/feature/example",
		"https://login.tailscale.com.evil.example/admin/feature/example",
		"https://user@login.tailscale.com/admin/feature/example",
		"https://login.tailscale.com:444/admin/feature/example",
		"https://login.tailscale.com/admin/feature/example#fragment",
	} {
		if validTailscaleProviderURL(value) {
			t.Errorf("unsafe Tailscale approval URL was accepted: %q", value)
		}
	}
}

type fixtureRemoteAccessController struct {
	status  TailscaleRemoteAccessStatus
	allowed string
	updates []bool
	urls    []string
}

type deadlineResponseRecorder struct {
	*httptest.ResponseRecorder
	deadline time.Time
}

func (r *deadlineResponseRecorder) SetWriteDeadline(deadline time.Time) error {
	r.deadline = deadline
	return nil
}

func (f *fixtureRemoteAccessController) Status(context.Context) TailscaleRemoteAccessStatus {
	return f.status
}

func (f *fixtureRemoteAccessController) Verify(context.Context) (TailscaleRemoteAccessStatus, error) {
	return f.status, nil
}

func (f *fixtureRemoteAccessController) Update(_ context.Context, enabled bool, value string, _ bool) (TailscaleRemoteAccessStatus, error) {
	f.updates = append(f.updates, enabled)
	f.urls = append(f.urls, value)
	f.status.Enabled = enabled
	f.status.Active = enabled
	f.status.State = map[bool]string{true: "enabled", false: "ready"}[enabled]
	return f.status, nil
}

func (f *fixtureRemoteAccessController) AllowsHost(value string) bool {
	return strings.EqualFold(hostnameOnly(value), f.allowed)
}

func TestTailscaleHostnameGetsSecureCookiesHSTSAndHTTPSOriginEnforcement(t *testing.T) {
	const hostname = "tautweekly.example-tailnet.ts.net"
	remote := &fixtureRemoteAccessController{
		allowed: hostname,
		status:  TailscaleRemoteAccessStatus{Supported: true, Installed: true, Enabled: true, Active: true, State: "enabled", URL: "https://" + hostname, Provider: "tailscale", NetworkKind: "public-funnel"},
	}
	server, err := New(Options{DataDir: t.TempDir(), TautWeeklyRoot: t.TempDir(), Version: "test", RuntimeMode: runtimeModeWindows, remoteAccessController: remote})
	if err != nil {
		t.Fatal(err)
	}

	remoteSessionRequest := httptest.NewRequest(http.MethodGet, "/api/v1/auth/session", nil)
	remoteSessionRequest.Host = hostname
	remoteSessionResponse := httptest.NewRecorder()
	server.Handler().ServeHTTP(remoteSessionResponse, remoteSessionRequest)
	if remoteSessionResponse.Code != http.StatusOK {
		t.Fatalf("remote session: got %d, body %s", remoteSessionResponse.Code, remoteSessionResponse.Body.String())
	}
	if !strings.Contains(remoteSessionResponse.Header().Get("Set-Cookie"), "; Secure") {
		t.Fatalf("remote session cookie was not Secure: %q", remoteSessionResponse.Header().Get("Set-Cookie"))
	}
	if remoteSessionResponse.Header().Get("Strict-Transport-Security") == "" {
		t.Fatal("remote hostname did not receive HSTS")
	}

	localSession := requestForTest(server, http.MethodGet, "/api/v1/auth/session", nil, nil)
	if strings.Contains(localSession.Header().Get("Set-Cookie"), "; Secure") || localSession.Header().Get("Strict-Transport-Security") != "" {
		t.Fatalf("local HTTP access inherited remote-only TLS policy: cookie=%q hsts=%q", localSession.Header().Get("Set-Cookie"), localSession.Header().Get("Strict-Transport-Security"))
	}

	current, err := server.auth.newSession()
	if err != nil {
		t.Fatal(err)
	}
	cookie := &http.Cookie{Name: sessionCookieName, Value: current.Token}
	acceptedMutations := 0
	for _, test := range []struct {
		name           string
		host           string
		origin         string
		forwardedProto string
		want           int
		wantCode       string
	}{
		{name: "Tailscale HTTP rejected", host: hostname, origin: "http://" + hostname, want: http.StatusForbidden, wantCode: "remote-http"},
		{name: "exact HTTPS", host: hostname, origin: "https://" + hostname, want: http.StatusOK},
		{name: "equivalent default HTTPS port", host: hostname + ":443", origin: "https://" + hostname, want: http.StatusOK},
		{name: "case and trailing dot normalized", host: strings.ToUpper(hostname) + ".", origin: "https://" + strings.ToUpper(hostname) + ".", want: http.StatusOK},
		{name: "non-default remote HTTPS port rejected", host: hostname + ":8443", origin: "https://" + hostname + ":8443", want: http.StatusForbidden, wantCode: "remote-http"},
		{name: "different host rejected", host: hostname, origin: "https://other.example-tailnet.ts.net", want: http.StatusForbidden, wantCode: "origin-host-mismatch"},
		{name: "spoofed proxy proto ignored", host: hostname, origin: "http://" + hostname, forwardedProto: "https", want: http.StatusForbidden, wantCode: "remote-http"},
		{name: "origin path rejected", host: hostname, origin: "https://" + hostname + "/mutated", want: http.StatusForbidden, wantCode: "invalid-origin"},
	} {
		t.Run(test.name, func(t *testing.T) {
			request := httptest.NewRequest(http.MethodPut, "/api/v1/remote-access/tailscale", strings.NewReader(`{"operation":"enable"}`))
			request.Host = test.host
			request.Header.Set("Content-Type", "application/json")
			request.Header.Set("Origin", test.origin)
			request.Header.Set("X-CSRF-Token", current.CSRFToken)
			if test.forwardedProto != "" {
				request.Header.Set("Forwarded", "proto="+test.forwardedProto+";host=attacker.example")
				request.Header.Set("X-Forwarded-Proto", test.forwardedProto)
				request.Header.Set("X-Forwarded-Host", "attacker.example")
			}
			request.AddCookie(cookie)
			response := httptest.NewRecorder()
			server.Handler().ServeHTTP(response, request)
			if response.Code != test.want || test.wantCode != "" && !strings.Contains(response.Body.String(), `"code":"`+test.wantCode+`"`) {
				t.Fatalf("origin %q host %q: got %d, want %d/%q, body %s", test.origin, test.host, response.Code, test.want, test.wantCode, response.Body.String())
			}
			if response.Code == http.StatusOK {
				acceptedMutations++
			}
		})
	}
	if len(remote.updates) != acceptedMutations || acceptedMutations != 3 {
		t.Fatalf("HTTPS mutation did not reach the typed controller: %v", remote.updates)
	}
	history := server.diagnostics.History()
	if len(history.Events) != acceptedMutations {
		t.Fatalf("remote access diagnostic was not retained safely: %+v", history.Events)
	}
	for _, event := range history.Events {
		if event.Area != "remote-access" || event.Code != "tailscale-funnel-enabled" {
			t.Fatalf("remote access diagnostic was not retained safely: %+v", history.Events)
		}
	}
}

func TestTailscaleInteractiveEndpointsExtendOnlyTheirResponseDeadline(t *testing.T) {
	remote := &fixtureRemoteAccessController{
		status: TailscaleRemoteAccessStatus{Supported: true, Installed: true, State: "ready", Provider: "tailscale", NetworkKind: "public-funnel"},
	}
	server, err := New(Options{DataDir: t.TempDir(), TautWeeklyRoot: t.TempDir(), Version: "test", RuntimeMode: runtimeModeWindows, remoteAccessController: remote})
	if err != nil {
		t.Fatal(err)
	}
	current, err := server.auth.newSession()
	if err != nil {
		t.Fatal(err)
	}
	cookie := &http.Cookie{Name: sessionCookieName, Value: current.Token}
	for _, test := range []struct {
		method string
		path   string
		body   string
	}{
		{http.MethodPost, "/api/v1/remote-access/tailscale/verify", ""},
		{http.MethodPut, "/api/v1/remote-access/tailscale", `{"operation":"enable"}`},
	} {
		started := time.Now()
		request := httptest.NewRequest(test.method, test.path, strings.NewReader(test.body))
		request.Host = "127.0.0.1:8788"
		request.Header.Set("X-CSRF-Token", current.CSRFToken)
		request.AddCookie(cookie)
		if test.body != "" {
			request.Header.Set("Content-Type", "application/json")
		}
		response := &deadlineResponseRecorder{ResponseRecorder: httptest.NewRecorder()}
		server.Handler().ServeHTTP(response, request)
		if response.Code != http.StatusOK {
			t.Fatalf("%s %s: got %d, body %s", test.method, test.path, response.Code, response.Body.String())
		}
		if response.deadline.Before(started.Add(4*time.Minute)) || response.deadline.After(started.Add(6*time.Minute)) {
			t.Fatalf("%s %s: unexpected interactive response deadline %v", test.method, test.path, response.deadline)
		}
	}
}
