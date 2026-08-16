package manager

import (
	"errors"
	"net/http"
	"strings"
	"testing"
)

type fixtureStartupController struct {
	status    StartupSettings
	updateErr error
	updates   [][2]bool
}

func (f *fixtureStartupController) Status() StartupSettings { return f.status }

func (f *fixtureStartupController) Update(startManager, openDashboard bool) (StartupSettings, error) {
	f.updates = append(f.updates, [2]bool{startManager, openDashboard})
	if f.updateErr != nil {
		return f.status, f.updateErr
	}
	f.status.StartManager = startManager
	f.status.OpenDashboard = openDashboard
	f.status.State = map[bool]string{true: "enabled", false: "disabled"}[startManager]
	return f.status, nil
}

func TestStartupSettingsAPIReportsCapabilityAndEnforcesDependency(t *testing.T) {
	controller := &fixtureStartupController{status: StartupSettings{Supported: true, State: "disabled"}}
	server, err := New(Options{DataDir: t.TempDir(), TautWeeklyRoot: t.TempDir(), Version: "test", startupController: controller})
	if err != nil {
		t.Fatal(err)
	}
	session, err := server.auth.newSession()
	if err != nil {
		t.Fatal(err)
	}
	cookie := &http.Cookie{Name: sessionCookieName, Value: session.Token}
	status := requestForTest(server, http.MethodGet, "/api/v1/startup", nil, cookie)
	if status.Code != http.StatusOK || !strings.Contains(status.Body.String(), `"supported":true`) || !strings.Contains(status.Body.String(), `"state":"disabled"`) {
		t.Fatalf("startup status: got %d, body %s", status.Code, status.Body.String())
	}

	invalid := mutationRequestForTest(server, http.MethodPut, "/api/v1/startup", []byte(`{"startManager":false,"openDashboard":true}`), cookie, session.CSRFToken)
	if invalid.Code != http.StatusBadRequest || len(controller.updates) != 0 || !strings.Contains(invalid.Body.String(), `"openDashboard"`) {
		t.Fatalf("dependent setting request: got %d, updates %v, body %s", invalid.Code, controller.updates, invalid.Body.String())
	}

	enabled := mutationRequestForTest(server, http.MethodPut, "/api/v1/startup", []byte(`{"startManager":true,"openDashboard":true}`), cookie, session.CSRFToken)
	if enabled.Code != http.StatusOK || len(controller.updates) != 1 || controller.updates[0] != [2]bool{true, true} || !strings.Contains(enabled.Body.String(), `"openDashboard":true`) {
		t.Fatalf("enable startup: got %d, updates %v, body %s", enabled.Code, controller.updates, enabled.Body.String())
	}
	history := server.diagnostics.History()
	found := false
	for _, event := range history.Events {
		found = found || event.Code == "startup-enabled-dashboard" && event.Area == "startup"
	}
	if !found {
		t.Fatalf("startup diagnostic was not retained safely: %+v", history.Events)
	}
}

func TestStartupSettingsAPILeavesConflictingEntryUnchanged(t *testing.T) {
	controller := &fixtureStartupController{
		status:    StartupSettings{Supported: true, State: "conflict", ErrorCode: "startup-entry-conflict"},
		updateErr: ErrStartupConflict,
	}
	server, err := New(Options{DataDir: t.TempDir(), TautWeeklyRoot: t.TempDir(), Version: "test", startupController: controller})
	if err != nil {
		t.Fatal(err)
	}
	session, _ := server.auth.newSession()
	cookie := &http.Cookie{Name: sessionCookieName, Value: session.Token}
	response := mutationRequestForTest(server, http.MethodPut, "/api/v1/startup", []byte(`{"startManager":true,"openDashboard":false}`), cookie, session.CSRFToken)
	if response.Code != http.StatusConflict || !strings.Contains(response.Body.String(), "startup-entry-conflict") || !errors.Is(controller.updateErr, ErrStartupConflict) {
		t.Fatalf("conflicting startup entry: got %d, body %s", response.Code, response.Body.String())
	}
}
