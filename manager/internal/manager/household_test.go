package manager

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestHouseholdConfigValidationAndPrivacy(t *testing.T) {
	root := integrationConfigRoot(t, "http://127.0.0.1:8181", "synthetic-key", "", "")
	for _, raw := range []string{`{"0":["copy@example.org"]}`, `{"1":"copy@example.org"}`, `{"1":["Name <copy@example.org>"]}`, `{"1":["copy@example.org\r\nBcc:x@example.org"]}`, `{"1":[],"01":[]}`, `{"1":[],"1":[]}`, `null`, `{"1":[12]}`} {
		req := validConfigSaveRequest(t, ReadConfigEditor(root))
		req.Values["UserBccAddresses"] = json.RawMessage(raw)
		_, fields, err := SaveConfig(root, req, time.Now)
		if err != nil || fields["UserBccAddresses"] == "" {
			t.Fatalf("accepted invalid map %s: %v %v", raw, fields, err)
		}
	}
	req := validConfigSaveRequest(t, ReadConfigEditor(root))
	req.Values["UserBccAddresses"] = json.RawMessage(`{" 01 ":[" Copy@example.org ","COPY@example.org"],"999":[]}`)
	result, fields, err := SaveConfig(root, req, time.Now)
	if err != nil || len(fields) != 0 {
		t.Fatalf("save: %v %v", fields, err)
	}
	raw, _ := json.Marshal(editorField(t, result.Editor, "UserBccAddresses").Value)
	if string(raw) != `{"1":["copy@example.org"]}` {
		t.Fatalf("normalization: %s", raw)
	}
	server, err := New(Options{DataDir: t.TempDir(), TautWeeklyRoot: root, Version: "test"})
	if err != nil {
		t.Fatal(err)
	}
	session, _ := server.auth.newSession()
	cookie := &http.Cookie{Name: sessionCookieName, Value: session.Token}
	response := requestForTest(server, http.MethodGet, "/api/v1/config", nil, cookie)
	if strings.Contains(response.Body.String(), "copy@example.org") {
		t.Fatal("private copy leaked in generic config")
	}
	req = validConfigSaveRequest(t, result.Editor)
	req.Values["UserBccAddresses"] = json.RawMessage(`{"1":["other@example.org"]}`)
	result, fields, err = SaveConfig(root, req, time.Now)
	if err != nil || len(fields) != 0 || result.PostSave.RunDiscovery || result.PostSave.RunSMTP || result.PostSave.GeneratePreviews || result.PostSave.WarmCache {
		t.Fatalf("BCC save triggered unrelated work: %+v %v %v", result.PostSave, fields, err)
	}
}

func TestHouseholdSelectedPrimaryEndpoint(t *testing.T) {
	native := "native@example.org"
	returnedID := "7"
	tautulli := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("cmd") != "get_user" || r.URL.Query().Get("user_id") != "7" {
			t.Error("lookup was not selected-user only")
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"response": map[string]any{"result": "success", "data": map[string]any{"user_id": returnedID, "email": native, "is_active": 1}}})
	}))
	defer tautulli.Close()
	root := integrationConfigRoot(t, tautulli.URL, "synthetic-key", "", "")
	req := validConfigSaveRequest(t, ReadConfigEditor(root))
	req.Values["UserEmailOverrides"] = json.RawMessage(`{"7":"fallback@example.org"}`)
	saved, fields, err := SaveConfig(root, req, time.Now)
	if err != nil || len(fields) != 0 {
		t.Fatalf("seed: %v %v", fields, err)
	}
	server, err := New(Options{DataDir: t.TempDir(), TautWeeklyRoot: root, Version: "test"})
	if err != nil {
		t.Fatal(err)
	}
	session, _ := server.auth.newSession()
	cookie := &http.Cookie{Name: sessionCookieName, Value: session.Token}
	target := "/api/v1/config/household-primary"
	body, _ := json.Marshal(map[string]string{"userId": "7", "expectedRevision": saved.Editor.Revision})
	if r := mutationRequestForTest(server, http.MethodPost, target, body, cookie, ""); r.Code != http.StatusForbidden {
		t.Fatalf("missing CSRF accepted: %d", r.Code)
	}
	for _, test := range []struct {
		address, id, want string
		code              int
	}{
		{"native@example.org", "7", "native", 200}, {"", "7", "fallback", 200}, {"private@example.org", "8", "", 502}, {"private@example.org", "0", "", 502},
	} {
		native, returnedID = test.address, test.id
		r := mutationRequestForTest(server, http.MethodPost, target, body, cookie, session.CSRFToken)
		if r.Code != test.code || r.Header().Get("Cache-Control") != "no-store" {
			t.Fatalf("lookup: %d %s", r.Code, r.Body.String())
		}
		if test.code == 200 && !strings.Contains(r.Body.String(), `"source":"`+test.want+`"`) {
			t.Fatalf("wrong source: %s", r.Body.String())
		}
		if test.code != 200 && strings.Contains(r.Body.String(), "private@example.org") {
			t.Fatal("lookup leaked mismatched identity")
		}
	}
	body = []byte(`{"userId":"7","expectedRevision":"stale"}`)
	if r := mutationRequestForTest(server, http.MethodPost, target, body, cookie, session.CSRFToken); r.Code != 409 {
		t.Fatal("stale revision accepted")
	}
	if server.discovery.Load(saved.Editor.Revision) != nil {
		t.Fatal("private lookup populated discovery cache")
	}
}

func TestHouseholdRendererCopyWarnings(t *testing.T) {
	for _, mode := range []string{"SendAll", "SendWelcome"} {
		r := rendererResult{SchemaVersion: 4, Mode: mode, Outcome: "partial", DeliveryScope: expectedDeliveryScope(mode), StartedAtUTC: "2031-04-18T16:30:00Z", FinishedAtUTC: "2031-04-18T16:30:01Z", DurationMS: 1000, SMTPAcceptedCount: 1, BCCAcceptedCount: 1, BCCRejectedCount: 1, SkipReasonCounts: &DeliverySkipReasonCounts{}}
		if !validRendererResult(r, mode) {
			t.Fatalf("valid copy warning rejected: %+v", r)
		}
		for _, mutate := range []func(*rendererResult){func(r *rendererResult) { r.Outcome = "succeeded" }, func(r *rendererResult) { r.SMTPAcceptedCount = 0 }, func(r *rendererResult) { r.SchemaVersion = 3 }, func(r *rendererResult) { r.BCCAcceptedCount = 21 }, func(r *rendererResult) { r.Mode = "SendTest"; r.DeliveryScope = "test" }} {
			bad := r
			mutate(&bad)
			if validRendererResult(bad, bad.Mode) {
				t.Fatalf("invalid copy result accepted: %+v", bad)
			}
		}
	}
}

func TestHouseholdWarningsSurviveRecoveryAndHistory(t *testing.T) {
	for _, operationType := range []string{"send-all", "send-welcome"} {
		root := integrationConfigRoot(t, "http://127.0.0.1:8181", "synthetic-key", "", "")
		c, err := newOperationCoordinator(Options{DataDir: t.TempDir(), TautWeeklyRoot: root, Now: time.Now, operationRunner: &fixturePreviewRunner{}})
		if err != nil {
			t.Fatal(err)
		}
		record := OperationRecord{SchemaVersion: operationSchemaVersion, ID: "household-recovery", Type: operationType, State: "running", StartedAtUTC: "2031-04-18T16:30:00Z"}
		c.current = &record
		result := rendererResult{SchemaVersion: 4, Mode: operationMode(operationType), Outcome: "partial", DeliveryScope: expectedDeliveryScope(operationMode(operationType)), StartedAtUTC: record.StartedAtUTC, FinishedAtUTC: "2031-04-18T16:30:01Z", SMTPAcceptedCount: 1, BCCAcceptedCount: 2, BCCRejectedCount: 1, SkipReasonCounts: &DeliverySkipReasonCounts{}}
		c.finishRecoveredDelivery(record, ReadConfigEditor(root).Revision, result)
		for _, saved := range append(c.store.readHistory(), *c.store.readCurrent()) {
			if saved.State != "partial" || saved.SMTPAcceptedCount != 1 || saved.BCCAcceptedCount != 2 || saved.BCCRejectedCount != 1 || saved.FailedCount != 0 {
				t.Fatalf("lost recovered copy evidence: %+v", saved)
			}
		}
	}
}
