package manager

import (
	"encoding/json"
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
	cache := DeletedItemCacheStatus{
		SchemaVersion: deletedItemCacheStatusSchemaVersion, Enabled: true, State: "passed",
		Summary: "Caller-provided detail must not be persisted.", ManifestState: "primary-valid", BackupState: "valid",
		Writability: "passed", IntegrityState: "verified", Verification: "full",
		EntryCount: 2, ArtworkCount: 2, ArtworkBytes: 512, RetentionDays: 365, MaxItems: 1000, MaxBytesMB: 512,
		CheckedAtUTC: now.Format(time.RFC3339),
	}
	if err := store.StoreCache(revision, cache); err != nil {
		t.Fatal(err)
	}

	restarted := newConfigurationStatusStore(dataDir, func() time.Time { return now.Add(time.Hour) })
	loaded := restarted.Load(revision)
	if !loaded.Available || loaded.Running || loaded.Steps["choices"].State != "passed" || loaded.Steps["previews"].State != "skipped" || loaded.Steps["cache"].State != "passed" || loaded.LastVerification == nil || loaded.LastSMTPCheck == nil || loaded.Cache == nil {
		t.Fatalf("unexpected persisted configuration status: %+v", loaded)
	}
	if loaded.LastVerification.Steps[0].State != "passed" || loaded.LastVerification.Steps[1].State != "passed" || loaded.LastSMTPCheck.State != "passed" {
		t.Fatalf("unexpected persisted verification evidence: %+v", loaded)
	}
	if stale := restarted.Load(strings.Repeat("b", 64)); stale.Steps["choices"].State != "not-run" {
		t.Fatalf("stale status was reused for a new configuration: %+v", stale)
		if loaded.Cache.Verification != "full" || loaded.Cache.Writability != "passed" || loaded.Cache.IntegrityState != "verified" || loaded.Cache.Summary != "Full deleted-item cache verification passed." {
			t.Fatalf("unexpected persisted full cache evidence: %+v", loaded.Cache)
		}
	}
	raw, err := os.ReadFile(filepath.Join(dataDir, "configuration-status.json"))
	if err != nil {
		t.Fatal(err)
	}
	for _, forbidden := range []string{"apikey", "password", "token", "email", "caller-provided"} {
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

func TestConfigurationStatusMigratesLegacyEvidenceWithoutCacheResult(t *testing.T) {
	now := time.Date(2031, 4, 18, 16, 30, 0, 0, time.UTC)
	dataDir := t.TempDir()
	revision := strings.Repeat("a", 64)
	legacy := newConfigurationStatus(revision, "not-run", now)
	legacy.SchemaVersion = 1
	delete(legacy.Steps, "cache")
	legacy.Cache = nil
	encoded, err := json.Marshal(legacy)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dataDir, "configuration-status.json"), encoded, 0o600); err != nil {
		t.Fatal(err)
	}

	loaded := newConfigurationStatusStore(dataDir, func() time.Time { return now }).Load(revision)
	if loaded.SchemaVersion != configurationStatusSchemaVersion || loaded.Cache != nil {
		t.Fatalf("legacy evidence migration: %+v", loaded)
	}
	cacheStep, exists := loaded.Steps["cache"]
	if !exists || cacheStep.State != "not-run" {
		t.Fatalf("legacy evidence did not gain a cache step: %+v", loaded.Steps)
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
