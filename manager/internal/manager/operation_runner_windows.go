//go:build windows

package manager

import (
	"context"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

type platformPreviewOperationRunner struct{}

func (platformPreviewOperationRunner) RunPreviewAll(ctx context.Context, root, configPath, resultPath, userID string) (int, error) {
	return runWindowsRendererOperation(ctx, root, configPath, resultPath, userID, "PreviewAll", true)
}

func (platformPreviewOperationRunner) RunSendTestAll(ctx context.Context, root, configPath, resultPath, userID string) (int, error) {
	return runWindowsRendererOperation(ctx, root, configPath, resultPath, userID, "SendTestAll", false)
}

func runWindowsRendererOperation(ctx context.Context, root, configPath, resultPath, userID, mode string, noOpen bool) (int, error) {
	scriptPath := filepath.Join(root, "TautWeekly.ps1")
	if info, err := os.Stat(scriptPath); err != nil || !info.Mode().IsRegular() {
		return -1, errors.New("packaged renderer is unavailable")
	}
	systemRoot := strings.TrimSpace(os.Getenv("SystemRoot"))
	if systemRoot == "" {
		return -1, ErrOperationUnsupported
	}
	powerShellPath := filepath.Join(systemRoot, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
	if info, err := os.Stat(powerShellPath); err != nil || !info.Mode().IsRegular() {
		return -1, ErrOperationUnsupported
	}
	arguments := []string{
		"-NoLogo",
		"-NoProfile",
		"-NonInteractive",
		"-ExecutionPolicy", "Bypass",
		"-File", scriptPath,
		"-Mode", mode,
		"-UserId", userID,
		"-ConfigPath", configPath,
		"-ResultPath", resultPath,
	}
	if noOpen {
		arguments = append(arguments, "-NoOpen")
	}
	command := exec.CommandContext(ctx, powerShellPath, arguments...)
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
