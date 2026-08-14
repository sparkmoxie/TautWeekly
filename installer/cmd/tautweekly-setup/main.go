package main

import (
	"archive/zip"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

const (
	productName       = "TautWeekly for Plex"
	installFolderName = "TautWeekly"
	launcherName      = "Open TautWeekly Manager.lnk"
	resetLauncherName = "Reset TautWeekly Manager Access.lnk"
)

var version = "local"

type options struct {
	uninstall          bool
	testMode           bool
	noLaunch           bool
	installDir         string
	installDirExplicit bool
	dataDir            string
	logPath            string
}

func main() {
	args := os.Args[1:]
	if uninstallerOnly && !hasArgument(args, "--uninstall") {
		args = append([]string{"--uninstall"}, args...)
	}
	if err := run(args); err != nil {
		log.Printf("ERROR: %v", err)
		_ = showFailure("TautWeekly setup could not finish", err.Error(), hasArgument(os.Args[1:], "--test-mode"))
		os.Exit(1)
	}
}

func run(args []string) error {
	opts, err := parseOptions(args)
	if err != nil {
		return err
	}
	if !opts.uninstall && !opts.testMode && !opts.installDirExplicit {
		previousInstallDir := opts.installDir
		selected, accepted, err := chooseInstallDirectory(opts.installDir)
		if err != nil {
			return err
		}
		if !accepted {
			return nil
		}
		opts.installDir = selected
		if err := normalizeAndValidatePaths(&opts); err != nil {
			return err
		}
		if !samePath(previousInstallDir, opts.installDir) && installedApplication(previousInstallDir) {
			return fmt.Errorf("TautWeekly is already installed at:\n%s\n\nRun Setup again and keep that folder to update it safely. To change the application folder, remove the existing app first; private configuration and history will be preserved", previousInstallDir)
		}
	}
	logger, closeLog, err := newLogger(opts.logPath)
	if err != nil {
		return err
	}
	defer closeLog()

	if opts.uninstall {
		confirmed, err := confirmAction("Remove TautWeekly", "Remove TautWeekly application files and shortcuts?\n\nYour configuration, history, previews, logs, and Manager data will be preserved.", opts.testMode)
		if err != nil || !confirmed {
			return err
		}
		if err := uninstall(opts, logger); err != nil {
			logger.Printf("uninstall failed: %v", err)
			return fmt.Errorf("Removal stopped safely. No private data was removed.\n\nReview the installer log for details:\n%s", opts.logPath)
		}
		return showCompletion("TautWeekly removed", "TautWeekly application files and shortcuts were removed. Private configuration and runtime data were preserved.", opts.testMode)
	}
	action := "Install"
	if installedApplication(opts.installDir) {
		action = "Update"
	} else if verifiedPortableApplication(opts.installDir) {
		action = "Migrate"
	}
	confirmed, err := confirmAction(action+" TautWeekly", fmt.Sprintf("%s %s %s for this Windows account?\n\nApplication files:\n%s\n\nPrivate configuration, history, previews, and logs are preserved.", action, productName, version, opts.installDir), opts.testMode)
	if err != nil || !confirmed {
		return err
	}
	if err := install(opts, logger); err != nil {
		logger.Printf("install failed: %v", err)
		return fmt.Errorf("Installation stopped safely. Existing configuration and history were not removed.\n\nReview the installer log for details:\n%s", opts.logPath)
	}
	return finishInstallation(opts, showCompletion, startDetached)
}

func finishInstallation(opts options, completion func(string, string, bool) error, launch func(string, string) error) error {
	completionErr := completion("TautWeekly is ready", installationCompletionMessage(opts.noLaunch), opts.testMode)
	if !opts.noLaunch && !opts.testMode {
		if err := launch(filepath.Join(opts.installDir, "Open-TautWeekly.cmd"), opts.installDir); err != nil {
			return fmt.Errorf("open installed Manager: %w", err)
		}
	}
	return completionErr
}

func installationCompletionMessage(noLaunch bool) string {
	message := "Installation completed successfully.\n\nUse Open TautWeekly Manager in the Start menu."
	if !noLaunch {
		message += "\n\nThe local Manager will now open in your browser."
	}
	return message
}

func hasArgument(args []string, wanted string) bool {
	for _, argument := range args {
		if argument == wanted {
			return true
		}
	}
	return false
}

func parseOptions(args []string) (options, error) {
	var opts options
	opts.installDirExplicit = hasOption(args, "--install-dir")
	flags := flag.NewFlagSet("TautWeekly-Setup", flag.ContinueOnError)
	flags.BoolVar(&opts.uninstall, "uninstall", false, "remove installed application files and shortcuts")
	flags.BoolVar(&opts.testMode, "test-mode", false, "skip registry, shortcuts, and process launch")
	flags.BoolVar(&opts.noLaunch, "no-launch", false, "do not open the Manager after installation")
	flags.StringVar(&opts.installDir, "install-dir", "", "explicit installation directory")
	flags.StringVar(&opts.dataDir, "data-dir", "", "explicit private data directory")
	flags.StringVar(&opts.logPath, "log", "", "explicit installer log path")
	if err := flags.Parse(args); err != nil {
		return options{}, err
	}
	if flags.NArg() != 0 {
		return options{}, fmt.Errorf("unexpected arguments: %s", strings.Join(flags.Args(), " "))
	}

	localAppData := os.Getenv("LOCALAPPDATA")
	if localAppData == "" {
		var err error
		localAppData, err = os.UserConfigDir()
		if err != nil {
			return options{}, fmt.Errorf("resolve local application data: %w", err)
		}
	}
	if opts.installDir == "" {
		if uninstallerOnly {
			executable, err := os.Executable()
			if err != nil {
				return options{}, fmt.Errorf("resolve installed uninstaller location: %w", err)
			}
			opts.installDir = filepath.Dir(executable)
		} else {
			opts.installDir = preferredInstallDirectory(filepath.Join(localAppData, "Programs", installFolderName))
		}
	}
	if opts.dataDir == "" {
		if uninstallerOnly {
			storedDataDir, err := installedDataDirectory(opts.installDir)
			if err != nil {
				return options{}, err
			}
			opts.dataDir = storedDataDir
		}
		if opts.dataDir == "" {
			opts.dataDir = filepath.Join(localAppData, installFolderName, "data")
		}
	}
	if opts.logPath == "" {
		opts.logPath = filepath.Join(localAppData, installFolderName, "installer.log")
	}
	if err := normalizeAndValidatePaths(&opts); err != nil {
		return options{}, err
	}
	return opts, nil
}

func hasOption(args []string, wanted string) bool {
	for _, argument := range args {
		if argument == wanted || strings.HasPrefix(argument, wanted+"=") {
			return true
		}
	}
	return false
}

func normalizeAndValidatePaths(opts *options) error {
	for name, value := range map[string]string{
		"install directory": opts.installDir,
		"data directory":    opts.dataDir,
		"log path":          opts.logPath,
	} {
		absolute, err := filepath.Abs(value)
		if err != nil {
			return fmt.Errorf("resolve %s: %w", name, err)
		}
		switch name {
		case "install directory":
			opts.installDir = absolute
		case "data directory":
			opts.dataDir = absolute
		case "log path":
			opts.logPath = absolute
		}
	}
	if samePath(opts.installDir, opts.dataDir) || pathWithin(opts.installDir, opts.dataDir) || pathWithin(opts.dataDir, opts.installDir) {
		return errors.New("private data directory must be outside the application installation directory")
	}
	return nil
}

func installedDataDirectory(installDir string) (string, error) {
	content, err := os.ReadFile(filepath.Join(installDir, "INSTALL-METADATA.txt"))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return "", nil
		}
		return "", fmt.Errorf("read installed data-directory metadata: %w", err)
	}
	for _, line := range strings.Split(strings.ReplaceAll(string(content), "\r\n", "\n"), "\n") {
		key, value, found := strings.Cut(line, "=")
		if found && strings.EqualFold(strings.TrimSpace(key), "DataDirectory") {
			return strings.TrimSpace(value), nil
		}
	}
	return "", nil
}

func newLogger(path string) (*log.Logger, func(), error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, nil, fmt.Errorf("create installer log directory: %w", err)
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return nil, nil, fmt.Errorf("open installer log: %w", err)
	}
	return log.New(file, "", log.Ldate|log.Ltime|log.LUTC), func() { _ = file.Close() }, nil
}

func install(opts options, logger *log.Logger) error {
	logger.Printf("install start version=%s test=%t", version, opts.testMode)
	if err := verifyPayload(); err != nil {
		return err
	}
	if err := os.MkdirAll(opts.dataDir, 0o700); err != nil {
		return fmt.Errorf("create private data directory: %w", err)
	}

	parent := filepath.Dir(opts.installDir)
	if err := os.MkdirAll(parent, 0o755); err != nil {
		return fmt.Errorf("create installation parent: %w", err)
	}
	if err := validateInstallTarget(opts.installDir); err != nil {
		return err
	}
	updatingExisting := installedApplication(opts.installDir) || verifiedPortableApplication(opts.installDir)
	staging, err := os.MkdirTemp(parent, ".tautweekly-install-")
	if err != nil {
		return fmt.Errorf("create installation staging directory: %w", err)
	}
	defer os.RemoveAll(staging)

	if err := extractPayload(staging); err != nil {
		return err
	}
	packageRoot := filepath.Join(staging, "TautWeekly-windows")
	if err := validatePackage(packageRoot); err != nil {
		return err
	}
	managerWasRunning := false
	managerRestarted := false
	installSucceeded := false
	if updatingExisting {
		if err := migrateLegacyManagerData(opts.installDir, opts.dataDir); err != nil {
			return err
		}
		if err := applyVerifiedUpdate(opts, packageRoot, version); err != nil {
			return err
		}
		if err := writeInstalledLaunchers(opts.installDir, opts.dataDir); err != nil {
			return err
		}
		if err := writeInstallMetadata(opts.installDir, opts); err != nil {
			return err
		}
		if err := os.RemoveAll(filepath.Join(opts.installDir, ".manager-data")); err != nil {
			return fmt.Errorf("remove migrated legacy Manager state: %w", err)
		}
	} else {
		if err := writeInstalledLaunchers(packageRoot, opts.dataDir); err != nil {
			return err
		}
		if err := writeFile(filepath.Join(packageRoot, "tautweekly.ico"), applicationIcon, 0o644); err != nil {
			return err
		}
		if err := writeInstallMetadata(packageRoot, opts); err != nil {
			return err
		}
		var err error
		managerWasRunning, err = stopInstalledManager(opts.installDir, opts.testMode)
		if err != nil {
			return err
		}
		defer func() {
			if managerWasRunning && !managerRestarted && !installSucceeded {
				_ = startDetached(filepath.Join(opts.installDir, "Open-TautWeekly.cmd"), opts.installDir)
			}
		}()
		if err := replaceDirectory(packageRoot, opts.installDir); err != nil {
			return err
		}
	}

	if !opts.testMode {
		if err := registerUninstaller(opts); err != nil {
			return err
		}
		if err := createShortcuts(opts, logger); err != nil {
			return err
		}
	}
	logger.Printf("install complete version=%s", version)
	if managerWasRunning && opts.noLaunch && !opts.testMode {
		if err := startDetached(filepath.Join(opts.installDir, "Open-TautWeekly.cmd"), opts.installDir); err != nil {
			return fmt.Errorf("open installed Manager: %w", err)
		}
		managerRestarted = true
	}
	installSucceeded = true
	return nil
}

func validateInstallTarget(root string) error {
	entries, err := os.ReadDir(root)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("inspect installation directory: %w", err)
	}
	if len(entries) == 0 {
		return nil
	}
	marker := filepath.Join(root, "INSTALL-METADATA.txt")
	if info, err := os.Stat(marker); err == nil && info.Mode().IsRegular() {
		return nil
	}
	// A verified portable release has no installer marker yet, but its exact
	// release-owned file manifest makes it safe to preserve private material and
	// convert the folder into a normal installed application.
	for _, required := range []string{"TautWeekly.ps1", "RELEASE-FILES.txt", "RELEASE-METADATA.txt"} {
		if info, err := os.Stat(filepath.Join(root, required)); err != nil || !info.Mode().IsRegular() {
			return errors.New("the selected installation directory is not empty and is not a verified TautWeekly installation or portable release")
		}
	}
	if _, err := readOwnedPaths(root); err != nil {
		return errors.New("the selected portable TautWeekly folder has an invalid release ownership manifest")
	}
	return nil
}

func installedApplication(root string) bool {
	info, err := os.Stat(filepath.Join(root, "INSTALL-METADATA.txt"))
	return err == nil && info.Mode().IsRegular()
}

func verifiedPortableApplication(root string) bool {
	if installedApplication(root) {
		return false
	}
	for _, required := range []string{"TautWeekly.ps1", "RELEASE-FILES.txt", "RELEASE-METADATA.txt"} {
		if info, err := os.Stat(filepath.Join(root, required)); err != nil || !info.Mode().IsRegular() {
			return false
		}
	}
	_, err := readOwnedPaths(root)
	return err == nil
}

func uninstall(opts options, logger *log.Logger) error {
	logger.Printf("uninstall start test=%t", opts.testMode)
	if err := removeInstalledSchedule(opts.installDir, opts.testMode); err != nil {
		return err
	}
	managerWasRunning, err := stopInstalledManager(opts.installDir, opts.testMode)
	if err != nil {
		return err
	}
	if !opts.testMode {
		_ = removeShortcuts()
		_ = unregisterUninstaller()
	}
	if err := removeOwnedInstall(opts.installDir); err != nil {
		if managerWasRunning {
			_ = startDetached(filepath.Join(opts.installDir, "Open-TautWeekly.cmd"), opts.installDir)
		}
		return err
	}
	logger.Printf("uninstall complete private-data-preserved=%s", opts.dataDir)
	return nil
}

func verifyPayload() error {
	if len(payload) == 0 || len(applicationIcon) == 0 {
		return errors.New("installer payload was not generated by the release builder")
	}
	expected := strings.ToLower(strings.TrimSpace(payloadHashText))
	if len(expected) != sha256.Size*2 {
		return errors.New("embedded payload checksum is invalid")
	}
	sum := sha256.Sum256(payload)
	actual := hex.EncodeToString(sum[:])
	if actual != expected {
		return errors.New("embedded payload checksum verification failed")
	}
	return nil
}

func extractPayload(destination string) error {
	archive, err := zip.NewReader(bytes.NewReader(payload), int64(len(payload)))
	if err != nil {
		return fmt.Errorf("open embedded payload: %w", err)
	}
	for _, entry := range archive.File {
		name := filepath.FromSlash(entry.Name)
		if filepath.IsAbs(name) || filepath.VolumeName(name) != "" {
			return fmt.Errorf("payload contains an absolute path: %s", entry.Name)
		}
		target := filepath.Clean(filepath.Join(destination, name))
		if !pathWithin(destination, target) {
			return fmt.Errorf("payload path escapes staging: %s", entry.Name)
		}
		if entry.FileInfo().IsDir() {
			if err := os.MkdirAll(target, 0o755); err != nil {
				return err
			}
			continue
		}
		if entry.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("payload contains a symbolic link: %s", entry.Name)
		}
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return err
		}
		reader, err := entry.Open()
		if err != nil {
			return err
		}
		file, err := os.OpenFile(target, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o644)
		if err != nil {
			reader.Close()
			return err
		}
		_, copyErr := io.Copy(file, reader)
		closeErr := file.Close()
		readerErr := reader.Close()
		if copyErr != nil {
			return copyErr
		}
		if closeErr != nil {
			return closeErr
		}
		if readerErr != nil {
			return readerErr
		}
	}
	return nil
}

func validatePackage(root string) error {
	required := []string{
		"tautweekly-manager.exe",
		"TautWeekly-Uninstall.exe",
		"TautWeekly.ps1",
		"SCHEDULE-HELPER.ps1",
		"RESET-MANAGER-ACCESS.ps1",
		"RELEASE-FILES.txt",
		"RELEASE-METADATA.txt",
	}
	for _, name := range required {
		if info, err := os.Stat(filepath.Join(root, name)); err != nil || info.IsDir() {
			return fmt.Errorf("embedded package is missing %s", name)
		}
	}
	return nil
}

func writeInstalledLaunchers(root, dataDir string) error {
	launcher := "@echo off\r\n" +
		"cd /d \"%~dp0\"\r\n" +
		"powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"%~dp0START-MANAGER.ps1\" -DataRoot \"" + escapeBatch(dataDir) + "\"\r\n"
	if err := writeFile(filepath.Join(root, "Open-TautWeekly.cmd"), []byte(launcher), 0o644); err != nil {
		return fmt.Errorf("write installed launcher: %w", err)
	}
	resetLauncher := "@echo off\r\n" +
		"cd /d \"%~dp0\"\r\n" +
		"powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File \"%~dp0RESET-MANAGER-ACCESS.ps1\" -DataRoot \"" + escapeBatch(dataDir) + "\"\r\n" +
		"if errorlevel 1 pause\r\n"
	if err := writeFile(filepath.Join(root, "Reset-TautWeekly-Access.cmd"), []byte(resetLauncher), 0o644); err != nil {
		return fmt.Errorf("write Manager access recovery launcher: %w", err)
	}
	uninstaller := "@echo off\r\n" +
		"\"%~dp0TautWeekly-Uninstall.exe\"\r\n"
	if err := writeFile(filepath.Join(root, "Uninstall-TautWeekly.cmd"), []byte(uninstaller), 0o644); err != nil {
		return fmt.Errorf("write uninstaller launcher: %w", err)
	}
	return nil
}

func writeInstallMetadata(root string, opts options) error {
	metadata := fmt.Sprintf("Version=%s\r\nInstalledUtc=%s\r\nDataDirectory=%s\r\n", version, time.Now().UTC().Format(time.RFC3339), opts.dataDir)
	return writeFile(filepath.Join(root, "INSTALL-METADATA.txt"), []byte(metadata), 0o600)
}

func replaceDirectory(staged, destination string) error {
	// This path is used only for a fresh install after validateInstallTarget has
	// accepted a missing or empty destination. Never delete or reuse a
	// predictable sibling such as "TautWeekly.previous"; it may belong to the
	// user. Recheck the destination and remove only the exact empty directory.
	if entries, err := os.ReadDir(destination); err == nil {
		if len(entries) != 0 {
			return errors.New("installation directory became non-empty before activation")
		}
		if err := os.Remove(destination); err != nil {
			return fmt.Errorf("remove empty installation directory: %w", err)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if err := os.Rename(staged, destination); err != nil {
		return fmt.Errorf("activate installation: %w", err)
	}
	return nil
}

func removeOwnedInstall(root string) error {
	marker := filepath.Join(root, "INSTALL-METADATA.txt")
	if _, err := os.Stat(root); errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if _, err := os.Stat(marker); err != nil {
		return errors.New("refusing to remove an installation without TautWeekly ownership metadata")
	}
	owned, err := readOwnedPaths(root)
	if err != nil {
		return err
	}
	for _, relative := range installerOwnedPaths() {
		owned[filepath.Clean(relative)] = struct{}{}
	}
	for relative := range owned {
		target := filepath.Join(root, relative)
		if !pathWithin(root, target) {
			return fmt.Errorf("owned path escapes installation: %s", relative)
		}
		if err := os.Remove(target); err != nil && !errors.Is(err, os.ErrNotExist) {
			// The running uninstaller cannot remove itself on Windows. A short-lived
			// cleanup process removes the final executable and empty directory later.
			if samePath(target, executablePath()) {
				continue
			}
			return fmt.Errorf("remove application file %s: %w", relative, err)
		}
	}
	removeEmptyDirectories(root)
	if pathWithin(root, executablePath()) {
		return scheduleSelfRemoval(executablePath(), root)
	}
	_ = os.Remove(root)
	return nil
}

func readOwnedPaths(root string) (map[string]struct{}, error) {
	content, err := os.ReadFile(filepath.Join(root, "RELEASE-FILES.txt"))
	if err != nil {
		return nil, fmt.Errorf("read release ownership manifest: %w", err)
	}
	owned := make(map[string]struct{})
	for _, line := range strings.Split(strings.ReplaceAll(string(content), "\r\n", "\n"), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, "  ", 2)
		if len(parts) != 2 || len(parts[0]) != sha256.Size*2 {
			return nil, fmt.Errorf("invalid release ownership manifest line")
		}
		if _, err := hex.DecodeString(parts[0]); err != nil {
			return nil, fmt.Errorf("invalid release ownership manifest hash")
		}
		relative := filepath.Clean(filepath.FromSlash(parts[1]))
		if relative == "." || filepath.IsAbs(relative) || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
			return nil, fmt.Errorf("unsafe release ownership path: %s", parts[1])
		}
		if isPrivateRuntimePath(relative) {
			return nil, fmt.Errorf("release ownership manifest includes private runtime material: %s", parts[1])
		}
		owned[relative] = struct{}{}
	}
	return owned, nil
}

func isPrivateRuntimePath(relative string) bool {
	clean := strings.ToLower(filepath.ToSlash(filepath.Clean(relative)))
	segments := strings.Split(clean, "/")
	leaf := segments[len(segments)-1]
	for _, segment := range segments {
		if segment == ".manager-data" || segment == "logs" || segment == "output" || segment == "cache" {
			return true
		}
	}
	switch leaf {
	case "config.json", ".env", "state.json", "access-state.json",
		"scheduler-state.json", "scheduler-heartbeat.json", "service-heartbeat.json",
		"configuration-status.json", "last-run.json", "deleted-item-cache.json",
		".tautweekly-operation.lock":
		return true
	}
	if strings.HasPrefix(leaf, "config.backup.") && strings.HasSuffix(leaf, ".json") {
		return true
	}
	return strings.HasSuffix(leaf, ".log") || strings.Contains(leaf, ".log.")
}

func installerOwnedPaths() []string {
	return []string{
		"INSTALL-METADATA.txt",
		"Open-TautWeekly.cmd",
		"Reset-TautWeekly-Access.cmd",
		"RELEASE-FILES.txt",
		"TautWeekly-Setup.exe",
		"Uninstall-TautWeekly.cmd",
		"tautweekly.ico",
	}
}

func migrateLegacyManagerData(existingRoot, dataDir string) error {
	legacy := filepath.Join(existingRoot, ".manager-data")
	info, err := os.Stat(legacy)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if !info.IsDir() {
		return errors.New("legacy Manager state is not a directory")
	}
	if err := copyDirectoryWithoutReplacement(legacy, dataDir); err != nil {
		return fmt.Errorf("migrate legacy Manager state: %w", err)
	}
	return nil
}

func copyDirectoryWithoutReplacement(source, destination string) error {
	return filepath.Walk(source, func(path string, info os.FileInfo, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		relative, err := filepath.Rel(source, path)
		if err != nil {
			return err
		}
		target := filepath.Join(destination, relative)
		if info.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("private data contains an unsupported symbolic link: %s", relative)
		}
		if info.IsDir() {
			return os.MkdirAll(target, info.Mode().Perm())
		}
		if existing, err := os.ReadFile(target); err == nil {
			incoming, readErr := os.ReadFile(path)
			if readErr != nil {
				return readErr
			}
			if !bytes.Equal(existing, incoming) {
				return fmt.Errorf("existing external Manager data conflicts with legacy file: %s", relative)
			}
			return nil
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}
		return copyFile(path, target, info.Mode().Perm())
	})
}

func copyFile(source, destination string, mode os.FileMode) error {
	input, err := os.Open(source)
	if err != nil {
		return err
	}
	defer input.Close()
	if err := os.MkdirAll(filepath.Dir(destination), 0o755); err != nil {
		return err
	}
	output, err := os.OpenFile(destination, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, mode)
	if err != nil {
		return err
	}
	_, copyErr := io.Copy(output, input)
	closeErr := output.Close()
	if copyErr != nil {
		return copyErr
	}
	return closeErr
}

func removeEmptyDirectories(root string) {
	var directories []string
	_ = filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err == nil && info.IsDir() {
			directories = append(directories, path)
		}
		return nil
	})
	for index := len(directories) - 1; index >= 0; index-- {
		_ = os.Remove(directories[index])
	}
}

func executablePath() string {
	path, err := os.Executable()
	if err != nil {
		return ""
	}
	absolute, _ := filepath.Abs(path)
	return absolute
}

func writeFile(path string, content []byte, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, content, mode)
}

func samePath(left, right string) bool {
	return strings.EqualFold(filepath.Clean(left), filepath.Clean(right))
}

func pathWithin(root, candidate string) bool {
	relative, err := filepath.Rel(filepath.Clean(root), filepath.Clean(candidate))
	if err != nil {
		return false
	}
	return relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator)) && !filepath.IsAbs(relative)
}

func escapeBatch(value string) string {
	replacer := strings.NewReplacer("%", "%%", "^", "^^", "&", "^&", "|", "^|", "<", "^<", ">", "^>")
	return replacer.Replace(value)
}

func startDetached(_ string, workingDirectory string) error {
	if runtime.GOOS != "windows" {
		return errors.New("installed Manager can be launched only on Windows")
	}
	arguments := []string{"-NoLogo", "-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden", "-ExecutionPolicy", "Bypass", "-File", filepath.Join(workingDirectory, "START-MANAGER.ps1")}
	if dataDir, err := installedDataDirectory(workingDirectory); err == nil && dataDir != "" {
		arguments = append(arguments, "-DataRoot", dataDir)
	}
	command := exec.Command("powershell.exe", arguments...)
	command.Dir = workingDirectory
	hideProcessWindow(command)
	return command.Start()
}
