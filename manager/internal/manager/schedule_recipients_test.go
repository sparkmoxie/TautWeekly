package manager

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

func TestSchedulePrimaryRecipientPolicy(t *testing.T) {
	user := func(id, email string, active, deleted int) map[string]any {
		return map[string]any{"user_id": id, "email": email, "is_active": active, "deleted_user": deleted, "do_notify": 0}
	}
	users := []map[string]any{
		user("0", "local@example.org", 1, 0), user("1", "native@example.org", 1, 0),
		user("2", "", 1, 0), user("3", "blocked@example.org", 1, 0),
		user("4", "inactive@example.org", 0, 0), user("5", "deleted@example.org", 1, 1),
		user("6", "excluded@example.org", 1, 0), user("7", "", 1, 0),
		user("8", "shared@example.org", 1, 0), user("9", "shared@example.org", 1, 0),
		user("10", "", 1, 0),
	}
	config := map[string]any{
		"ExcludedUserIds": []any{"6"}, "ExcludedEmails": []any{"blocked@example.org", "fallback-blocked@example.org"},
		"UserEmailOverrides": map[string]any{"1": "blocked@example.org", "2": "fallback@example.org", "10": "fallback-blocked@example.org"},
		"UserBccAddresses":   map[string]any{"7": []any{"copy@example.org"}, "1": []any{"copy@example.org"}},
	}
	got := countDiscoveredPrimaryRecipients(users, config)
	if got == nil || *got != 4 {
		t.Fatalf("want 4 primary recipients (native, fallback, two shared-inbox users), got %v", got)
	}
	for _, incomplete := range [][]map[string]any{{{"user_id": "1"}}, {user("1", "a@example.org", 1, 0), user("1", "a@example.org", 1, 0)}, make([]map[string]any, maximumDiscoveryChoices)} {
		if got := countDiscoveredPrimaryRecipients(incomplete, config); got != nil {
			t.Fatalf("incomplete roster claimed count %d", *got)
		}
	}
	if got := countDiscoveredPrimaryRecipients(nil, config); got == nil || *got != 0 {
		t.Fatal("empty successful roster should be zero")
	}
}

func TestScheduleRecipientEvidencePersistenceAndInvalidation(t *testing.T) {
	store := newTautulliDiscoveryStore(t.TempDir())
	count := 0
	revision := strings.Repeat("a", 64)
	result := TautulliDiscoveryResult{Mode: "real-lan-discovery", NetworkBoundary: "private-and-loopback-only", CompletedAtUTC: "2031-04-18T16:30:00Z", ConfigRevision: revision, PrimaryRecipientCount: &count, Libraries: []DiscoveredLibrary{{ID: "1", Name: "Movies", MediaType: "movie"}}}
	if err := store.Save(result); err != nil {
		t.Fatal(err)
	}
	loaded := store.Load(revision)
	if loaded == nil || loaded.PrimaryRecipientCount == nil || *loaded.PrimaryRecipientCount != 0 || !loaded.Retained {
		t.Fatal("zero count/provenance lost")
	}
	raw, err := os.ReadFile(store.path)
	if err != nil {
		t.Fatal(err)
	}
	var payload map[string]any
	if err := json.Unmarshal(raw, &payload); err != nil {
		t.Fatal(err)
	}
	if payload["primaryRecipientCount"] != float64(0) {
		t.Fatal("aggregate missing")
	}
	next := strings.Repeat("b", 64)
	if ok, err := store.Rebase(revision, next); err != nil || !ok {
		t.Fatalf("rebase: %v", err)
	}
	if got := store.Load(next); got == nil || got.PrimaryRecipientCount != nil {
		t.Fatal("config rebase retained obsolete recipient evidence")
	}
	result.PrimaryRecipientCount = nil
	if err := store.Save(result); err != nil {
		t.Fatal(err)
	}
	if got := store.Load(revision); got == nil || got.PrimaryRecipientCount != nil {
		t.Fatal("legacy cache synthesized recipient count")
	}
}

func TestDiscoveryReturnsOnlyAggregatePrimaryEvidence(t *testing.T) {
	requests := 0
	tautulli := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests++
		var data any
		switch r.URL.Query().Get("cmd") {
		case "get_libraries":
			data = []any{map[string]any{"section_id": "1", "section_name": "Movies", "section_type": "movie", "is_active": 1}}
		case "get_user_names":
			data = []any{map[string]any{"user_id": "1", "friendly_name": "Viewer"}}
		case "get_users":
			data = []any{map[string]any{"user_id": "1", "friendly_name": "Viewer", "email": "private@example.org", "is_active": 1, "deleted_user": 0, "do_notify": 0}}
		default:
			t.Errorf("unexpected added lookup %s", r.URL.Query().Get("cmd"))
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"response": map[string]any{"result": "success", "data": data}})
	}))
	defer tautulli.Close()
	root := integrationConfigRoot(t, tautulli.URL, "fictional-aggregate-secret", "", "")
	view := ReadConfigEditor(root)
	result, err := DiscoverTautulliChoices(context.Background(), root, TautulliDiscoveryRequest{ExpectedRevision: view.Revision, ConfirmRealNetwork: true}, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	if result.PrimaryRecipientCount == nil || *result.PrimaryRecipientCount != 1 || requests != 3 {
		t.Fatalf("aggregate or bounded request contract: %+v, %d", result, requests)
	}
	encoded, err := json.Marshal(result)
	if err != nil {
		t.Fatal(err)
	}
	for _, private := range []string{"private@example.org", "fictional-aggregate-secret", tautulli.URL} {
		if strings.Contains(string(encoded), private) {
			t.Fatal("private lookup input escaped in evidence")
		}
	}
}

func TestScheduleRecipientCountPreservesLegacyExclusionWhitespace(t *testing.T) {
	users := []map[string]any{{"user_id": "1", "email": "native@example.org", "is_active": 1}}
	for _, config := range []map[string]any{
		{"ExcludedEmails": []any{" native@example.org "}},
		{"ExcludedUserIds": []any{" 1 "}},
	} {
		count := countDiscoveredPrimaryRecipients(users, config)
		if count == nil || *count != 1 {
			t.Fatal("count normalized a legacy exclusion that production would not match")
		}
	}
	for _, config := range []map[string]any{
		{"ExcludedEmails": []any{"NATIVE@example.org"}},
		{"ExcludedEmails": "native@example.org"},
		{"ExcludedUserIds": []any{"1"}},
	} {
		count := countDiscoveredPrimaryRecipients(users, config)
		if count == nil || *count != 0 {
			t.Fatal("count missed a production exclusion")
		}
	}
	if count := countDiscoveredPrimaryRecipients(users, map[string]any{"ExcludedEmails": []any{12}}); count != nil {
		t.Fatal("ambiguous legacy policy should remain unknown")
	}
}
