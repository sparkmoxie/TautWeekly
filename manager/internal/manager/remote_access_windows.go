//go:build windows

package manager

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

type windowsTailscaleRunner struct {
	path       string
	powershell string
	helper     string
}

func newPlatformRemoteAccessController(options Options) remoteAccessController {
	path := installedWindowsTailscalePath()
	systemRoot := strings.TrimSpace(os.Getenv("SystemRoot"))
	powershell := ""
	if systemRoot != "" {
		powershell = filepath.Join(systemRoot, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
	}
	runner := &windowsTailscaleRunner{
		path:       path,
		powershell: powershell,
		helper:     filepath.Join(options.TautWeeklyRoot, "TAILSCALE-HELPER.ps1"),
	}
	return newTailscaleRemoteAccessController(options.DataDir, options.ListenAddress, options.RuntimeMode == runtimeModeWindows, runner)
}

func installedWindowsTailscalePath() string {
	seen := map[string]bool{}
	for _, root := range []string{os.Getenv("ProgramW6432"), os.Getenv("ProgramFiles")} {
		root = strings.TrimSpace(root)
		if root == "" {
			continue
		}
		candidate := filepath.Clean(filepath.Join(root, "Tailscale", "tailscale.exe"))
		key := strings.ToLower(candidate)
		if seen[key] {
			continue
		}
		seen[key] = true
		if info, err := os.Stat(candidate); err == nil && info.Mode().IsRegular() {
			return candidate
		}
	}
	return ""
}

func (r *windowsTailscaleRunner) Available() bool {
	if r == nil || r.path == "" || r.powershell == "" || r.helper == "" {
		return false
	}
	for _, path := range []string{r.path, r.powershell, r.helper} {
		info, err := os.Stat(path)
		if err != nil || !info.Mode().IsRegular() {
			return false
		}
	}
	return true
}

func (*windowsTailscaleRunner) RequiresApproval() bool { return true }

func (r *windowsTailscaleRunner) Run(ctx context.Context, arguments ...string) ([]byte, error) {
	command := exec.CommandContext(ctx, r.path, arguments...)
	command.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: 0x08000000}
	var output boundedCommandOutput
	var diagnostic boundedCommandOutput
	command.Stdout = &output
	command.Stderr = &diagnostic
	if err := command.Run(); err != nil {
		message := strings.ToLower(diagnostic.buffer.String())
		switch {
		case strings.Contains(message, "access is denied"), strings.Contains(message, "permission"), strings.Contains(message, "operator"), strings.Contains(message, "administrator"):
			return nil, ErrTailscaleApprovalRequired
		case strings.Contains(message, "not logged"), strings.Contains(message, "logged out"), strings.Contains(message, "needs login"), strings.Contains(message, "no current profile"):
			return nil, ErrTailscaleSignInRequired
		case errors.Is(ctx.Err(), context.DeadlineExceeded), errors.Is(ctx.Err(), context.Canceled):
			return nil, ctx.Err()
		}
		return nil, err
	}
	if output.overflow || diagnostic.overflow {
		return nil, ErrTailscaleConfigurationInvalid
	}
	return output.buffer.Bytes(), nil
}

func (r *windowsTailscaleRunner) RunPrivileged(ctx context.Context, action, target string) ([]byte, error) {
	if !r.Available() || (action != "enable" && action != "disable" && action != "inspect") {
		return nil, ErrTailscaleUnavailable
	}
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return nil, ErrTailscaleUnavailable
	}
	defer listener.Close()
	tcpListener, ok := listener.(*net.TCPListener)
	if !ok {
		return nil, ErrTailscaleUnavailable
	}
	port := tcpListener.Addr().(*net.TCPAddr).Port
	nonceBytes := make([]byte, 32)
	if _, err := rand.Read(nonceBytes); err != nil {
		return nil, ErrTailscaleUnavailable
	}
	nonce := hex.EncodeToString(nonceBytes)
	commandCtx, cancel := context.WithTimeout(ctx, tailscaleResponseTimeout-15*time.Second)
	defer cancel()
	command := exec.CommandContext(
		commandCtx,
		r.powershell,
		"-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
		"-File", r.helper,
		"-Action", strings.ToUpper(action[:1])+action[1:],
		"-Target", target,
		"-CallbackPort", strconv.Itoa(port),
		"-Nonce", nonce,
	)
	command.Dir = filepath.Dir(r.helper)
	command.Env = operationEnvironment(os.Environ())
	command.Stdin = nil
	command.Stdout = io.Discard
	command.Stderr = io.Discard
	command.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: 0x08000000}
	runErr := command.Run()
	if errors.Is(commandCtx.Err(), context.DeadlineExceeded) || errors.Is(commandCtx.Err(), context.Canceled) {
		return nil, commandCtx.Err()
	}
	if err := tcpListener.SetDeadline(time.Now().Add(2 * time.Second)); err != nil {
		return nil, ErrTailscaleUnavailable
	}
	connection, acceptErr := tcpListener.AcceptTCP()
	if acceptErr != nil {
		var exitError *exec.ExitError
		if errors.As(runErr, &exitError) && exitError.ExitCode() == 10 {
			return nil, ErrTailscaleApprovalDeclined
		}
		return nil, ErrTailscaleUnavailable
	}
	defer connection.Close()
	_ = connection.SetReadDeadline(time.Now().Add(2 * time.Second))
	raw, readErr := io.ReadAll(io.LimitReader(connection, maximumTailscaleOutput+1))
	if readErr != nil || len(raw) == 0 || len(raw) > maximumTailscaleOutput {
		return nil, ErrTailscaleConfigurationInvalid
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	var result tailscaleHelperResult
	if err := decoder.Decode(&result); err != nil || decoder.Decode(&struct{}{}) != io.EOF || result.SchemaVersion != 1 || result.Nonce != nonce {
		return nil, ErrTailscaleConfigurationInvalid
	}
	switch result.Code {
	case "enabled", "disabled", "inspected":
		if runErr != nil || len(result.ServeStatus) == 0 {
			return nil, ErrTailscaleConfigurationInvalid
		}
		return result.ServeStatus, nil
	case "conflict":
		return nil, ErrTailscaleServeConflict
	case "not-installed":
		return nil, ErrTailscaleUnavailable
	case "sign-in-required":
		return nil, ErrTailscaleSignInRequired
	case "provider-approval-required":
		if !validTailscaleProviderURL(result.SetupURL) {
			return nil, ErrTailscaleConfigurationInvalid
		}
		return nil, tailscaleProviderApprovalError{url: result.SetupURL}
	case "verification-failed":
		return nil, ErrTailscaleConfigurationInvalid
	default:
		return nil, ErrTailscaleUnavailable
	}
}
