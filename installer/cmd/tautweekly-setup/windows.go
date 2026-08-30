//go:build windows

package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"unsafe"
)

type installedScheduleConfig struct {
	TaskName string `json:"ScheduledTaskName"`
}

type installedScheduleProbe struct {
	Installed bool `json:"installed"`
	Owned     bool `json:"owned"`
	Running   bool `json:"running"`
}

type verifiedUpdateResult struct {
	Status  string `json:"Status"`
	Version string `json:"Version"`
	Message string `json:"Message"`
}

var (
	user32            = syscall.NewLazyDLL("user32.dll")
	messageBox        = user32.NewProc("MessageBoxW")
	sendMessage       = user32.NewProc("SendMessageW")
	showWindow        = user32.NewProc("ShowWindow")
	setForeground     = user32.NewProc("SetForegroundWindow")
	setWindowPos      = user32.NewProc("SetWindowPos")
	shell32           = syscall.NewLazyDLL("shell32.dll")
	browseForFolder   = shell32.NewProc("SHBrowseForFolderW")
	getFolderPath     = shell32.NewProc("SHGetPathFromIDListW")
	getSpecialFolder  = shell32.NewProc("SHGetFolderPathW")
	ole32             = syscall.NewLazyDLL("ole32.dll")
	coTaskMemFree     = ole32.NewProc("CoTaskMemFree")
	buttonYesNo       = uintptr(0x00000004)
	iconQuestion      = uintptr(0x00000020)
	iconInformation   = uintptr(0x00000040)
	iconError         = uintptr(0x00000010)
	messageForeground = uintptr(0x00010000)
	buttonOK          = uintptr(0x00000000)
	resultYes         = uintptr(6)
)

const elevatedUpdateLauncherScript = `$ErrorActionPreference='Stop';$q=[char]34;$arguments=@('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',($q+$env:TAUTWEEKLY_UPDATE_SCRIPT+$q),'-InstallRoot',($q+$env:TAUTWEEKLY_UPDATE_ROOT+$q),'-CandidateRoot',($q+$env:TAUTWEEKLY_UPDATE_CANDIDATE+$q),'-TargetVersion',$env:TAUTWEEKLY_UPDATE_VERSION,'-ResultPath',($q+$env:TAUTWEEKLY_UPDATE_RESULT+$q),'-ManagerDataRoot',($q+$env:TAUTWEEKLY_UPDATE_DATA+$q));$process=Start-Process -FilePath $env:TAUTWEEKLY_UPDATE_POWERSHELL -ArgumentList $arguments -WorkingDirectory $env:TAUTWEEKLY_UPDATE_CANDIDATE -Verb RunAs -WindowStyle Hidden -PassThru;$process.WaitForExit();exit [int]$process.ExitCode`

type browseInfo struct {
	owner       uintptr
	root        uintptr
	displayName *uint16
	title       *uint16
	flags       uint32
	callback    uintptr
	callbackArg uintptr
	image       int32
}

func chooseInstallDirectory(initial string) (string, bool, error) {
	title, err := syscall.UTF16PtrFromString("Select or create the TautWeekly application folder")
	if err != nil {
		return "", false, err
	}
	initialPath, err := syscall.UTF16PtrFromString(initial)
	if err != nil {
		return "", false, err
	}
	displayName := make([]uint16, 260)
	callback := syscall.NewCallback(func(window, message, _, data uintptr) uintptr {
		if message == 1 { // BFFM_INITIALIZED
			sendMessage.Call(window, 0x467, 1, data) // BFFM_SETSELECTIONW
			showWindow.Call(window, 5)               // SW_SHOW
			// The setup executable has no console or parent window. Briefly place
			// the chooser at the top of the desktop stack so it cannot open behind
			// the browser that launched Setup, then immediately restore normal
			// non-topmost behavior.
			const positionFlags = uintptr(0x0001 | 0x0002 | 0x0040)           // SWP_NOSIZE | SWP_NOMOVE | SWP_SHOWWINDOW
			setWindowPos.Call(window, ^uintptr(0), 0, 0, 0, 0, positionFlags) // HWND_TOPMOST
			setWindowPos.Call(window, ^uintptr(1), 0, 0, 0, 0, positionFlags) // HWND_NOTOPMOST
			setForeground.Call(window)
		}
		return 0
	})
	info := browseInfo{
		displayName: &displayName[0],
		title:       title,
		flags:       0x0001 | 0x0010 | 0x0040, // filesystem folders, edit box, modern dialog
		callback:    callback,
		callbackArg: uintptr(unsafe.Pointer(initialPath)),
	}
	item, _, callErr := browseForFolder.Call(uintptr(unsafe.Pointer(&info)))
	if item == 0 {
		return "", false, nil
	}
	defer coTaskMemFree.Call(item)
	selected := make([]uint16, 32768)
	ok, _, pathErr := getFolderPath.Call(item, uintptr(unsafe.Pointer(&selected[0])))
	if ok == 0 {
		if pathErr != syscall.Errno(0) {
			return "", false, pathErr
		}
		return "", false, callErr
	}
	return syscall.UTF16ToString(selected), true, nil
}

func preferredInstallDirectory(fallback string) string {
	for _, registered := range []struct {
		name      string
		directory func(string) string
	}{
		{name: "InstallLocation", directory: registeredInstallLocation},
		{name: "UninstallString", directory: registeredExecutableDirectory},
		{name: "DisplayIcon", directory: registeredDisplayIconDirectory},
	} {
		value, err := readWindowsUninstallValue(registered.name)
		if err != nil {
			continue
		}
		candidate := registered.directory(value)
		if filepath.IsAbs(candidate) && (installedApplication(candidate) || verifiedPortableApplication(candidate)) {
			return filepath.Clean(candidate)
		}
	}
	return fallback
}

const (
	windowsUninstallRegistrySubkey = `Software\Microsoft\Windows\CurrentVersion\Uninstall\TautWeekly`
	windowsUninstallRegistryKey    = `HKCU\` + windowsUninstallRegistrySubkey
)

var readWindowsUninstallValue = windowsUninstallValue

func windowsUninstallValue(name string) (string, error) {
	path, err := syscall.UTF16PtrFromString(windowsUninstallRegistrySubkey)
	if err != nil {
		return "", err
	}
	var key uintptr
	result, _, _ := managerRegOpenKey.Call(
		uintptr(syscall.HKEY_CURRENT_USER),
		uintptr(unsafe.Pointer(path)),
		0,
		uintptr(managerKeyQuery),
		uintptr(unsafe.Pointer(&key)),
	)
	if result != 0 {
		return "", syscall.Errno(result)
	}
	defer managerRegCloseKey.Call(key)

	valueName, err := syscall.UTF16PtrFromString(name)
	if err != nil {
		return "", err
	}
	var valueType uint32
	var size uint32
	result, _, _ = managerRegQueryValue.Call(
		key,
		uintptr(unsafe.Pointer(valueName)),
		0,
		uintptr(unsafe.Pointer(&valueType)),
		0,
		uintptr(unsafe.Pointer(&size)),
	)
	if result != 0 {
		return "", syscall.Errno(result)
	}
	if valueType != managerRegistrySZ || size < 2 || size > 64<<10 {
		return "", fmt.Errorf("Windows uninstall value %s is not a bounded string", name)
	}
	buffer := make([]uint16, (size+1)/2)
	result, _, _ = managerRegQueryValue.Call(
		key,
		uintptr(unsafe.Pointer(valueName)),
		0,
		uintptr(unsafe.Pointer(&valueType)),
		uintptr(unsafe.Pointer(&buffer[0])),
		uintptr(unsafe.Pointer(&size)),
	)
	if result != 0 {
		return "", syscall.Errno(result)
	}
	if value := strings.TrimSpace(syscall.UTF16ToString(buffer)); value != "" {
		return value, nil
	}
	return "", fmt.Errorf("Windows uninstall value %s is empty", name)
}

func registeredInstallLocation(value string) string {
	return strings.Trim(strings.TrimSpace(value), `"`)
}

func registeredExecutableDirectory(value string) string {
	executable := strings.TrimSpace(value)
	if strings.HasPrefix(executable, `"`) {
		executable = strings.TrimPrefix(executable, `"`)
		if closing := strings.Index(executable, `"`); closing >= 0 {
			executable = executable[:closing]
		}
	} else if separator := strings.IndexAny(executable, " \t"); separator >= 0 {
		executable = executable[:separator]
	}
	if executable == "" {
		return ""
	}
	return filepath.Dir(executable)
}

func registeredDisplayIconDirectory(value string) string {
	icon := strings.TrimSpace(value)
	if comma := strings.LastIndex(icon, ","); comma >= 0 {
		if _, err := strconv.Atoi(strings.TrimSpace(icon[comma+1:])); err == nil {
			icon = icon[:comma]
		}
	}
	icon = strings.Trim(strings.TrimSpace(icon), `"`)
	if icon == "" {
		return ""
	}
	return filepath.Dir(icon)
}

func hiddenCommand(name string, args ...string) *exec.Cmd {
	command := exec.Command(name, args...)
	hideProcessWindow(command)
	return command
}

func applyVerifiedUpdate(opts options, candidateRoot, targetVersion string) error {
	updateScript := filepath.Join(candidateRoot, "Windows-Update.ps1")
	if info, err := os.Stat(updateScript); err != nil || !info.Mode().IsRegular() {
		return errors.New("the verified update helper is unavailable")
	}
	systemRoot := strings.TrimSpace(os.Getenv("SystemRoot"))
	if systemRoot == "" {
		return errors.New("Windows system directory is unavailable")
	}
	powerShellPath := filepath.Join(systemRoot, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
	if info, err := os.Stat(powerShellPath); err != nil || !info.Mode().IsRegular() {
		return errors.New("Windows PowerShell is unavailable")
	}

	resultFile, err := os.CreateTemp(opts.dataDir, ".installer-update-*.json")
	if err != nil {
		return fmt.Errorf("create private update result: %w", err)
	}
	resultPath := resultFile.Name()
	if err := resultFile.Close(); err != nil {
		return fmt.Errorf("close private update result: %w", err)
	}
	_ = os.Remove(resultPath)
	defer os.Remove(resultPath)

	arguments := []string{
		"-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
		"-File", updateScript,
		"-InstallRoot", opts.installDir,
		"-CandidateRoot", candidateRoot,
		"-TargetVersion", targetVersion,
		"-ResultPath", resultPath,
		"-ManagerDataRoot", opts.dataDir,
	}
	var command *exec.Cmd
	if opts.testMode {
		arguments = append(arguments, "-InstallerTestMode")
		command = hiddenCommand(powerShellPath, arguments...)
	} else {
		command = hiddenCommand(powerShellPath, "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", elevatedUpdateLauncherScript)
		command.Env = append(os.Environ(),
			"TAUTWEEKLY_UPDATE_POWERSHELL="+powerShellPath,
			"TAUTWEEKLY_UPDATE_SCRIPT="+updateScript,
			"TAUTWEEKLY_UPDATE_ROOT="+opts.installDir,
			"TAUTWEEKLY_UPDATE_CANDIDATE="+candidateRoot,
			"TAUTWEEKLY_UPDATE_VERSION="+targetVersion,
			"TAUTWEEKLY_UPDATE_RESULT="+resultPath,
			"TAUTWEEKLY_UPDATE_DATA="+opts.dataDir,
		)
	}
	output, runErr := command.CombinedOutput()
	raw, readErr := os.ReadFile(resultPath)
	var result verifiedUpdateResult
	if readErr == nil {
		raw = bytes.TrimPrefix(raw, []byte{0xEF, 0xBB, 0xBF})
		if err := json.Unmarshal(raw, &result); err != nil {
			return fmt.Errorf("verified update helper returned an invalid result: %w", err)
		}
	}
	if runErr != nil {
		if message := strings.TrimSpace(result.Message); message != "" {
			return fmt.Errorf("verified update failed: %s", message)
		}
		return fmt.Errorf("verified update helper failed: %w: %s", runErr, strings.TrimSpace(string(output)))
	}
	if readErr != nil {
		return errors.New("verified update helper did not return a result")
	}
	if !strings.EqualFold(strings.TrimSpace(result.Status), "success") || strings.TrimSpace(result.Version) != targetVersion {
		return errors.New("verified update helper did not confirm the requested version")
	}
	return nil
}

func hideProcessWindow(command *exec.Cmd) {
	command.SysProcAttr = &syscall.SysProcAttr{
		HideWindow:       true,
		CreationFlags:    0x08000000,
		NoInheritHandles: true,
	}
}

func confirmAction(title, message string, testMode bool) (bool, error) {
	if testMode {
		return true, nil
	}
	result, err := showMessage(title, message, buttonYesNo|iconQuestion|messageForeground)
	return result == resultYes, err
}

func showCompletion(title, message string, suppressed bool) error {
	if suppressed {
		return nil
	}
	_, err := showMessage(title, message, buttonOK|iconInformation|messageForeground)
	return err
}

func showFailure(title, message string, suppressed bool) error {
	if suppressed {
		return nil
	}
	_, err := showMessage(title, message, buttonOK|iconError|messageForeground)
	return err
}

func showMessage(title, message string, style uintptr) (uintptr, error) {
	titlePointer, err := syscall.UTF16PtrFromString(title)
	if err != nil {
		return 0, err
	}
	messagePointer, err := syscall.UTF16PtrFromString(message)
	if err != nil {
		return 0, err
	}
	result, _, callErr := messageBox.Call(0, uintptr(unsafe.Pointer(messagePointer)), uintptr(unsafe.Pointer(titlePointer)), style)
	if result == 0 {
		return 0, callErr
	}
	return result, nil
}

func registerUninstaller(opts options) error {
	uninstaller := filepath.Join(opts.installDir, "TautWeekly-Uninstall.exe")
	key := windowsUninstallRegistryKey
	values := [][]string{
		{"add", key, "/v", "DisplayName", "/t", "REG_SZ", "/d", productName, "/f"},
		{"add", key, "/v", "DisplayVersion", "/t", "REG_SZ", "/d", version, "/f"},
		{"add", key, "/v", "Publisher", "/t", "REG_SZ", "/d", "sparkmoxie", "/f"},
		{"add", key, "/v", "InstallLocation", "/t", "REG_SZ", "/d", opts.installDir, "/f"},
		{"add", key, "/v", "DisplayIcon", "/t", "REG_SZ", "/d", filepath.Join(opts.installDir, "tautweekly.ico"), "/f"},
		{"add", key, "/v", "UninstallString", "/t", "REG_SZ", "/d", windowsQuote(uninstaller), "/f"},
		{"add", key, "/v", "NoModify", "/t", "REG_DWORD", "/d", "1", "/f"},
		{"add", key, "/v", "NoRepair", "/t", "REG_DWORD", "/d", "1", "/f"},
	}
	for _, args := range values {
		if output, err := hiddenCommand("reg.exe", args...).CombinedOutput(); err != nil {
			return fmt.Errorf("register uninstaller: %w: %s", err, output)
		}
	}
	return nil
}

func unregisterUninstaller() error {
	output, err := hiddenCommand("reg.exe", "delete", windowsUninstallRegistryKey, "/f").CombinedOutput()
	if err != nil {
		return fmt.Errorf("unregister uninstaller: %w: %s", err, output)
	}
	return nil
}

var (
	resolveWindowsSpecialFolder = windowsSpecialFolder
	queryWindowsSpecialFolder   = nativeWindowsSpecialFolder
	writeWindowsShortcut        = createShortcut
)

func createShortcuts(opts options, logger *log.Logger) error {
	programs, err := resolveWindowsSpecialFolder("Programs")
	if err != nil {
		return fmt.Errorf("resolve Windows Start menu: %w", err)
	}
	startMenu := filepath.Join(programs, "TautWeekly")
	if err := os.MkdirAll(startMenu, 0o755); err != nil {
		return fmt.Errorf("create Windows Start menu folder: %w", err)
	}
	systemRoot := os.Getenv("SystemRoot")
	if systemRoot == "" {
		return fmt.Errorf("resolve Windows PowerShell location")
	}
	target := filepath.Join(systemRoot, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
	arguments := fmt.Sprintf(`-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "%s" -DataRoot "%s"`, filepath.Join(opts.installDir, "START-MANAGER.ps1"), opts.dataDir)
	icon := filepath.Join(opts.installDir, "tautweekly.ico")
	if err := writeWindowsShortcut(filepath.Join(startMenu, launcherName), target, arguments, opts.installDir, icon); err != nil {
		return err
	}
	resetArguments := fmt.Sprintf(`-NoLogo -NoProfile -ExecutionPolicy Bypass -File "%s" -DataRoot "%s"`, filepath.Join(opts.installDir, "RESET-MANAGER-ACCESS.ps1"), opts.dataDir)
	if err := writeWindowsShortcut(filepath.Join(startMenu, resetLauncherName), target, resetArguments, opts.installDir, icon); err != nil {
		return err
	}

	desktop, err := resolveWindowsSpecialFolder("Desktop")
	if err != nil {
		logger.Printf("desktop shortcut skipped: %v", err)
		return nil
	}
	if info, statErr := os.Stat(desktop); statErr != nil || !info.IsDir() {
		if statErr != nil {
			logger.Printf("desktop shortcut skipped: resolved Desktop is unavailable: %v", statErr)
		} else {
			logger.Printf("desktop shortcut skipped: resolved Desktop is not a directory")
		}
		return nil
	}
	if err := writeWindowsShortcut(filepath.Join(desktop, launcherName), target, arguments, opts.installDir, icon); err != nil {
		logger.Printf("desktop shortcut skipped: %v", err)
	}
	return nil
}

func windowsSpecialFolder(name string) (string, error) {
	path, nativeErr := queryWindowsSpecialFolder(name)
	if cleaned, ok := cleanAbsoluteWindowsPath(path); ok {
		return cleaned, nil
	}
	if fallback, ok := fallbackWindowsSpecialFolder(name); ok {
		return fallback, nil
	}
	if nativeErr != nil {
		return "", fmt.Errorf("resolve %s shell folder: %w", name, nativeErr)
	}
	return "", fmt.Errorf("resolve %s shell folder: Windows returned an invalid path", name)
}

func nativeWindowsSpecialFolder(name string) (string, error) {
	var folderID uintptr
	switch name {
	case "Programs":
		folderID = 0x0002 // CSIDL_PROGRAMS
	case "Desktop":
		folderID = 0x0010 // CSIDL_DESKTOPDIRECTORY
	default:
		return "", fmt.Errorf("unsupported Windows shell folder %q", name)
	}
	if err := getSpecialFolder.Find(); err != nil {
		return "", fmt.Errorf("load SHGetFolderPathW: %w", err)
	}
	buffer := make([]uint16, 260) // SHGetFolderPathW is defined for MAX_PATH.
	result, _, callErr := getSpecialFolder.Call(
		0,
		folderID,
		0,
		0, // SHGFP_TYPE_CURRENT
		uintptr(unsafe.Pointer(&buffer[0])),
	)
	if result != 0 {
		return "", fmt.Errorf("SHGetFolderPathW returned HRESULT 0x%08x: %v", uint32(result), callErr)
	}
	return syscall.UTF16ToString(buffer), nil
}

func fallbackWindowsSpecialFolder(name string) (string, bool) {
	switch name {
	case "Programs":
		if appData, ok := cleanAbsoluteWindowsPath(os.Getenv("APPDATA")); ok {
			return filepath.Join(appData, "Microsoft", "Windows", "Start Menu", "Programs"), true
		}
		if profile, ok := cleanAbsoluteWindowsPath(os.Getenv("USERPROFILE")); ok {
			return filepath.Join(profile, "AppData", "Roaming", "Microsoft", "Windows", "Start Menu", "Programs"), true
		}
	case "Desktop":
		if profile, ok := cleanAbsoluteWindowsPath(os.Getenv("USERPROFILE")); ok {
			return filepath.Join(profile, "Desktop"), true
		}
	}
	return "", false
}

func cleanAbsoluteWindowsPath(path string) (string, bool) {
	path = strings.TrimSpace(path)
	if path == "" || !filepath.IsAbs(path) {
		return "", false
	}
	return filepath.Clean(path), true
}

func createShortcut(destination, target, arguments, workingDirectory, icon string) error {
	script := `$s=(New-Object -ComObject WScript.Shell).CreateShortcut($env:TAUTWEEKLY_SHORTCUT_DESTINATION);$s.TargetPath=$env:TAUTWEEKLY_SHORTCUT_TARGET;$s.Arguments=$env:TAUTWEEKLY_SHORTCUT_ARGUMENTS;$s.WorkingDirectory=$env:TAUTWEEKLY_SHORTCUT_WORKING;$s.IconLocation=$env:TAUTWEEKLY_SHORTCUT_ICON;$s.WindowStyle=7;$s.Save()`
	command := hiddenCommand("powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script)
	command.Env = append(os.Environ(),
		"TAUTWEEKLY_SHORTCUT_DESTINATION="+destination,
		"TAUTWEEKLY_SHORTCUT_TARGET="+target,
		"TAUTWEEKLY_SHORTCUT_ARGUMENTS="+arguments,
		"TAUTWEEKLY_SHORTCUT_WORKING="+workingDirectory,
		"TAUTWEEKLY_SHORTCUT_ICON="+icon,
	)
	output, err := command.CombinedOutput()
	if err != nil {
		return fmt.Errorf("create shortcut: %w: %s", err, output)
	}
	return nil
}

func removeShortcuts() error {
	programs, err := resolveWindowsSpecialFolder("Programs")
	if err != nil {
		return fmt.Errorf("resolve Windows Start menu: %w", err)
	}
	paths := []string{
		filepath.Join(programs, "TautWeekly"),
	}
	if desktop, desktopErr := resolveWindowsSpecialFolder("Desktop"); desktopErr == nil {
		paths = append(paths, filepath.Join(desktop, launcherName))
	}
	// v0.11.0 guessed this legacy path instead of consulting Windows. Remove a
	// stale launcher there when it differs from the current shell Desktop.
	if userProfile := strings.TrimSpace(os.Getenv("USERPROFILE")); userProfile != "" {
		paths = append(paths, filepath.Join(userProfile, "Desktop", launcherName))
	}
	for _, path := range paths {
		if err := os.RemoveAll(path); err != nil {
			return err
		}
	}
	return nil
}

func stopInstalledManager(root string, testMode bool) (bool, error) {
	if testMode {
		return false, nil
	}
	manager := filepath.Join(root, "tautweekly-manager.exe")
	if _, err := os.Stat(manager); err != nil {
		if os.IsNotExist(err) {
			return false, nil
		}
		return false, err
	}
	script := `$expected=[IO.Path]::GetFullPath($env:TAUTWEEKLY_MANAGER_PATH);$root=[IO.Path]::GetFullPath($env:TAUTWEEKLY_MANAGER_ROOT);$find={@(Get-Process -Name 'tautweekly-manager' -ErrorAction SilentlyContinue|Where-Object{try{[IO.Path]::GetFullPath([string]$_.Path)-ieq $expected}catch{$false}})};$found=@(&$find);if($found.Count-gt 0){try{& $expected shutdown --listen=127.0.0.1:8788 "--tautweekly-root=$root" 2>$null}catch{};$deadline=(Get-Date).AddSeconds(10);foreach($process in $found){$remaining=[Math]::Max(0,[int]($deadline-(Get-Date)).TotalMilliseconds);if((-not $process.HasExited)-and($remaining-gt 0)){[void]$process.WaitForExit($remaining)}};$remaining=@(&$find);foreach($process in $remaining){Stop-Process -Id $process.Id -Force -ErrorAction Stop};foreach($process in $remaining){if(-not $process.WaitForExit(10000)){throw 'Manager did not exit'}};'stopped'}`
	command := hiddenCommand("powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script)
	command.Env = append(os.Environ(), "TAUTWEEKLY_MANAGER_PATH="+manager, "TAUTWEEKLY_MANAGER_ROOT="+root)
	output, err := command.CombinedOutput()
	if err != nil {
		return false, fmt.Errorf("stop the installed Manager before upgrade: %w: %s", err, output)
	}
	return strings.TrimSpace(string(output)) == "stopped", nil
}

func removeInstalledSchedule(root string, testMode bool) error {
	if testMode {
		return nil
	}
	configPath := filepath.Join(root, "config.json")
	raw, err := os.ReadFile(configPath)
	if err != nil {
		if os.IsNotExist(err) {
			return refuseDanglingSchedule(root)
		}
		return fmt.Errorf("inspect scheduled task configuration: %w", err)
	}
	var config installedScheduleConfig
	if err := json.Unmarshal(raw, &config); err != nil {
		return fmt.Errorf("inspect scheduled task configuration: %w", err)
	}
	taskName := strings.TrimSpace(config.TaskName)
	if taskName == "" {
		taskName = "TautWeekly for Plex Newsletter"
	}
	probeScript := `$ErrorActionPreference='Stop';$task=Get-ScheduledTask -TaskName $env:TAUTWEEKLY_SETUP_TASK -ErrorAction SilentlyContinue;if($null -eq $task){[pscustomobject]@{installed=$false;owned=$false;running=$false}|ConvertTo-Json -Compress;exit 0};$engine=Join-Path $env:TAUTWEEKLY_SETUP_ROOT 'TautWeekly.ps1';$result=Join-Path $env:TAUTWEEKLY_SETUP_ROOT 'last-run.json';$expected='-NoProfile -ExecutionPolicy Bypass -File "{0}" -Mode SendAll -ResultPath "{1}" -ConfirmSendAll' -f $engine,$result;$actions=@($task.Actions);$owned=$false;if($actions.Count -eq 1){$action=$actions[0];try{$working=[IO.Path]::GetFullPath([string]$action.WorkingDirectory).TrimEnd('\');$root=[IO.Path]::GetFullPath($env:TAUTWEEKLY_SETUP_ROOT).TrimEnd('\');$owned=([IO.Path]::GetFileName([string]$action.Execute)-ieq 'powershell.exe')-and([string]$action.Arguments-ieq $expected)-and($working-ieq $root)-and([string]$task.Principal.UserId-ieq 'SYSTEM')}catch{$owned=$false}};[pscustomobject]@{installed=$true;owned=$owned;running=([string]$task.State -eq 'Running')}|ConvertTo-Json -Compress`
	probeCommand := hiddenCommand("powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", probeScript)
	probeCommand.Env = append(os.Environ(), "TAUTWEEKLY_SETUP_TASK="+taskName, "TAUTWEEKLY_SETUP_ROOT="+root)
	output, err := probeCommand.Output()
	if err != nil {
		return fmt.Errorf("inspect Windows Scheduled Task before removal")
	}
	var probe installedScheduleProbe
	if err := json.Unmarshal(output, &probe); err != nil {
		return fmt.Errorf("inspect Windows Scheduled Task before removal")
	}
	if !probe.Installed {
		return nil
	}
	if !probe.Owned {
		return fmt.Errorf("a same-named Windows Scheduled Task is not owned by this installation; it was not changed")
	}
	if probe.Running {
		return fmt.Errorf("the scheduled newsletter is currently running; wait for it to finish before removing TautWeekly")
	}
	revision := sha256.Sum256(raw)
	helper := filepath.Join(root, "SCHEDULE-HELPER.ps1")
	if info, err := os.Stat(helper); err != nil || !info.Mode().IsRegular() {
		return fmt.Errorf("the verified schedule helper is unavailable; remove the owned schedule from the Manager before uninstalling")
	}
	command := hiddenCommand("powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", helper, "-Action", "Remove", "-ExpectedRevision", hex.EncodeToString(revision[:]))
	command.Dir = root
	if output, err := command.CombinedOutput(); err != nil {
		return fmt.Errorf("remove the owned Windows Scheduled Task before uninstalling: %w: %s", err, output)
	}
	return nil
}

func refuseDanglingSchedule(root string) error {
	// Without config.json the verified helper cannot safely reproduce the task
	// name or configuration revision needed for removal. Still inspect all tasks
	// for the narrow action/working-directory/SYSTEM signature so uninstall can
	// refuse to orphan an owned task that points at files it is about to remove.
	script := `$ErrorActionPreference='Stop';$root=[IO.Path]::GetFullPath($env:TAUTWEEKLY_SETUP_ROOT).TrimEnd('\');$matches=@(Get-ScheduledTask|Where-Object{$task=$_;$actions=@($task.Actions);if($actions.Count-ne 1){return $false};$action=$actions[0];try{$working=[IO.Path]::GetFullPath([string]$action.WorkingDirectory).TrimEnd('\');([IO.Path]::GetFileName([string]$action.Execute)-ieq 'powershell.exe')-and($working-ieq $root)-and([string]$task.Principal.UserId-ieq 'SYSTEM')}catch{$false}});$matches|ForEach-Object{$_.TaskName}`
	command := hiddenCommand("powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script)
	command.Env = append(os.Environ(), "TAUTWEEKLY_SETUP_ROOT="+root)
	output, err := command.CombinedOutput()
	if err != nil {
		return fmt.Errorf("cannot safely inspect Windows Scheduled Tasks before removal: %w", err)
	}
	if strings.TrimSpace(string(output)) != "" {
		return fmt.Errorf("a Windows Scheduled Task still points at this installation, but config.json is missing; restore the configuration and remove the schedule from the Manager before uninstalling")
	}
	return nil
}

func scheduleSelfRemoval(executable, root string) error {
	// Never recursively remove the installation root: unowned configuration,
	// output, cache, and custom files intentionally survive uninstall. The
	// non-recursive rmdir succeeds only when no preserved material remains.
	cleanupPath := filepath.Join(os.TempDir(), fmt.Sprintf("tautweekly-uninstall-%d.delete", os.Getpid()))
	if err := os.Rename(executable, cleanupPath); err != nil {
		cleanupPath = executable
	}
	command := `ping 127.0.0.1 -n 3 >nul & del /f /q "%TAUTWEEKLY_REMOVE_EXE%" & rmdir "%TAUTWEEKLY_REMOVE_ROOT%"`
	process := exec.Command("cmd.exe", "/d", "/c", command)
	hideProcessWindow(process)
	process.Env = append(os.Environ(), "TAUTWEEKLY_REMOVE_EXE="+cleanupPath, "TAUTWEEKLY_REMOVE_ROOT="+root)
	if err := process.Start(); err != nil {
		return err
	}
	return process.Process.Release()
}

func windowsQuote(value string) string {
	return `"` + strings.ReplaceAll(value, `"`, `\"`) + `"`
}
