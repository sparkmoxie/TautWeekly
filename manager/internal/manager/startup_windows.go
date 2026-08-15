//go:build windows

package manager

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"unsafe"
)

const (
	startupRunKeyPath = `Software\Microsoft\Windows\CurrentVersion\Run`
	startupValueName  = "TautWeekly for Plex Manager"
	registryString    = 1
	keyQueryValue     = 0x0001
	keySetValue       = 0x0002
)

var (
	startupAdvapi32       = syscall.NewLazyDLL("advapi32.dll")
	startupRegOpenKeyEx   = startupAdvapi32.NewProc("RegOpenKeyExW")
	startupRegCreateKeyEx = startupAdvapi32.NewProc("RegCreateKeyExW")
	startupRegQueryValue  = startupAdvapi32.NewProc("RegQueryValueExW")
	startupRegSetValue    = startupAdvapi32.NewProc("RegSetValueExW")
	startupRegDeleteValue = startupAdvapi32.NewProc("RegDeleteValueW")
	startupRegCloseKey    = startupAdvapi32.NewProc("RegCloseKey")
)

type startupRegistry interface {
	Read(name string) (string, bool, error)
	Write(name, value string) error
	Delete(name string) error
}

type currentUserRunRegistry struct{}

type windowsStartupController struct {
	root       string
	dataDir    string
	systemRoot string
	registry   startupRegistry
}

func newPlatformStartupController(root, dataDir string) startupSettingsController {
	if absolute, err := filepath.Abs(root); err == nil {
		root = absolute
	}
	if absolute, err := filepath.Abs(dataDir); err == nil {
		dataDir = absolute
	}
	return &windowsStartupController{
		root:       filepath.Clean(root),
		dataDir:    filepath.Clean(dataDir),
		systemRoot: strings.TrimSpace(os.Getenv("SystemRoot")),
		registry:   currentUserRunRegistry{},
	}
}

func (c *windowsStartupController) Status() StartupSettings {
	status := StartupSettings{Supported: true, State: "disabled"}
	if c.systemRoot == "" {
		status.State = "unavailable"
		status.ErrorCode = "windows-system-root-unavailable"
		return status
	}
	value, exists, err := c.registry.Read(startupValueName)
	if err != nil {
		status.State = "unavailable"
		status.ErrorCode = "startup-read-failed"
		return status
	}
	if !exists {
		return status
	}
	if strings.EqualFold(value, c.command(false)) {
		status.StartManager = true
		status.State = "enabled"
		return status
	}
	if strings.EqualFold(value, c.command(true)) {
		status.StartManager = true
		status.OpenDashboard = true
		status.State = "enabled"
		return status
	}
	status.State = "conflict"
	status.ErrorCode = "startup-entry-conflict"
	return status
}

func (c *windowsStartupController) Update(startManager, openDashboard bool) (StartupSettings, error) {
	if openDashboard && !startManager {
		return c.Status(), errors.New("Open Dashboard after sign-in requires Manager startup")
	}
	current := c.Status()
	if !current.Supported {
		return current, ErrStartupUnsupported
	}
	if current.State == "unavailable" {
		return current, ErrStartupUnavailable
	}
	if current.State == "conflict" {
		return current, ErrStartupConflict
	}
	if startManager {
		if err := c.registry.Write(startupValueName, c.command(openDashboard)); err != nil {
			return c.Status(), fmt.Errorf("write current-user startup entry: %w", err)
		}
	} else {
		if err := c.registry.Delete(startupValueName); err != nil {
			return c.Status(), fmt.Errorf("remove current-user startup entry: %w", err)
		}
	}
	updated := c.Status()
	if updated.State == "unavailable" || updated.State == "conflict" || updated.StartManager != startManager || updated.OpenDashboard != openDashboard {
		return updated, errors.New("Windows did not retain the requested startup settings")
	}
	return updated, nil
}

func (c *windowsStartupController) command(openDashboard bool) string {
	powerShell := filepath.Join(c.systemRoot, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
	script := filepath.Join(c.root, "START-MANAGER.ps1")
	command := windowsCommandQuote(powerShell) + " -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File " + windowsCommandQuote(script) + " -DataRoot " + windowsCommandQuote(c.dataDir) + " -Startup"
	if openDashboard {
		command += " -OpenDashboard"
	}
	return command
}

func windowsCommandQuote(value string) string {
	return `"` + strings.ReplaceAll(value, `"`, `\"`) + `"`
}

func (currentUserRunRegistry) Read(name string) (string, bool, error) {
	key, err := openStartupRunKey(keyQueryValue, false)
	if err != nil {
		if errors.Is(err, syscall.ERROR_FILE_NOT_FOUND) {
			return "", false, nil
		}
		return "", false, err
	}
	defer startupRegCloseKey.Call(key)
	namePointer, err := syscall.UTF16PtrFromString(name)
	if err != nil {
		return "", false, err
	}
	var valueType uint32
	var size uint32
	result, _, _ := startupRegQueryValue.Call(key, uintptr(unsafe.Pointer(namePointer)), 0, uintptr(unsafe.Pointer(&valueType)), 0, uintptr(unsafe.Pointer(&size)))
	if result == uintptr(syscall.ERROR_FILE_NOT_FOUND) {
		return "", false, nil
	}
	if result != 0 {
		return "", false, syscall.Errno(result)
	}
	if valueType != registryString || size < 2 || size > 64<<10 {
		return "", false, errors.New("startup registry value is not a bounded string")
	}
	buffer := make([]uint16, (size+1)/2)
	result, _, _ = startupRegQueryValue.Call(key, uintptr(unsafe.Pointer(namePointer)), 0, uintptr(unsafe.Pointer(&valueType)), uintptr(unsafe.Pointer(&buffer[0])), uintptr(unsafe.Pointer(&size)))
	if result != 0 {
		return "", false, syscall.Errno(result)
	}
	return syscall.UTF16ToString(buffer), true, nil
}

func (currentUserRunRegistry) Write(name, value string) error {
	key, err := openStartupRunKey(keySetValue, true)
	if err != nil {
		return err
	}
	defer startupRegCloseKey.Call(key)
	namePointer, err := syscall.UTF16PtrFromString(name)
	if err != nil {
		return err
	}
	encoded, err := syscall.UTF16FromString(value)
	if err != nil {
		return err
	}
	result, _, _ := startupRegSetValue.Call(key, uintptr(unsafe.Pointer(namePointer)), 0, registryString, uintptr(unsafe.Pointer(&encoded[0])), uintptr(len(encoded)*2))
	if result != 0 {
		return syscall.Errno(result)
	}
	return nil
}

func (currentUserRunRegistry) Delete(name string) error {
	key, err := openStartupRunKey(keySetValue, false)
	if err != nil {
		if errors.Is(err, syscall.ERROR_FILE_NOT_FOUND) {
			return nil
		}
		return err
	}
	defer startupRegCloseKey.Call(key)
	namePointer, err := syscall.UTF16PtrFromString(name)
	if err != nil {
		return err
	}
	result, _, _ := startupRegDeleteValue.Call(key, uintptr(unsafe.Pointer(namePointer)))
	if result == uintptr(syscall.ERROR_FILE_NOT_FOUND) {
		return nil
	}
	if result != 0 {
		return syscall.Errno(result)
	}
	return nil
}

func openStartupRunKey(access uint32, create bool) (uintptr, error) {
	pathPointer, err := syscall.UTF16PtrFromString(startupRunKeyPath)
	if err != nil {
		return 0, err
	}
	var key uintptr
	if create {
		var disposition uint32
		result, _, _ := startupRegCreateKeyEx.Call(uintptr(syscall.HKEY_CURRENT_USER), uintptr(unsafe.Pointer(pathPointer)), 0, 0, 0, uintptr(access), 0, uintptr(unsafe.Pointer(&key)), uintptr(unsafe.Pointer(&disposition)))
		if result != 0 {
			return 0, syscall.Errno(result)
		}
		return key, nil
	}
	result, _, _ := startupRegOpenKeyEx.Call(uintptr(syscall.HKEY_CURRENT_USER), uintptr(unsafe.Pointer(pathPointer)), 0, uintptr(access), uintptr(unsafe.Pointer(&key)))
	if result != 0 {
		return 0, syscall.Errno(result)
	}
	return key, nil
}
