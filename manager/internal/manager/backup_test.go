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

func TestListAndRestoreConfigBackup(t *testing.T) {
	root := t.TempDir()
	initial := validConfigSaveRequest(t, ReadConfigEditor(root))
	initial.Secrets["ApiKey"] = SecretChange{Action: "replace", Value: "backup-api-secret"}
	initial.Secrets["SmtpPassword"] = SecretChange{Action: "replace", Value: "backup-smtp-secret"}
	created, fields, err := SaveConfig(root, initial, func() time.Time { return time.Date(2031, 4, 18, 16, 0, 0, 0, time.UTC) })
	if err != nil || len(fields) > 0 {
		t.Fatalf("create config: result=%+v fields=%v err=%v", created, fields, err)
	}

	update := validConfigSaveRequest(t, created.Editor)
	update.Values["FooterServerName"] = json.RawMessage(`"Changed server"`)
	updated, fields, err := SaveConfig(root, update, func() time.Time { return time.Date(2031, 4, 18, 16, 30, 0, 0, time.UTC) })
	if err != nil || len(fields) > 0 || updated.Backup == "" {
		t.Fatalf("update config: result=%+v fields=%v err=%v", updated, fields, err)
	}

	listed := ListConfigBackups(root)
	if len(listed.Backups) != 1 || listed.Backups[0].ID != updated.Backup || listed.Backups[0].Revision == "" || listed.MaximumEntries != 10 || listed.RetentionPolicy != "newest-first-fifo" {
		t.Fatalf("unexpected backup list: %+v", listed)
	}
	encodedList, err := json.Marshal(listed)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(encodedList), "backup-api-secret") || strings.Contains(string(encodedList), "backup-smtp-secret") {
		t.Fatal("backup list returned configuration secrets")
	}

	restored, fields, err := RestoreConfigBackup(root, updated.Backup, updated.Editor.Revision, func() time.Time {
		return time.Date(2031, 4, 18, 17, 0, 0, 0, time.UTC)
	})
	if err != nil || len(fields) > 0 {
		t.Fatalf("restore backup: result=%+v fields=%v err=%v", restored, fields, err)
	}
	if !restored.Restored || restored.SafetyBackup == "" || restored.Editor.Revision == updated.Editor.Revision {
		t.Fatalf("unexpected restore result: %+v", restored)
	}
	raw, err := os.ReadFile(filepath.Join(root, "config.json"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), "Changed server") || !strings.Contains(string(raw), "My Plex") {
		t.Fatalf("restore did not replace config with the selected backup: %s", raw)
	}
	if _, err := os.Stat(filepath.Join(root, restored.SafetyBackup)); err != nil {
		t.Fatalf("pre-restore safety backup is unavailable: %v", err)
	}
}

func TestConfigBackupRetentionNormalizesCanonicalAndLegacyOverflow(t *testing.T) {
	root := t.TempDir()
	created := []string{}
	for index := 0; index < configBackupLimit+3; index++ {
		stamp := time.Date(2031, 4, 18, 16, index, 0, 0, time.UTC).Format("20060102-150405")
		name := "config.backup." + stamp + ".json"
		if index%2 == 0 {
			name = "config.backup." + stamp + ".000000000Z.json"
		}
		if err := os.WriteFile(filepath.Join(root, name), []byte(`{"FooterServerName":"Fictional"}`), 0o600); err != nil {
			t.Fatal(err)
		}
		created = append(created, name)
	}
	unsafe := "config.backup.unsafe.json"
	if err := os.WriteFile(filepath.Join(root, unsafe), []byte("leave me"), 0o600); err != nil {
		t.Fatal(err)
	}

	listed := ListConfigBackups(root)
	if len(listed.Backups) != configBackupLimit {
		t.Fatalf("backup count: got %d, want %d", len(listed.Backups), configBackupLimit)
	}
	for _, name := range created[:3] {
		if _, err := os.Stat(filepath.Join(root, name)); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("oldest backup was not removed: %s (%v)", name, err)
		}
	}
	if _, err := os.Stat(filepath.Join(root, unsafe)); err != nil {
		t.Fatalf("unrecognized file was changed: %v", err)
	}
}

func TestRestoreConfigBackupRejectsUnsafeInputs(t *testing.T) {
	root := t.TempDir()
	view := ReadConfigEditor(root)
	if _, _, err := RestoreConfigBackup(root, `..\config.json`, view.Revision, time.Now); !errors.Is(err, ErrBackupNotFound) {
		t.Fatalf("unsafe backup ID: got %v", err)
	}
	invalidName := "config.backup.20310418-163000.000000000Z.json"
	if err := os.WriteFile(filepath.Join(root, invalidName), []byte(`{"ApiKey":`), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, _, err := RestoreConfigBackup(root, invalidName, view.Revision, time.Now); !errors.Is(err, ErrBackupInvalid) {
		t.Fatalf("invalid backup: got %v", err)
	}
}

func TestDeleteConfigBackupRemovesOnlyValidatedBackupFiles(t *testing.T) {
	root := t.TempDir()
	backupID := "config.backup.20310418-163000.000000000Z.json"
	backupPath := filepath.Join(root, backupID)
	if err := os.WriteFile(backupPath, []byte(`{"FooterServerName":"Fictional"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	result, err := DeleteConfigBackup(root, backupID)
	if err != nil || !result.Deleted || result.ID != backupID {
		t.Fatalf("delete backup: result=%+v err=%v", result, err)
	}
	if _, err := os.Stat(backupPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("deleted backup is still present: %v", err)
	}
	for _, unsafe := range []string{"config.json", `..\config.json`, "config.backup.invalid.json"} {
		if _, err := DeleteConfigBackup(root, unsafe); !errors.Is(err, ErrBackupNotFound) {
			t.Fatalf("unsafe delete %q: got %v", unsafe, err)
		}
	}
	directoryID := "config.backup.20310418-163001.000000000Z.json"
	if err := os.Mkdir(filepath.Join(root, directoryID), 0o700); err != nil {
		t.Fatal(err)
	}
	if _, err := DeleteConfigBackup(root, directoryID); !errors.Is(err, ErrBackupNotFound) {
		t.Fatalf("directory-shaped backup delete: got %v", err)
	}
}

func TestRestoreConfigBackupCanRecoverInvalidCurrentJSON(t *testing.T) {
	root := integrationConfigRoot(t, "http://127.0.0.1:8181", "fictional-api-key", "", "")
	valid, err := os.ReadFile(filepath.Join(root, "config.json"))
	if err != nil {
		t.Fatal(err)
	}
	backupID := "config.backup.20310418-163000.000000000Z.json"
	if err := os.WriteFile(filepath.Join(root, backupID), valid, 0o600); err != nil {
		t.Fatal(err)
	}
	invalid := []byte(`{"ApiKey":`)
	if err := os.WriteFile(filepath.Join(root, "config.json"), invalid, 0o600); err != nil {
		t.Fatal(err)
	}
	view := ReadConfigEditor(root)
	if view.State != "invalid-json" {
		t.Fatalf("expected invalid current config, got %+v", view)
	}
	restored, fields, err := RestoreConfigBackup(root, backupID, view.Revision, func() time.Time {
		return time.Date(2031, 4, 18, 17, 0, 0, 0, time.UTC)
	})
	if err != nil || len(fields) > 0 || !restored.Restored || restored.Editor.State != "ready" {
		t.Fatalf("recover invalid config: result=%+v fields=%v err=%v", restored, fields, err)
	}
	safety, err := os.ReadFile(filepath.Join(root, restored.SafetyBackup))
	if err != nil {
		t.Fatal(err)
	}
	if string(safety) != string(invalid) {
		t.Fatal("pre-restore safety backup did not preserve the invalid current file")
	}
}
