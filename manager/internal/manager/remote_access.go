package manager

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const (
	remoteAccessSchemaVersion = 1
	remoteAccessStateFile     = "remote-access.json"
	tailscaleCommandTimeout   = 8 * time.Second
	tailscaleResponseTimeout  = 5 * time.Minute
	maximumTailscaleOutput    = 256 << 10
)

var (
	ErrRemoteAccessUnsupported       = errors.New("remote access is unsupported on this platform")
	ErrTailscaleUnavailable          = errors.New("Tailscale is unavailable")
	ErrTailscaleApprovalRequired     = errors.New("Windows administrator approval is required for Tailscale Serve")
	ErrTailscaleApprovalDeclined     = errors.New("Windows administrator approval was declined")
	ErrTailscaleHostAuthorization    = errors.New("host administrator authorization is required for Tailscale Serve")
	ErrTailscaleProviderApproval     = errors.New("Tailscale provider approval is required")
	ErrTailscaleSignInRequired       = errors.New("Tailscale sign-in is required")
	ErrTailscaleServeConflict        = errors.New("Tailscale Serve is already configured for another service")
	ErrTailscaleConfigurationInvalid = errors.New("Tailscale Serve returned an unexpected configuration")
	ErrTailscaleDisableIncomplete    = errors.New("local remote access was blocked, but Tailscale Serve cleanup is incomplete")
)

type tailscaleProviderApprovalError struct {
	url string
}

func (e tailscaleProviderApprovalError) Error() string { return ErrTailscaleProviderApproval.Error() }
func (e tailscaleProviderApprovalError) Is(target error) bool {
	return target == ErrTailscaleProviderApproval
}

type TailscaleRemoteAccessStatus struct {
	Supported                 bool   `json:"supported"`
	Installed                 bool   `json:"installed"`
	Enabled                   bool   `json:"enabled"`
	Active                    bool   `json:"active"`
	State                     string `json:"state"`
	URL                       string `json:"url,omitempty"`
	ErrorCode                 string `json:"errorCode,omitempty"`
	Provider                  string `json:"provider"`
	NetworkKind               string `json:"networkKind"`
	Management                string `json:"management"`
	RequiresURL               bool   `json:"requiresUrl"`
	HostAuthorizationRequired bool   `json:"hostAuthorizationRequired"`
	HostAuthorizationCommand  string `json:"hostAuthorizationCommand,omitempty"`
}

type tailscaleRemoteAccessRequest struct {
	Enabled          bool   `json:"enabled"`
	URL              string `json:"url,omitempty"`
	ConfirmedPrivate bool   `json:"confirmedPrivate,omitempty"`
}

type remoteAccessController interface {
	Status(context.Context) TailscaleRemoteAccessStatus
	Verify(context.Context) (TailscaleRemoteAccessStatus, error)
	Update(context.Context, bool, string, bool) (TailscaleRemoteAccessStatus, error)
	AllowsHost(string) bool
}

type tailscaleCommandRunner interface {
	Available() bool
	Run(context.Context, ...string) ([]byte, error)
}

type privilegedTailscaleCommandRunner interface {
	RunPrivileged(context.Context, string, string) ([]byte, error)
	RequiresApproval() bool
}

type tailscaleRunnerAvailability interface {
	Availability() string
}

type tailscaleHelperRequest struct {
	SchemaVersion int    `json:"schemaVersion"`
	Nonce         string `json:"nonce"`
	Action        string `json:"action"`
	Target        string `json:"target"`
}

type tailscaleHelperResult struct {
	SchemaVersion int             `json:"schemaVersion"`
	Nonce         string          `json:"nonce"`
	Code          string          `json:"code"`
	ServeStatus   json.RawMessage `json:"serveStatus,omitempty"`
	SetupURL      string          `json:"setupUrl,omitempty"`
}

type remoteAccessFile struct {
	SchemaVersion int    `json:"schemaVersion"`
	Enabled       bool   `json:"enabled"`
	Hostname      string `json:"hostname,omitempty"`
}

type tailscaleRemoteAccessController struct {
	opMu       sync.Mutex
	stateMu    sync.RWMutex
	runner     tailscaleCommandRunner
	statePath  string
	target     string
	supported  bool
	state      remoteAccessFile
	stateError error
}

type tailscaleServeStatus struct {
	TCP         map[string]tailscaleTCPHandler `json:"TCP"`
	Web         map[string]tailscaleWebServer  `json:"Web"`
	Services    map[string]json.RawMessage     `json:"Services"`
	AllowFunnel map[string]bool                `json:"AllowFunnel"`
	Foreground  map[string]json.RawMessage     `json:"Foreground"`
}

type tailscaleTCPHandler struct {
	HTTP          bool   `json:"HTTP"`
	HTTPS         bool   `json:"HTTPS"`
	TCPForward    string `json:"TCPForward"`
	TerminateTLS  string `json:"TerminateTLS"`
	ProxyProtocol int    `json:"ProxyProtocol"`
}

type tailscaleWebServer struct {
	Handlers map[string]tailscaleHTTPHandler `json:"Handlers"`
}

type tailscaleHTTPHandler struct {
	Proxy         string            `json:"Proxy"`
	Path          string            `json:"Path"`
	Text          string            `json:"Text"`
	Redirect      string            `json:"Redirect"`
	AcceptAppCaps []json.RawMessage `json:"AcceptAppCaps"`
}

type boundedCommandOutput struct {
	buffer   bytes.Buffer
	overflow bool
}

func (w *boundedCommandOutput) Write(value []byte) (int, error) {
	length := len(value)
	remaining := maximumTailscaleOutput + 1 - w.buffer.Len()
	if remaining > 0 {
		if remaining < len(value) {
			value = value[:remaining]
		}
		_, _ = w.buffer.Write(value)
	}
	if w.buffer.Len() > maximumTailscaleOutput || length > remaining {
		w.overflow = true
	}
	return length, nil
}

func newTailscaleRemoteAccessController(dataDir, listenAddress string, supported bool, runner tailscaleCommandRunner) *tailscaleRemoteAccessController {
	c := &tailscaleRemoteAccessController{
		runner:    runner,
		statePath: filepath.Join(dataDir, remoteAccessStateFile),
		target:    tailscaleLoopbackTarget(listenAddress),
		supported: supported,
		state:     remoteAccessFile{SchemaVersion: remoteAccessSchemaVersion},
	}
	c.loadState()
	return c
}

func tailscaleLoopbackTarget(listenAddress string) string {
	host, port, err := net.SplitHostPort(strings.TrimSpace(listenAddress))
	if err != nil || port == "" {
		return "http://127.0.0.1:8788"
	}
	ip := net.ParseIP(strings.Trim(host, "[]"))
	if !strings.EqualFold(host, "localhost") && (ip == nil || !ip.IsLoopback()) {
		return "http://127.0.0.1:8788"
	}
	return "http://127.0.0.1:" + port
}

func (c *tailscaleRemoteAccessController) loadState() {
	raw, err := os.ReadFile(c.statePath)
	if errors.Is(err, os.ErrNotExist) {
		return
	}
	if err != nil {
		c.stateError = err
		return
	}
	if len(raw) > 64<<10 {
		c.stateError = errors.New("remote access state is too large")
		return
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	var saved remoteAccessFile
	if err := decoder.Decode(&saved); err != nil {
		c.stateError = err
		return
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		c.stateError = errors.New("remote access state contains trailing data")
		return
	}
	if saved.SchemaVersion != remoteAccessSchemaVersion || (saved.Enabled && !validTailscaleHostname(saved.Hostname)) || (!saved.Enabled && saved.Hostname != "") {
		c.stateError = errors.New("remote access state is invalid")
		return
	}
	c.state = saved
}

func (c *tailscaleRemoteAccessController) savedState() (remoteAccessFile, error) {
	c.stateMu.RLock()
	defer c.stateMu.RUnlock()
	return c.state, c.stateError
}

func (c *tailscaleRemoteAccessController) saveState(next remoteAccessFile) error {
	if err := writePrivateJSON(c.statePath, next); err != nil {
		return err
	}
	c.stateMu.Lock()
	c.state = next
	c.stateError = nil
	c.stateMu.Unlock()
	return nil
}

func (c *tailscaleRemoteAccessController) AllowsHost(value string) bool {
	host := hostnameOnly(value)
	state, err := c.savedState()
	return err == nil && state.Enabled && validTailscaleHostname(state.Hostname) && strings.EqualFold(state.Hostname, host)
}

func (c *tailscaleRemoteAccessController) Status(ctx context.Context) TailscaleRemoteAccessStatus {
	c.opMu.Lock()
	defer c.opMu.Unlock()
	return c.status(ctx)
}

func (c *tailscaleRemoteAccessController) Verify(ctx context.Context) (TailscaleRemoteAccessStatus, error) {
	c.opMu.Lock()
	defer c.opMu.Unlock()
	state, stateErr := c.savedState()
	if !c.supported {
		return c.status(ctx), ErrRemoteAccessUnsupported
	}
	if stateErr != nil {
		return c.status(ctx), ErrTailscaleConfigurationInvalid
	}
	if c.runner == nil || !c.runner.Available() {
		if runner, ok := c.runner.(tailscaleRunnerAvailability); ok && runner.Availability() == "authorization-required" {
			return c.status(ctx), ErrTailscaleHostAuthorization
		}
		return c.status(ctx), ErrTailscaleUnavailable
	}
	var (
		serve tailscaleServeStatus
		err   error
	)
	if runner, ok := c.runner.(privilegedTailscaleCommandRunner); ok && runner.RequiresApproval() {
		var raw []byte
		raw, err = runner.RunPrivileged(ctx, "inspect", c.target)
		if err == nil {
			serve, err = decodeTailscaleServeStatus(raw)
		}
	} else {
		serve, err = c.readServeStatus(ctx)
	}
	if err != nil {
		return c.status(ctx), err
	}
	result := TailscaleRemoteAccessStatus{
		Supported: true, Installed: true, Enabled: state.Enabled,
		State: "ready", Provider: "tailscale", NetworkKind: "private-tailnet", Management: "integrated",
	}
	if state.Enabled {
		result.URL = "https://" + state.Hostname
	}
	if serveStatusEmpty(serve) {
		if state.Enabled {
			result.State = "interrupted"
			result.ErrorCode = "tailscale-serve-missing"
		}
		return result, nil
	}
	hostname, owned := ownedTailscaleServe(serve, c.target)
	if !owned {
		result.State = "conflict"
		result.ErrorCode = "tailscale-serve-conflict"
		return result, nil
	}
	if !state.Enabled {
		result.State = "detected"
		result.URL = "https://" + hostname
		return result, nil
	}
	if !strings.EqualFold(state.Hostname, hostname) {
		result.State = "conflict"
		result.ErrorCode = "tailscale-hostname-changed"
		return result, nil
	}
	result.Active = true
	result.State = "enabled"
	return result, nil
}

func (c *tailscaleRemoteAccessController) status(ctx context.Context) TailscaleRemoteAccessStatus {
	state, stateErr := c.savedState()
	result := TailscaleRemoteAccessStatus{
		Supported:   c.supported,
		Enabled:     stateErr == nil && state.Enabled,
		State:       "unsupported",
		Provider:    "tailscale",
		NetworkKind: "private-tailnet",
		Management:  "integrated",
	}
	if stateErr == nil && state.Enabled {
		result.URL = "https://" + state.Hostname
	}
	if !c.supported {
		result.ErrorCode = "platform-unsupported"
		return result
	}
	if stateErr != nil {
		result.State = "unavailable"
		result.ErrorCode = "remote-state-invalid"
		return result
	}
	if c.runner == nil || !c.runner.Available() {
		if runner, ok := c.runner.(tailscaleRunnerAvailability); ok && runner.Availability() == "authorization-required" {
			result.Installed = true
			result.State = "authorization-required"
			result.ErrorCode = "tailscale-host-authorization-required"
			result.HostAuthorizationRequired = true
			result.HostAuthorizationCommand = "sudo tautweekly remote-access-authorize"
			return result
		}
		result.State = "not-installed"
		result.ErrorCode = "tailscale-not-installed"
		return result
	}
	result.Installed = true
	if runner, ok := c.runner.(privilegedTailscaleCommandRunner); ok && runner.RequiresApproval() {
		if state.Enabled {
			result.State = "enabled-unverified"
		} else {
			result.State = "approval-required"
		}
		result.ErrorCode = "tailscale-approval-required"
		return result
	}
	serve, err := c.readServeStatus(ctx)
	if err != nil {
		switch {
		case errors.Is(err, ErrTailscaleApprovalRequired):
			if state.Enabled {
				result.State = "enabled-unverified"
			} else {
				result.State = "approval-required"
			}
			result.ErrorCode = "tailscale-approval-required"
		case errors.Is(err, ErrTailscaleSignInRequired):
			result.State = "sign-in-required"
			result.ErrorCode = "tailscale-sign-in-required"
		default:
			result.State = "unavailable"
			result.ErrorCode = "tailscale-status-unavailable"
		}
		return result
	}
	if serveStatusEmpty(serve) {
		if state.Enabled {
			result.State = "interrupted"
			result.ErrorCode = "tailscale-serve-missing"
		} else {
			result.State = "ready"
		}
		return result
	}
	hostname, owned := ownedTailscaleServe(serve, c.target)
	if !owned {
		result.State = "conflict"
		result.ErrorCode = "tailscale-serve-conflict"
		return result
	}
	if state.Enabled {
		if !strings.EqualFold(state.Hostname, hostname) {
			result.State = "conflict"
			result.ErrorCode = "tailscale-hostname-changed"
			return result
		}
		result.Active = true
		result.State = "enabled"
		return result
	}
	result.State = "detected"
	result.URL = "https://" + hostname
	return result
}

func (c *tailscaleRemoteAccessController) Update(ctx context.Context, enabled bool, _ string, _ bool) (TailscaleRemoteAccessStatus, error) {
	c.opMu.Lock()
	defer c.opMu.Unlock()
	if !c.supported {
		return c.status(ctx), ErrRemoteAccessUnsupported
	}
	if enabled {
		return c.enable(ctx)
	}
	return c.disable(ctx)
}

func (c *tailscaleRemoteAccessController) enable(ctx context.Context) (TailscaleRemoteAccessStatus, error) {
	if c.runner == nil || !c.runner.Available() {
		if runner, ok := c.runner.(tailscaleRunnerAvailability); ok && runner.Availability() == "authorization-required" {
			return c.status(ctx), ErrTailscaleHostAuthorization
		}
		return c.status(ctx), ErrTailscaleUnavailable
	}
	if runner, ok := c.runner.(privilegedTailscaleCommandRunner); ok && runner.RequiresApproval() {
		return c.enablePrivileged(ctx)
	}
	serve, err := c.readServeStatus(ctx)
	if err != nil {
		if errors.Is(err, ErrTailscaleApprovalRequired) {
			return c.enablePrivileged(ctx)
		}
		return c.status(ctx), err
	}
	if !serveStatusEmpty(serve) {
		hostname, owned := ownedTailscaleServe(serve, c.target)
		if !owned {
			return c.status(ctx), ErrTailscaleServeConflict
		}
		if err := c.saveState(remoteAccessFile{SchemaVersion: remoteAccessSchemaVersion, Enabled: true, Hostname: hostname}); err != nil {
			return c.status(ctx), err
		}
		return c.status(ctx), nil
	}
	commandCtx, cancel := context.WithTimeout(ctx, tailscaleCommandTimeout)
	_, commandErr := c.runner.Run(commandCtx, "serve", "--bg", "--yes", "--https=443", c.target)
	cancel()
	if commandErr != nil {
		if errors.Is(commandErr, ErrTailscaleApprovalRequired) || errors.Is(commandErr, ErrTailscaleSignInRequired) {
			return c.status(ctx), commandErr
		}
		return c.status(ctx), ErrTailscaleUnavailable
	}
	serve, err = c.readServeStatus(ctx)
	if err != nil {
		return c.status(ctx), ErrTailscaleConfigurationInvalid
	}
	hostname, owned := ownedTailscaleServe(serve, c.target)
	if !owned {
		return c.status(ctx), ErrTailscaleConfigurationInvalid
	}
	if err := c.saveState(remoteAccessFile{SchemaVersion: remoteAccessSchemaVersion, Enabled: true, Hostname: hostname}); err != nil {
		return c.status(ctx), err
	}
	return c.status(ctx), nil
}

func (c *tailscaleRemoteAccessController) enablePrivileged(ctx context.Context) (TailscaleRemoteAccessStatus, error) {
	runner, ok := c.runner.(privilegedTailscaleCommandRunner)
	if !ok {
		return c.status(ctx), ErrTailscaleApprovalRequired
	}
	raw, err := runner.RunPrivileged(ctx, "enable", c.target)
	if err != nil {
		return c.status(ctx), err
	}
	serve, err := decodeTailscaleServeStatus(raw)
	if err != nil {
		return c.status(ctx), ErrTailscaleConfigurationInvalid
	}
	hostname, owned := ownedTailscaleServe(serve, c.target)
	if !owned {
		return c.status(ctx), ErrTailscaleConfigurationInvalid
	}
	if err := c.saveState(remoteAccessFile{SchemaVersion: remoteAccessSchemaVersion, Enabled: true, Hostname: hostname}); err != nil {
		return c.status(ctx), err
	}
	return TailscaleRemoteAccessStatus{
		Supported: true, Installed: true, Enabled: true, Active: true, State: "enabled",
		URL: "https://" + hostname, Provider: "tailscale", NetworkKind: "private-tailnet", Management: "integrated",
	}, nil
}

func (c *tailscaleRemoteAccessController) disable(ctx context.Context) (TailscaleRemoteAccessStatus, error) {
	if err := c.saveState(remoteAccessFile{SchemaVersion: remoteAccessSchemaVersion}); err != nil {
		return c.status(ctx), err
	}
	if c.runner == nil || !c.runner.Available() {
		return c.status(ctx), ErrTailscaleDisableIncomplete
	}
	if runner, ok := c.runner.(privilegedTailscaleCommandRunner); ok && runner.RequiresApproval() {
		return c.disablePrivileged(ctx)
	}
	serve, err := c.readServeStatus(ctx)
	if err != nil {
		if errors.Is(err, ErrTailscaleApprovalRequired) {
			return c.disablePrivileged(ctx)
		}
		return c.status(ctx), ErrTailscaleDisableIncomplete
	}
	if serveStatusEmpty(serve) {
		return c.status(ctx), nil
	}
	if _, owned := ownedTailscaleServe(serve, c.target); !owned {
		return c.status(ctx), nil
	}
	commandCtx, cancel := context.WithTimeout(ctx, tailscaleCommandTimeout)
	_, commandErr := c.runner.Run(commandCtx, "serve", "--yes", "--https=443", "off")
	cancel()
	if commandErr != nil {
		return c.status(ctx), ErrTailscaleDisableIncomplete
	}
	serve, err = c.readServeStatus(ctx)
	if err != nil || !serveStatusEmpty(serve) {
		return c.status(ctx), ErrTailscaleDisableIncomplete
	}
	return c.status(ctx), nil
}

func (c *tailscaleRemoteAccessController) disablePrivileged(ctx context.Context) (TailscaleRemoteAccessStatus, error) {
	runner, ok := c.runner.(privilegedTailscaleCommandRunner)
	if !ok {
		return c.status(ctx), ErrTailscaleDisableIncomplete
	}
	raw, err := runner.RunPrivileged(ctx, "disable", c.target)
	if err != nil {
		return c.status(ctx), ErrTailscaleDisableIncomplete
	}
	serve, err := decodeTailscaleServeStatus(raw)
	if err != nil {
		return c.status(ctx), ErrTailscaleDisableIncomplete
	}
	result := TailscaleRemoteAccessStatus{
		Supported: true, Installed: true, State: "ready", Provider: "tailscale", NetworkKind: "private-tailnet", Management: "integrated",
	}
	if !serveStatusEmpty(serve) {
		if _, owned := ownedTailscaleServe(serve, c.target); owned {
			return c.status(ctx), ErrTailscaleDisableIncomplete
		}
		result.State = "conflict"
		result.ErrorCode = "tailscale-serve-conflict"
	}
	return result, nil
}

func (c *tailscaleRemoteAccessController) readServeStatus(ctx context.Context) (tailscaleServeStatus, error) {
	commandCtx, cancel := context.WithTimeout(ctx, tailscaleCommandTimeout)
	raw, err := c.runner.Run(commandCtx, "serve", "status", "--json")
	cancel()
	if err != nil {
		return tailscaleServeStatus{}, err
	}
	return decodeTailscaleServeStatus(raw)
}

func decodeTailscaleServeStatus(raw []byte) (tailscaleServeStatus, error) {
	if len(raw) == 0 || len(raw) > 256<<10 {
		return tailscaleServeStatus{}, ErrTailscaleUnavailable
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	var status tailscaleServeStatus
	if err := decoder.Decode(&status); err != nil {
		return tailscaleServeStatus{}, ErrTailscaleConfigurationInvalid
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		return tailscaleServeStatus{}, ErrTailscaleConfigurationInvalid
	}
	return status, nil
}

func serveStatusEmpty(status tailscaleServeStatus) bool {
	return len(status.TCP) == 0 && len(status.Web) == 0 && len(status.Services) == 0 && len(status.AllowFunnel) == 0 && len(status.Foreground) == 0
}

func ownedTailscaleServe(status tailscaleServeStatus, target string) (string, bool) {
	if len(status.TCP) != 1 || len(status.Web) != 1 || len(status.Services) != 0 || len(status.Foreground) != 0 {
		return "", false
	}
	tcp, ok := status.TCP["443"]
	if !ok || !tcp.HTTPS || tcp.HTTP || tcp.TCPForward != "" || tcp.TerminateTLS != "" || tcp.ProxyProtocol != 0 {
		return "", false
	}
	for hostPort, web := range status.Web {
		hostname, port, err := net.SplitHostPort(hostPort)
		if err != nil || port != "443" || !validTailscaleHostname(hostname) || len(web.Handlers) != 1 {
			return "", false
		}
		handler, ok := web.Handlers["/"]
		if !ok || handler.Proxy != target || handler.Path != "" || handler.Text != "" || handler.Redirect != "" || len(handler.AcceptAppCaps) != 0 {
			return "", false
		}
		if len(status.AllowFunnel) > 1 {
			return "", false
		}
		for funnelHostPort, allowed := range status.AllowFunnel {
			if allowed || !strings.EqualFold(funnelHostPort, hostPort) {
				return "", false
			}
		}
		return strings.ToLower(hostname), true
	}
	return "", false
}

func validTailscaleHostname(value string) bool {
	hostname := strings.ToLower(strings.TrimSuffix(strings.TrimSpace(value), "."))
	if len(hostname) < len("a.ts.net") || len(hostname) > 253 || !strings.HasSuffix(hostname, ".ts.net") {
		return false
	}
	for _, label := range strings.Split(hostname, ".") {
		if label == "" || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
			return false
		}
		for _, character := range label {
			if (character < 'a' || character > 'z') && (character < '0' || character > '9') && character != '-' {
				return false
			}
		}
	}
	return true
}

func validTailscaleProviderURL(value string) bool {
	if len(value) == 0 || len(value) > 2048 {
		return false
	}
	parsed, err := url.Parse(value)
	return err == nil && parsed.Scheme == "https" && parsed.User == nil && parsed.Port() == "" &&
		strings.EqualFold(parsed.Hostname(), "login.tailscale.com") && strings.HasPrefix(parsed.Path, "/") && parsed.Fragment == ""
}

func hostnameOnly(value string) string {
	host := strings.TrimSpace(value)
	if parsed, _, err := net.SplitHostPort(host); err == nil {
		host = parsed
	}
	return strings.ToLower(strings.Trim(strings.TrimSuffix(host, "."), "[]"))
}

func (s *Server) handleTailscaleRemoteAccessStatus(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, s.remoteAccess.Status(r.Context()))
}

func (s *Server) handleVerifyTailscaleRemoteAccess(w http.ResponseWriter, r *http.Request) {
	// Windows UAC and first-time HTTPS certificate provisioning can take longer
	// than the Manager's normal response deadline. Keep the stricter global
	// timeout and extend only this explicit, authenticated interaction.
	_ = http.NewResponseController(w).SetWriteDeadline(time.Now().Add(tailscaleResponseTimeout))
	status, err := s.remoteAccess.Verify(r.Context())
	if err != nil {
		var providerApproval tailscaleProviderApprovalError
		switch {
		case errors.Is(err, ErrRemoteAccessUnsupported):
			writeAPIError(w, http.StatusConflict, "platform-unsupported", "Tailscale remote access is not available for this package yet.")
		case errors.Is(err, ErrTailscaleApprovalDeclined):
			s.recordDiagnostic("remote-access", "warning", "tailscale-approval-declined")
			writeAPIError(w, http.StatusConflict, "tailscale-approval-declined", "Windows administrator approval was cancelled. Tailscale Serve was not changed.")
		case errors.Is(err, ErrTailscaleHostAuthorization):
			s.recordDiagnostic("remote-access", "warning", "tailscale-host-authorization-required")
			writeAPIError(w, http.StatusConflict, "tailscale-host-authorization-required", "Run sudo tautweekly remote-access-authorize on the Linux host, then retry.")
		case errors.As(err, &providerApproval) && validTailscaleProviderURL(providerApproval.url):
			s.recordDiagnostic("remote-access", "warning", "tailscale-provider-approval-required")
			writeAPIFieldErrors(w, http.StatusConflict, "tailscale-provider-approval-required", "Tailscale requires one-time HTTPS approval before Serve can be enabled.", map[string]string{"setupUrl": providerApproval.url})
		case errors.Is(err, ErrTailscaleServeConflict):
			writeAPIError(w, http.StatusConflict, "tailscale-serve-conflict", "Tailscale Serve already has a different configuration. TautWeekly left it unchanged.")
		case errors.Is(err, ErrTailscaleConfigurationInvalid):
			s.recordDiagnostic("remote-access", "failed", "tailscale-verification-failed")
			writeAPIError(w, http.StatusBadGateway, "tailscale-verification-failed", "Tailscale returned an unexpected Serve configuration. Nothing was changed.")
		default:
			s.recordDiagnostic("remote-access", "failed", "tailscale-unavailable")
			writeAPIError(w, http.StatusBadGateway, "tailscale-unavailable", "Tailscale status could not be verified.")
		}
		return
	}
	outcome := "passed"
	if status.State == "conflict" || status.State == "interrupted" {
		outcome = "warning"
	}
	s.recordDiagnostic("remote-access", outcome, "tailscale-verified")
	writeJSON(w, http.StatusOK, status)
}

func (s *Server) handleUpdateTailscaleRemoteAccess(w http.ResponseWriter, r *http.Request) {
	// See handleVerifyTailscaleRemoteAccess. This deadline covers the response;
	// the elevated helper still owns and verifies the complete Serve operation.
	_ = http.NewResponseController(w).SetWriteDeadline(time.Now().Add(tailscaleResponseTimeout))
	var request tailscaleRemoteAccessRequest
	if err := decodeJSON(r, &request); err != nil {
		s.recordDiagnostic("remote-access", "failed", "remote-access-request-invalid")
		writeAPIError(w, http.StatusBadRequest, "invalid-request", "The Tailscale remote access request was invalid.")
		return
	}
	status, err := s.remoteAccess.Update(r.Context(), request.Enabled, request.URL, request.ConfirmedPrivate)
	if err != nil {
		var providerApproval tailscaleProviderApprovalError
		switch {
		case errors.Is(err, ErrRemoteAccessUnsupported):
			s.recordDiagnostic("remote-access", "failed", "remote-access-unsupported")
			writeAPIError(w, http.StatusConflict, "platform-unsupported", "Tailscale remote access is not available for this package yet.")
		case errors.Is(err, ErrTailscaleServeConflict):
			s.recordDiagnostic("remote-access", "failed", "tailscale-serve-conflict")
			writeAPIError(w, http.StatusConflict, "tailscale-serve-conflict", "Tailscale Serve already has a different configuration. TautWeekly left it unchanged.")
		case errors.Is(err, ErrTailscaleDisableIncomplete):
			s.recordDiagnostic("remote-access", "warning", "tailscale-disable-incomplete")
			writeAPIError(w, http.StatusBadGateway, "tailscale-disable-incomplete", "TautWeekly blocked the private hostname locally, but Tailscale Serve could not be cleaned up. Restore Tailscale access and try Disable again, or remove its HTTPS Serve route manually.")
		case errors.Is(err, ErrTailscaleApprovalDeclined):
			s.recordDiagnostic("remote-access", "warning", "tailscale-approval-declined")
			writeAPIError(w, http.StatusConflict, "tailscale-approval-declined", "Windows administrator approval was cancelled. Tailscale Serve was not changed.")
		case errors.Is(err, ErrTailscaleHostAuthorization):
			s.recordDiagnostic("remote-access", "warning", "tailscale-host-authorization-required")
			writeAPIError(w, http.StatusConflict, "tailscale-host-authorization-required", "Run sudo tautweekly remote-access-authorize on the Linux host, then retry.")
		case errors.As(err, &providerApproval) && validTailscaleProviderURL(providerApproval.url):
			s.recordDiagnostic("remote-access", "warning", "tailscale-provider-approval-required")
			writeAPIFieldErrors(w, http.StatusConflict, "tailscale-provider-approval-required", "Tailscale requires one-time HTTPS approval before Serve can be enabled.", map[string]string{"setupUrl": providerApproval.url})
		case errors.Is(err, ErrTailscaleUnavailable):
			s.recordDiagnostic("remote-access", "failed", "tailscale-unavailable")
			writeAPIError(w, http.StatusBadGateway, "tailscale-unavailable", "Tailscale is not installed, connected, or available to this package host.")
		case errors.Is(err, ErrTailscaleApprovalRequired):
			s.recordDiagnostic("remote-access", "failed", "tailscale-approval-required")
			writeAPIError(w, http.StatusConflict, "tailscale-approval-required", "Windows administrator approval is required to change Tailscale Serve. The Manager itself remains unelevated.")
		case errors.Is(err, ErrTailscaleSignInRequired):
			s.recordDiagnostic("remote-access", "failed", "tailscale-sign-in-required")
			writeAPIError(w, http.StatusConflict, "tailscale-sign-in-required", "Sign in to Tailscale on this Windows computer, then refresh this status.")
		case errors.Is(err, ErrTailscaleConfigurationInvalid):
			s.recordDiagnostic("remote-access", "failed", "tailscale-verification-failed")
			writeAPIError(w, http.StatusBadGateway, "tailscale-verification-failed", "Tailscale did not retain the expected private HTTPS route. TautWeekly did not allow the remote hostname.")
		case errors.Is(err, ErrTailscaleURLRequired):
			s.recordDiagnostic("remote-access", "failed", "remote-access-request-invalid")
			writeAPIFieldErrors(w, http.StatusBadRequest, "tailscale-url-required", "Paste the exact private HTTPS address created by Tailscale Serve.", map[string]string{"url": "A private https://…ts.net address is required."})
		case errors.Is(err, ErrTailscaleURLInvalid):
			s.recordDiagnostic("remote-access", "failed", "remote-access-request-invalid")
			writeAPIFieldErrors(w, http.StatusBadRequest, "tailscale-url-invalid", "The private Tailscale address was invalid.", map[string]string{"url": "Use an exact https://…ts.net address without a port, path, query, user information, or fragment."})
		case errors.Is(err, ErrTailscalePrivateConfirmation):
			s.recordDiagnostic("remote-access", "failed", "remote-access-request-invalid")
			writeAPIFieldErrors(w, http.StatusBadRequest, "tailscale-private-confirmation-required", "Confirm that the host route uses private HTTPS Serve and that Funnel is off.", map[string]string{"confirmedPrivate": "Private HTTPS and Funnel-off confirmation is required."})
		default:
			s.recordDiagnostic("remote-access", "failed", "remote-access-state-write-failed")
			writeAPIError(w, http.StatusInternalServerError, "remote-access-update-failed", "The private remote access setting could not be saved safely.")
		}
		return
	}
	code := "tailscale-disabled"
	if status.Enabled && status.Active {
		code = "tailscale-enabled"
	}
	s.recordDiagnostic("remote-access", "passed", code)
	writeJSON(w, http.StatusOK, status)
}

func (s *Server) remoteRequestIsSecure(r *http.Request) bool {
	authority, ok := canonicalAuthority(r.Host, "https")
	return r.TLS != nil || s.options.SecureCookies || ok && authority.port == "443" && s.remoteAccess.AllowsHost(authority.host)
}
