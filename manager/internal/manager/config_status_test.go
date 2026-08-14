package manager

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestConfigurationStatusPersistsForCurrentRevision(t *testing.T) {
	now := time.Date(2031, 4, 18, 16, 30, 0, 0, time.UTC)
	dataDir := t.TempDir()
	store := newConfigurationStatusStore(dataDir, func() time.Time { return now })
	revision := strings.Repeat("a", 64)
	if err := store.Reset(revision); err != nil {
		t.Fatal(err)
	}
	if err := store.Update(revision, "choices", "passed", "3 libraries and 77 users loaded and retained locally."); err != nil {
		t.Fatal(err)
	}
	if err := store.Update(revision, "lan", "passed", "Tautulli and direct Plex verification passed."); err != nil {
		t.Fatal(err)
	}
	if err := store.Update(revision, "smtp", "passed", "SMTP connectivity and STARTTLS validation passed."); err != nil {
		t.Fatal(err)
	}
	if err := store.Update(revision, "previews", "skipped", "Metadata readiness was not confirmed."); err != nil {
		t.Fatal(err)
	}
	integration := IntegrationCheckResult{
		Mode:            "real-lan",
		NetworkBoundary: "private-and-loopback-only",
		Overall:         "passed",
		StartedAtUTC:    now.Add(-time.Second).Format(time.RFC3339),
		CompletedAtUTC:  now.Format(time.RFC3339),
		ConfigRevision:  revision,
		Steps: []IntegrationCheckStep{
			{Service: "tautulli", State: "passed", Summary: "Authenticated Tautulli API compatibility passed."},
			{Service: "plex", State: "passed", Summary: "Authenticated direct Plex compatibility passed."},
		},
	}
	if err := store.StoreIntegrationCheck(revision, integration); err != nil {
		t.Fatal(err)
	}
	smtp := SMTPNetworkCheckResult{Mode: "smtp-network", Overall: "passed", State: "passed", Security: "starttls-validated", CompletedAtUTC: now.Format(time.RFC3339), ConfigRevision: revision, Summary: "SMTP connectivity and certificate-validated STARTTLS passed."}
	if err := store.StoreSMTPCheck(revision, smtp); err != nil {
		t.Fatal(err)
	}

	restarted := newConfigurationStatusStore(dataDir, func() time.Time { return now.Add(time.Hour) })
	loaded := restarted.Load(revision)
	if !loaded.Available || loaded.Running || loaded.Steps["choices"].State != "passed" || loaded.Steps["previews"].State != "skipped" || loaded.LastVerification == nil || loaded.LastSMTPCheck == nil {
		t.Fatalf("unexpected persisted configuration status: %+v", loaded)
	}
	if loaded.LastVerification.Steps[0].State != "passed" || loaded.LastVerification.Steps[1].State != "passed" || loaded.LastSMTPCheck.State != "passed" {
		t.Fatalf("unexpected persisted verification evidence: %+v", loaded)
	}
	if stale := restarted.Load(strings.Repeat("b", 64)); stale.Steps["choices"].State != "not-run" {
		t.Fatalf("stale status was reused for a new configuration: %+v", stale)
	}
	raw, err := os.ReadFile(filepath.Join(dataDir, "configuration-status.json"))
	if err != nil {
		t.Fatal(err)
	}
	for _, forbidden := range []string{"apikey", "password", "token", "email"} {
		if strings.Contains(strings.ToLower(string(raw)), forbidden) {
			t.Fatalf("configuration status retained forbidden value %q: %s", forbidden, raw)
		}
	}
	newRevision := strings.Repeat("c", 64)
	if err := restarted.Reset(newRevision); err != nil {
		t.Fatal(err)
	}
	reset := restarted.Load(newRevision)
	if reset.LastVerification != nil || reset.LastSMTPCheck != nil {
		t.Fatalf("verification evidence survived a configuration revision reset: %+v", reset)
	}
}

func TestConfigurationStatusRejectsInvalidFile(t *testing.T) {
	dataDir := t.TempDir()
	store := newConfigurationStatusStore(dataDir, time.Now)
	revision := strings.Repeat("a", 64)
	if err := os.WriteFile(filepath.Join(dataDir, "configuration-status.json"), []byte(`{"schemaVersion":1,"available":true,"configRevision":"private"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	loaded := store.Load(revision)
	if loaded.Steps["choices"].State != "not-run" || loaded.ConfigRevision != revision {
		t.Fatalf("invalid stored status was not rejected: %+v", loaded)
	}
}

func TestConfigurationStatusRejectsLateUpdateFromStaleRevision(t *testing.T) {
	dataDir := t.TempDir()
	store := newConfigurationStatusStore(dataDir, time.Now)
	currentRevision := strings.Repeat("a", 64)
	staleRevision := strings.Repeat("b", 64)
	if err := store.Reset(currentRevision); err != nil {
		t.Fatal(err)
	}
	if err := store.Update(staleRevision, "lan", "failed", "A late result from an older configuration."); !errors.Is(err, errConfigurationStatusRevision) {
		t.Fatalf("stale update returned %v, want %v", err, errConfigurationStatusRevision)
	}
	loaded := store.Load(currentRevision)
	if loaded.Steps["lan"].State != "waiting" {
		t.Fatalf("stale update replaced the current revision: %+v", loaded)
	}
}
