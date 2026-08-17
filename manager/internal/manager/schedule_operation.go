package manager

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const scheduleOperationSchemaVersion = 1

var (
	ErrScheduleBusy         = errors.New("a schedule operation is active")
	ErrScheduleConfirmation = errors.New("schedule confirmation is required")
	ErrScheduleInvalid      = errors.New("schedule operation is invalid")
	ErrScheduleNotReady     = errors.New("configuration is not ready for schedule changes")
	ErrScheduleUnsupported  = errors.New("schedule changes are unsupported on this platform")
)

type ScheduleMutationRequest struct {
	ExpectedRevision string `json:"expectedRevision"`
	Confirm          bool   `json:"confirm"`
}

type ScheduleOperationRecord struct {
	SchemaVersion int    `json:"schemaVersion"`
	ID            string `json:"id"`
	Action        string `json:"action"`
	State         string `json:"state"`
	StartedAtUTC  string `json:"startedAtUtc"`
	FinishedAtUTC string `json:"finishedAtUtc,omitempty"`
	ExitCode      *int   `json:"exitCode,omitempty"`
	ErrorCategory string `json:"errorCategory,omitempty"`
	SupportCode   string `json:"supportCode,omitempty"`
}

type scheduleMutationRunner interface {
	Run(ctx context.Context, root, action, expectedRevision, taskName string) (int, error)
}

type scheduleCoordinator struct {
	mu          sync.RWMutex
	root        string
	runtimeRoot string
	currentPath string
	now         func() time.Time
	runner      scheduleMutationRunner
	actions     []string
	current     *ScheduleOperationRecord
}

func newScheduleCoordinator(options Options) (*scheduleCoordinator, error) {
	runtimeRoot := options.RuntimeRoot
	if strings.TrimSpace(runtimeRoot) == "" {
		runtimeRoot = options.TautWeeklyRoot
	}
	runner := options.scheduleRunner
	if runner == nil {
		mode := normalizedRuntimeMode(options.RuntimeMode)
		if mode == runtimeModeNAS || mode == runtimeModeLinux {
			runner = containerScheduleMutationRunner{runtimeRoot: runtimeRoot, now: options.Now}
		} else {
			runner = platformScheduleMutationRunner{}
		}
	}
	coordinator := &scheduleCoordinator{
		root:        options.TautWeeklyRoot,
		runtimeRoot: runtimeRoot,
		currentPath: filepath.Join(options.DataDir, "schedule-operation.json"),
		now:         options.Now,
		runner:      runner,
		actions:     append([]string(nil), capabilitiesFor(options).ScheduleActions...),
	}
	if coordinator.now == nil {
		coordinator.now = time.Now
	}
	coordinator.current = coordinator.readCurrent()
	if coordinator.current != nil && scheduleOperationActive(coordinator.current.State) {
		exitCode := -1
		coordinator.current.State = "failed"
		coordinator.current.FinishedAtUTC = coordinator.now().UTC().Format(time.RFC3339)
		coordinator.current.ExitCode = &exitCode
		coordinator.current.ErrorCategory = "manager-restarted"
		coordinator.current.SupportCode = operationSupportCode(coordinator.current.ID)
		if err := coordinator.saveCurrent(*coordinator.current); err != nil {
			return nil, err
		}
	}
	return coordinator, nil
}

func (c *scheduleCoordinator) Start(action string, request ScheduleMutationRequest) (ScheduleOperationRecord, error) {
	action = strings.ToLower(strings.TrimSpace(action))
	if !validScheduleAction(action) || !containsCapabilityAction(c.actions, action) {
		return ScheduleOperationRecord{}, ErrScheduleInvalid
	}
	if !request.Confirm {
		return ScheduleOperationRecord{}, ErrScheduleConfirmation
	}
	values, raw, exists, state := readConfigDocument(c.runtimeRoot)
	if state != "ready" || !exists || len(existingConfigIssues(values)) > 0 {
		return ScheduleOperationRecord{}, ErrScheduleNotReady
	}
	if request.ExpectedRevision == "" || request.ExpectedRevision != configRevision(raw, true) {
		return ScheduleOperationRecord{}, ErrConfigConflict
	}

	c.mu.Lock()
	defer c.mu.Unlock()
	if c.current != nil && scheduleOperationActive(c.current.State) {
		return ScheduleOperationRecord{}, ErrScheduleBusy
	}
	id, err := randomToken(12)
	if err != nil {
		return ScheduleOperationRecord{}, err
	}
	record := ScheduleOperationRecord{
		SchemaVersion: scheduleOperationSchemaVersion,
		ID:            id,
		Action:        action,
		State:         "queued",
		StartedAtUTC:  c.now().UTC().Format(time.RFC3339),
	}
	if err := c.saveCurrent(record); err != nil {
		return ScheduleOperationRecord{}, err
	}
	c.current = &record
	taskName := strings.TrimSpace(configMapString(values, "ScheduledTaskName"))
	if taskName == "" {
		taskName = "TautWeekly for Plex Newsletter"
	}
	go c.run(record, request.ExpectedRevision, taskName)
	return record, nil
}

func (c *scheduleCoordinator) run(record ScheduleOperationRecord, expectedRevision, taskName string) {
	c.setRunning(record.ID)
	exitCode, runErr := c.runner.Run(context.Background(), c.root, record.Action, expectedRevision, taskName)
	record.ExitCode = &exitCode
	record.FinishedAtUTC = c.now().UTC().Format(time.RFC3339)
	if runErr == nil && exitCode == 0 {
		record.State = "succeeded"
	} else {
		record.State = "failed"
		record.ErrorCategory = scheduleErrorCategory(exitCode, runErr)
		record.SupportCode = operationSupportCode(record.ID)
	}
	c.mu.Lock()
	c.current = &record
	_ = c.saveCurrent(record)
	c.mu.Unlock()
}

func (c *scheduleCoordinator) setRunning(id string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.current == nil || c.current.ID != id || c.current.State != "queued" {
		return
	}
	c.current.State = "running"
	_ = c.saveCurrent(*c.current)
}

func (c *scheduleCoordinator) Current() *ScheduleOperationRecord {
	c.mu.RLock()
	defer c.mu.RUnlock()
	if c.current == nil {
		return nil
	}
	copy := *c.current
	return &copy
}

func (c *scheduleCoordinator) readCurrent() *ScheduleOperationRecord {
	var record ScheduleOperationRecord
	raw, err := os.ReadFile(c.currentPath)
	if err != nil || len(raw) > maximumOperationLine || decodeScheduleRecord(raw, &record) != nil || !validScheduleOperationRecord(record) {
		return nil
	}
	return &record
}

func decodeScheduleRecord(raw []byte, record *ScheduleOperationRecord) error {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(record); err != nil {
		return err
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		return ErrScheduleInvalid
	}
	return nil
}

func (c *scheduleCoordinator) saveCurrent(record ScheduleOperationRecord) error {
	return writePrivateJSON(c.currentPath, record)
}

func validScheduleAction(action string) bool {
	return action == "install" || action == "enable" || action == "disable" || action == "remove"
}

func validScheduleOperationRecord(record ScheduleOperationRecord) bool {
	if record.SchemaVersion != scheduleOperationSchemaVersion || record.ID == "" || !validScheduleAction(record.Action) {
		return false
	}
	started, err := time.Parse(time.RFC3339, record.StartedAtUTC)
	if err != nil {
		return false
	}
	if scheduleOperationActive(record.State) {
		return record.FinishedAtUTC == "" && record.ExitCode == nil && record.ErrorCategory == "" && record.SupportCode == ""
	}
	if record.State != "succeeded" && record.State != "failed" {
		return false
	}
	finished, err := time.Parse(time.RFC3339, record.FinishedAtUTC)
	if err != nil || finished.Before(started) || record.ExitCode == nil {
		return false
	}
	if record.State == "succeeded" {
		return *record.ExitCode == 0 && record.ErrorCategory == "" && record.SupportCode == ""
	}
	return record.ErrorCategory != "" && record.SupportCode != ""
}

func scheduleOperationActive(state string) bool {
	return state == "queued" || state == "running"
}

func scheduleErrorCategory(exitCode int, runErr error) string {
	if errors.Is(runErr, ErrScheduleUnsupported) {
		return "platform-unsupported"
	}
	switch exitCode {
	case 10:
		return "elevation-declined"
	case 20:
		return "configuration-missing"
	case 21:
		return "configuration-changed"
	case 22:
		return "task-not-found"
	case 23:
		return "task-ownership-mismatch"
	case 24:
		return "schedule-invalid"
	case 25:
		return "renderer-missing"
	case 26:
		return "elevation-failed"
	case 27:
		return "postcondition-failed"
	case 28:
		return "schedule-configuration-read-failed"
	case 29:
		return "task-definition-failed"
	case 30:
		return "task-mutation-failed"
	case 31:
		return "task-verification-failed"
	case 32:
		return "task-read-access-failed"
	case 33:
		return "container-schedule-update-failed"
	case 34:
		return "container-schedule-verification-failed"
	default:
		return "schedule-helper-failed"
	}
}
