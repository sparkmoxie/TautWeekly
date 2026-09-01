//go:build linux

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
	"path/filepath"
	"strings"
	"time"
)

const (
	linuxRemoteAccessSocket     = "/run/tautweekly/remote-access.sock"
	linuxRemoteAccessTarget     = "http://127.0.0.1:8788"
	containerRemoteAccessSocket = "/run/tautweekly-remote-access/adapter.sock"
	containerRemoteAccessTarget = "http://127.0.0.1:8080"
	containerTailscaleSocket    = "/run/tautweekly-tailscale/tailscaled.sock"
	linuxFunnelStateFile        = "linux-funnel.json"
	containerFunnelStateFile    = "container-funnel.json"
)

type linuxTailscaleRunner struct {
	socket               string
	target               string
	tailscalePath        string
	requireLocalCLI      bool
	authorizationCommand string
}

func newPlatformRemoteAccessController(options Options) remoteAccessController {
	if normalizedRuntimeMode(options.RuntimeMode) == runtimeModeLinux {
		target := tailscaleLoopbackTarget(options.ListenAddress)
		if target == linuxRemoteAccessTarget {
			runner := &linuxTailscaleRunner{
				socket: linuxRemoteAccessSocket, target: target, requireLocalCLI: true,
				authorizationCommand: "sudo tautweekly remote-access-authorize",
			}
			return newPublicFunnelController(options.DataDir, options.ListenAddress, linuxFunnelStateFile, true, runner)
		}
		return newPublicFunnelController(options.DataDir, options.ListenAddress, linuxFunnelStateFile, false, nil)
	}
	if isContainerRuntimeMode(options.RuntimeMode) && strings.TrimSpace(options.ListenAddress) == "0.0.0.0:8080" {
		runner := &linuxTailscaleRunner{
			socket: containerRemoteAccessSocket, target: containerRemoteAccessTarget,
			authorizationCommand: containerFunnelAuthorizationCommand(options.PackageKind),
		}
		return newPublicFunnelController(options.DataDir, "127.0.0.1:8080", containerFunnelStateFile, true, runner)
	}
	if isManagedServiceRuntimeMode(options.RuntimeMode) {
		return newPublicFunnelController(options.DataDir, options.ListenAddress, containerFunnelStateFile, false, nil)
	}
	return newPublicFunnelController(options.DataDir, options.ListenAddress, containerFunnelStateFile, false, nil)
}

func containerFunnelAuthorizationCommand(packageKind string) string {
	switch strings.TrimSpace(packageKind) {
	case packageKindFreeBSD:
		return "sudo tautweekly remote-access-authorize"
	case packageKindUnraid:
		return "/opt/tautweekly/bin/tautweekly-funnel login"
	default:
		return "./tautweekly.sh remote-access-login"
	}
}

func fixedLinuxTailscalePath() string {
	for _, candidate := range []string{"/usr/bin/tailscale", "/usr/local/bin/tailscale"} {
		info, err := os.Lstat(candidate)
		if err == nil && info.Mode().IsRegular() {
			return filepath.Clean(candidate)
		}
	}
	return ""
}

var findFixedLinuxTailscalePath = fixedLinuxTailscalePath

func (r *linuxTailscaleRunner) Availability() string {
	if r == nil {
		return "not-installed"
	}
	if r.requireLocalCLI {
		path := r.tailscalePath
		if path == "" {
			path = findFixedLinuxTailscalePath()
		}
		info, err := os.Lstat(path)
		if err != nil || !info.Mode().IsRegular() {
			return "not-installed"
		}
	}
	info, err := os.Lstat(r.socket)
	if err != nil || info.Mode()&os.ModeSocket == 0 {
		return "authorization-required"
	}
	return "available"
}

func (r *linuxTailscaleRunner) HostAuthorizationCommand() string {
	if r == nil {
		return ""
	}
	return r.authorizationCommand
}

func (r *linuxTailscaleRunner) Available() bool {
	return r != nil && validLinuxRemoteAccessTarget(r.target) && r.Availability() == "available"
}

func (*linuxTailscaleRunner) RequiresApproval() bool { return false }

func (r *linuxTailscaleRunner) RunPublicRoute(ctx context.Context, action, target string) (publicRemoteAccessObservation, error) {
	if !r.Available() {
		if r != nil && r.Availability() == "authorization-required" {
			return publicRemoteAccessObservation{}, ErrTailscaleHostAuthorization
		}
		return publicRemoteAccessObservation{}, ErrTailscaleUnavailable
	}
	if target != r.target || (action != "inspect" && action != "enable" && action != "disable") {
		return publicRemoteAccessObservation{}, ErrTailscaleConfigurationInvalid
	}

	nonceBytes := make([]byte, 32)
	if _, err := rand.Read(nonceBytes); err != nil {
		return publicRemoteAccessObservation{}, ErrTailscaleUnavailable
	}
	nonce := hex.EncodeToString(nonceBytes)
	request := tailscaleHelperRequest{SchemaVersion: 1, Nonce: nonce, Action: action, Target: r.target}
	rawRequest, err := json.Marshal(request)
	if err != nil {
		return publicRemoteAccessObservation{}, ErrTailscaleConfigurationInvalid
	}

	var dialer net.Dialer
	connection, err := dialer.DialContext(ctx, "unix", r.socket)
	if err != nil {
		return publicRemoteAccessObservation{}, ErrTailscaleUnavailable
	}
	defer connection.Close()
	deadline := time.Now().Add(tailscaleResponseTimeout)
	if value, ok := ctx.Deadline(); ok && value.Before(deadline) {
		deadline = value
	}
	_ = connection.SetDeadline(deadline)
	if _, err := connection.Write(rawRequest); err != nil {
		return publicRemoteAccessObservation{}, ErrTailscaleUnavailable
	}
	if unix, ok := connection.(*net.UnixConn); ok {
		_ = unix.CloseWrite()
	}
	raw, err := io.ReadAll(io.LimitReader(connection, maximumTailscaleOutput+1))
	if err != nil || len(raw) == 0 || len(raw) > maximumTailscaleOutput {
		return publicRemoteAccessObservation{}, ErrTailscaleUnavailable
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	var result tailscaleHelperResult
	if err := decoder.Decode(&result); err != nil || decoder.Decode(&struct{}{}) != io.EOF || result.SchemaVersion != 1 || result.Nonce != nonce {
		return publicRemoteAccessObservation{}, ErrTailscaleConfigurationInvalid
	}
	switch result.Code {
	case "enabled", "disabled", "inspected":
		if len(result.ServeStatus) == 0 || len(result.ServeStatus) > maximumTailscaleOutput {
			return publicRemoteAccessObservation{}, ErrTailscaleConfigurationInvalid
		}
		serveStatus, err := decodeTailscaleServeStatus(result.ServeStatus)
		if err != nil {
			return publicRemoteAccessObservation{}, ErrTailscaleConfigurationInvalid
		}
		return normalizeTailscalePublicObservation(serveStatus, target, result.PubliclyPublished), nil
	case "conflict":
		return publicRemoteAccessObservation{}, ErrTailscaleServeConflict
	case "not-installed":
		return publicRemoteAccessObservation{}, ErrTailscaleUnavailable
	case "not-running":
		return publicRemoteAccessObservation{}, ErrTailscaleNotRunning
	case "unsupported":
		return publicRemoteAccessObservation{}, ErrTailscaleFunnelUnsupported
	case "sign-in-required":
		return publicRemoteAccessObservation{}, ErrTailscaleSignInRequired
	case "provider-approval-required":
		if !validTailscaleProviderURL(result.SetupURL) {
			return publicRemoteAccessObservation{}, ErrTailscaleConfigurationInvalid
		}
		return publicRemoteAccessObservation{}, tailscaleProviderApprovalError{url: result.SetupURL}
	case "verification-failed":
		return publicRemoteAccessObservation{}, ErrTailscaleConfigurationInvalid
	default:
		return publicRemoteAccessObservation{}, errors.New("the authorized Linux Tailscale helper returned an unsupported result")
	}
}
