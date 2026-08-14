package manager

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"time"
)

const maximumConfigBytes = 1 << 20

var backupNamePattern = regexp.MustCompile(`^config\.backup\.\d{8}-\d{6}\.\d{9}Z\.json$`)

var (
	ErrBackupInvalid  = errors.New("configuration backup is invalid")
	ErrBackupNotFound = errors.New("configuration backup was not found")
)

type ConfigBackup struct {
	ID           string `json:"id"`
	CreatedAtUTC string `json:"createdAtUtc"`
	SizeBytes    int64  `json:"sizeBytes"`
	Revision     string `json:"revision"`
}

type ConfigBackupList struct {
	Backups []ConfigBackup `json:"backups"`
}

type ConfigRestoreRequest struct {
	ExpectedRevision string `json:"expectedRevision"`
}

type ConfigRestoreResult struct {
	Restored     bool             `json:"restored"`
	SourceID     string           `json:"sourceId"`
	SafetyBackup string           `json:"safetyBackup,omitempty"`
	Editor       ConfigEditorView `json:"editor"`
}

func ListConfigBackups(root string) ConfigBackupList {
	result := ConfigBackupList{Backups: []ConfigBackup{}}
	entries, err := os.ReadDir(root)
	if err != nil {
		return result
	}
	for _, entry := range entries {
		if entry.Type()&os.ModeSymlink != 0 || !backupNamePattern.MatchString(entry.Name()) {
			continue
		}
		info, err := entry.Info()
		if err != nil || !info.Mode().IsRegular() || info.Size() > maximumConfigBytes {
			continue
		}
		raw, err := os.ReadFile(filepath.Join(root, entry.Name()))
		if err != nil {
			continue
		}
		result.Backups = append(result.Backups, ConfigBackup{
			ID:           entry.Name(),
			CreatedAtUTC: info.ModTime().UTC().Format(time.RFC3339),
			SizeBytes:    info.Size(),
			Revision:     configRevision(raw, true),
		})
	}
	sort.Slice(result.Backups, func(i, j int) bool {
		return result.Backups[i].ID > result.Backups[j].ID
	})
	return result
}

func RestoreConfigBackup(root, id, expectedRevision string, now func() time.Time) (ConfigRestoreResult, map[string]string, error) {
	current, currentRaw, currentExists, currentState := readConfigDocument(root)
	_ = current
	if currentState != "ready" && currentState != "unconfigured" && currentState != "invalid-json" {
		return ConfigRestoreResult{}, nil, ErrConfigInvalid
	}
	if expectedRevision == "" || expectedRevision != configRevision(currentRaw, currentExists) {
		return ConfigRestoreResult{}, nil, ErrConfigConflict
	}
	if !backupNamePattern.MatchString(id) {
		return ConfigRestoreResult{}, nil, ErrBackupNotFound
	}
	path := filepath.Join(root, id)
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) || err == nil && (!info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0) {
		return ConfigRestoreResult{}, nil, ErrBackupNotFound
	}
	if err != nil {
		return ConfigRestoreResult{}, nil, fmt.Errorf("inspect configuration backup: %w", err)
	}
	if info.Size() > maximumConfigBytes {
		return ConfigRestoreResult{}, nil, ErrBackupInvalid
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return ConfigRestoreResult{}, nil, fmt.Errorf("read configuration backup: %w", err)
	}
	values, state := decodeConfigDocument(raw)
	if state != "ready" {
		return ConfigRestoreResult{}, nil, ErrBackupInvalid
	}
	issues := existingConfigIssues(values)
	if len(issues) > 0 {
		return ConfigRestoreResult{}, issues, ErrBackupInvalid
	}
	if now == nil {
		now = time.Now
	}
	safetyBackup, err := writeConfigAtomically(root, currentRaw, currentExists, raw, now())
	if err != nil {
		return ConfigRestoreResult{}, nil, err
	}
	return ConfigRestoreResult{
		Restored:     true,
		SourceID:     id,
		SafetyBackup: safetyBackup,
		Editor:       ReadConfigEditor(root),
	}, nil, nil
}
