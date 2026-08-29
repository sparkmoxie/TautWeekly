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
	"sync"
	"syscall"
	"time"
)

const (
	windowsFunnelSchemaVersion = 1
	windowsFunnelStateFile     = "windows-funnel.json"
)

type windowsFunnelFile struct {
	SchemaVersion int    `json:"schemaVersion"`
	Enabled       bool   `json:"enabled"`
	Hostname      string `json:"hostname,omitempty"`
}

type windowsFunnelRunner interface {
	tailscaleCommandRunner
	privilegedTailscaleCommandRunner
}

type windowsFunnelController struct {
	opMu            sync.Mutex
	stateMu         sync.RWMutex
	runner          windowsFunnelRunner
	statePath       string
	legacyStatePath string
	target          string
	supported       bool
	state           windowsFunnelFile
	stateError      error
	legacyEnabled   bool
	legacyError     error
}

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
	return newWindowsFunnelController(options.DataDir, options.ListenAddress, options.RuntimeMode == runtimeModeWindows, runner)
}

func newWindowsFunnelController(dataDir, listenAddress string, supported bool, runner windowsFunnelRunner) *windowsFunnelController {
	controller := &windowsFunnelController{
		runner:          runner,
		statePath:       filepath.Join(dataDir, windowsFunnelStateFile),
		legacyStatePath: filepath.Join(dataDir, remoteAccessStateFile),
		target:          tailscaleLoopbackTarget(listenAddress),
		supported:       supported,
		state:           windowsFunnelFile{SchemaVersion: windowsFunnelSchemaVersion},
	}
	controller.loadState()
	controller.loadLegacyState()
	return controller
}

func (c *windowsFunnelController) loadState() {
	raw, err := os.ReadFile(c.statePath)
	if errors.Is(err, os.ErrNotExist) {
		return
	}
	if err != nil || len(raw) > 64<<10 {
		c.stateError = errors.New("Windows Funnel state is unavailable")
		return
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	var saved windowsFunnelFile
	if err := decoder.Decode(&saved); err != nil || decoder.Decode(&struct{}{}) != io.EOF ||
		saved.SchemaVersion != windowsFunnelSchemaVersion ||
		(saved.Enabled && !validTailscaleHostname(saved.Hostname)) || (!saved.Enabled && saved.Hostname != "") {
		c.stateError = errors.New("Windows Funnel state is invalid")
		return
	}
	c.state = saved
}

func (c *windowsFunnelController) loadLegacyState() {
	raw, err := os.ReadFile(c.legacyStatePath)
	if errors.Is(err, os.ErrNotExist) {
		return
	}
	if err != nil || len(raw) > 64<<10 {
		c.legacyError = errors.New("legacy Windows remote-access state is unavailable")
		return
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	var saved remoteAccessFile
	if err := decoder.Decode(&saved); err != nil || decoder.Decode(&struct{}{}) != io.EOF ||
		saved.SchemaVersion != remoteAccessSchemaVersion ||
		(saved.Enabled && !validTailscaleHostname(saved.Hostname)) || (!saved.Enabled && saved.Hostname != "") {
		c.legacyError = errors.New("legacy Windows remote-access state is invalid")
		return
	}
	c.legacyEnabled = saved.Enabled
}

func (c *windowsFunnelController) savedState() (windowsFunnelFile, error) {
	c.stateMu.RLock()
	defer c.stateMu.RUnlock()
	if c.stateError != nil {
		return c.state, c.stateError
	}
	return c.state, c.legacyError
}

func (c *windowsFunnelController) saveState(next windowsFunnelFile) error {
	if err := writePrivateJSON(c.statePath, next); err != nil {
		return err
	}
	c.stateMu.Lock()
	c.state = next
	c.stateError = nil
	c.stateMu.Unlock()
	return nil
}

func (c *windowsFunnelController) clearLegacyState() error {
	info, err := os.Lstat(c.legacyStatePath)
	if errors.Is(err, os.ErrNotExist) {
		c.legacyEnabled = false
		c.legacyError = nil
		return nil
	}
	if err != nil || !info.Mode().IsRegular() {
		return errors.New("legacy Windows remote-access state could not be removed safely")
	}
	if err := os.Remove(c.legacyStatePath); err != nil {
		return err
	}
	c.legacyEnabled = false
	c.legacyError = nil
	return nil
}

func (c *windowsFunnelController) PublicExposureConfigured() bool {
	state, err := c.savedState()
	return err != nil || state.Enabled || c.legacyEnabled
}

func (c *windowsFunnelController) AllowsHost(value string) bool {
	state, err := c.savedState()
	return err == nil && state.Enabled && validTailscaleHostname(state.Hostname) && strings.EqualFold(state.Hostname, hostnameOnly(value))
}

func (c *windowsFunnelController) Status(context.Context) TailscaleRemoteAccessStatus {
	c.opMu.Lock()
	defer c.opMu.Unlock()
	return c.status()
}

func (c *windowsFunnelController) status() TailscaleRemoteAccessStatus {
	state, stateErr := c.savedState()
	result := TailscaleRemoteAccessStatus{
		Supported: c.supported, State: "unavailable", Provider: "tailscale",
		NetworkKind: "public-funnel", Management: "integrated",
	}
	if state.Enabled && validTailscaleHostname(state.Hostname) {
		result.Enabled = true
		result.URL = "https://" + state.Hostname
		result.CleanupRequired = true
	}
	if !c.supported {
		result.State = "unsupported"
		result.ErrorCode = "platform-unsupported"
		return result
	}
	if stateErr != nil {
		result.State = "needs-attention"
		result.ErrorCode = "remote-state-invalid"
		result.CleanupRequired = true
		return result
	}
	if c.legacyEnabled {
		result.State = "migration-required"
		result.ErrorCode = "tailscale-serve-migration-required"
		result.CleanupRequired = true
		return result
	}
	if c.runner == nil || !c.runner.Available() {
		result.Installed = false
		if result.Enabled {
			result.State = "needs-attention"
			result.ErrorCode = "tailscale-required"
		} else {
			result.State = "tailscale-required"
			result.ErrorCode = "tailscale-required"
		}
		return result
	}
	result.Installed = true
	result.State = "approval-required"
	result.ErrorCode = "tailscale-approval-required"
	return result
}

func (c *windowsFunnelController) Verify(ctx context.Context) (TailscaleRemoteAccessStatus, error) {
	c.opMu.Lock()
	defer c.opMu.Unlock()
	if !c.supported {
		return c.status(), ErrRemoteAccessUnsupported
	}
	if c.runner == nil || !c.runner.Available() {
		return c.status(), ErrTailscaleUnavailable
	}
	raw, err := c.runner.RunPrivileged(ctx, "inspect", c.target)
	if err != nil {
		return c.status(), err
	}
	observed, err := decodeTailscaleServeStatus(raw)
	if err != nil {
		return c.status(), ErrTailscaleConfigurationInvalid
	}
	return c.observedStatus(observed), nil
}

func (c *windowsFunnelController) observedStatus(observed tailscaleServeStatus) TailscaleRemoteAccessStatus {
	state, stateErr := c.savedState()
	result := TailscaleRemoteAccessStatus{
		Supported: true, Installed: true, Provider: "tailscale", NetworkKind: "public-funnel", Management: "integrated",
	}
	if stateErr != nil {
		result.State = "needs-attention"
		result.ErrorCode = "remote-state-invalid"
		result.CleanupRequired = true
		return result
	}
	if state.Enabled {
		result.Enabled = true
		result.URL = "https://" + state.Hostname
		result.CleanupRequired = true
	}
	if serveStatusEmpty(observed) {
		if state.Enabled || c.legacyEnabled {
			result.State = "needs-attention"
			result.ErrorCode = "tailscale-funnel-missing"
			return result
		}
		result.State = "inactive"
		return result
	}
	if hostname, owned := ownedTailscaleFunnel(observed, c.target); owned {
		if state.Enabled && strings.EqualFold(state.Hostname, hostname) {
			result.Active = true
			result.State = "active"
			return result
		}
		result.Enabled = false
		result.Active = false
		result.URL = ""
		result.State = "needs-attention"
		result.ErrorCode = "tailscale-funnel-untracked"
		result.CleanupRequired = true
		return result
	}
	if _, owned := ownedTailscaleServe(observed, c.target); owned {
		result.Enabled = false
		result.Active = false
		result.URL = ""
		result.State = "migration-required"
		result.ErrorCode = "tailscale-serve-migration-required"
		result.CleanupRequired = true
		return result
	}
	result.State = "needs-attention"
	result.ErrorCode = "tailscale-funnel-conflict"
	result.CleanupRequired = state.Enabled || c.legacyEnabled
	return result
}

func (c *windowsFunnelController) Update(ctx context.Context, enabled bool, _ string, _ bool) (TailscaleRemoteAccessStatus, error) {
	c.opMu.Lock()
	defer c.opMu.Unlock()
	if !c.supported {
		return c.status(), ErrRemoteAccessUnsupported
	}
	if enabled {
		return c.enable(ctx)
	}
	return c.ensureInactive(ctx)
}

func (c *windowsFunnelController) enable(ctx context.Context) (TailscaleRemoteAccessStatus, error) {
	if c.runner == nil || !c.runner.Available() {
		return c.status(), ErrTailscaleUnavailable
	}
	raw, err := c.runner.RunPrivileged(ctx, "enable", c.target)
	if err != nil {
		return c.status(), err
	}
	observed, err := decodeTailscaleServeStatus(raw)
	if err != nil {
		return c.status(), ErrTailscaleConfigurationInvalid
	}
	hostname, owned := ownedTailscaleFunnel(observed, c.target)
	if !owned {
		return c.status(), ErrTailscaleConfigurationInvalid
	}
	if err := c.saveState(windowsFunnelFile{SchemaVersion: windowsFunnelSchemaVersion, Enabled: true, Hostname: hostname}); err != nil {
		if _, rollbackErr := c.runner.RunPrivileged(ctx, "disable", c.target); rollbackErr != nil {
			return c.status(), ErrTailscaleDisableIncomplete
		}
		return c.status(), err
	}
	if err := c.clearLegacyState(); err != nil {
		if _, rollbackErr := c.runner.RunPrivileged(ctx, "disable", c.target); rollbackErr != nil {
			return c.status(), ErrTailscaleDisableIncomplete
		}
		if resetErr := c.saveState(windowsFunnelFile{SchemaVersion: windowsFunnelSchemaVersion}); resetErr != nil {
			return c.status(), resetErr
		}
		return c.status(), err
	}
	return c.observedStatus(observed), nil
}

func (c *windowsFunnelController) EnsureInactive(ctx context.Context) (TailscaleRemoteAccessStatus, error) {
	c.opMu.Lock()
	defer c.opMu.Unlock()
	return c.ensureInactive(ctx)
}

func (c *windowsFunnelController) ensureInactive(ctx context.Context) (TailscaleRemoteAccessStatus, error) {
	if !c.PublicExposureConfigured() {
		return c.status(), nil
	}
	if c.runner == nil || !c.runner.Available() {
		return c.status(), ErrTailscaleDisableIncomplete
	}
	raw, err := c.runner.RunPrivileged(ctx, "disable", c.target)
	if err != nil {
		return c.status(), ErrTailscaleDisableIncomplete
	}
	observed, err := decodeTailscaleServeStatus(raw)
	if err != nil || !serveStatusEmpty(observed) {
		return c.status(), ErrTailscaleDisableIncomplete
	}
	if err := c.saveState(windowsFunnelFile{SchemaVersion: windowsFunnelSchemaVersion}); err != nil {
		return c.status(), err
	}
	if err := c.clearLegacyState(); err != nil {
		return c.status(), err
	}
	return TailscaleRemoteAccessStatus{
		Supported: true, Installed: true, State: "inactive", Provider: "tailscale", NetworkKind: "public-funnel", Management: "integrated",
	}, nil
}

func ownedTailscaleFunnel(status tailscaleServeStatus, target string) (string, bool) {
	if len(status.TCP) != 1 || len(status.Web) != 1 || len(status.Services) != 0 || len(status.Foreground) != 0 || len(status.AllowFunnel) != 1 {
		return "", false
	}
	tcp, ok := status.TCP["443"]
	if !ok || !tcp.HTTPS || tcp.HTTP || tcp.TCPForward != "" || tcp.TerminateTLS != "" || tcp.ProxyProtocol != 0 {
		return "", false
	}
	for hostPort, web := range status.Web {
		hostname, port, err := net.SplitHostPort(hostPort)
		if err != nil || port != "443" || !validTailscaleHostname(hostname) || len(web.Handlers) != 1 || !status.AllowFunnel[hostPort] {
			return "", false
		}
		handler, ok := web.Handlers["/"]
		if !ok || handler.Proxy != target || handler.Path != "" || handler.Text != "" || handler.Redirect != "" || len(handler.AcceptAppCaps) != 0 {
			return "", false
		}
		return strings.ToLower(hostname), true
	}
	return "", false
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
		case strings.Contains(message, "service is not running"), strings.Contains(message, "failed to connect to local tailscaled"), strings.Contains(message, "no backend"):
			return nil, ErrTailscaleNotRunning
		case strings.Contains(message, "unknown command"), strings.Contains(message, "does not support funnel"):
			return nil, ErrTailscaleFunnelUnsupported
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
	case "not-running":
		return nil, ErrTailscaleNotRunning
	case "unsupported":
		return nil, ErrTailscaleFunnelUnsupported
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
