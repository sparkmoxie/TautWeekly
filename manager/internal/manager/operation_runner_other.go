//go:build !windows

package manager

import (
	"context"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
)

type platformPreviewOperationRunner struct{}

func (platformPreviewOperationRunner) RunPreviewAll(ctx context.Context, root, configPath, resultPath, userID string) (int, error) {
	return runContainerRendererOperation(ctx, root, configPath, resultPath, userID, "PreviewAll", true, false, false)
}

func (platformPreviewOperationRunner) RunSendTestAll(ctx context.Context, root, configPath, resultPath, userID string) (int, error) {
	return runContainerRendererOperation(ctx, root, configPath, resultPath, userID, "SendTestAll", false, false, false)
}

func (platformPreviewOperationRunner) RunSendWelcome(ctx context.Context, root, configPath, resultPath, userID string) (int, error) {
	return runContainerRendererOperation(ctx, root, configPath, resultPath, userID, "SendWelcome", false, false, true)
}

func (platformPreviewOperationRunner) RunSendAll(ctx context.Context, root, configPath, resultPath string) (int, error) {
	return runContainerRendererOperation(ctx, root, configPath, resultPath, "", "SendAll", false, true, false)
}

func runContainerRendererOperation(ctx context.Context, root, configPath, resultPath, userID, mode string, noOpen, confirmSendAll, confirmWelcome bool) (int, error) {
	launcher := filepath.Join(root, "bin", "run-mode.sh")
	if info, err := os.Stat(launcher); err != nil || !info.Mode().IsRegular() {
		return -1, ErrOperationUnsupported
	}
	arguments := []string{mode}
	if userID != "" {
		arguments = append(arguments, userID)
	}
	arguments = append(arguments, "--manager-config", configPath, "--manager-result", resultPath)
	if noOpen {
		arguments = append(arguments, "--no-open")
	}
	if confirmSendAll {
		arguments = append(arguments, "--confirm-send-all")
	}
	if confirmWelcome {
		arguments = append(arguments, "--confirm-welcome")
	}
	command := exec.CommandContext(ctx, launcher, arguments...)
	command.Dir = root
	command.Env = operationEnvironment(os.Environ())
	command.Stdout = io.Discard
	command.Stderr = io.Discard
	err := command.Run()
	if err == nil {
		return 0, nil
	}
	if ctx.Err() != nil {
		return -1, ctx.Err()
	}
	var exitError *exec.ExitError
	if errors.As(err, &exitError) {
		return exitError.ExitCode(), err
	}
	return -1, err
}
