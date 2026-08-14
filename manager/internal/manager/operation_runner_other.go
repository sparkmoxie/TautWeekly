//go:build !windows

package manager

import "context"

type platformPreviewOperationRunner struct{}

func (platformPreviewOperationRunner) RunPreviewAll(_ context.Context, _, _, _, _ string) (int, error) {
	return -1, ErrOperationUnsupported
}

func (platformPreviewOperationRunner) RunSendTestAll(_ context.Context, _, _, _, _ string) (int, error) {
	return -1, ErrOperationUnsupported
}
