package manager

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

func TestDiagnosticHistoryIsBoundedSanitizedAndPrivate(t *testing.T) {
	data := t.TempDir()
	now := time.Date(2031, 4, 18, 16, 30, 0, 0, time.UTC)
	store := newDiagnosticStore(data, func() time.Time { return now })

	store.Record("configuration", "failed", "https://private.example/?token=never-store-this")
	store.Record("configuration", "passed", "config-saved")
	for index := 0; index < diagnosticHistoryLimit+8; index++ {
		now = now.Add(time.Minute)
		store.Record("configuration", "warning", "config-validation-failed")
	}

	history := store.History()
	if len(history.Events) != diagnosticHistoryLimit {
		t.Fatalf("diagnostic count: got %d, want %d", len(history.Events), diagnosticHistoryLimit)
	}
	if history.MaximumEntries != diagnosticHistoryLimit || history.RetentionPolicy != "count-only-fifo" {
		t.Fatalf("unexpected retention metadata: %+v", history)
	}
	encoded, err := json.Marshal(history)
	if err != nil {
		t.Fatal(err)
	}
	for _, forbidden := range []string{"private.example", "never-store-this"} {
		if strings.Contains(string(encoded), forbidden) {
			t.Fatalf("diagnostic history retained private value %q", forbidden)
		}
	}
	path := filepath.Join(data, "diagnostic-history.jsonl")
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if runtime.GOOS != "windows" && info.Mode().Perm()&0o077 != 0 {
		t.Fatalf("diagnostic permissions are too broad: %v", info.Mode().Perm())
	}
}

func TestDiagnosticHistoryRetainsOldValidEventsAndPrunesMalformedEventsAtStartup(t *testing.T) {
	data := t.TempDir()
	now := time.Date(2031, 4, 18, 16, 30, 0, 0, time.UTC)
	path := filepath.Join(data, "diagnostic-history.jsonl")
	old := DiagnosticEvent{
		SchemaVersion: diagnosticSchemaVersion,
		RecordedAtUTC: now.Add(-400 * 24 * time.Hour).Format(time.RFC3339),
		Area:          "configuration",
		Outcome:       "passed",
		Code:          "config-saved",
		Summary:       diagnosticSummaries["config-saved"],
	}
	raw, _ := json.Marshal(old)
	raw = append(raw, '\n')
	raw = append(raw, []byte(`{"schemaVersion":1,"summary":"raw private error from https://192.168.1.5"}`+"\n")...)
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	store := newDiagnosticStore(data, func() time.Time { return now })
	store.Record("smtp-preflight", "failed", "smtp-result-failed")
	history := store.History()
	if len(history.Events) != 2 || history.Events[0].Code != "smtp-result-failed" || history.Events[1].Code != "config-saved" {
		t.Fatalf("unexpected diagnostic history: %+v", history.Events)
	}
	encoded, _ := json.Marshal(history)
	if strings.Contains(string(encoded), "192.168.1.5") {
		t.Fatal("malformed private diagnostic was returned")
	}
}
