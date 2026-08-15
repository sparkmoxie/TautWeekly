//go:build windows

package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"unsafe"
)

const dashboardWindowTitle = "TautWeekly Manager"

var (
	browserUser32              = syscall.NewLazyDLL("user32.dll")
	browserEnumWindows         = browserUser32.NewProc("EnumWindows")
	browserIsWindowVisible     = browserUser32.NewProc("IsWindowVisible")
	browserIsIconic            = browserUser32.NewProc("IsIconic")
	browserGetWindowTextLength = browserUser32.NewProc("GetWindowTextLengthW")
	browserGetWindowText       = browserUser32.NewProc("GetWindowTextW")
	browserShowWindow          = browserUser32.NewProc("ShowWindow")
	browserBringWindowToTop    = browserUser32.NewProc("BringWindowToTop")
	browserSetForegroundWindow = browserUser32.NewProc("SetForegroundWindow")
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
	var found uintptr
	callback := syscall.NewCallback(func(window, _ uintptr) uintptr {
		if visible, _, _ := browserIsWindowVisible.Call(window); visible == 0 {
			return 1
		}
		length, _, _ := browserGetWindowTextLength.Call(window)
		if length == 0 {
			return 1
		}
		if length > 2048 {
			length = 2048
		}
		buffer := make([]uint16, int(length)+1)
		copied, _, _ := browserGetWindowText.Call(window, uintptr(unsafe.Pointer(&buffer[0])), uintptr(len(buffer)))
		if copied == 0 || !isDashboardWindowTitle(syscall.UTF16ToString(buffer)) {
			return 1
		}
		found = window
		return 0
	})
	browserEnumWindows.Call(callback, 0)
	if found == 0 {
		return false
	}
	if iconic, _, _ := browserIsIconic.Call(found); iconic != 0 {
		browserShowWindow.Call(found, 9) // SW_RESTORE
	}
	browserBringWindowToTop.Call(found)
	browserSetForegroundWindow.Call(found)
	return true
}

func isDashboardWindowTitle(title string) bool {
	title = strings.TrimSpace(title)
	if title == dashboardWindowTitle {
		return true
	}
	for _, separator := range []string{" - ", " — ", " – "} {
		if strings.HasPrefix(title, dashboardWindowTitle+separator) {
			return true
		}
	}
	return false
}
