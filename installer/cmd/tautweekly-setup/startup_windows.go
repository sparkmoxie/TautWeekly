//go:build windows

package main

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
	managerStartupRunKey = `Software\Microsoft\Windows\CurrentVersion\Run`
	managerStartupName   = "TautWeekly for Plex Manager"
	managerRegistrySZ    = 1
	managerKeyQuery      = 0x0001
	managerKeySet        = 0x0002
)

var (
	managerStartupAdvapi      = syscall.NewLazyDLL("advapi32.dll")
	managerRegOpenKey         = managerStartupAdvapi.NewProc("RegOpenKeyExW")
	managerRegCreateKey       = managerStartupAdvapi.NewProc("RegCreateKeyExW")
	managerRegQueryValue      = managerStartupAdvapi.NewProc("RegQueryValueExW")
	managerRegSetValue        = managerStartupAdvapi.NewProc("RegSetValueExW")
	managerRegDeleteValue     = managerStartupAdvapi.NewProc("RegDeleteValueW")
	managerRegCloseKey        = managerStartupAdvapi.NewProc("RegCloseKey")
	readManagerStartupValue   = readCurrentUserManagerStartup
	writeManagerStartupValue  = writeCurrentUserManagerStartup
	deleteManagerStartupValue = deleteCurrentUserManagerStartup
)

type managerStartupPreference struct {
	Enabled       bool
	OpenDashboard bool
	InstallRoot   string
	DataRoot      string
}

func captureManagerStartup(testMode bool) (managerStartupPreference, error) {
	if testMode {
		return managerStartupPreference{}, nil
	}
	value, exists, err := readManagerStartupValue()
	if err != nil {
		return managerStartupPreference{}, fmt.Errorf("inspect Manager sign-in startup: %w", err)
	}
	if !exists {
		return managerStartupPreference{}, nil
	}
	preference, owned := parseManagerStartupCommand(value)
	if !owned {
		return managerStartupPreference{}, nil
	}
	return preference, nil
}

func reconcileManagerStartup(preference managerStartupPreference, opts options, testMode bool) error {
	if testMode || !preference.Enabled {
		return nil
	}
	command, err := managerStartupCommand(opts.installDir, opts.dataDir, preference.OpenDashboard)
	if err != nil {
		return err
	}
	if err := writeManagerStartupValue(command); err != nil {
		return fmt.Errorf("refresh Manager sign-in startup for the installed path: %w", err)
	}
	return nil
}

func removeManagerStartup(installRoot string, testMode bool) error {
	if testMode {
		return nil
	}
	value, exists, err := readManagerStartupValue()
	if err != nil {
		return fmt.Errorf("inspect Manager sign-in startup before removal: %w", err)
	}
	if !exists {
		return nil
	}
	preference, owned := parseManagerStartupCommand(value)
	if !owned || !samePath(preference.InstallRoot, installRoot) {
		return nil
	}
	if err := deleteManagerStartupValue(); err != nil {
		return fmt.Errorf("remove Manager sign-in startup: %w", err)
	}
	return nil
}

func managerStartupCommand(installRoot, dataRoot string, openDashboard bool) (string, error) {
	systemRoot := strings.TrimSpace(os.Getenv("SystemRoot"))
	if systemRoot == "" {
		return "", errors.New("Windows system directory is unavailable")
	}
	powerShell := filepath.Join(systemRoot, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
	script := filepath.Join(filepath.Clean(installRoot), "START-MANAGER.ps1")
	command := quoteStartupArgument(powerShell) + " -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File " + quoteStartupArgument(script) + " -DataRoot " + quoteStartupArgument(filepath.Clean(dataRoot)) + " -Startup"
	if openDashboard {
		command += " -OpenDashboard"
	}
	return command, nil
}

func parseManagerStartupCommand(command string) (managerStartupPreference, bool) {
	arguments, err := splitWindowsCommandLine(command)
	if err != nil || (len(arguments) != 13 && len(arguments) != 14) {
		return managerStartupPreference{}, false
	}
	systemRoot := strings.TrimSpace(os.Getenv("SystemRoot"))
	if systemRoot == "" || !samePath(arguments[0], filepath.Join(systemRoot, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")) {
		return managerStartupPreference{}, false
	}
	expected := []string{"-NoLogo", "-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden", "-ExecutionPolicy", "Bypass", "-File"}
	for index, value := range expected {
		if !strings.EqualFold(arguments[index+1], value) {
			return managerStartupPreference{}, false
		}
	}
	if !strings.EqualFold(filepath.Base(arguments[9]), "START-MANAGER.ps1") || !filepath.IsAbs(arguments[9]) || !strings.EqualFold(arguments[10], "-DataRoot") || !filepath.IsAbs(arguments[11]) || !strings.EqualFold(arguments[12], "-Startup") {
		return managerStartupPreference{}, false
	}
	openDashboard := len(arguments) == 14 && strings.EqualFold(arguments[13], "-OpenDashboard")
	if len(arguments) == 14 && !openDashboard {
		return managerStartupPreference{}, false
	}
	return managerStartupPreference{
		Enabled:       true,
		OpenDashboard: openDashboard,
		InstallRoot:   filepath.Dir(filepath.Clean(arguments[9])),
		DataRoot:      filepath.Clean(arguments[11]),
	}, true
}

func splitWindowsCommandLine(command string) ([]string, error) {
	arguments := make([]string, 0, 16)
	var current strings.Builder
	inQuotes := false
	inArgument := false
	flush := func() {
		if inArgument {
			arguments = append(arguments, current.String())
			current.Reset()
			inArgument = false
		}
	}
	for _, character := range command {
		switch {
		case character == '"':
			inQuotes = !inQuotes
			inArgument = true
		case (character == ' ' || character == '\t') && !inQuotes:
			flush()
		default:
			current.WriteRune(character)
			inArgument = true
		}
		if len(arguments) > 64 || current.Len() > 64<<10 {
			return nil, errors.New("startup command is too large")
		}
	}
	if inQuotes {
		return nil, errors.New("startup command contains an unmatched quote")
	}
	flush()
	if len(arguments) == 0 || len(arguments) > 64 {
		return nil, errors.New("startup command contains an invalid argument count")
	}
	return arguments, nil
}

func quoteStartupArgument(value string) string {
	return `"` + strings.ReplaceAll(value, `"`, `\"`) + `"`
}

func readCurrentUserManagerStartup() (string, bool, error) {
	key, err := openManagerStartupKey(managerKeyQuery, false)
	if err != nil {
		if errors.Is(err, syscall.ERROR_FILE_NOT_FOUND) {
			return "", false, nil
		}
		return "", false, err
	}
	defer managerRegCloseKey.Call(key)
	name, _ := syscall.UTF16PtrFromString(managerStartupName)
	var valueType uint32
	var size uint32
	result, _, _ := managerRegQueryValue.Call(key, uintptr(unsafe.Pointer(name)), 0, uintptr(unsafe.Pointer(&valueType)), 0, uintptr(unsafe.Pointer(&size)))
	if result == uintptr(syscall.ERROR_FILE_NOT_FOUND) {
		return "", false, nil
	}
	if result != 0 {
		return "", false, syscall.Errno(result)
	}
	if valueType != managerRegistrySZ || size < 2 || size > 64<<10 {
		return "", false, errors.New("Manager startup registry value is not a bounded string")
	}
	buffer := make([]uint16, (size+1)/2)
	result, _, _ = managerRegQueryValue.Call(key, uintptr(unsafe.Pointer(name)), 0, uintptr(unsafe.Pointer(&valueType)), uintptr(unsafe.Pointer(&buffer[0])), uintptr(unsafe.Pointer(&size)))
	if result != 0 {
		return "", false, syscall.Errno(result)
	}
	return syscall.UTF16ToString(buffer), true, nil
}

func writeCurrentUserManagerStartup(value string) error {
	key, err := openManagerStartupKey(managerKeySet, true)
	if err != nil {
		return err
	}
	defer managerRegCloseKey.Call(key)
	name, _ := syscall.UTF16PtrFromString(managerStartupName)
	encoded, err := syscall.UTF16FromString(value)
	if err != nil {
		return err
	}
	result, _, _ := managerRegSetValue.Call(key, uintptr(unsafe.Pointer(name)), 0, managerRegistrySZ, uintptr(unsafe.Pointer(&encoded[0])), uintptr(len(encoded)*2))
	if result != 0 {
		return syscall.Errno(result)
	}
	return nil
}

func deleteCurrentUserManagerStartup() error {
	key, err := openManagerStartupKey(managerKeySet, false)
	if err != nil {
		if errors.Is(err, syscall.ERROR_FILE_NOT_FOUND) {
			return nil
		}
		return err
	}
	defer managerRegCloseKey.Call(key)
	name, _ := syscall.UTF16PtrFromString(managerStartupName)
	result, _, _ := managerRegDeleteValue.Call(key, uintptr(unsafe.Pointer(name)))
	if result == uintptr(syscall.ERROR_FILE_NOT_FOUND) {
		return nil
	}
	if result != 0 {
		return syscall.Errno(result)
	}
	return nil
}

func openManagerStartupKey(access uint32, create bool) (uintptr, error) {
	path, _ := syscall.UTF16PtrFromString(managerStartupRunKey)
	var key uintptr
	if create {
		var disposition uint32
		result, _, _ := managerRegCreateKey.Call(uintptr(syscall.HKEY_CURRENT_USER), uintptr(unsafe.Pointer(path)), 0, 0, 0, uintptr(access), 0, uintptr(unsafe.Pointer(&key)), uintptr(unsafe.Pointer(&disposition)))
		if result != 0 {
			return 0, syscall.Errno(result)
		}
		return key, nil
	}
	result, _, _ := managerRegOpenKey.Call(uintptr(syscall.HKEY_CURRENT_USER), uintptr(unsafe.Pointer(path)), 0, uintptr(access), uintptr(unsafe.Pointer(&key)))
	if result != 0 {
		return 0, syscall.Errno(result)
	}
	return key, nil
}
