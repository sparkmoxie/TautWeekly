//go:build windows

package manager

import (
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
)

const windowsUpdateCreateNoWindow = 0x08000000

type windowsUpdateInstaller struct {
	root       string
	powershell string
	script     string
}

func newPlatformUpdateInstaller(root string) updateInstallController {
	installer := windowsUpdateInstaller{root: root, script: filepath.Join(root, "Check-Update.ps1")}
	systemRoot := strings.TrimSpace(os.Getenv("SystemRoot"))
	if systemRoot != "" {
		installer.powershell = filepath.Join(systemRoot, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
	}
	return installer
}

func (i windowsUpdateInstaller) Supported() bool {
	for _, path := range []string{i.powershell, i.script, filepath.Join(i.root, "Windows-Update.ps1"), filepath.Join(i.root, "RELEASE-METADATA.txt")} {
		info, err := os.Stat(path)
		if err != nil || !info.Mode().IsRegular() {
			return false
		}
	}
	return normalizedLocalVersion(readRepositoryVersion(i.root)) != ""
}

func (i windowsUpdateInstaller) Start() (<-chan error, error) {
	if !i.Supported() {
		return nil, errors.New("verified Windows update package is unavailable")
	}
	command := exec.Command(
		i.powershell,
		"-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
		"-File", i.script,
		"-InstallRoot", i.root,
		"-Apply",
	)
	command.Dir = i.root
	command.Env = operationEnvironment(os.Environ())
	command.Stdin = nil
	command.Stdout = io.Discard
	command.Stderr = io.Discard
	command.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: windowsUpdateCreateNoWindow}
	if err := command.Start(); err != nil {
		return nil, err
	}
	result := make(chan error, 1)
	go func() {
		result <- command.Wait()
		close(result)
	}()
	return result, nil
}
