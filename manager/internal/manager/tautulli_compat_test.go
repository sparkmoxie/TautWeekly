package manager

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestTautulliArchiveDiscoveryCountCacheAndUnarchive(t *testing.T) {
	for _, version := range []string{"2.18", "2.19"} {
		t.Run(version, func(t *testing.T) {
			var archived atomic.Bool
			archived.Store(version == "2.19")
			tautulli := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Header.Get("X-Api-Key") != "synthetic-secret" || r.URL.Query().Has("apikey") {
					t.Error("API credential did not stay in the dedicated header")
				}
				var data any
				switch r.URL.Query().Get("cmd") {
				case "get_libraries":
					data = []map[string]any{{"section_id": "9007199254740993", "section_type": "movie", "section_name": "Synthetic Movies", "is_active": 1}}
				case "get_library_names":
					if r.URL.Query().Get("include_archived") != "1" {
						t.Error("archive roster was not requested")
					}
					item := map[string]any{"section_id": json.Number("9007199254740993"), "section_type": "movie", "section_name": "Synthetic Movies"}
					if version == "2.19" {
						item["is_archived"] = archived.Load()
					}
					data = []map[string]any{item}
				case "get_libraries_table":
					if version != "2.19" {
						t.Error("unnecessary table request for unique pre-archive names")
					}
					data = map[string]any{"recordsFiltered": 1, "recordsTotal": 1, "data": []map[string]any{{
						"section_id": json.Number("9007199254740993"), "section_type": "movie", "server_id": "fictional-current",
						"is_active": 1, "is_archived": archived.Load(), "deleted_section": 0,
					}}}
				case "get_server_identity":
					data = map[string]any{"machine_identifier": "fictional-current"}
				case "get_user_names", "get_users":
					item := map[string]any{"user_id": json.Number("1234567890123456789"), "friendly_name": "Synthetic Owner", "is_active": 1, "email": "synthetic@example.org", "is_owner": 1}
					if version == "2.19" {
						item["is_archived"] = archived.Load()
					}
					data = []map[string]any{item}
				default:
					t.Errorf("unexpected command %s", r.URL.Query().Get("cmd"))
				}
				_ = json.NewEncoder(w).Encode(map[string]any{"response": map[string]any{"result": "success", "data": data}})
			}))
			defer tautulli.Close()
			root := integrationConfigRoot(t, tautulli.URL, "synthetic-secret", "", "")
			setIntegrationConfigValues(t, root, map[string]any{
				"IncludedLibraryIds": []string{"9007199254740993"},
				"UserEmailOverrides": map[string]string{"1234567890123456789": "retained@example.org"},
			})
			view := ReadConfigEditor(root)
			request := TautulliDiscoveryRequest{ExpectedRevision: view.Revision, ConfirmRealNetwork: true}
			result, err := DiscoverTautulliChoices(context.Background(), root, request, time.Now)
			if err != nil {
				t.Fatal(err)
			}
			wantCount, wantLibrary := 1, "active"
			if version == "2.19" {
				wantCount, wantLibrary = 0, "archived"
			}
			if len(result.Users) != 1 || result.Users[0].ID != "1234567890123456789" || result.Users[0].Archived != archived.Load() || result.PrimaryRecipientCount == nil || *result.PrimaryRecipientCount != wantCount || len(result.Libraries) != 1 || result.Libraries[0].ID != "9007199254740993" || result.Libraries[0].Availability != wantLibrary {
				t.Fatalf("archive status, exact IDs, and count diverged: %+v", result)
			}
			if archived.Load() && result.SuggestedPreviewUserID != "" {
				t.Fatal("archived owner was suggested")
			}
			store := newTautulliDiscoveryStore(t.TempDir())
			if err := store.Save(result); err != nil {
				t.Fatal(err)
			}
			cached := store.Load(view.Revision)
			if cached == nil || cached.Users[0].Archived != archived.Load() || cached.Libraries[0].Availability != wantLibrary {
				t.Fatalf("cache lost archive status: %+v", cached)
			}
			if version == "2.19" {
				archived.Store(false)
				result, err = DiscoverTautulliChoices(context.Background(), root, request, time.Now)
				if err != nil || result.PrimaryRecipientCount == nil || *result.PrimaryRecipientCount != 1 || result.Users[0].Archived || result.Libraries[0].Availability != "active" || result.SuggestedPreviewUserID != "1234567890123456789" {
					t.Fatalf("unarchive refresh did not restore eligibility: %+v, %v", result, err)
				}
			}
			values, _, _, _ := readConfigDocument(root)
			if !configStringListContains(values["IncludedLibraryIds"], "9007199254740993", false) || configUserEmailOverride(values["UserEmailOverrides"], "1234567890123456789") != "retained@example.org" {
				t.Fatal("discovery changed saved selections or addresses")
			}
		})
	}
}

func TestTautulliLibraryArchiveLookupFailsClosed(t *testing.T) {
	for _, fallback := range []bool{false, true} {
		t.Run(map[bool]string{false: "DB lookup failed", true: "DB table fallback"}[fallback], func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				var data any
				switch r.URL.Query().Get("cmd") {
				case "get_libraries":
					data = []map[string]any{{"section_id": "10", "section_type": "movie", "is_active": 1}}
				case "get_libraries_table":
					if !fallback {
						http.Error(w, "unavailable", 500)
						return
					}
					if r.URL.Query().Get("include_archived") != "1" || r.URL.Query().Get("include_deleted") != "1" {
						t.Error("table fallback omitted archive/deletion policy")
					}
					data = map[string]any{"recordsFiltered": 2, "recordsTotal": 2, "data": []map[string]any{
						{"section_id": "10", "section_type": "movie", "is_active": 1, "is_archived": 1, "deleted_section": 0, "server_id": "fictional-current"},
						{"section_id": "20", "section_type": "show", "is_active": 1, "is_archived": 0, "deleted_section": 1, "server_id": "fictional-current"},
					}}
				case "get_server_identity":
					data = map[string]any{"machine_identifier": "fictional-current"}
				default:
					http.Error(w, "unavailable", 500)
					return
				}
				_ = json.NewEncoder(w).Encode(map[string]any{"response": map[string]any{"result": "success", "data": data}})
			}))
			defer server.Close()
			base, _ := url.Parse(server.URL)
			libraries, err := discoverTautulliLibraries(context.Background(), server.Client(), base, "synthetic")
			if !fallback {
				if err == nil || len(libraries) != 0 {
					t.Fatalf("failed DB lookup enabled live libraries: %+v, %v", libraries, err)
				}
			} else if err != nil || len(libraries) != 2 || libraries[0].Availability != "archived" || libraries[1].Availability != "deleted" {
				t.Fatalf("table archive evidence lost: %+v, %v", libraries, err)
			}
		})
	}
}

func TestTautulliLiveLibraryMissingFromDBIsUnavailable(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		data := []map[string]any{}
		if r.URL.Query().Get("cmd") == "get_libraries" {
			data = append(data, map[string]any{"section_id": "10", "section_type": "movie", "is_active": 1})
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"response": map[string]any{"result": "success", "data": data}})
	}))
	defer server.Close()
	base, _ := url.Parse(server.URL)
	libraries, err := discoverTautulliLibraries(context.Background(), server.Client(), base, "synthetic")
	if err != nil || len(libraries) != 1 || libraries[0].Availability != "unavailable" {
		t.Fatalf("unverified live library became active: %+v, %v", libraries, err)
	}
}

func TestTautulliArchivedUserBlocksEveryUserScopedOperation(t *testing.T) {
	for _, operationType := range []string{"preview-all", "send-test-all", "send-welcome"} {
		for _, eligibility := range []string{"archived", "deleted"} {
			t.Run(operationType+"/"+eligibility, func(t *testing.T) {
				root := integrationConfigRoot(t, "http://127.0.0.1:8181", "synthetic", "", "")
				data := t.TempDir()
				view := ReadConfigEditor(root)
				store := newTautulliDiscoveryStore(data)
				if err := store.Save(TautulliDiscoveryResult{Mode: "real-lan-discovery", NetworkBoundary: "private-and-loopback-only", ConfigRevision: view.Revision, CompletedAtUTC: time.Now().UTC().Format(time.RFC3339), Libraries: []DiscoveredLibrary{{ID: "10", Name: "Movies", MediaType: "movie", Availability: "archived"}}, Users: []DiscoveredUser{{ID: "42", Name: "Synthetic", Eligibility: eligibility}}}); err != nil {
					t.Fatal(err)
				}
				coordinator, err := newOperationCoordinator(Options{DataDir: data, TautWeeklyRoot: root, Now: time.Now, operationRunner: &fixturePreviewRunner{}})
				if err != nil {
					t.Fatal(err)
				}
				coordinator.discovery = store
				_, err = coordinator.Start(CreateOperationRequest{Type: operationType, ExpectedRevision: view.Revision, UserID: "42", ConfirmNoSend: operationType == "preview-all", ConfirmTestSend: operationType == "send-test-all", ConfirmProductionSend: operationType == "send-welcome"})
				if !errors.Is(err, ErrOperationUserUnavailable) || coordinator.Current() != nil {
					t.Fatalf("archived/deleted operation created state: %v", err)
				}
			})
		}
	}
}

func TestTautulliHeaderNeverFollowsRedirectOrEntersURL(t *testing.T) {
	var leaked atomic.Int32
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { leaked.Add(1) }))
	defer target.Close()
	for _, status := range []int{301, 302, 303, 307, 308} {
		for _, sameOrigin := range []bool{false, true} {
			source := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path != "/api/v2" {
					leaked.Add(1)
					return
				}
				if r.Header.Get("X-Api-Key") != "synthetic-header-secret" || strings.Contains(r.URL.String(), "synthetic") || r.URL.Query().Has("apikey") {
					t.Error("credential leaked to URL or header missing")
				}
				destination := target.URL + "/capture"
				if sameOrigin {
					destination = "/capture"
				}
				http.Redirect(w, r, destination, status)
			}))
			base, _ := url.Parse(source.URL)
			var data any
			err := tautulliCommandWithParams(context.Background(), source.Client(), base, "synthetic-header-secret", "get_users", url.Values{"apikey": {"synthetic-parameter-secret"}}, &data)
			source.Close()
			if err == nil || strings.Contains(err.Error(), "synthetic") {
				t.Fatalf("redirect error exposed credentials: %v", err)
			}
		}
	}
	if leaked.Load() != 0 {
		t.Fatal("credential-bearing request followed a redirect")
	}
}

func TestTautulliArchiveCountRejectsMalformedFlags(t *testing.T) {
	for _, value := range []any{nil, "invalid", map[string]any{}} {
		users := []map[string]any{{"user_id": "42", "is_active": 1, "email": "synthetic@example.org", "is_archived": value}}
		if count := countDiscoveredPrimaryRecipients(users, nil); count != nil {
			t.Fatalf("malformed archive flag produced count %d", *count)
		}
	}
}

func TestTautulliArchivedNameRemainsUnavailableWithoutDetails(t *testing.T) {
	users, _ := normalizeDiscoveredUsers([]map[string]any{{"user_id": "42", "friendly_name": "Synthetic Archived", "is_archived": 1}}, nil, nil, nil)
	if len(users) != 1 || !users[0].Archived || users[0].Eligibility != "archived" {
		t.Fatalf("archived names-only user remained selectable: %+v", users)
	}
}

func TestTautulliLibraryTableIncompleteRosterIsRejected(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("cmd") != "get_libraries_table" {
			http.Error(w, "unavailable", 500)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"response": map[string]any{"result": "success", "data": map[string]any{"recordsFiltered": 2, "data": []map[string]any{{"section_id": "10", "section_type": "movie", "is_active": 1}}}}})
	}))
	defer server.Close()
	base, _ := url.Parse(server.URL)
	if libraries, err := discoverTautulliLibraries(context.Background(), server.Client(), base, "synthetic"); err == nil || len(libraries) != 0 {
		t.Fatalf("partial roster enabled libraries: %+v, %v", libraries, err)
	}
}

func TestTautulliArchivedOperationAPIReturnsSanitizedAvailabilityGuidance(t *testing.T) {
	root := integrationConfigRoot(t, "http://127.0.0.1:8181", "synthetic-api-secret", "", "")
	const privateUserID = "9876543210123456789"
	server, err := New(Options{DataDir: t.TempDir(), TautWeeklyRoot: root, Version: "test", operationRunner: &fixturePreviewRunner{}})
	if err != nil {
		t.Fatal(err)
	}
	revision := ReadConfigEditor(root).Revision
	if err := server.discovery.Save(TautulliDiscoveryResult{Mode: "real-lan-discovery", NetworkBoundary: "private-and-loopback-only", ConfigRevision: revision, CompletedAtUTC: time.Now().UTC().Format(time.RFC3339), Libraries: []DiscoveredLibrary{{ID: "10", Name: "Synthetic Movies", MediaType: "movie"}}, Users: []DiscoveredUser{{ID: privateUserID, Name: "Synthetic Archived", Eligibility: "archived", Archived: true}}}); err != nil {
		t.Fatal(err)
	}
	current, err := server.auth.newSession()
	if err != nil {
		t.Fatal(err)
	}
	body, _ := json.Marshal(CreateOperationRequest{Type: "preview-all", ExpectedRevision: revision, UserID: privateUserID, ConfirmNoSend: true})
	response := mutationRequestForTest(server, http.MethodPost, "/api/v1/operations", body, &http.Cookie{Name: sessionCookieName, Value: current.Token}, current.CSRFToken)
	if response.Code != http.StatusUnprocessableEntity || !strings.Contains(response.Body.String(), `"code":"operation-user-unavailable"`) || !strings.Contains(response.Body.String(), "Restore the account in Tautulli") {
		t.Fatalf("incorrect archive guidance: %d %s", response.Code, response.Body.String())
	}
	assertOperationResponseSanitized(t, response.Body.String(), privateUserID)
}

func TestTautulliRecipientCountMatchesConservativeJoinedArchiveChoices(t *testing.T) {
	for _, namesArchived := range []bool{false, true} {
		t.Run(map[bool]string{true: "names archived first", false: "details archived later"}[namesArchived], func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				var data any
				switch r.URL.Query().Get("cmd") {
				case "get_libraries", "get_library_names":
					data = []map[string]any{{"section_id": "10", "section_type": "movie", "is_active": 1}}
				case "get_user_names":
					data = []map[string]any{{"user_id": "42", "friendly_name": "Synthetic Changing", "is_archived": namesArchived}, {"user_id": "43", "friendly_name": "Synthetic Active", "is_archived": false}}
				case "get_users":
					data = []map[string]any{{"user_id": "42", "friendly_name": "Synthetic Changing", "is_active": 1, "email": "changing@example.org", "is_archived": !namesArchived}, {"user_id": "43", "friendly_name": "Synthetic Active", "is_active": 1, "email": "active@example.org", "is_archived": false}}
				default:
					t.Errorf("unexpected command: %s", r.URL.Query().Get("cmd"))
				}
				_ = json.NewEncoder(w).Encode(map[string]any{"response": map[string]any{"result": "success", "data": data}})
			}))
			defer server.Close()
			root := integrationConfigRoot(t, server.URL, "synthetic", "", "")
			result, err := DiscoverTautulliChoices(context.Background(), root, TautulliDiscoveryRequest{ExpectedRevision: ReadConfigEditor(root).Revision, ConfirmRealNetwork: true}, time.Now)
			if err != nil {
				t.Fatal(err)
			}
			if result.PrimaryRecipientCount == nil || *result.PrimaryRecipientCount != 1 {
				t.Fatalf("joined archive policy and count disagree: %+v", result)
			}
			for _, user := range result.Users {
				if user.ID == "42" && (!user.Archived || user.Eligibility != "archived") {
					t.Fatalf("joined choice lost conservative archive status: %+v", user)
				}
			}
		})
	}
}

// A repointed Tautulli instance keeps other servers' DB rows. The live, names,
// and table responses deliberately expose different fields, as upstream does.
func TestTautulliRepointedLibraryDiscoveryVerificationAndCache(t *testing.T) {
	const current = "fictional-current-machine"
	type row = map[string]any
	table := []row{
		{"section_id": 1, "section_type": "movie", "server_id": "fictional-other", "is_active": 0, "is_archived": 1, "deleted_section": 0},
		{"section_id": 1, "section_type": "movie", "server_id": current, "is_active": 1, "is_archived": 0, "deleted_section": 0},
		{"section_id": 1, "section_type": "artist", "server_id": "fictional-retired", "is_active": 0, "is_archived": 0, "deleted_section": 0},
		{"section_id": 2, "section_type": "show", "server_id": current, "is_active": 1, "is_archived": 0, "deleted_section": 0},
		{"section_id": 2, "section_type": "artist", "server_id": "fictional-other", "is_active": 1, "is_archived": 0, "deleted_section": 0},
		{"section_id": 3, "section_type": "show", "server_id": current, "is_active": 1, "is_archived": 1, "deleted_section": 0},
		{"section_id": 4, "section_type": "movie", "server_id": current, "is_active": 1, "is_archived": 0, "deleted_section": 1},
		{"section_id": 4, "section_type": "movie", "server_id": "fictional-retired", "is_active": 0, "is_archived": 0, "deleted_section": 0},
		{"section_id": 5, "section_type": "movie", "server_id": "fictional-other", "is_active": 1, "is_archived": 0, "deleted_section": 0},
		{"section_id": 6, "section_type": "show", "server_id": current, "is_active": 1, "is_archived": 0, "deleted_section": 0},
	}
	var names, live []row
	for _, entry := range table {
		if entry["deleted_section"] != 1 {
			names = append(names, row{"section_id": entry["section_id"], "section_name": "DB display", "section_type": entry["section_type"], "agent": "fixture", "is_archived": entry["is_archived"]})
		}
	}
	for id, mediaType := range map[int]string{1: "movie", 2: "show", 3: "show", 4: "movie", 5: "movie", 6: "show"} {
		live = append(live, row{"section_id": id, "section_type": mediaType, "section_name": "Live display", "is_active": 1})
	}
	var hideLive atomic.Bool
	service := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-Api-Key") != "fictional-api-key" || r.URL.Query().Has("apikey") {
			t.Error("credential transport changed")
		}
		var data any
		switch r.URL.Query().Get("cmd") {
		case "get_libraries":
			data = live
			if hideLive.Load() {
				data = []row{}
			}
		case "get_library_names":
			data = names
		case "get_libraries_table":
			params := r.URL.Query()
			if params.Get("start") != "0" || params.Get("length") != "-1" || params.Get("include_deleted") != "1" || params.Get("include_archived") != "1" {
				t.Error("table did not request every policy row")
			}
			data = row{"recordsTotal": len(table), "recordsFiltered": len(table), "data": table}
		case "get_server_identity":
			data = row{"machine_identifier": current}
		case "get_tautulli_info":
			data = row{"tautulli_version": "2.19.1"}
		case "get_server_info":
			data = row{}
		case "get_user_names", "get_users":
			data = []row{{"user_id": 7, "friendly_name": "Fixture user", "is_active": 1, "email": "fixture@example.org"}}
		default:
			t.Errorf("unexpected command %s", r.URL.Query().Get("cmd"))
		}
		_ = json.NewEncoder(w).Encode(row{"response": row{"result": "success", "data": data}})
	}))
	defer service.Close()
	root := integrationConfigRoot(t, service.URL, "fictional-api-key", "", "")
	setIntegrationConfigValues(t, root, row{"IncludedLibraryIds": []string{"1", "6"}})
	revision := ReadConfigEditor(root).Revision
	result, err := DiscoverTautulliChoices(context.Background(), root, TautulliDiscoveryRequest{ExpectedRevision: revision, ConfirmRealNetwork: true}, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	store := newTautulliDiscoveryStore(t.TempDir())
	if err := store.Save(result); err != nil {
		t.Fatal(err)
	}
	cached := store.Load(revision)
	if cached == nil || len(cached.Libraries) != 6 {
		t.Fatalf("missing choices: %+v", cached)
	}
	expected := map[string]string{"1": "active", "2": "unavailable", "3": "archived", "4": "deleted", "5": "unavailable", "6": "active"}
	for _, choice := range cached.Libraries {
		if expected[choice.ID] != choice.Availability || choice.Name != "Live display" {
			t.Errorf("unexpected library choice %+v", choice)
		}
	}
	encoded, _ := json.Marshal(cached)
	for _, private := range []string{current, "fictional-other", "fictional-retired", "fictional-api-key", "fixture@example.org"} {
		if strings.Contains(string(encoded), private) {
			t.Error("raw table or user details escaped into cached choices")
		}
	}
	values, _, _, _ := readConfigDocument(root)
	check, _ := verifyTautulli(context.Background(), service.Client(), values)
	if check.State != "passed" || !strings.Contains(check.Summary, "2 active movie/TV libraries") {
		t.Fatalf("incorrect verification: %+v", check)
	}
	if ReadConfigEditor(root).Revision != revision {
		t.Error("discovery modified saved configuration")
	}
	hideLive.Store(true)
	base, _ := url.Parse(service.URL)
	choices, err := discoverTautulliLibraries(context.Background(), service.Client(), base, "fictional-api-key")
	if err != nil || len(choices) == 0 {
		t.Fatalf("table-only policy lookup failed: %v", err)
	}
	for _, choice := range choices {
		if choice.Availability == "active" {
			t.Errorf("archive-aware DB-only row became active without a live library: %+v", choice)
		}
	}
}

func TestTautulliDuplicatePolicyNeedsCompleteEvidence(t *testing.T) {
	type row = map[string]any
	live := row{"section_id": 8, "section_type": "show"}
	names := []row{{"section_id": 8, "section_type": "show", "is_archived": 0}, {"section_id": 8, "section_type": "show", "is_archived": 0}}
	for _, test := range []struct {
		name   string
		change func([]row)
	}{
		{"unproven activity", func(rows []row) { delete(rows[1], "is_active") }},
		{"nonbinary activity", func(rows []row) { rows[1]["is_active"] = 4 }},
		{"missing archive evidence", func(rows []row) { delete(rows[0], "is_archived") }},
		{"missing deletion evidence", func(rows []row) { delete(rows[0], "deleted_section") }},
		{"missing server identity", func(rows []row) { delete(rows[0], "server_id") }},
		{"wrong live section type", func(rows []row) { rows[0]["section_type"] = "artist" }},
		{"insufficient nondeleted rows", func(rows []row) { rows[1]["deleted_section"] = 1 }},
		{"no active row", func(rows []row) { rows[0]["is_active"] = 0 }},
	} {
		t.Run(test.name, func(t *testing.T) {
			rows := []row{
				{"server_id": "fixture-current", "section_type": "show", "is_active": 1, "is_archived": 0, "deleted_section": 0},
				{"server_id": "fixture-other", "section_type": "show", "is_active": 0, "is_archived": 0, "deleted_section": 0},
			}
			test.change(rows)
			if currentLibraryPolicy(live, names, rows, true, true, "fixture-current") != nil {
				t.Error("invalid evidence made duplicate eligible")
			}
		})
	}
	// In 2.18 get_libraries_table groups by server and section and always
	// omits deleted DB rows. Archive and deleted flags are absent.
	legacyNames := []row{{"section_type": "show"}, {"section_type": "show"}}
	legacy := []row{{"section_type": "show", "is_active": 0, "server_id": "fixture-other"}, {"section_type": "show", "is_active": 1, "server_id": "fixture-current"}}
	page := tautulliLibrariesTable{Data: legacy, RecordsTotal: "3", RecordsFiltered: "2"}
	if !page.complete(false) || page.complete(true) || currentLibraryPolicy(live, legacyNames, legacy, false, true, "fixture-current") == nil {
		t.Fatal("pre-archive table shape was not distinguished from a partial modern table")
	}
	for _, count := range []json.Number{"", "-1", "1", "3", "2.1"} {
		page.RecordsFiltered = count
		if page.complete(false) {
			t.Errorf("invalid filtered count %q accepted", count)
		}
	}
}
