package manager

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const (
	deletedItemCacheStatusSchemaVersion = 1
	maximumDeletedItemManifestBytes     = 32 << 20
	maximumDeletedItemManifestEntries   = 10000
)

var (
	deletedItemStableGUIDPattern = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9+.-]*://\S+$`)
	deletedItemArtworkPattern    = regexp.MustCompile(`^[0-9a-f]{64}\.jpg$`)
)

// DeletedItemCacheStatus is deliberately aggregate-only. It must never grow
// fields containing cache paths, item identifiers, GUIDs, titles, hashes, or
// any configuration secret.
type DeletedItemCacheStatus struct {
	SchemaVersion            int    `json:"schemaVersion"`
	Enabled                  bool   `json:"enabled"`
	State                    string `json:"state"`
	Summary                  string `json:"summary"`
	ManifestState            string `json:"manifestState"`
	BackupState              string `json:"backupState"`
	Writability              string `json:"writability"`
	IntegrityState           string `json:"integrityState"`
	Verification             string `json:"verification"`
	EntryCount               int    `json:"entryCount"`
	ArtworkCount             int    `json:"artworkCount"`
	ArtworkBytes             int64  `json:"artworkBytes"`
	MissingArtworkCount      int    `json:"missingArtworkCount"`
	OrphanArtworkCount       int    `json:"orphanArtworkCount"`
	ArtworkSizeMismatchCount int    `json:"artworkSizeMismatchCount"`
	HashMismatchCount        int    `json:"hashMismatchCount"`
	ExpiredEntryCount        int    `json:"expiredEntryCount"`
	RetentionDays            int    `json:"retentionDays"`
	MaxItems                 int    `json:"maxItems"`
	MaxBytesMB               int    `json:"maxBytesMb"`
	CheckedAtUTC             string `json:"checkedAtUtc"`
}

type deletedItemCacheManifest struct {
	SchemaVersion int                     `json:"SchemaVersion"`
	Entries       []deletedItemCacheEntry `json:"Entries"`
}

type deletedItemCacheEntry struct {
	ID          string                 `json:"Id"`
	MediaType   string                 `json:"MediaType"`
	GUID        string                 `json:"Guid"`
	CreatedUTC  string                 `json:"CreatedUtc"`
	LastSeenUTC string                 `json:"LastSeenUtc"`
	Poster      deletedItemCachePoster `json:"Poster"`
}

type deletedItemCachePoster struct {
	FileName string `json:"FileName"`
	SHA256   string `json:"Sha256"`
	Bytes    int64  `json:"Bytes"`
}

func newDeletedItemCacheStatus(now func() time.Time, full bool) DeletedItemCacheStatus {
	if now == nil {
		now = time.Now
	}
	verification := "read-only"
	if full {
		verification = "full"
	}
	return DeletedItemCacheStatus{
		SchemaVersion:  deletedItemCacheStatusSchemaVersion,
		Enabled:        true,
		State:          "warning",
		Summary:        "Deleted-item cache configuration could not be verified.",
		ManifestState:  "unavailable",
		BackupState:    "unavailable",
		Writability:    "not-checked",
		IntegrityState: "not-checked",
		Verification:   verification,
		RetentionDays:  365,
		MaxItems:       1000,
		MaxBytesMB:     256,
		CheckedAtUTC:   now().UTC().Format(time.RFC3339),
	}
}

func collectDeletedItemCacheStatus(runtimeRoot string, verifyArtworkHashes, probeWritable bool, now func() time.Time) DeletedItemCacheStatus {
	status := newDeletedItemCacheStatus(now, verifyArtworkHashes || probeWritable)
	values, _, exists, configState := readConfigDocument(runtimeRoot)
	if !exists || configState != "ready" {
		status.Enabled = false
		status.State = "failed"
		status.ManifestState = "unavailable"
		status.BackupState = "unavailable"
		status.Writability = "not-applicable"
		status.Summary = "The saved configuration is unavailable, so deleted-item cache settings could not be checked."
		return status
	}
	status.Enabled = deletedItemConfigBool(values, "DeletedItemCacheEnabled", true)
	status.RetentionDays = deletedItemConfigInt(values, "DeletedItemCacheRetentionDays", 365, 1, 3650)
	status.MaxItems = deletedItemConfigInt(values, "DeletedItemCacheMaxItems", 1000, 1, 10000)
	status.MaxBytesMB = deletedItemConfigInt(values, "DeletedItemCacheMaxBytesMB", 256, 16, 2048)
	if !status.Enabled {
		status.State = "skipped"
		status.ManifestState = "disabled"
		status.BackupState = "not-applicable"
		status.Writability = "not-applicable"
		status.IntegrityState = "skipped"
		status.Summary = "Deleted-item cache is disabled in the saved configuration."
		return status
	}

	cacheRoot := filepath.Join(runtimeRoot, "cache", "deleted-items")
	artworkRoot := filepath.Join(cacheRoot, "artwork")
	if probeWritable {
		status.Writability = probeDeletedItemCacheWritable(cacheRoot, artworkRoot)
	}

	primary, primaryState := readDeletedItemCacheManifest(filepath.Join(cacheRoot, "index.json"))
	backup, backupState := readDeletedItemCacheManifest(filepath.Join(cacheRoot, "index.backup.json"))
	status.BackupState = backupState
	manifest := primary
	switch {
	case primaryState == "valid":
		status.ManifestState = "primary-valid"
	case primaryState == "missing":
		status.ManifestState = "unseeded"
		if backupState == "valid" {
			status.BackupState = "stale-ignored"
		}
		if status.Writability == "failed" {
			status.State = "failed"
			status.Summary = "Deleted-item cache is enabled, but its local storage is not writable."
		} else {
			status.State = "warning"
			status.Summary = "Deleted-item cache is enabled, but no qualifying live item has been captured yet."
			if backupState == "valid" {
				status.Summary = "Deleted-item cache has no primary manifest; a stale backup is ignored until a live capture creates current state."
			}
		}
		return status
	case primaryState != "valid" && backupState == "valid":
		manifest = backup
		status.ManifestState = "backup-recoverable"
		status.BackupState = "valid"
	default:
		status.State = "failed"
		status.ManifestState = "corrupt"
		status.IntegrityState = "failed"
		status.Summary = "Deleted-item cache manifest health failed; the runtime will attempt bounded recovery on its next render."
		return status
	}

	status.EntryCount = len(manifest.Entries)
	referenced := make(map[string]deletedItemCacheEntry, len(manifest.Entries))
	current := time.Now
	if now != nil {
		current = now
	}
	cutoff := current().UTC().AddDate(0, 0, -status.RetentionDays)
	for _, entry := range manifest.Entries {
		referenced[entry.Poster.FileName] = entry
		entryTime := deletedItemEntryTime(entry)
		if entryTime.IsZero() || entryTime.Before(cutoff) {
			status.ExpiredEntryCount++
		}
	}

	artworkFiles, artworkReadFailed := readDeletedItemArtwork(artworkRoot)
	if artworkReadFailed {
		status.State = "failed"
		status.IntegrityState = "failed"
		status.Summary = "Deleted-item cache artwork could not be read from local storage."
		return status
	}
	for name, info := range artworkFiles {
		status.ArtworkCount++
		status.ArtworkBytes += info.Size()
		entry, used := referenced[name]
		if !used {
			status.OrphanArtworkCount++
			continue
		}
		if entry.Poster.Bytes != info.Size() {
			status.ArtworkSizeMismatchCount++
		}
		if verifyArtworkHashes {
			actual, err := deletedItemFileSHA256(filepath.Join(artworkRoot, name))
			if err != nil || !strings.EqualFold(actual, entry.Poster.SHA256) {
				status.HashMismatchCount++
			}
		}
	}
	for name := range referenced {
		if _, exists := artworkFiles[name]; !exists {
			status.MissingArtworkCount++
		}
	}
	if status.EntryCount > 0 && status.Writability == "not-checked" {
		status.Writability = "previously-evidenced"
	}
	if verifyArtworkHashes {
		status.IntegrityState = "verified"
	} else {
		status.IntegrityState = "structural"
	}
	problems := status.MissingArtworkCount + status.ArtworkSizeMismatchCount + status.HashMismatchCount
	switch {
	case status.Writability == "failed":
		status.State = "failed"
		status.Summary = "Deleted-item cache is enabled, but its local storage is not writable."
	case problems > 0:
		status.State = "failed"
		status.IntegrityState = "failed"
		status.Summary = "Deleted-item cache entries or artwork failed the local integrity check."
	case status.ManifestState == "backup-recoverable":
		status.State = "warning"
		status.IntegrityState = "warning"
		status.Summary = "The primary cache manifest is unhealthy, but its bounded backup is recoverable."
	case status.BackupState == "invalid":
		status.State = "warning"
		status.IntegrityState = "warning"
		status.Summary = "Deleted-item cache is usable, but its current backup manifest is unhealthy."
	case status.EntryCount == 0:
		status.State = "warning"
		status.Summary = "Deleted-item cache is initialized, but no qualifying live item has been captured yet."
	case status.OrphanArtworkCount > 0 || status.ExpiredEntryCount > 0 || status.EntryCount > status.MaxItems || status.ArtworkBytes > int64(status.MaxBytesMB)<<20:
		status.State = "warning"
		status.Summary = "Deleted-item cache is usable, with cleanup work pending for the next renderer initialization."
	default:
		status.State = "passed"
		status.Summary = fmt.Sprintf("Deleted-item cache has %d restorable %s and %d artwork %s.", status.EntryCount, pluralWord(status.EntryCount, "entry", "entries"), status.ArtworkCount, pluralWord(status.ArtworkCount, "file", "files"))
	}
	return status
}

func (status DeletedItemCacheStatus) configurationStep() ConfigurationStatusStep {
	return ConfigurationStatusStep{State: status.State, Summary: status.Summary, UpdatedAtUTC: status.CheckedAtUTC}
}

func readDeletedItemCacheManifest(path string) (deletedItemCacheManifest, string) {
	info, err := os.Stat(path)
	if errors.Is(err, os.ErrNotExist) {
		return deletedItemCacheManifest{}, "missing"
	}
	if err != nil || !info.Mode().IsRegular() || info.Size() > maximumDeletedItemManifestBytes {
		return deletedItemCacheManifest{}, "invalid"
	}
	file, err := os.Open(path)
	if err != nil {
		return deletedItemCacheManifest{}, "invalid"
	}
	defer file.Close()
	decoder := json.NewDecoder(io.LimitReader(file, maximumDeletedItemManifestBytes+1))
	var manifest deletedItemCacheManifest
	if decoder.Decode(&manifest) != nil || decoder.Decode(&struct{}{}) != io.EOF || manifest.SchemaVersion != 1 || len(manifest.Entries) > maximumDeletedItemManifestEntries {
		return deletedItemCacheManifest{}, "invalid"
	}
	for _, entry := range manifest.Entries {
		if !validDeletedItemCacheEntry(entry) {
			return deletedItemCacheManifest{}, "invalid"
		}
	}
	return manifest, "valid"
}

func validDeletedItemCacheEntry(entry deletedItemCacheEntry) bool {
	guid := strings.ToLower(strings.TrimSpace(entry.GUID))
	mediaType := strings.ToLower(strings.TrimSpace(entry.MediaType))
	if len(guid) == 0 || len(guid) > 512 || !deletedItemStableGUIDPattern.MatchString(guid) || (mediaType != "movie" && mediaType != "show") {
		return false
	}
	digest := sha256.Sum256([]byte(mediaType + "|" + guid))
	expectedID := hex.EncodeToString(digest[:])
	return entry.ID == expectedID && entry.Poster.FileName == expectedID+".jpg" && validLowerHexDigest(entry.Poster.SHA256) && entry.Poster.Bytes >= 0
}

func validLowerHexDigest(value string) bool {
	if len(value) != 64 || strings.ToLower(value) != value {
		return false
	}
	decoded, err := hex.DecodeString(value)
	return err == nil && len(decoded) == sha256.Size
}

func readDeletedItemArtwork(root string) (map[string]os.FileInfo, bool) {
	entries, err := os.ReadDir(root)
	if errors.Is(err, os.ErrNotExist) {
		return map[string]os.FileInfo{}, false
	}
	if err != nil {
		return nil, true
	}
	files := make(map[string]os.FileInfo)
	for _, entry := range entries {
		if entry.Type()&os.ModeSymlink != 0 || entry.IsDir() || !deletedItemArtworkPattern.MatchString(entry.Name()) {
			continue
		}
		info, err := entry.Info()
		if err != nil || !info.Mode().IsRegular() {
			return nil, true
		}
		files[entry.Name()] = info
	}
	return files, false
}

func probeDeletedItemCacheWritable(cacheRoot, artworkRoot string) string {
	if err := os.MkdirAll(artworkRoot, 0o700); err != nil {
		return "failed"
	}
	probe, err := os.CreateTemp(cacheRoot, ".manager-cache-write-probe-*.tmp")
	if err != nil {
		return "failed"
	}
	name := probe.Name()
	defer os.Remove(name)
	failed := probe.Chmod(0o600) != nil
	if !failed {
		_, err = probe.Write([]byte("tautweekly-cache-write-probe\n"))
		failed = err != nil
	}
	if !failed {
		failed = probe.Sync() != nil
	}
	if probe.Close() != nil {
		failed = true
	}
	if os.Remove(name) != nil {
		failed = true
	}
	if failed {
		return "failed"
	}
	return "passed"
}

func deletedItemFileSHA256(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	digest := sha256.New()
	if _, err := io.Copy(digest, file); err != nil {
		return "", err
	}
	return hex.EncodeToString(digest.Sum(nil)), nil
}

func deletedItemEntryTime(entry deletedItemCacheEntry) time.Time {
	for _, value := range []string{entry.LastSeenUTC, entry.CreatedUTC} {
		if parsed, err := time.Parse(time.RFC3339Nano, strings.TrimSpace(value)); err == nil {
			return parsed.UTC()
		}
	}
	return time.Time{}
}

func deletedItemConfigBool(values map[string]any, name string, fallback bool) bool {
	if value, exists := values[name]; exists {
		if parsed, ok := value.(bool); ok {
			return parsed
		}
	}
	return fallback
}

func deletedItemConfigInt(values map[string]any, name string, fallback, minimum, maximum int) int {
	value, exists := values[name]
	if !exists {
		return fallback
	}
	var parsed int64
	var err error
	switch typed := value.(type) {
	case json.Number:
		parsed, err = typed.Int64()
	case float64:
		parsed = int64(typed)
		if float64(parsed) != typed {
			err = errors.New("not an integer")
		}
	case int:
		parsed = int64(typed)
	case int64:
		parsed = typed
	case string:
		parsed, err = strconv.ParseInt(strings.TrimSpace(typed), 10, 64)
	default:
		err = errors.New("unsupported number")
	}
	if err != nil || parsed < int64(minimum) || parsed > int64(maximum) {
		return fallback
	}
	return int(parsed)
}

func pluralWord(value int, singular, plural string) string {
	if value == 1 {
		return singular
	}
	return plural
}
