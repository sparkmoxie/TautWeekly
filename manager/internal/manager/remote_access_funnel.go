package manager

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
)

const publicFunnelSchemaVersion = 2

type publicFunnelFile struct {
	SchemaVersion     int    `json:"schemaVersion"`
	Enabled           bool   `json:"enabled"`
	Hostname          string `json:"hostname,omitempty"`
	PubliclyPublished bool   `json:"publiclyPublished,omitempty"`
}

// publicRemoteAccessRunner is the narrow provider-adapter boundary. Browser input
// can select only one of the three actions; the adapter owns the fixed target,
// provider CLI path, privilege transition, and sanitized observation.
type publicRemoteAccessRunner interface {
	Available() bool
	RunPublicRoute(context.Context, string, string) (publicRemoteAccessObservation, error)
}

type publicRemoteAccessRouteState string

const (
	publicRemoteAccessRouteEmpty    publicRemoteAccessRouteState = "empty"
	publicRemoteAccessRouteOwned    publicRemoteAccessRouteState = "owned"
	publicRemoteAccessRouteLegacy   publicRemoteAccessRouteState = "legacy"
	publicRemoteAccessRouteConflict publicRemoteAccessRouteState = "conflict"
)

type publicRemoteAccessObservation struct {
	RouteState        publicRemoteAccessRouteState
	Hostname          string
	PubliclyPublished bool
}

type publicFunnelController struct {
	opMu            sync.Mutex
	stateMu         sync.RWMutex
	runner          publicRemoteAccessRunner
	statePath       string
	legacyStatePath string
	target          string
	supported       bool
	state           publicFunnelFile
	stateError      error
	legacyEnabled   bool
	legacyError     error
}

func newPublicFunnelController(dataDir, listenAddress, stateFile string, supported bool, runner publicRemoteAccessRunner) *publicFunnelController {
	controller := &publicFunnelController{
		runner:          runner,
		statePath:       filepath.Join(dataDir, stateFile),
		legacyStatePath: filepath.Join(dataDir, remoteAccessStateFile),
		target:          tailscaleLoopbackTarget(listenAddress),
		supported:       supported,
		state:           publicFunnelFile{SchemaVersion: publicFunnelSchemaVersion},
	}
	controller.loadState()
	controller.loadLegacyState()
	return controller
}

func (c *publicFunnelController) loadState() {
	raw, err := os.ReadFile(c.statePath)
	if errors.Is(err, os.ErrNotExist) {
		return
	}
	if err != nil || len(raw) > 64<<10 {
		c.stateError = errors.New("public remote-access state is unavailable")
		return
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	var saved publicFunnelFile
	if err := decoder.Decode(&saved); err != nil || decoder.Decode(&struct{}{}) != io.EOF ||
		(saved.SchemaVersion != 1 && saved.SchemaVersion != publicFunnelSchemaVersion) ||
		(saved.Enabled && !validTailscaleHostname(saved.Hostname)) ||
		(!saved.Enabled && (saved.Hostname != "" || saved.PubliclyPublished)) {
		c.stateError = errors.New("public remote-access state is invalid")
		return
	}
	// Schema 1 recorded only the local route. Treat it as publication pending
	// until an explicit Verify proves public DNS and trusted TLS.
	saved.SchemaVersion = publicFunnelSchemaVersion
	c.state = saved
}

func (c *publicFunnelController) loadLegacyState() {
	raw, err := os.ReadFile(c.legacyStatePath)
	if errors.Is(err, os.ErrNotExist) {
		return
	}
	if err != nil || len(raw) > 64<<10 {
		c.legacyError = errors.New("legacy remote-access state is unavailable")
		return
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	var saved remoteAccessFile
	if err := decoder.Decode(&saved); err != nil || decoder.Decode(&struct{}{}) != io.EOF ||
		saved.SchemaVersion != remoteAccessSchemaVersion ||
		(saved.Enabled && !validTailscaleHostname(saved.Hostname)) || (!saved.Enabled && saved.Hostname != "") {
		c.legacyError = errors.New("legacy remote-access state is invalid")
		return
	}
	c.legacyEnabled = saved.Enabled
}

func (c *publicFunnelController) savedState() (publicFunnelFile, error) {
	c.stateMu.RLock()
	defer c.stateMu.RUnlock()
	if c.stateError != nil {
		return c.state, c.stateError
	}
	return c.state, c.legacyError
}

func (c *publicFunnelController) saveState(next publicFunnelFile) error {
	if err := writePrivateJSON(c.statePath, next); err != nil {
		return err
	}
	c.stateMu.Lock()
	c.state = next
	c.stateError = nil
	c.stateMu.Unlock()
	return nil
}

func (c *publicFunnelController) clearLegacyState() error {
	info, err := os.Lstat(c.legacyStatePath)
	if errors.Is(err, os.ErrNotExist) {
		c.legacyEnabled = false
		c.legacyError = nil
		return nil
	}
	if err != nil || !info.Mode().IsRegular() {
		return errors.New("legacy remote-access state could not be removed safely")
	}
	if err := os.Remove(c.legacyStatePath); err != nil {
		return err
	}
	c.legacyEnabled = false
	c.legacyError = nil
	return nil
}

func (c *publicFunnelController) PublicExposureConfigured() bool {
	state, err := c.savedState()
	return err != nil || state.Enabled || c.legacyEnabled
}

func (c *publicFunnelController) PublicExposureSupported() bool {
	return c != nil && c.supported
}

func (c *publicFunnelController) AllowsHost(value string) bool {
	state, err := c.savedState()
	return err == nil && state.Enabled && state.PubliclyPublished && validTailscaleHostname(state.Hostname) && strings.EqualFold(state.Hostname, hostnameOnly(value))
}

func (c *publicFunnelController) Status(context.Context) TailscaleRemoteAccessStatus {
	c.opMu.Lock()
	defer c.opMu.Unlock()
	return c.status()
}

func (c *publicFunnelController) runnerAvailability() string {
	if c.runner == nil {
		return "not-installed"
	}
	if availability, ok := c.runner.(tailscaleRunnerAvailability); ok {
		return availability.Availability()
	}
	if c.runner.Available() {
		return "available"
	}
	return "not-installed"
}

func (c *publicFunnelController) runnerError() error {
	if c.runnerAvailability() == "authorization-required" {
		return ErrTailscaleHostAuthorization
	}
	return ErrTailscaleUnavailable
}

func (c *publicFunnelController) status() TailscaleRemoteAccessStatus {
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
	availability := c.runnerAvailability()
	result.Installed = availability != "not-installed"
	if c.legacyEnabled {
		result.State = "migration-required"
		result.ErrorCode = "tailscale-serve-migration-required"
		result.CleanupRequired = true
		if availability == "authorization-required" {
			result.HostAuthorizationRequired = true
			result.HostAuthorizationCommand = "sudo tautweekly remote-access-authorize"
		}
		return result
	}
	if availability != "available" || c.runner == nil || !c.runner.Available() {
		if availability == "authorization-required" {
			result.Installed = true
			result.State = "authorization-required"
			result.ErrorCode = "tailscale-host-authorization-required"
			result.HostAuthorizationRequired = true
			result.HostAuthorizationCommand = "sudo tautweekly remote-access-authorize"
			return result
		}
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
	if result.Enabled {
		if state.PubliclyPublished {
			result.Active = true
			result.State = "active"
		} else {
			result.State = "starting"
			result.ErrorCode = "tailscale-funnel-publication-pending"
		}
		return result
	}
	if approval, ok := c.runner.(tailscaleApprovalRequirement); ok && approval.RequiresApproval() {
		result.State = "approval-required"
		result.ErrorCode = "tailscale-approval-required"
		return result
	}
	result.State = "ready"
	return result
}

func (c *publicFunnelController) Verify(ctx context.Context) (TailscaleRemoteAccessStatus, error) {
	c.opMu.Lock()
	defer c.opMu.Unlock()
	if !c.supported {
		return c.status(), ErrRemoteAccessUnsupported
	}
	if c.runner == nil || !c.runner.Available() {
		return c.status(), c.runnerError()
	}
	observation, err := c.runner.RunPublicRoute(ctx, "inspect", c.target)
	if err != nil {
		return c.status(), err
	}
	status := c.observedStatus(observation)
	if status.Enabled && (status.State == "active" || status.State == "starting") {
		state, stateErr := c.savedState()
		if stateErr != nil {
			return c.status(), ErrTailscaleConfigurationInvalid
		}
		state.PubliclyPublished = observation.PubliclyPublished
		if err := c.saveState(state); err != nil {
			return c.status(), err
		}
	}
	return status, nil
}

func (c *publicFunnelController) observedStatus(observation publicRemoteAccessObservation) TailscaleRemoteAccessStatus {
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
	switch observation.RouteState {
	case publicRemoteAccessRouteEmpty:
		if state.Enabled || c.legacyEnabled {
			result.State = "needs-attention"
			result.ErrorCode = "tailscale-funnel-missing"
			return result
		}
		result.State = "inactive"
		return result
	case publicRemoteAccessRouteOwned:
		if state.Enabled && validTailscaleHostname(observation.Hostname) && strings.EqualFold(state.Hostname, observation.Hostname) {
			if observation.PubliclyPublished {
				result.Active = true
				result.State = "active"
			} else {
				result.State = "starting"
				result.ErrorCode = "tailscale-funnel-publication-pending"
			}
			return result
		}
		result.State = "needs-attention"
		result.ErrorCode = "tailscale-funnel-untracked"
		result.CleanupRequired = true
		return result
	case publicRemoteAccessRouteLegacy:
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

func (c *publicFunnelController) Update(ctx context.Context, enabled bool, _ string, _ bool) (TailscaleRemoteAccessStatus, error) {
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

func (c *publicFunnelController) enable(ctx context.Context) (TailscaleRemoteAccessStatus, error) {
	if c.runner == nil || !c.runner.Available() {
		return c.status(), c.runnerError()
	}
	observation, err := c.runner.RunPublicRoute(ctx, "enable", c.target)
	if err != nil {
		return c.status(), err
	}
	if observation.RouteState != publicRemoteAccessRouteOwned || !validTailscaleHostname(observation.Hostname) {
		return c.status(), ErrTailscaleConfigurationInvalid
	}
	if err := c.saveState(publicFunnelFile{
		SchemaVersion: publicFunnelSchemaVersion, Enabled: true, Hostname: observation.Hostname,
		PubliclyPublished: observation.PubliclyPublished,
	}); err != nil {
		if _, rollbackErr := c.runner.RunPublicRoute(ctx, "disable", c.target); rollbackErr != nil {
			return c.status(), ErrTailscaleDisableIncomplete
		}
		return c.status(), err
	}
	if err := c.clearLegacyState(); err != nil {
		if _, rollbackErr := c.runner.RunPublicRoute(ctx, "disable", c.target); rollbackErr != nil {
			return c.status(), ErrTailscaleDisableIncomplete
		}
		if resetErr := c.saveState(publicFunnelFile{SchemaVersion: publicFunnelSchemaVersion}); resetErr != nil {
			return c.status(), resetErr
		}
		return c.status(), err
	}
	return c.observedStatus(observation), nil
}

func (c *publicFunnelController) EnsureInactive(ctx context.Context) (TailscaleRemoteAccessStatus, error) {
	c.opMu.Lock()
	defer c.opMu.Unlock()
	return c.ensureInactive(ctx)
}

func (c *publicFunnelController) ensureInactive(ctx context.Context) (TailscaleRemoteAccessStatus, error) {
	if !c.PublicExposureConfigured() {
		return c.status(), nil
	}
	if c.runner == nil || !c.runner.Available() {
		return c.status(), ErrTailscaleDisableIncomplete
	}
	observation, err := c.runner.RunPublicRoute(ctx, "disable", c.target)
	if err != nil || observation.RouteState != publicRemoteAccessRouteEmpty {
		return c.status(), ErrTailscaleDisableIncomplete
	}
	if err := c.saveState(publicFunnelFile{SchemaVersion: publicFunnelSchemaVersion}); err != nil {
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

// normalizeTailscalePublicObservation keeps provider CLI JSON out of the
// shared controller boundary.
func normalizeTailscalePublicObservation(status tailscaleServeStatus, target string, publiclyPublished bool) publicRemoteAccessObservation {
	if serveStatusEmpty(status) {
		return publicRemoteAccessObservation{RouteState: publicRemoteAccessRouteEmpty}
	}
	if hostname, owned := ownedTailscaleFunnel(status, target); owned {
		return publicRemoteAccessObservation{
			RouteState:        publicRemoteAccessRouteOwned,
			Hostname:          hostname,
			PubliclyPublished: publiclyPublished,
		}
	}
	if hostname, owned := ownedTailscaleServe(status, target); owned {
		return publicRemoteAccessObservation{RouteState: publicRemoteAccessRouteLegacy, Hostname: hostname}
	}
	return publicRemoteAccessObservation{RouteState: publicRemoteAccessRouteConflict}
}
