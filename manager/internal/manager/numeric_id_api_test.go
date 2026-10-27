package manager

import (
	"bytes"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestNumericIDPolicyAuthenticatedAPISmoke(t *testing.T) {
	for _, profile := range []struct{ mode, runtimeProfile, packageKind string }{
		{"windows", "native-windows", "windows-installer"},
		{"nas", "server", "container-compose"},
		{"nas", "unraid", "container-unraid"},
		{"mac", "desktop", "container-desktop"},
		{"linux", "native-linux", "linux-native"},
		{"nas", "server", "freebsd-podman"},
	} {
		t.Run(profile.mode+"/"+profile.runtimeProfile+"/"+profile.packageKind, func(t *testing.T) {
			root, original := numericIDListConfig(t, `[12345678,9007199254740993,18446744073709551615]`, `[1,2]`)
			server, err := New(Options{DataDir: t.TempDir(), TautWeeklyRoot: root, RuntimeRoot: root, RuntimeMode: profile.mode, RuntimeProfile: profile.runtimeProfile, PackageKind: profile.packageKind, Version: "test"})
			if err != nil {
				t.Fatal(err)
			}
			session, err := server.auth.newSession()
			if err != nil {
				t.Fatal(err)
			}
			cookie := &http.Cookie{Name: sessionCookieName, Value: session.Token}
			response := requestForTest(server, http.MethodGet, "/api/v1/config/editor", nil, cookie)
			if response.Code != http.StatusOK {
				t.Fatalf("editor GET returned %d", response.Code)
			}
			var view ConfigEditorView
			if err := json.Unmarshal(response.Body.Bytes(), &view); err != nil {
				t.Fatal(err)
			}
			want := []string{"12345678", "9007199254740993", "18446744073709551615"}
			assertIDs := func(t *testing.T, view ConfigEditorView) {
				t.Helper()
				encoded, err := json.Marshal(editorField(t, view, "ExcludedUserIds").Value)
				if err != nil {
					t.Fatal(err)
				}
				var ids []string
				if err := json.Unmarshal(encoded, &ids); err != nil {
					t.Fatal("API returned numeric IDs instead of exact strings")
				}
				if !reflect.DeepEqual(ids, want) {
					t.Fatalf("API lost exclusions: got %v", ids)
				}
			}
			assertIDs(t, view)
			request := validConfigSaveRequest(t, view)
			request.Values["IncludedLibraryIds"] = json.RawMessage(`["1"]`)
			body, err := json.Marshal(request)
			if err != nil {
				t.Fatal(err)
			}
			saved := mutationRequestForTest(server, http.MethodPut, "/api/v1/config", body, cookie, session.CSRFToken)
			if saved.Code != http.StatusOK {
				t.Fatalf("unrelated save returned %d", saved.Code)
			}
			var result ConfigSaveResult
			if err := json.Unmarshal(saved.Body.Bytes(), &result); err != nil {
				t.Fatal(err)
			}
			if !result.Saved {
				t.Fatal("save did not persist")
			}
			assertIDs(t, result.Editor)
			stored, _, _, state := readConfigDocument(root)
			if state != "ready" {
				t.Fatal(state)
			}
			for _, id := range want {
				if !savedOperationUserExcluded(stored, id) {
					t.Fatalf("saved numeric exclusion %s missing", id)
				}
			}
			backup, err := os.ReadFile(filepath.Join(root, result.Backup))
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(backup, original) {
				t.Fatal("backup did not preserve original numeric JSON")
			}
		})
	}
}
