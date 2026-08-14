//go:build windows

package manager

import (
	"context"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

type scheduleTaskProbe func(context.Context, string, string) (windowsTaskProbe, error)

type platformScheduleMutationRunner struct {
	probe scheduleTaskProbe
}

func (r platformScheduleMutationRunner) Run(ctx context.Context, root, action, expectedRevision, taskName string) (int, error) {
	if !validScheduleAction(action) || len(expectedRevision) != 64 {
		return -1, ErrScheduleInvalid
	}
	if _, err := hex.DecodeString(expectedRevision); err != nil {
		return -1, ErrScheduleInvalid
	}
	helperPath := filepath.Join(root, "SCHEDULE-HELPER.ps1")
	if info, err := os.Stat(helperPath); err != nil || !info.Mode().IsRegular() {
		return -1, errors.New("packaged schedule helper is unavailable")
	}
	systemRoot := strings.TrimSpace(os.Getenv("SystemRoot"))
	if systemRoot == "" {
		return -1, ErrScheduleUnsupported
	}
	powerShellPath := filepath.Join(systemRoot, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
	if info, err := os.Stat(powerShellPath); err != nil || !info.Mode().IsRegular() {
		return -1, ErrScheduleUnsupported
	}
	command := exec.CommandContext(ctx, powerShellPath,
		"-NoLogo",
		"-NoProfile",
		"-NonInteractive",
		"-ExecutionPolicy", "Bypass",
		"-File", helperPath,
		"-Action", titleCaseScheduleAction(action),
		"-ExpectedRevision", strings.ToLower(expectedRevision),
	)
	command.Dir = root
	command.Env = operationEnvironment(os.Environ())
	command.Stdout = io.Discard
	command.Stderr = io.Discard
	err := command.Run()
	if err != nil {
		if ctx.Err() != nil {
			return -1, ctx.Err()
		}
		var exitError *exec.ExitError
		if errors.As(err, &exitError) {
			return exitError.ExitCode(), err
		}
		return -1, err
	}
	probeTask := r.probe
	if probeTask == nil {
		probeTask = probeWindowsTask
	}
	probe, err := probeTask(ctx, taskName, root)
	if err != nil || !schedulePostcondition(action, probe) {
		return 27, errors.New("schedule postcondition was not observed")
	}
	return 0, nil
}

func titleCaseScheduleAction(action string) string {
	if action == "" {
		return ""
	}
	return strings.ToUpper(action[:1]) + action[1:]
}

func schedulePostcondition(action string, probe windowsTaskProbe) bool {
	switch action {
	case "install", "enable":
		return probe.Installed && probe.Enabled && probe.Owned
	case "disable":
		return probe.Installed && !probe.Enabled && probe.Owned
	case "remove":
		return !probe.Installed
	default:
		return false
	}
}
