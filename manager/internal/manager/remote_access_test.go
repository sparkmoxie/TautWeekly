package manager

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"testing"
	"time"
)

type fixtureTailscaleRunner struct {
	available bool
	serve     []byte
	commands  [][]string
	runError  error
	hostname  string
	target    string
}

type fixturePrivilegedTailscaleRunner struct {
	available bool
	hostname  string
	target    string
	enabled   bool
	commands  []string
	error     error
}

func (f *fixturePrivilegedTailscaleRunner) Available() bool        { return f.available }
func (f *fixturePrivilegedTailscaleRunner) RequiresApproval() bool { return true }
func (f *fixturePrivilegedTailscaleRunner) Run(context.Context, ...string) ([]byte, error) {
	return nil, errors.New("unelevated Tailscale command was not expected")
}
func (f *fixturePrivilegedTailscaleRunner) RunPrivileged(_ context.Context, action, target string) ([]byte, error) {
	f.commands = append(f.commands, action+" "+target)
	if f.error != nil {
		return nil, f.error
	}
	if target != f.target {
		return nil, errors.New("unexpected target")
	}
	switch action {
	case "inspect":
		if f.enabled {
			return ownedTailscaleServeJSON(f.hostname, f.target), nil
		}
		return []byte(`{}`), nil
	case "enable":
		f.enabled = true
		return ownedTailscaleServeJSON(f.hostname, f.target), nil
	case "disable":
		f.enabled = false
		return []byte(`{}`), nil
	default:
		return nil, errors.New("unexpected privileged action")
	}
}

func (f *fixtureTailscaleRunner) Available() bool { return f.available }

func (f *fixtureTailscaleRunner) Run(_ context.Context, arguments ...string) ([]byte, error) {
	f.commands = append(f.commands, slices.Clone(arguments))
	if f.runError != nil {
		return nil, f.runError
	}
	command := strings.Join(arguments, " ")
	switch {
	case command == "serve status --json":
		return slices.Clone(f.serve), nil
	case strings.HasPrefix(command, "serve --bg --yes --https=443 "):
		f.serve = ownedTailscaleServeJSON(f.hostname, f.target)
		return []byte("configured"), nil
	case command == "serve --yes --https=443 off":
		f.serve = []byte(`{}`)
		return []byte("disabled"), nil
	default:
		return nil, errors.New("unexpected Tailscale command")
	}
}

func ownedTailscaleServeJSON(hostname, target string) []byte {
	value := map[string]any{
		"TCP": map[string]any{"443": map[string]any{"HTTPS": true}},
		"Web": map[string]any{hostname + ":443": map[string]any{
			"Handlers": map[string]any{"/": map[string]any{"Proxy": target}},
		}},
	}
	raw, _ := json.Marshal(value)
	return raw
}

func TestTailscaleRemoteAccessLifecycleOwnsOnlyExactServeRoute(t *testing.T) {
	const (
		hostname = "tautweekly.example-tailnet.ts.net"
		target   = "http://127.0.0.1:18788"
	)
	runner := &fixtureTailscaleRunner{available: true, serve: []byte(`{}`), hostname: hostname, target: target}
	dataDir := t.TempDir()
	controller := newTailscaleRemoteAccessController(dataDir, "127.0.0.1:18788", true, runner)

	ready := controller.Status(context.Background())
	if ready.State != "ready" || ready.Enabled || ready.Active {
		t.Fatalf("initial Tailscale status: %+v", ready)
	}
	enabled, err := controller.Update(context.Background(), true, "", false)
	if err != nil {
		t.Fatal(err)
	}
	if !enabled.Enabled || !enabled.Active || enabled.State != "enabled" || enabled.URL != "https://"+hostname {
		t.Fatalf("enabled Tailscale status: %+v", enabled)
	}
	if !controller.AllowsHost(hostname) || !controller.AllowsHost(hostname+":443") || controller.AllowsHost("other.ts.net") {
		t.Fatal("saved Tailscale hostname was not enforced exactly")
	}

	restarted := newTailscaleRemoteAccessController(dataDir, "127.0.0.1:18788", true, runner)
	if status := restarted.Status(context.Background()); !status.Enabled || !status.Active {
		t.Fatalf("Tailscale ownership did not survive Manager restart: %+v", status)
	}
	disabled, err := restarted.Update(context.Background(), false, "", false)
	if err != nil {
		t.Fatal(err)
	}
	if disabled.Enabled || disabled.Active || restarted.AllowsHost(hostname) {
		t.Fatalf("disabled Tailscale hostname remained accepted: %+v", disabled)
	}
	for _, command := range runner.commands {
		if len(command) >= 2 && command[0] == "serve" && command[1] == "reset" {
			t.Fatal("TautWeekly used destructive tailscale serve reset")
		}
	}
}

func TestWindowsTailscaleRemoteAccessRequestsApprovalOnlyForExplicitChanges(t *testing.T) {
	const (
		hostname = "tautweekly.example-tailnet.ts.net"
		target   = "http://127.0.0.1:18788"
	)
	runner := &fixturePrivilegedTailscaleRunner{available: true, hostname: hostname, target: target}
	dataDir := t.TempDir()
	controller := newTailscaleRemoteAccessController(dataDir, "127.0.0.1:18788", true, runner)

	status := controller.Status(context.Background())
	if status.State != "approval-required" || status.Enabled || len(runner.commands) != 0 {
		t.Fatalf("passive status unexpectedly requested approval: status=%+v commands=%v", status, runner.commands)
	}
	verified, err := controller.Verify(context.Background())
	if err != nil || verified.State != "ready" || len(runner.commands) != 1 || runner.commands[0] != "inspect "+target {
		t.Fatalf("explicit verification should inspect without changing Serve: status=%+v err=%v commands=%v", verified, err, runner.commands)
	}
	enabled, err := controller.Update(context.Background(), true, "", false)
	if err != nil || !enabled.Active || !enabled.Enabled || enabled.URL != "https://"+hostname {
		t.Fatalf("privileged enable: status=%+v err=%v", enabled, err)
	}
	if len(runner.commands) != 2 || runner.commands[1] != "enable "+target {
		t.Fatalf("unexpected privileged enable commands: %v", runner.commands)
	}

	restarted := newTailscaleRemoteAccessController(dataDir, "127.0.0.1:18788", true, runner)
	status = restarted.Status(context.Background())
	if status.State != "enabled-unverified" || !status.Enabled || status.Active || status.URL != "https://"+hostname || len(runner.commands) != 2 {
		t.Fatalf("restart status should not request approval: status=%+v commands=%v", status, runner.commands)
	}
	disabled, err := restarted.Update(context.Background(), false, "", false)
	if err != nil || disabled.Enabled || disabled.Active || disabled.State != "ready" || restarted.AllowsHost(hostname) {
		t.Fatalf("privileged disable: status=%+v err=%v", disabled, err)
	}
	if len(runner.commands) != 3 || runner.commands[2] != "disable "+target {
		t.Fatalf("unexpected privileged disable commands: %v", runner.commands)
	}
}

func TestTailscaleRemoteAccessRefusesExistingServeConfiguration(t *testing.T) {
	const target = "http://127.0.0.1:8788"
	runner := &fixtureTailscaleRunner{
		available: true,
		hostname:  "tautweekly.example-tailnet.ts.net",
		target:    target,
		serve:     ownedTailscaleServeJSON("other.example-tailnet.ts.net", "http://127.0.0.1:9999"),
	}
	controller := newTailscaleRemoteAccessController(t.TempDir(), "127.0.0.1:8788", true, runner)
	status := controller.Status(context.Background())
	if status.State != "conflict" || status.Enabled {
		t.Fatalf("conflicting Serve route was not reported: %+v", status)
	}
	if _, err := controller.Update(context.Background(), true, "", false); !errors.Is(err, ErrTailscaleServeConflict) {
		t.Fatalf("conflicting Serve route was not rejected: %v", err)
	}
	for _, command := range runner.commands {
		if strings.Contains(strings.Join(command, " "), "--bg") || slices.Contains(command, "off") {
			t.Fatalf("conflicting Serve route was modified: %v", runner.commands)
		}
	}
}

func TestTailscaleOwnershipRejectsUnrelatedFalseFunnelMetadata(t *testing.T) {
	const (
		hostname = "tautweekly.example-tailnet.ts.net"
		target   = "http://127.0.0.1:8788"
	)
	var status map[string]any
	if err := json.Unmarshal(ownedTailscaleServeJSON(hostname, target), &status); err != nil {
		t.Fatal(err)
	}
	status["AllowFunnel"] = map[string]bool{"unrelated.example-tailnet.ts.net:443": false}
	raw, err := json.Marshal(status)
	if err != nil {
		t.Fatal(err)
	}
	runner := &fixtureTailscaleRunner{available: true, hostname: hostname, target: target, serve: raw}
	controller := newTailscaleRemoteAccessController(t.TempDir(), "127.0.0.1:8788", true, runner)
	if observed := controller.Status(context.Background()); observed.State != "conflict" {
		t.Fatalf("unrelated Funnel metadata was treated as owned: %+v", observed)
	}
}

func TestTailscaleProviderApprovalURLIsPinnedToOfficialHTTPSHost(t *testing.T) {
	for _, value := range []string{
		"https://login.tailscale.com/admin/feature/example",
		"https://login.tailscale.com/a/example?next=serve",
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

func TestExternalTailscaleRemoteAccessRequiresExactPrivateHTTPSURL(t *testing.T) {
	const hostname = "tautweekly.example-tailnet.ts.net"
	dataDir := t.TempDir()
	controller := newExternalTailscaleRemoteAccessController(dataDir, "0.0.0.0:8788")
	ready := controller.Status(context.Background())
	if ready.Management != "external" || !ready.RequiresURL || ready.State != "external-ready" || ready.Enabled {
		t.Fatalf("external initial status: %+v", ready)
	}
	if _, err := controller.Update(context.Background(), true, "https://"+hostname, false); !errors.Is(err, ErrTailscalePrivateConfirmation) {
		t.Fatalf("external access did not require private/Funnel-off confirmation: %v", err)
	}
	for _, value := range []string{
		"", "http://" + hostname, "https://example.com", "https://" + hostname + ":443",
		"https://" + hostname + "/admin", "https://user@" + hostname, "https://" + hostname + "?public=true",
	} {
		if _, err := controller.Update(context.Background(), true, value, true); err == nil {
			t.Errorf("unsafe external Tailscale address was accepted: %q", value)
		}
	}
	enabled, err := controller.Update(context.Background(), true, "https://"+hostname+"/", true)
	if err != nil {
		t.Fatal(err)
	}
	if !enabled.Enabled || !enabled.Active || enabled.State != "external-enabled" || enabled.URL != "https://"+hostname || !controller.AllowsHost(hostname) {
		t.Fatalf("external enabled status: %+v", enabled)
	}
	restarted := newExternalTailscaleRemoteAccessController(dataDir, "0.0.0.0:8788")
	if status := restarted.Status(context.Background()); !status.Enabled || !status.Active || !restarted.AllowsHost(hostname) {
		t.Fatalf("external exact hostname did not survive restart: %+v", status)
	}
	disabled, err := restarted.Update(context.Background(), false, "", false)
	if err != nil || disabled.Enabled || disabled.Active || restarted.AllowsHost(hostname) {
		t.Fatalf("external hostname was not blocked on disable: status=%+v err=%v", disabled, err)
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
		status:  TailscaleRemoteAccessStatus{Supported: true, Installed: true, Enabled: true, Active: true, State: "enabled", URL: "https://" + hostname, Provider: "tailscale", NetworkKind: "private-tailnet"},
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
			request := httptest.NewRequest(http.MethodPut, "/api/v1/remote-access/tailscale", strings.NewReader(`{"enabled":true}`))
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
		if event.Area != "remote-access" || event.Code != "tailscale-enabled" {
			t.Fatalf("remote access diagnostic was not retained safely: %+v", history.Events)
		}
	}
}

func TestTailscaleInteractiveEndpointsExtendOnlyTheirResponseDeadline(t *testing.T) {
	remote := &fixtureRemoteAccessController{
		status: TailscaleRemoteAccessStatus{Supported: true, Installed: true, State: "ready", Provider: "tailscale", NetworkKind: "private-tailnet"},
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
		{http.MethodPut, "/api/v1/remote-access/tailscale", `{"enabled":true}`},
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
