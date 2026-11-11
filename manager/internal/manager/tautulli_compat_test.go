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
					data = map[string]any{"data": []map[string]any{{"section_id": "10", "section_type": "movie", "is_active": 1, "is_archived": 1}, {"section_id": "20", "section_type": "show", "is_active": 1, "deleted_section": 1}}}
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
