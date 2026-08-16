package manager

import (
	"context"
	"encoding/json"
	"errors"
	"time"
)

type containerScheduleMutationRunner struct {
	runtimeRoot string
	now         func() time.Time
}

func (r containerScheduleMutationRunner) Run(ctx context.Context, _ string, action, expectedRevision, _ string) (int, error) {
	if action != "enable" && action != "disable" {
		return 24, errors.New("container schedule action is unsupported")
	}
	select {
	case <-ctx.Done():
		return -1, ctx.Err()
	default:
	}
	values, raw, exists, state := readConfigDocument(r.runtimeRoot)
	if state != "ready" || !exists || len(existingConfigIssues(values)) > 0 {
		return 20, errors.New("configuration is unavailable")
	}
	if expectedRevision == "" || expectedRevision != configRevision(raw, true) {
		return 21, ErrConfigConflict
	}
	values["ScheduleEnabled"] = action == "enable"
	encoded, err := json.MarshalIndent(values, "", "  ")
	if err != nil {
		return 33, errors.New("schedule configuration could not be encoded")
	}
	encoded = append(encoded, '\n')
	now := r.now
	if now == nil {
		now = time.Now
	}
	if _, err := writeConfigAtomically(r.runtimeRoot, raw, true, encoded, now().UTC()); err != nil {
		return 33, errors.New("schedule configuration could not be updated")
	}
	updated, _, updatedExists, updatedState := readConfigDocument(r.runtimeRoot)
	if updatedState != "ready" || !updatedExists || configMapBool(updated, "ScheduleEnabled", false) != (action == "enable") {
		return 34, errors.New("schedule state could not be verified")
	}
	return 0, nil
}
