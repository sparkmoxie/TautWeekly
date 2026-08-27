package manager

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

var cacheStatusNow = time.Date(2032, 7, 8, 9, 10, 11, 0, time.UTC)

func TestDeletedItemCacheStatusDisabledAndUnseeded(t *testing.T) {
	root := normalizedConfigRoot(t)
	status := collectDeletedItemCacheStatus(root, false, false, func() time.Time { return cacheStatusNow })
	if status.State != "warning" || status.ManifestState != "unseeded" || status.EntryCount != 0 || status.Writability != "not-checked" {
		t.Fatalf("unseeded status: %+v", status)
	}
	if _, err := os.Stat(filepath.Join(root, "cache")); !os.IsNotExist(err) {
		t.Fatalf("read-only status created cache storage: %v", err)
	}

	request := validConfigSaveRequest(t, ReadConfigEditor(root))
	request.Values["DeletedItemCacheEnabled"] = json.RawMessage(`false`)
	result, fields, err := SaveConfig(root, request, time.Now)
	if err != nil || len(fields) != 0 || !result.Saved {
		t.Fatalf("disable cache: fields=%v err=%v", fields, err)
	}
	status = collectDeletedItemCacheStatus(root, true, true, func() time.Time { return cacheStatusNow })
	if status.State != "skipped" || status.ManifestState != "disabled" || status.Writability != "not-applicable" {
		t.Fatalf("disabled status: %+v", status)
	}
}

func TestDeletedItemCacheStatusHealthyAndPrivate(t *testing.T) {
	root := normalizedConfigRoot(t)
	private := seedDeletedItemCache(t, root, cacheStatusNow, false)
	status := collectDeletedItemCacheStatus(root, true, true, func() time.Time { return cacheStatusNow })
	if status.State != "passed" || status.ManifestState != "primary-valid" || status.Writability != "passed" || status.IntegrityState != "verified" || status.EntryCount != 1 || status.ArtworkCount != 1 || status.HashMismatchCount != 0 {
		t.Fatalf("healthy status: %+v", status)
	}
	encoded, err := json.Marshal(status)
	if err != nil {
		t.Fatal(err)
	}
	for _, forbidden := range private {
		if strings.Contains(string(encoded), forbidden) {
			t.Fatalf("status exposed private cache value %q: %s", forbidden, encoded)
		}
	}
	if matches, _ := filepath.Glob(filepath.Join(root, "cache", "deleted-items", ".manager-cache-write-probe-*.tmp")); len(matches) != 0 {
		t.Fatalf("write probe was not removed: %v", matches)
	}
}

func TestDeletedItemCacheStatusReportsUnhealthyBackup(t *testing.T) {
	root := normalizedConfigRoot(t)
	seedDeletedItemCache(t, root, cacheStatusNow, false)
	cacheRoot := filepath.Join(root, "cache", "deleted-items")
	if err := os.WriteFile(filepath.Join(cacheRoot, "index.backup.json"), []byte(`{"SchemaVersion":1,"Entries":[`), 0o600); err != nil {
		t.Fatal(err)
	}
	status := collectDeletedItemCacheStatus(root, false, false, func() time.Time { return cacheStatusNow })
	if status.State != "warning" || status.ManifestState != "primary-valid" || status.BackupState != "invalid" || status.IntegrityState != "warning" || !strings.Contains(status.Summary, "backup manifest") {
		t.Fatalf("unhealthy backup status: %+v", status)
	}
}

func TestDeletedItemCacheStatusDetectsRecoveryAndDamage(t *testing.T) {
	root := normalizedConfigRoot(t)
	seedDeletedItemCache(t, root, cacheStatusNow, true)
	cacheRoot := filepath.Join(root, "cache", "deleted-items")
	valid, err := os.ReadFile(filepath.Join(cacheRoot, "index.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(cacheRoot, "index.backup.json"), valid, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(cacheRoot, "index.json"), []byte(`{"SchemaVersion":1,"Entries":[`), 0o600); err != nil {
		t.Fatal(err)
	}
	status := collectDeletedItemCacheStatus(root, false, false, func() time.Time { return cacheStatusNow })
	if status.State != "warning" || status.ManifestState != "backup-recoverable" || status.IntegrityState != "warning" {
		t.Fatalf("backup recovery status: %+v", status)
	}

	if err := os.WriteFile(filepath.Join(cacheRoot, "index.json"), valid, 0o600); err != nil {
		t.Fatal(err)
	}
	artwork, err := os.ReadDir(filepath.Join(cacheRoot, "artwork"))
	if err != nil || len(artwork) != 1 {
		t.Fatalf("artwork fixture: %v entries=%d", err, len(artwork))
	}
	if err := os.WriteFile(filepath.Join(cacheRoot, "artwork", artwork[0].Name()), []byte(strings.Repeat("x", 1024)), 0o600); err != nil {
		t.Fatal(err)
	}
	status = collectDeletedItemCacheStatus(root, true, false, func() time.Time { return cacheStatusNow })
	if status.State != "failed" || status.HashMismatchCount != 1 || status.IntegrityState != "failed" {
		t.Fatalf("hash damage status: %+v", status)
	}
}

func TestDeletedItemCacheStatusDoesNotTreatOrphanBackupAsRecoverable(t *testing.T) {
	root := normalizedConfigRoot(t)
	seedDeletedItemCache(t, root, cacheStatusNow, false)
	cacheRoot := filepath.Join(root, "cache", "deleted-items")
	valid, err := os.ReadFile(filepath.Join(cacheRoot, "index.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(cacheRoot, "index.backup.json"), valid, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(cacheRoot, "index.json")); err != nil {
		t.Fatal(err)
	}
	status := collectDeletedItemCacheStatus(root, false, false, func() time.Time { return cacheStatusNow })
	if status.ManifestState != "unseeded" || status.BackupState != "stale-ignored" || status.EntryCount != 0 || !strings.Contains(status.Summary, "stale backup") {
		t.Fatalf("orphan backup status: %+v", status)
	}
}

func TestDeletedItemCacheStatusEndpointRequiresSessionCSRFAndRevision(t *testing.T) {
	root := normalizedConfigRoot(t)
	server, err := New(Options{DataDir: t.TempDir(), TautWeeklyRoot: root, RuntimeRoot: root, Version: "test", Now: func() time.Time { return cacheStatusNow }})
	if err != nil {
		t.Fatal(err)
	}
	session, err := server.auth.newSession()
	if err != nil {
		t.Fatal(err)
	}
	cookie := &http.Cookie{Name: sessionCookieName, Value: session.Token}
	revision := ReadConfigEditor(root).Revision
	body, _ := json.Marshal(cacheVerificationRequest{ExpectedRevision: revision})
	withoutCSRF := requestForTest(server, http.MethodPost, "/api/v1/checks/deleted-item-cache", strings.NewReader(string(body)), cookie)
	if withoutCSRF.Code != http.StatusForbidden {
		t.Fatalf("cache check without CSRF: %d %s", withoutCSRF.Code, withoutCSRF.Body.String())
	}
	conflictBody, _ := json.Marshal(cacheVerificationRequest{ExpectedRevision: strings.Repeat("0", 64)})
	conflict := mutationRequestForTest(server, http.MethodPost, "/api/v1/checks/deleted-item-cache", conflictBody, cookie, session.CSRFToken)
	if conflict.Code != http.StatusConflict {
		t.Fatalf("cache check wrong revision: %d %s", conflict.Code, conflict.Body.String())
	}
	checked := mutationRequestForTest(server, http.MethodPost, "/api/v1/checks/deleted-item-cache", body, cookie, session.CSRFToken)
	if checked.Code != http.StatusOK {
		t.Fatalf("cache check: %d %s", checked.Code, checked.Body.String())
	}
	if checked.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("cache check response is cacheable: %q", checked.Header().Get("Cache-Control"))
	}
	var status DeletedItemCacheStatus
	if err := json.Unmarshal(checked.Body.Bytes(), &status); err != nil || status.Verification != "full" || status.Writability != "passed" {
		t.Fatalf("cache check response: status=%+v err=%v", status, err)
	}
	configuration := requestForTest(server, http.MethodGet, "/api/v1/config/status", nil, cookie)
	if configuration.Code != http.StatusOK {
		t.Fatalf("configuration status: %d %s", configuration.Code, configuration.Body.String())
	}
	var setup ConfigurationStatus
	if err := json.Unmarshal(configuration.Body.Bytes(), &setup); err != nil || setup.Cache == nil || setup.Steps["cache"].State == "" {
		t.Fatalf("configuration cache status: setup=%+v err=%v", setup, err)
	}
}

func seedDeletedItemCache(t *testing.T, root string, observed time.Time, expired bool) []string {
	t.Helper()
	cacheRoot := filepath.Join(root, "cache", "deleted-items")
	artworkRoot := filepath.Join(cacheRoot, "artwork")
	if err := os.MkdirAll(artworkRoot, 0o700); err != nil {
		t.Fatal(err)
	}
	guid := "plex://movie/private-synthetic-guid"
	mediaType := "movie"
	idDigest := sha256.Sum256([]byte(mediaType + "|" + guid))
	id := hex.EncodeToString(idDigest[:])
	artworkBytes := []byte(strings.Repeat("synthetic-artwork-", 64))
	artworkDigest := sha256.Sum256(artworkBytes)
	artworkHash := hex.EncodeToString(artworkDigest[:])
	fileName := id + ".jpg"
	if err := os.WriteFile(filepath.Join(artworkRoot, fileName), artworkBytes, 0o600); err != nil {
		t.Fatal(err)
	}
	lastSeen := observed
	if expired {
		lastSeen = observed.AddDate(-2, 0, 0)
	}
	manifest := map[string]any{
		"SchemaVersion": 1,
		"UpdatedUtc":    observed.Format(time.RFC3339Nano),
		"Entries": []map[string]any{{
			"Id": id, "MediaType": mediaType, "Guid": guid, "Title": "PRIVATE SYNTHETIC TITLE",
			"CreatedUtc": lastSeen.Format(time.RFC3339Nano), "LastSeenUtc": lastSeen.Format(time.RFC3339Nano),
			"Poster": map[string]any{"FileName": fileName, "Sha256": artworkHash, "Bytes": len(artworkBytes)},
		}},
	}
	raw, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(cacheRoot, "index.json"), raw, 0o600); err != nil {
		t.Fatal(err)
	}
	return []string{root, guid, id, fileName, artworkHash, "PRIVATE SYNTHETIC TITLE"}
}
