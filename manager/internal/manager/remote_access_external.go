package manager

import (
	"context"
	"errors"
	"net/url"
	"strings"
)

var (
	ErrTailscaleURLRequired         = errors.New("a private Tailscale HTTPS address is required")
	ErrTailscaleURLInvalid          = errors.New("the private Tailscale HTTPS address is invalid")
	ErrTailscalePrivateConfirmation = errors.New("private HTTPS and Funnel-off confirmation is required")
)

// externalTailscaleRemoteAccessController is used when the package host owns
// Tailscale. The Manager never receives host or container control; it accepts
// only one exact HTTPS .ts.net hostname after the authenticated administrator
// has created the private Serve route outside the Manager.
type externalTailscaleRemoteAccessController struct {
	*tailscaleRemoteAccessController
}

func newExternalTailscaleRemoteAccessController(dataDir, listenAddress string) remoteAccessController {
	return &externalTailscaleRemoteAccessController{
		tailscaleRemoteAccessController: newTailscaleRemoteAccessController(dataDir, listenAddress, true, nil),
	}
}

func (c *externalTailscaleRemoteAccessController) Status(context.Context) TailscaleRemoteAccessStatus {
	state, err := c.savedState()
	result := TailscaleRemoteAccessStatus{
		Supported: true, Installed: true, State: "external-ready", Provider: "tailscale",
		NetworkKind: "private-tailnet", Management: "external", RequiresURL: true,
	}
	if err != nil {
		result.Installed = false
		result.State = "unavailable"
		result.ErrorCode = "remote-state-invalid"
		return result
	}
	if state.Enabled {
		result.Enabled = true
		result.Active = true
		result.State = "external-enabled"
		result.URL = "https://" + state.Hostname
	}
	return result
}

func (c *externalTailscaleRemoteAccessController) Verify(ctx context.Context) (TailscaleRemoteAccessStatus, error) {
	return c.Status(ctx), nil
}

func (c *externalTailscaleRemoteAccessController) Update(ctx context.Context, enabled bool, value string, confirmedPrivate bool) (TailscaleRemoteAccessStatus, error) {
	if !enabled {
		if err := c.saveState(remoteAccessFile{SchemaVersion: remoteAccessSchemaVersion}); err != nil {
			return c.Status(ctx), err
		}
		return c.Status(ctx), nil
	}
	if !confirmedPrivate {
		return c.Status(ctx), ErrTailscalePrivateConfirmation
	}
	hostname, err := tailscaleHostnameFromURL(value)
	if err != nil {
		return c.Status(ctx), err
	}
	if err := c.saveState(remoteAccessFile{SchemaVersion: remoteAccessSchemaVersion, Enabled: true, Hostname: hostname}); err != nil {
		return c.Status(ctx), err
	}
	return c.Status(ctx), nil
}

func tailscaleHostnameFromURL(value string) (string, error) {
	value = strings.TrimSpace(value)
	if value == "" {
		return "", ErrTailscaleURLRequired
	}
	if len(value) > 2048 {
		return "", ErrTailscaleURLInvalid
	}
	parsed, err := url.Parse(value)
	if err != nil || parsed.Scheme != "https" || parsed.User != nil || parsed.Port() != "" ||
		(parsed.Path != "" && parsed.Path != "/") || parsed.RawQuery != "" || parsed.Fragment != "" ||
		!validTailscaleHostname(parsed.Hostname()) {
		return "", ErrTailscaleURLInvalid
	}
	return strings.ToLower(strings.TrimSuffix(parsed.Hostname(), ".")), nil
}
