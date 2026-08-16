//go:build windows

package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
)

const (
	dashboardWindowTitle  = "TautWeekly Manager"
	windowsCreateNoWindow = 0x08000000
)

func openLocalBrowser(target string) error {
	if err := validateLocalBrowserURL(target); err != nil {
		return err
	}
	if activateExistingDashboardWindow() {
		return nil
	}
	systemRoot := strings.TrimSpace(os.Getenv("SystemRoot"))
	if systemRoot == "" {
		return fmt.Errorf("SystemRoot is unavailable")
	}
	opener := filepath.Join(systemRoot, "System32", "rundll32.exe")
	if info, err := os.Stat(opener); err != nil || !info.Mode().IsRegular() {
		return fmt.Errorf("Windows browser opener is unavailable")
	}
	return exec.Command(opener, "url.dll,FileProtocolHandler", target).Start()
}

func activateExistingDashboardWindow() bool {
	command, err := dashboardActivationCommand(strings.TrimSpace(os.Getenv("SystemRoot")))
	if err != nil {
		return false
	}
	return command.Run() == nil
}

func dashboardActivationCommand(systemRoot string) (*exec.Cmd, error) {
	if systemRoot == "" {
		return nil, fmt.Errorf("SystemRoot is unavailable")
	}
	powerShell := filepath.Join(systemRoot, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
	if info, err := os.Stat(powerShell); err != nil || !info.Mode().IsRegular() {
		return nil, fmt.Errorf("Windows PowerShell is unavailable")
	}

	// WScript.Shell.AppActivate is the documented Windows accessibility path
	// for focusing an application by title. It first uses an exact match and
	// then a title prefix, which covers the suffixes added by common browsers.
	// A non-zero exit means there is no matching Dashboard window, so the
	// caller can open the validated loopback URL in the default browser.
	script := `$shell=New-Object -ComObject WScript.Shell;if($shell.AppActivate('TautWeekly Manager')){exit 0};exit 1`
	command := exec.Command(
		powerShell,
		"-NoLogo",
		"-NoProfile",
		"-NonInteractive",
		"-WindowStyle", "Hidden",
		"-Command", script,
	)
	command.SysProcAttr = &syscall.SysProcAttr{
		HideWindow:    true,
		CreationFlags: windowsCreateNoWindow,
	}
	return command, nil
}
