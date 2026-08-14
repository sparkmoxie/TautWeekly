package manager

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	operationSchemaVersion = 1
	operationHistoryLimit  = 500
	operationHistoryAge    = 90 * 24 * time.Hour
	maximumOperationLine   = 64 << 10
)

var (
	ErrOperationBusy           = errors.New("another manager operation is active")
	ErrOperationConfirmation   = errors.New("operation confirmation is required")
	ErrOperationInvalid        = errors.New("operation request is invalid")
	ErrOperationNotFound       = errors.New("operation was not found")
	ErrOperationNotReady       = errors.New("configuration is not ready for the operation")
	ErrOperationTerminal       = errors.New("operation is already complete")
	ErrOperationNotCancellable = errors.New("operation cannot be cancelled safely")
	ErrOperationUnsupported    = errors.New("operation is unsupported on this platform")
)

type CreateOperationRequest struct {
	Type             string `json:"type"`
	ExpectedRevision string `json:"expectedRevision"`
	UserID           string `json:"userId"`
	ConfirmNoSend    bool   `json:"confirmNoSend"`
	ConfirmTestSend  bool   `json:"confirmTestSend"`
}

type OperationRecord struct {
	SchemaVersion       int      `json:"schemaVersion"`
	ID                  string   `json:"id"`
	Type                string   `json:"type"`
	Trigger             string   `json:"trigger"`
	PackageVersion      string   `json:"packageVersion,omitempty"`
	State               string   `json:"state"`
	Outcome             string   `json:"outcome,omitempty"`
	StartedAtUTC        string   `json:"startedAtUtc"`
	FinishedAtUTC       string   `json:"finishedAtUtc,omitempty"`
	DurationMS          int64    `json:"durationMs,omitempty"`
	DeliveryScope       string   `json:"deliveryScope,omitempty"`
	SMTPAcceptedCount   int      `json:"smtpAcceptedCount,omitempty"`
	SkippedCount        int      `json:"skippedCount,omitempty"`
	FailedCount         int      `json:"failedCount,omitempty"`
	ExitCode            *int     `json:"exitCode,omitempty"`
	GeneratedPreviewIDs []string `json:"generatedPreviewIds"`
	ErrorCategory       string   `json:"errorCategory,omitempty"`
	SupportCode         string   `json:"supportCode,omitempty"`
	Cancellable         bool     `json:"cancellable"`
}

type OperationHistory struct {
	Operations []OperationRecord `json:"operations"`
}

type operationRunner interface {
	RunPreviewAll(ctx context.Context, root, configPath, resultPath, userID string) (int, error)
	RunSendTestAll(ctx context.Context, root, configPath, resultPath, userID string) (int, error)
}

type operationStore struct {
	currentPath string
	historyPath string
	now         func() time.Time
}

type operationCoordinator struct {
	mu         sync.RWMutex
	root       string
	dataDir    string
	now        func() time.Time
	runner     operationRunner
	store      operationStore
	current    *OperationRecord
	cancel     context.CancelFunc
	onComplete func(OperationRecord, string)
}

func newOperationCoordinator(options Options) (*operationCoordinator, error) {
	runner := options.operationRunner
	if runner == nil {
		runner = platformPreviewOperationRunner{}
	}
	coordinator := &operationCoordinator{
		root:       options.TautWeeklyRoot,
		dataDir:    options.DataDir,
		now:        options.Now,
		runner:     runner,
		onComplete: options.operationCompleted,
		store: operationStore{
			currentPath: filepath.Join(options.DataDir, "operation-current.json"),
			historyPath: filepath.Join(options.DataDir, "operation-history.jsonl"),
			now:         options.Now,
		},
	}
	if coordinator.now == nil {
		coordinator.now = time.Now
		coordinator.store.now = time.Now
	}
	coordinator.current = coordinator.store.readCurrent()
	if coordinator.current != nil && operationActive(coordinator.current.State) {
		revision := operationSnapshotRevision(coordinator.snapshotPath(coordinator.current.ID))
		coordinator.current.State = "failed"
		coordinator.current.Outcome = "failed"
		coordinator.current.Cancellable = false
		coordinator.current.FinishedAtUTC = coordinator.now().UTC().Format(time.RFC3339)
		coordinator.current.ErrorCategory = "manager-restarted"
		coordinator.current.SupportCode = operationSupportCode(coordinator.current.ID)
		if err := coordinator.store.saveCurrent(*coordinator.current); err != nil {
			return nil, err
		}
		if err := coordinator.store.appendHistory(*coordinator.current); err != nil {
			return nil, err
		}
		if coordinator.onComplete != nil {
			coordinator.onComplete(*coordinator.current, revision)
		}
	}
	coordinator.removeStaleSnapshots()
	return coordinator, nil
}

func (c *operationCoordinator) Start(request CreateOperationRequest) (OperationRecord, error) {
	if request.Type != "preview-all" && request.Type != "send-test-all" {
		return OperationRecord{}, ErrOperationInvalid
	}
	if request.Type == "preview-all" {
		if request.ConfirmTestSend {
			return OperationRecord{}, ErrOperationInvalid
		}
		if !request.ConfirmNoSend {
			return OperationRecord{}, ErrOperationConfirmation
		}
	}
	if request.Type == "send-test-all" {
		if request.ConfirmNoSend {
			return OperationRecord{}, ErrOperationInvalid
		}
		if !request.ConfirmTestSend {
			return OperationRecord{}, ErrOperationConfirmation
		}
	}
	userID := strings.TrimSpace(request.UserID)
	if !validTautulliUserID(userID) {
		return OperationRecord{}, ErrOperationInvalid
	}
	values, raw, exists, state := readConfigDocument(c.root)
	if state != "ready" || !exists || len(existingConfigIssues(values)) > 0 {
		return OperationRecord{}, ErrOperationNotReady
	}
	revision := configRevision(raw, true)
	if request.ExpectedRevision == "" || request.ExpectedRevision != revision {
		return OperationRecord{}, ErrConfigConflict
	}

	c.mu.Lock()
	defer c.mu.Unlock()
	if c.current != nil && operationActive(c.current.State) {
		return OperationRecord{}, ErrOperationBusy
	}
	id, err := randomToken(12)
	if err != nil {
		return OperationRecord{}, err
	}
	snapshotPath := c.snapshotPath(id)
	if err := writePrivateFile(snapshotPath, raw, os.O_CREATE|os.O_EXCL); err != nil {
		return OperationRecord{}, fmt.Errorf("create operation configuration snapshot: %w", err)
	}
	now := c.now().UTC()
	previewBaseline := map[string]previewFingerprint{}
	if request.Type == "preview-all" {
		previewBaseline = previewFingerprints(c.root)
	}
	resultPath := c.resultPath(id)
	record := OperationRecord{
		SchemaVersion:       operationSchemaVersion,
		ID:                  id,
		Type:                request.Type,
		Trigger:             "gui",
		PackageVersion:      readPackageVersion(c.root),
		State:               "queued",
		StartedAtUTC:        now.Format(time.RFC3339),
		GeneratedPreviewIDs: []string{},
		Cancellable:         request.Type == "preview-all",
	}
	if err := c.store.saveCurrent(record); err != nil {
		_ = os.Remove(snapshotPath)
		return OperationRecord{}, err
	}
	operationContext, cancel := context.WithCancel(context.Background())
	c.cancel = cancel
	c.current = &record
	go c.run(operationContext, record, revision, snapshotPath, resultPath, userID, previewBaseline)
	return record, nil
}

func (c *operationCoordinator) run(ctx context.Context, record OperationRecord, revision, snapshotPath, resultPath, userID string, previewBaseline map[string]previewFingerprint) {
	defer os.Remove(snapshotPath)
	defer os.Remove(resultPath)
	c.setRunning(record.ID)
	mode := "PreviewAll"
	var exitCode int
	var runErr error
	if record.Type == "send-test-all" {
		mode = "SendTestAll"
		exitCode, runErr = c.runner.RunSendTestAll(ctx, c.root, snapshotPath, resultPath, userID)
	} else {
		exitCode, runErr = c.runner.RunPreviewAll(ctx, c.root, snapshotPath, resultPath, userID)
	}
	structuredResult, resultErr := readRendererResult(resultPath, mode)
	finished := c.now().UTC()
	record.FinishedAtUTC = finished.Format(time.RFC3339)
	record.Cancellable = false
	record.ExitCode = &exitCode
	if record.Type == "preview-all" {
		record.GeneratedPreviewIDs = changedPreviewIDs(c.root, previewBaseline)
	}
	if resultErr == nil {
		record.DurationMS = structuredResult.DurationMS
		record.DeliveryScope = structuredResult.DeliveryScope
		record.SMTPAcceptedCount = structuredResult.SMTPAcceptedCount
		record.SkippedCount = structuredResult.SkippedCount
		record.FailedCount = structuredResult.FailedCount
	}
	switch {
	case errors.Is(ctx.Err(), context.Canceled), errors.Is(runErr, context.Canceled):
		record.State = "cancelled"
		record.Outcome = "cancelled"
		record.ErrorCategory = "cancelled"
	case errors.Is(runErr, ErrOperationUnsupported):
		record.State = "failed"
		record.Outcome = "failed"
		record.ErrorCategory = "platform-unsupported"
		record.SupportCode = operationSupportCode(record.ID)
	case runErr != nil:
		record.State = "failed"
		record.Outcome = "failed"
		record.ErrorCategory = "renderer-failed"
		record.SupportCode = operationSupportCode(record.ID)
	case resultErr != nil || structuredResult.Outcome != "succeeded":
		record.State = "failed"
		record.Outcome = "failed"
		record.ErrorCategory = "renderer-result-invalid"
		record.SupportCode = operationSupportCode(record.ID)
	case record.Type == "preview-all" && len(record.GeneratedPreviewIDs) != len(structuredResult.GeneratedPreviewFiles):
		record.State = "failed"
		record.Outcome = "failed"
		record.ErrorCategory = "renderer-result-mismatch"
		record.SupportCode = operationSupportCode(record.ID)
	default:
		record.State = "succeeded"
		record.Outcome = "success"
	}
	// Finish transient-file cleanup and downstream status updates before the
	// terminal operation state becomes observable. This keeps callers from
	// racing final side effects, especially on Windows where open-directory
	// cleanup is strict.
	_ = os.Remove(snapshotPath)
	_ = os.Remove(resultPath)
	if c.onComplete != nil {
		c.onComplete(record, revision)
	}
	c.mu.Lock()
	c.cancel = nil
	c.current = &record
	_ = c.store.saveCurrent(record)
	_ = c.store.appendHistory(record)
	c.mu.Unlock()
}

func operationSnapshotRevision(snapshotPath string) string {
	raw, err := os.ReadFile(snapshotPath)
	if err != nil {
		return ""
	}
	if _, state := decodeConfigDocument(raw); state != "ready" {
		return ""
	}
	return configRevision(raw, true)
}

func (c *operationCoordinator) setRunning(id string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.current == nil || c.current.ID != id || c.current.State != "queued" {
		return
	}
	c.current.State = "running"
	_ = c.store.saveCurrent(*c.current)
}

func (c *operationCoordinator) Current() *OperationRecord {
	c.mu.RLock()
	defer c.mu.RUnlock()
	if c.current == nil {
		return nil
	}
	copy := *c.current
	copy.GeneratedPreviewIDs = append([]string{}, c.current.GeneratedPreviewIDs...)
	return &copy
}

func (c *operationCoordinator) Get(id string) (OperationRecord, error) {
	if current := c.Current(); current != nil && current.ID == id {
		return *current, nil
	}
	for _, record := range c.store.readHistory() {
		if record.ID == id {
			return record, nil
		}
	}
	return OperationRecord{}, ErrOperationNotFound
}

func (c *operationCoordinator) History() OperationHistory {
	records := c.store.readHistory()
	if len(records) > 50 {
		records = records[:50]
	}
	return OperationHistory{Operations: records}
}

func (c *operationCoordinator) Cancel(id string) (OperationRecord, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.current == nil || c.current.ID != id {
		return OperationRecord{}, ErrOperationNotFound
	}
	if !operationActive(c.current.State) {
		return OperationRecord{}, ErrOperationTerminal
	}
	if !c.current.Cancellable {
		return OperationRecord{}, ErrOperationNotCancellable
	}
	c.current.State = "cancelling"
	c.current.Cancellable = false
	_ = c.store.saveCurrent(*c.current)
	if c.cancel != nil {
		c.cancel()
	}
	return *c.current, nil
}

func (c *operationCoordinator) snapshotPath(id string) string {
	return filepath.Join(c.dataDir, "operation-"+id+".config.json")
}

func (c *operationCoordinator) resultPath(id string) string {
	return filepath.Join(c.dataDir, "operation-"+id+".result.json")
}

func (c *operationCoordinator) removeStaleSnapshots() {
	entries, err := os.ReadDir(c.dataDir)
	if err != nil {
		return
	}
	for _, entry := range entries {
		name := entry.Name()
		if entry.Type().IsRegular() && strings.HasPrefix(name, "operation-") && (strings.HasSuffix(name, ".config.json") || strings.HasSuffix(name, ".result.json")) {
			_ = os.Remove(filepath.Join(c.dataDir, name))
		}
	}
}

func (s operationStore) readCurrent() *OperationRecord {
	raw, err := os.ReadFile(s.currentPath)
	if err != nil || len(raw) > maximumOperationLine {
		return nil
	}
	var record OperationRecord
	if json.Unmarshal(raw, &record) != nil || !validOperationRecord(record) {
		return nil
	}
	return &record
}

func (s operationStore) saveCurrent(record OperationRecord) error {
	if err := writePrivateJSON(s.currentPath, record); err != nil {
		return fmt.Errorf("save current operation: %w", err)
	}
	return nil
}

func (s operationStore) appendHistory(record OperationRecord) error {
	encoded, err := json.Marshal(record)
	if err != nil {
		return fmt.Errorf("encode operation history: %w", err)
	}
	encoded = append(encoded, '\n')
	if err := writePrivateFile(s.historyPath, encoded, os.O_CREATE|os.O_APPEND); err != nil {
		return fmt.Errorf("append operation history: %w", err)
	}
	return s.pruneHistory()
}

func (s operationStore) readHistory() []OperationRecord {
	file, err := os.Open(s.historyPath)
	if err != nil {
		return []OperationRecord{}
	}
	defer file.Close()
	records := []OperationRecord{}
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 4096), maximumOperationLine)
	for scanner.Scan() {
		var record OperationRecord
		if json.Unmarshal(scanner.Bytes(), &record) == nil && validOperationRecord(record) {
			records = append(records, record)
		}
	}
	sort.SliceStable(records, func(i, j int) bool {
		return records[i].StartedAtUTC > records[j].StartedAtUTC
	})
	return records
}

func (s operationStore) pruneHistory() error {
	records := s.readHistory()
	cutoff := s.now().UTC().Add(-operationHistoryAge)
	kept := make([]OperationRecord, 0, len(records))
	for _, record := range records {
		started, err := time.Parse(time.RFC3339, record.StartedAtUTC)
		if err == nil && !started.Before(cutoff) {
			kept = append(kept, record)
		}
		if len(kept) == operationHistoryLimit {
			break
		}
	}
	if len(kept) == len(records) {
		return nil
	}
	sort.SliceStable(kept, func(i, j int) bool {
		return kept[i].StartedAtUTC < kept[j].StartedAtUTC
	})
	var buffer bytes.Buffer
	for _, record := range kept {
		encoded, err := json.Marshal(record)
		if err != nil {
			continue
		}
		buffer.Write(encoded)
		buffer.WriteByte('\n')
	}
	return writePrivateBytes(s.historyPath, buffer.Bytes())
}

func validTautulliUserID(value string) bool {
	if value == "" || len(value) > 20 {
		return false
	}
	_, err := strconv.ParseUint(value, 10, 64)
	return err == nil
}

func validOperationRecord(record OperationRecord) bool {
	return record.SchemaVersion == operationSchemaVersion && record.ID != "" && (record.Type == "preview-all" || record.Type == "send-test-all") && record.StartedAtUTC != ""
}

func operationActive(state string) bool {
	return state == "queued" || state == "running" || state == "cancelling"
}

func operationSupportCode(id string) string {
	id = strings.ToUpper(strings.ReplaceAll(id, "_", ""))
	if len(id) > 8 {
		id = id[:8]
	}
	return "TW-" + id
}

type previewFingerprint struct {
	modifiedUnixNano int64
	sizeBytes        int64
}

func previewFingerprints(root string) map[string]previewFingerprint {
	previews, _ := listPreviews(root)
	fingerprints := make(map[string]previewFingerprint, len(previews))
	for _, preview := range previews {
		if strings.HasPrefix(strings.ToLower(preview.Name), "preview-all-") {
			fingerprints[preview.ID] = previewFingerprint{modifiedUnixNano: preview.ModifiedUTC.UnixNano(), sizeBytes: preview.SizeBytes}
		}
	}
	return fingerprints
}

func changedPreviewIDs(root string, before map[string]previewFingerprint) []string {
	after := previewFingerprints(root)
	ids := make([]string, 0, len(after))
	for id, fingerprint := range after {
		if previous, exists := before[id]; !exists || previous != fingerprint {
			ids = append(ids, id)
		}
	}
	sort.Strings(ids)
	return ids
}

func writePrivateBytes(path string, content []byte) error {
	temporary, err := os.CreateTemp(filepath.Dir(path), ".manager-private-*.tmp")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(0o600); err != nil {
		temporary.Close()
		return err
	}
	if _, err := temporary.Write(content); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	if err := hardenPrivateFile(temporaryPath); err != nil {
		return err
	}
	return os.Rename(temporaryPath, path)
}
