package manager

import (
	"context"
	"io/fs"
	"net/http"
	"strings"
	"testing"
)

type passiveDashboardFunnelRunner struct {
	calls int
}

func (f *passiveDashboardFunnelRunner) Available() bool { return true }
func (f *passiveDashboardFunnelRunner) RunPublicRoute(context.Context, string, string) (publicRemoteAccessObservation, error) {
	f.calls++
	return publicRemoteAccessObservation{RouteState: publicRemoteAccessRouteEmpty}, nil
}

func TestDashboardEmbedsLiveDeliveryAndTimelineStates(t *testing.T) {
	tests := []struct {
		name     string
		required []string
	}{
		{
			name: "web/index.html",
			required: []string{
				`id="delivery-status-icon"`,
				`id="timeline-upcoming-card"`,
				`id="timeline-last-attempt-card"`,
				`id="timeline-previews-card"`,
			},
		},
		{
			name: "web/app.js",
			required: []string{
				`productionDeliveryIsRunning`,
				`pollDeliveryStatus`,
				`deliveryRunning ? "Running"`,
				`"timeline-ready", scheduleHasUpcomingRun(snapshot)`,
				`"timeline-success", rendererEvidence && !deliveryRunning && snapshot.delivery.result === "smtp-accepted"`,
				`"timeline-ready", state.previews.length > 0`,
			},
		},
		{
			name: "web/app.css",
			required: []string{
				`.delivery-icon-running`,
				`.timeline-card.timeline-ready`,
				`.timeline-card.timeline-success`,
				`prefers-reduced-motion:reduce`,
			},
		},
	}
	for _, test := range tests {
		raw, err := fs.ReadFile(embeddedWeb, test.name)
		if err != nil {
			t.Fatalf("read %s: %v", test.name, err)
		}
		text := string(raw)
		for _, required := range test.required {
			if !strings.Contains(text, required) {
				t.Errorf("%s does not contain %q", test.name, required)
			}
		}
	}
}

func TestPassiveDashboardFunnelStatusUsesRetainedStateWithoutProviderCommand(t *testing.T) {
	dataDir := t.TempDir()
	runner := &passiveDashboardFunnelRunner{}
	controller := newPublicFunnelController(dataDir, "127.0.0.1:8788", "test-funnel.json", true, runner)
	server, err := New(Options{
		DataDir: dataDir, TautWeeklyRoot: t.TempDir(), Version: "test", RuntimeMode: runtimeModeWindows,
		remoteAccessController: controller,
	})
	if err != nil {
		t.Fatal(err)
	}
	session, err := server.auth.newSession()
	if err != nil {
		t.Fatal(err)
	}
	cookie := &http.Cookie{Name: sessionCookieName, Value: session.Token}
	response := requestForTest(server, http.MethodGet, "/api/v1/remote-access/tailscale", nil, cookie)
	if response.Code != http.StatusOK {
		t.Fatalf("passive Funnel status: got %d, body %s", response.Code, response.Body.String())
	}
	if runner.calls != 0 {
		t.Fatalf("passive Dashboard status invoked the provider runner %d times", runner.calls)
	}
	body := response.Body.String()
	for _, forbidden := range []string{"127.0.0.1", "test-funnel.json", "private address", "raw output", "token"} {
		if strings.Contains(strings.ToLower(body), strings.ToLower(forbidden)) {
			t.Fatalf("passive Funnel status disclosed implementation or private state %q: %s", forbidden, body)
		}
	}
	if !strings.Contains(body, `"state":"manager-password-required"`) || !strings.Contains(body, `"passwordRequired":true`) {
		t.Fatalf("passive Funnel status did not preserve the typed password boundary: %s", body)
	}
}
