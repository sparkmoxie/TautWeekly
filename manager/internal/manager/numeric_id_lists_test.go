package manager

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

// Write raw JSON values so IDs never pass through floating-point test fixtures.
func numericIDListConfig(t *testing.T, excluded, included string) (string, []byte) {
	t.Helper()
	root := integrationConfigRoot(t, "http://127.0.0.1:8181", "fictional-api-key", "", "")
	values, _, _, _ := readConfigDocument(root)
	values["ExcludedUserIds"] = json.RawMessage(excluded)
	values["IncludedLibraryIds"] = json.RawMessage(included)
	encoded, err := json.MarshalIndent(values, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	encoded = append(encoded, '\n')
	if err := os.WriteFile(filepath.Join(root, "config.json"), encoded, 0o600); err != nil {
		t.Fatal(err)
	}
	return root, encoded
}

func TestNumericIDListsSurviveUnrelatedConfigSave(t *testing.T) {
	for _, test := range []struct {
		name string
		raw  string
		want []string
	}{
		{"numbers", `[12345678,23456789,9007199254740993,18446744073709551615]`, []string{"12345678", "23456789", "9007199254740993", "18446744073709551615"}},
		{"mixed", `[12345678,"23456789",9007199254740993,"18446744073709551615"]`, []string{"12345678", "23456789", "9007199254740993", "18446744073709551615"}},
	} {
		t.Run(test.name, func(t *testing.T) {
			root, previous := numericIDListConfig(t, test.raw, `[1,2]`)
			view := ReadConfigEditor(root)
			if !view.Valid || view.State != "ready" {
				t.Fatalf("numeric IDs should load as ready: %+v", view.Issues)
			}
			if got := editorField(t, view, "ExcludedUserIds").Value; !reflect.DeepEqual(got, test.want) {
				t.Errorf("editor lost numeric exclusions or precision: got %#v, want %#v", got, test.want)
			}
			request := validConfigSaveRequest(t, view)
			request.Values["IncludedLibraryIds"] = json.RawMessage(`["1"]`)
			result, fields, err := SaveConfig(root, request, time.Now)
			if err != nil || len(fields) != 0 || !result.Saved {
				t.Fatalf("unrelated library save: %+v, fields=%v err=%v", result, fields, err)
			}
			current, _, _, state := readConfigDocument(root)
			if state != "ready" {
				t.Fatalf("saved configuration unreadable: %s", state)
			}
			encodedIDs, err := json.Marshal(current["ExcludedUserIds"])
			if err != nil {
				t.Fatal(err)
			}
			var got []string
			if err := json.Unmarshal(encodedIDs, &got); err != nil {
				t.Fatalf("stored IDs are not canonical strings: %s", encodedIDs)
			}
			if !reflect.DeepEqual(got, test.want) {
				t.Errorf("unrelated save widened exclusions: got %s, want %v", encodedIDs, test.want)
			}
			for _, id := range test.want {
				if !savedOperationUserExcluded(current, id) {
					t.Errorf("saved operation exclusion missing for %s after save", id)
				}
			}
			backup, err := os.ReadFile(filepath.Join(root, result.Backup))
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(backup, previous) {
				t.Fatal("save backup changed original numeric policy bytes")
			}
		})
	}
}

func TestNumericLibraryIDsSurviveUnrelatedConfigSave(t *testing.T) {
	root, _ := numericIDListConfig(t, `[]`, `[0,1,9007199254740993,18446744073709551615]`)
	view := ReadConfigEditor(root)
	want := []string{"0", "1", "9007199254740993", "18446744073709551615"}
	if got := editorField(t, view, "IncludedLibraryIds").Value; !reflect.DeepEqual(got, want) {
		t.Errorf("editor lost library scope: %#v", got)
	}
	request := validConfigSaveRequest(t, view)
	request.Values["ServerLabel"] = json.RawMessage(`"Fictional updated label"`)
	result, fields, err := SaveConfig(root, request, time.Now)
	if err != nil || len(fields) != 0 || !result.Saved {
		t.Fatalf("save: %+v fields=%v err=%v", result, fields, err)
	}
	if got := editorField(t, result.Editor, "IncludedLibraryIds").Value; !reflect.DeepEqual(got, want) {
		t.Errorf("unrelated save widened library scope: %#v", got)
	}
}

func TestNumericExcludedIDsApplyBeforeAndAfterConfigSave(t *testing.T) {
	root, _ := numericIDListConfig(t, `[12345678,9007199254740993,18446744073709551615]`, `[]`)
	ids := []string{"12345678", "9007199254740993", "18446744073709551615"}
	for _, phase := range []string{"before", "after"} {
		view := ReadConfigEditor(root)
		values, _, _, _ := readConfigDocument(root)
		users := []map[string]any{}
		for _, id := range ids {
			if !savedOperationUserExcluded(values, id) {
				t.Errorf("%s save: numeric exclusion ignored for %s", phase, id)
			}
			users = append(users, map[string]any{"user_id": id, "is_active": json.Number("1"), "deleted_user": json.Number("0"), "email": "recipient@example.org"})
		}
		users = append(users, map[string]any{"user_id": "7", "is_active": json.Number("1"), "email": "included@example.org"})
		count := countDiscoveredPrimaryRecipients(users, values)
		if count == nil || *count != 1 {
			t.Errorf("%s save: primary count should exclude numeric IDs and retain one included recipient, got %v", phase, count)
		}
		for _, operationType := range []string{"preview-all", "send-test-all", "send-welcome"} {
			coordinator, err := newOperationCoordinator(Options{DataDir: t.TempDir(), TautWeeklyRoot: root, Now: time.Now, operationRunner: &fixturePreviewRunner{}})
			if err != nil {
				t.Fatal(err)
			}
			request := CreateOperationRequest{Type: operationType, ExpectedRevision: view.Revision, UserID: ids[0], ConfirmNoSend: operationType == "preview-all", ConfirmTestSend: operationType == "send-test-all", ConfirmProductionSend: operationType == "send-welcome"}
			if _, err := coordinator.Start(request); !errors.Is(err, ErrOperationUserExcluded) {
				if coordinator.cancel != nil {
					coordinator.cancel()
				}
				t.Fatalf("%s save: %s bypassed numeric exclusion: %v", phase, operationType, err)
			}
			if coordinator.Current() != nil {
				t.Fatal("excluded operation created durable state")
			}
		}
		if phase == "before" {
			request := validConfigSaveRequest(t, view)
			request.Values["ServerLabel"] = json.RawMessage(`"Fictional updated label"`)
			if result, fields, err := SaveConfig(root, request, time.Now); err != nil || len(fields) != 0 || !result.Saved {
				t.Fatalf("save: %+v fields=%v err=%v", result, fields, err)
			}
		}
	}
}

func TestMalformedStoredIDListsAreVisibleAndCannotBeSilentlyCleared(t *testing.T) {
	for _, field := range []string{"ExcludedUserIds", "IncludedLibraryIds"} {
		for _, invalid := range []string{`[12345678,true]`, `[12345678,null]`, `[12345678,{}]`, `[-1]`, `[1.5]`, `[18446744073709551616]`, `12345678`, `"12345678"`, `null`} {
			t.Run(field+"/"+invalid, func(t *testing.T) {
				excluded, included := `[]`, `[]`
				if field == "ExcludedUserIds" {
					excluded = invalid
				} else {
					included = invalid
				}
				root, previous := numericIDListConfig(t, excluded, included)
				view := ReadConfigEditor(root)
				if view.Issues[field] == "" {
					t.Errorf("stored malformed policy has no visible %s validation issue", field)
				}
				request := validConfigSaveRequest(t, view)
				// Even a stale/sanitizing client cannot conceal malformed stored policy.
				request.Values[field] = json.RawMessage(`[]`)
				request.Values["ServerLabel"] = json.RawMessage(`"Fictional updated label"`)
				result, fields, err := SaveConfig(root, request, time.Now)
				if result.Saved || (err == nil && fields[field] == "") {
					t.Errorf("malformed stored ID policy was silently overwritten: result=%+v fields=%v err=%v", result, fields, err)
				}
				current, readErr := os.ReadFile(filepath.Join(root, "config.json"))
				if readErr != nil {
					t.Fatal(readErr)
				}
				if !bytes.Equal(current, previous) {
					t.Error("rejected save changed stored policy bytes")
				}
			})
		}
	}
}

func TestNumericIDAcceptanceDoesNotCoerceEmailLists(t *testing.T) {
	for _, raw := range []string{`[12345678]`, `["blocked@example.org",12345678]`} {
		if _, message := parseAndValidateConfigValue(json.RawMessage(raw), configDefinition{Name: "ExcludedEmails", Type: "email-list"}); message == "" {
			t.Fatalf("numeric email exclusion unexpectedly accepted: %s", raw)
		}
	}
	// ID support must not turn malformed email rules into usable delivery evidence.
	users := []map[string]any{{"user_id": "1", "is_active": json.Number("1"), "email": "recipient@example.org"}}
	if count := countDiscoveredPrimaryRecipients(users, map[string]any{"ExcludedEmails": []any{json.Number("12345678")}}); count != nil {
		t.Fatal("numeric email exclusion was coerced to usable delivery evidence")
	}
}

func TestIDListsAcceptExactNumericSubmissionsOnly(t *testing.T) {
	for _, name := range []string{"ExcludedUserIds", "IncludedLibraryIds"} {
		definition := configDefinition{Name: name, Type: "string-list"}
		result, message := parseAndValidateConfigValue(json.RawMessage(`[0,12345678,9007199254740993,18446744073709551615,"23456789"]`), definition)
		want := []string{"0", "12345678", "9007199254740993", "18446744073709551615", "23456789"}
		if message != "" || !reflect.DeepEqual(result, want) {
			t.Errorf("%s precise numeric API submission: got %#v message %q", name, result, message)
		}
		for _, raw := range []string{`[1.0]`, `[1e3]`, `[-1]`, `[true]`, `[null]`, `[{}]`, `[18446744073709551616]`} {
			if _, message := parseAndValidateConfigValue(json.RawMessage(raw), definition); message == "" {
				t.Errorf("%s accepted ambiguous numeric/type value %s", name, raw)
			}
		}
	}
}
