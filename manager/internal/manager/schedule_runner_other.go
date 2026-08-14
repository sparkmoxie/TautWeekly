//go:build !windows

package manager

import "context"

type platformScheduleMutationRunner struct{}

func (platformScheduleMutationRunner) Run(_ context.Context, _, _, _, _ string) (int, error) {
	return -1, ErrScheduleUnsupported
}
