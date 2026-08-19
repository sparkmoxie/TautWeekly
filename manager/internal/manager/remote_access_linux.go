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
	"slices"
	"time"
)

const (
	linuxRemoteAccessSocket = "/run/tautweekly/remote-access.sock"
	linuxRemoteAccessTarget = "http://127.0.0.1:8788"
)

type linuxTailscaleRunner struct {
	socket        string
	target        string
	tailscalePath string
}

func newPlatformRemoteAccessController(options Options) remoteAccessController {
	if normalizedRuntimeMode(options.RuntimeMode) == runtimeModeLinux {
		target := tailscaleLoopbackTarget(options.ListenAddress)
		if target == linuxRemoteAccessTarget {
			runner := &linuxTailscaleRunner{socket: linuxRemoteAccessSocket, target: target}
			return newTailscaleRemoteAccessController(options.DataDir, options.ListenAddress, true, runner)
		}
		return newExternalTailscaleRemoteAccessController(options.DataDir, options.ListenAddress)
	}
	if isManagedServiceRuntimeMode(options.RuntimeMode) {
		return newExternalTailscaleRemoteAccessController(options.DataDir, options.ListenAddress)
	}
	return newTailscaleRemoteAccessController(options.DataDir, options.ListenAddress, false, nil)
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

func (r *linuxTailscaleRunner) Availability() string {
	if r == nil {
		return "not-installed"
	}
	path := r.tailscalePath
	if path == "" {
		path = fixedLinuxTailscalePath()
	}
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() {
		return "not-installed"
	}
	info, err = os.Lstat(r.socket)
	if err != nil || info.Mode()&os.ModeSocket == 0 {
		return "authorization-required"
	}
	return "available"
}

func (r *linuxTailscaleRunner) Available() bool {
	return r != nil && r.target == linuxRemoteAccessTarget && r.Availability() == "available"
}

func (r *linuxTailscaleRunner) Run(ctx context.Context, arguments ...string) ([]byte, error) {
	if !r.Available() {
		if r != nil && r.Availability() == "authorization-required" {
			return nil, ErrTailscaleHostAuthorization
		}
		return nil, ErrTailscaleUnavailable
	}
	action := ""
	switch {
	case slices.Equal(arguments, []string{"serve", "status", "--json"}):
		action = "inspect"
	case len(arguments) == 5 && slices.Equal(arguments[:4], []string{"serve", "--bg", "--yes", "--https=443"}) && arguments[4] == r.target:
		action = "enable"
	case slices.Equal(arguments, []string{"serve", "--yes", "--https=443", "off"}):
		action = "disable"
	default:
		return nil, ErrTailscaleConfigurationInvalid
	}

	nonceBytes := make([]byte, 32)
	if _, err := rand.Read(nonceBytes); err != nil {
		return nil, ErrTailscaleUnavailable
	}
	nonce := hex.EncodeToString(nonceBytes)
	request := tailscaleHelperRequest{SchemaVersion: 1, Nonce: nonce, Action: action, Target: r.target}
	rawRequest, err := json.Marshal(request)
	if err != nil {
		return nil, ErrTailscaleConfigurationInvalid
	}

	var dialer net.Dialer
	connection, err := dialer.DialContext(ctx, "unix", r.socket)
	if err != nil {
		return nil, ErrTailscaleUnavailable
	}
	defer connection.Close()
	deadline := time.Now().Add(tailscaleCommandTimeout)
	if value, ok := ctx.Deadline(); ok && value.Before(deadline) {
		deadline = value
	}
	_ = connection.SetDeadline(deadline)
	if _, err := connection.Write(rawRequest); err != nil {
		return nil, ErrTailscaleUnavailable
	}
	if unix, ok := connection.(*net.UnixConn); ok {
		_ = unix.CloseWrite()
	}
	raw, err := io.ReadAll(io.LimitReader(connection, maximumTailscaleOutput+1))
	if err != nil || len(raw) == 0 || len(raw) > maximumTailscaleOutput {
		return nil, ErrTailscaleUnavailable
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	var result tailscaleHelperResult
	if err := decoder.Decode(&result); err != nil || decoder.Decode(&struct{}{}) != io.EOF || result.SchemaVersion != 1 || result.Nonce != nonce {
		return nil, ErrTailscaleConfigurationInvalid
	}
	switch result.Code {
	case "enabled", "disabled", "inspected":
		if len(result.ServeStatus) == 0 || len(result.ServeStatus) > maximumTailscaleOutput {
			return nil, ErrTailscaleConfigurationInvalid
		}
		return slices.Clone(result.ServeStatus), nil
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
		return nil, errors.New("the authorized Linux Tailscale helper returned an unsupported result")
	}
}
