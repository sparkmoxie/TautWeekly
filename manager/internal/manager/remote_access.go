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
	"strings"
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
	ErrTailscaleApprovalRequired     = errors.New("Windows administrator approval is required for Tailscale Funnel")
	ErrTailscaleApprovalDeclined     = errors.New("Windows administrator approval was declined")
	ErrTailscaleHostAuthorization    = errors.New("host administrator authorization is required for Tailscale remote access")
	ErrTailscaleProviderApproval     = errors.New("Tailscale provider approval is required")
	ErrTailscaleSignInRequired       = errors.New("Tailscale sign-in is required")
	ErrTailscaleServeConflict        = errors.New("Tailscale already has a conflicting route")
	ErrTailscaleConfigurationInvalid = errors.New("Tailscale Funnel returned an unexpected configuration")
	ErrTailscaleDisableIncomplete    = errors.New("Tailscale Funnel cleanup is incomplete")
	ErrManagerPasswordRequired       = errors.New("the Manager password lock is required for public remote access")
	ErrTailscaleNotRunning           = errors.New("the Tailscale service is not running")
	ErrTailscaleFunnelUnsupported    = errors.New("this Tailscale installation does not support Funnel")
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
	HostAuthorizationRequired bool   `json:"hostAuthorizationRequired"`
	HostAuthorizationCommand  string `json:"hostAuthorizationCommand,omitempty"`
	PasswordRequired          bool   `json:"passwordRequired,omitempty"`
	CleanupRequired           bool   `json:"cleanupRequired,omitempty"`
}

type tailscaleRemoteAccessRequest struct {
	Operation string `json:"operation"`
}

type remoteAccessController interface {
	Status(context.Context) TailscaleRemoteAccessStatus
	Verify(context.Context) (TailscaleRemoteAccessStatus, error)
	Update(context.Context, bool, string, bool) (TailscaleRemoteAccessStatus, error)
	AllowsHost(string) bool
}

// publicRemoteAccessSafety is the provider-neutral public ingress boundary.
// Implementations may report unsupported, but no maintained controller accepts
// an administrator-supplied host, port, URL, executable, or CLI argument.
type publicRemoteAccessSafety interface {
	remoteAccessController
	PublicExposureSupported() bool
	PublicExposureConfigured() bool
	EnsureInactive(context.Context) (TailscaleRemoteAccessStatus, error)
}

func isPublicRemoteAccess(controller remoteAccessController) bool {
	_, ok := controller.(publicRemoteAccessSafety)
	return ok
}

func publicRemoteAccessSupported(controller remoteAccessController) bool {
	public, ok := controller.(publicRemoteAccessSafety)
	return ok && public.PublicExposureSupported()
}

func cleanupPublicRemoteAccess(ctx context.Context, controller remoteAccessController) error {
	public, ok := controller.(publicRemoteAccessSafety)
	if !ok || !public.PublicExposureConfigured() {
		return nil
	}
	status, err := public.EnsureInactive(ctx)
	if err != nil || status.Enabled || status.Active || status.CleanupRequired {
		if err != nil {
			return err
		}
		return ErrTailscaleDisableIncomplete
	}
	return nil
}

// CleanupPublicRemoteAccess is used by local recovery, updates, shutdown, and
// uninstall before any can remove the password boundary or application files.
// It is a no-op when public exposure is unsupported or not configured.
func CleanupPublicRemoteAccess(ctx context.Context, options Options) error {
	return cleanupPublicRemoteAccess(ctx, newPlatformRemoteAccessController(options))
}

type tailscaleRunnerAvailability interface {
	Availability() string
}

type tailscaleHostAuthorizationCommand interface {
	HostAuthorizationCommand() string
}

type tailscaleApprovalRequirement interface {
	RequiresApproval() bool
}

type tailscaleHelperRequest struct {
	SchemaVersion int    `json:"schemaVersion"`
	Nonce         string `json:"nonce"`
	Action        string `json:"action"`
	Target        string `json:"target"`
}

type tailscaleHelperResult struct {
	SchemaVersion     int             `json:"schemaVersion"`
	Nonce             string          `json:"nonce"`
	Code              string          `json:"code"`
	ServeStatus       json.RawMessage `json:"serveStatus,omitempty"`
	SetupURL          string          `json:"setupUrl,omitempty"`
	PubliclyPublished bool            `json:"publiclyPublished,omitempty"`
}

type remoteAccessFile struct {
	SchemaVersion int    `json:"schemaVersion"`
	Enabled       bool   `json:"enabled"`
	Hostname      string `json:"hostname,omitempty"`
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
	writeJSON(w, http.StatusOK, s.remoteAccessStatus(r.Context()))
}

func (s *Server) remoteAccessStatus(ctx context.Context) TailscaleRemoteAccessStatus {
	status := s.remoteAccess.Status(ctx)
	if publicRemoteAccessSupported(s.remoteAccess) && !s.publicPasswordBoundaryActive() {
		status.PasswordRequired = true
		status.State = "manager-password-required"
		status.ErrorCode = "manager-password-required"
	}
	return status
}

func (s *Server) publicPasswordBoundaryActive() bool {
	return s.auth.authenticationRequired() && s.auth.passwordConfigured()
}

func (s *Server) handleVerifyTailscaleRemoteAccess(w http.ResponseWriter, r *http.Request) {
	// Platform approval and first-time HTTPS certificate provisioning can take longer
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
			message := "Windows administrator approval was cancelled. Tailscale Funnel was not changed."
			if isPublicRemoteAccess(s.remoteAccess) {
				message = "Windows administrator approval was cancelled. The TautWeekly Funnel was not changed."
			}
			writeAPIError(w, http.StatusConflict, "tailscale-approval-declined", message)
		case errors.Is(err, ErrTailscaleHostAuthorization):
			s.recordDiagnostic("remote-access", "warning", "tailscale-host-authorization-required")
			writeAPIError(w, http.StatusConflict, "tailscale-host-authorization-required", "Run the fixed package authorization command shown in Settings, then retry.")
		case errors.As(err, &providerApproval) && validTailscaleProviderURL(providerApproval.url):
			s.recordDiagnostic("remote-access", "warning", "tailscale-provider-approval-required")
			writeAPIFieldErrors(w, http.StatusConflict, "tailscale-provider-approval-required", "Tailscale requires one-time provider approval before remote access can be enabled.", map[string]string{"setupUrl": providerApproval.url})
		case errors.Is(err, ErrTailscaleServeConflict):
			writeAPIError(w, http.StatusConflict, "tailscale-route-conflict", "Tailscale already has a different configuration. TautWeekly left it unchanged.")
		case errors.Is(err, ErrTailscaleNotRunning):
			s.recordDiagnostic("remote-access", "failed", "tailscale-not-running")
			writeAPIError(w, http.StatusConflict, "tailscale-not-running", "Start the official Tailscale service on this host, then verify again.")
		case errors.Is(err, ErrTailscaleFunnelUnsupported):
			s.recordDiagnostic("remote-access", "failed", "tailscale-funnel-unsupported")
			writeAPIError(w, http.StatusConflict, "tailscale-funnel-unsupported", "Update the official Tailscale client on this host to a version that supports Funnel, then verify again.")
		case errors.Is(err, ErrTailscaleConfigurationInvalid):
			s.recordDiagnostic("remote-access", "failed", "tailscale-verification-failed")
			writeAPIError(w, http.StatusBadGateway, "tailscale-verification-failed", "Tailscale returned an unexpected route configuration. Nothing was changed.")
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
	code := "tailscale-verified"
	if isPublicRemoteAccess(s.remoteAccess) {
		code = "tailscale-funnel-verified"
		if status.State == "starting" {
			outcome = "warning"
			code = "tailscale-funnel-publication-pending"
		} else if status.State == "needs-attention" || status.State == "migration-required" {
			outcome = "warning"
			code = "tailscale-funnel-needs-attention"
		}
	}
	s.recordDiagnostic("remote-access", outcome, code)
	if publicRemoteAccessSupported(s.remoteAccess) && !s.publicPasswordBoundaryActive() {
		status.PasswordRequired = true
		status.State = "manager-password-required"
		status.ErrorCode = "manager-password-required"
	}
	writeJSON(w, http.StatusOK, status)
}

func (s *Server) handleUpdateTailscaleRemoteAccess(w http.ResponseWriter, r *http.Request) {
	// See handleVerifyTailscaleRemoteAccess. This deadline covers the response;
	// the platform adapter still owns and verifies the complete remote-access operation.
	_ = http.NewResponseController(w).SetWriteDeadline(time.Now().Add(tailscaleResponseTimeout))
	var request tailscaleRemoteAccessRequest
	if err := decodeJSON(r, &request); err != nil {
		s.recordDiagnostic("remote-access", "failed", "remote-access-request-invalid")
		writeAPIError(w, http.StatusBadRequest, "invalid-request", "The Tailscale remote access request was invalid.")
		return
	}
	if request.Operation != "enable" && request.Operation != "disable" {
		s.recordDiagnostic("remote-access", "failed", "remote-access-request-invalid")
		writeAPIError(w, http.StatusBadRequest, "invalid-operation", "The Funnel operation must be exactly enable or disable; targets and command arguments are fixed by TautWeekly.")
		return
	}
	enabled := request.Operation == "enable"
	if enabled && publicRemoteAccessSupported(s.remoteAccess) && !s.publicPasswordBoundaryActive() {
		s.recordDiagnostic("remote-access", "failed", "manager-password-required")
		writeAPIError(w, http.StatusConflict, "manager-password-required", "Set and enable the Manager password lock before making its login page publicly reachable.")
		return
	}
	status, err := s.remoteAccess.Update(r.Context(), enabled, "", false)
	if err != nil {
		var providerApproval tailscaleProviderApprovalError
		switch {
		case errors.Is(err, ErrRemoteAccessUnsupported):
			s.recordDiagnostic("remote-access", "failed", "remote-access-unsupported")
			writeAPIError(w, http.StatusConflict, "platform-unsupported", "Tailscale remote access is not available for this package yet.")
		case errors.Is(err, ErrTailscaleServeConflict):
			s.recordDiagnostic("remote-access", "failed", "tailscale-serve-conflict")
			writeAPIError(w, http.StatusConflict, "tailscale-route-conflict", "Tailscale already has a different configuration. TautWeekly left it unchanged.")
		case errors.Is(err, ErrTailscaleDisableIncomplete):
			s.recordDiagnostic("remote-access", "warning", "tailscale-disable-incomplete")
			message := "The Manager kept its password boundary active because the TautWeekly Funnel could not be disabled and verified. Restore Tailscale and try Disable again."
			writeAPIError(w, http.StatusBadGateway, "tailscale-disable-incomplete", message)
		case errors.Is(err, ErrTailscaleApprovalDeclined):
			s.recordDiagnostic("remote-access", "warning", "tailscale-approval-declined")
			message := "Windows administrator approval was cancelled. The TautWeekly Funnel was not changed."
			writeAPIError(w, http.StatusConflict, "tailscale-approval-declined", message)
		case errors.Is(err, ErrTailscaleHostAuthorization):
			s.recordDiagnostic("remote-access", "warning", "tailscale-host-authorization-required")
			writeAPIError(w, http.StatusConflict, "tailscale-host-authorization-required", "Run the fixed package authorization command shown in Settings, then retry.")
		case errors.As(err, &providerApproval) && validTailscaleProviderURL(providerApproval.url):
			s.recordDiagnostic("remote-access", "warning", "tailscale-provider-approval-required")
			writeAPIFieldErrors(w, http.StatusConflict, "tailscale-provider-approval-required", "Tailscale requires one-time provider approval before remote access can be enabled.", map[string]string{"setupUrl": providerApproval.url})
		case errors.Is(err, ErrTailscaleUnavailable):
			s.recordDiagnostic("remote-access", "failed", "tailscale-unavailable")
			writeAPIError(w, http.StatusBadGateway, "tailscale-unavailable", "Tailscale is not installed, connected, or available to this package host.")
		case errors.Is(err, ErrTailscaleNotRunning):
			s.recordDiagnostic("remote-access", "failed", "tailscale-not-running")
			writeAPIError(w, http.StatusConflict, "tailscale-not-running", "Start the official Tailscale service on this host, then verify again.")
		case errors.Is(err, ErrTailscaleFunnelUnsupported):
			s.recordDiagnostic("remote-access", "failed", "tailscale-funnel-unsupported")
			writeAPIError(w, http.StatusConflict, "tailscale-funnel-unsupported", "Update the official Tailscale client on this host to a version that supports Funnel, then verify again.")
		case errors.Is(err, ErrManagerPasswordRequired):
			s.recordDiagnostic("remote-access", "failed", "manager-password-required")
			writeAPIError(w, http.StatusConflict, "manager-password-required", "Set and enable the Manager password lock before making its login page publicly reachable.")
		case errors.Is(err, ErrTailscaleApprovalRequired):
			s.recordDiagnostic("remote-access", "failed", "tailscale-approval-required")
			message := "Windows administrator approval is required to change the TautWeekly Funnel. The Manager itself remains unelevated."
			writeAPIError(w, http.StatusConflict, "tailscale-approval-required", message)
		case errors.Is(err, ErrTailscaleSignInRequired):
			s.recordDiagnostic("remote-access", "failed", "tailscale-sign-in-required")
			writeAPIError(w, http.StatusConflict, "tailscale-sign-in-required", "Sign in to Tailscale on this host outside Manager, then refresh this status.")
		case errors.Is(err, ErrTailscaleConfigurationInvalid):
			s.recordDiagnostic("remote-access", "failed", "tailscale-verification-failed")
			message := "Tailscale did not retain the exact TautWeekly Funnel route. The public hostname was not admitted."
			writeAPIError(w, http.StatusBadGateway, "tailscale-verification-failed", message)
		default:
			s.recordDiagnostic("remote-access", "failed", "remote-access-state-write-failed")
			message := "The public Funnel setting could not be saved safely. TautWeekly attempted to leave its route off."
			writeAPIError(w, http.StatusInternalServerError, "remote-access-update-failed", message)
		}
		return
	}
	code := "tailscale-funnel-disabled"
	if status.Enabled && status.Active {
		code = "tailscale-funnel-enabled"
	} else if status.Enabled && status.State == "starting" {
		code = "tailscale-funnel-publication-pending"
	}
	outcome := "passed"
	if code == "tailscale-funnel-publication-pending" {
		outcome = "warning"
	}
	s.recordDiagnostic("remote-access", outcome, code)
	writeJSON(w, http.StatusOK, status)
}

func (s *Server) remoteRequestIsSecure(r *http.Request) bool {
	authority, ok := canonicalAuthority(r.Host, "https")
	return r.TLS != nil || s.options.SecureCookies || ok && authority.port == "443" && s.remoteHostAllowed(authority.host)
}

func (s *Server) remoteHostAllowed(host string) bool {
	if !s.remoteAccess.AllowsHost(host) {
		return false
	}
	return !publicRemoteAccessSupported(s.remoteAccess) || s.publicPasswordBoundaryActive()
}
