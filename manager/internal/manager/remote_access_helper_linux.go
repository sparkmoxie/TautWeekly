//go:build linux

package manager

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"os/exec"
	"os/user"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const linuxRemoteAccessServiceUser = "tautweekly"

// RunLinuxRemoteAccessHelper serves one socket-activated request. It must run
// as root, accepts only the dedicated tautweekly service account as its Unix
// peer, and exposes only the fixed Manager Funnel actions and target.
func RunLinuxRemoteAccessHelper(input, output *os.File) error {
	if os.Geteuid() != 0 {
		return errors.New("the Linux remote-access helper must run as root")
	}
	if input == nil || output == nil {
		return errors.New("the Linux remote-access helper requires a systemd socket")
	}
	if err := requireLinuxRemoteAccessPeer(input); err != nil {
		return err
	}
	raw, err := io.ReadAll(io.LimitReader(input, 16<<10))
	if err != nil || len(raw) == 0 || len(raw) >= 16<<10 {
		return errors.New("the Linux remote-access helper request was invalid")
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	var request tailscaleHelperRequest
	if err := decoder.Decode(&request); err != nil || decoder.Decode(&struct{}{}) != io.EOF ||
		request.SchemaVersion != 1 || !validHelperNonce(request.Nonce) || request.Target != linuxRemoteAccessTarget ||
		(request.Action != "inspect" && request.Action != "enable" && request.Action != "disable") {
		return errors.New("the Linux remote-access helper request was rejected")
	}
	result := runLinuxTailscaleAction(context.Background(), request.Action, request.Target)
	result.SchemaVersion = 1
	result.Nonce = request.Nonce
	encoder := json.NewEncoder(output)
	encoder.SetEscapeHTML(true)
	if err := encoder.Encode(result); err != nil {
		return errors.New("the Linux remote-access helper response could not be written")
	}
	return nil
}

func requireLinuxRemoteAccessPeer(input *os.File) error {
	credentials, err := syscall.GetsockoptUcred(int(input.Fd()), syscall.SOL_SOCKET, syscall.SO_PEERCRED)
	if err != nil {
		return errors.New("the Linux remote-access helper could not verify its peer")
	}
	account, err := user.Lookup(linuxRemoteAccessServiceUser)
	if err != nil {
		return errors.New("the TautWeekly Linux service account is unavailable")
	}
	uid, err := strconv.ParseUint(account.Uid, 10, 32)
	if err != nil || credentials.Uid != uint32(uid) {
		return errors.New("the Linux remote-access helper rejected an unauthorized peer")
	}
	return nil
}

func validHelperNonce(value string) bool {
	if len(value) != 64 {
		return false
	}
	for _, character := range value {
		if (character < '0' || character > '9') && (character < 'a' || character > 'f') {
			return false
		}
	}
	return true
}

func runLinuxTailscaleAction(parent context.Context, action, target string) tailscaleHelperResult {
	result := tailscaleHelperResult{Code: "verification-failed"}
	if target != linuxRemoteAccessTarget || (action != "inspect" && action != "enable" && action != "disable") {
		return result
	}
	path := fixedLinuxTailscalePath()
	if path == "" || !trustedRootExecutable(path) {
		result.Code = "not-installed"
		return result
	}
	if backendCode := linuxTailscaleBackendCode(parent, path); backendCode != "" {
		result.Code = backendCode
		return result
	}
	serve, raw, err := readLinuxTailscaleFunnel(parent, path)
	if err != nil {
		switch {
		case errors.Is(err, ErrTailscaleFunnelUnsupported):
			result.Code = "unsupported"
		case errors.Is(err, ErrTailscaleSignInRequired):
			result.Code = "sign-in-required"
		case errors.Is(err, ErrTailscaleNotRunning):
			result.Code = "not-running"
		}
		return result
	}

	switch action {
	case "inspect":
		result.Code = "inspected"
		result.ServeStatus = raw
		result.PubliclyPublished = verifyLinuxPublicFunnel(parent, serve, target)
		return result
	case "disable":
		if serveStatusEmpty(serve) {
			result.Code = "disabled"
			result.ServeStatus = raw
			return result
		}
		_, ownedFunnel := ownedTailscaleFunnel(serve, target)
		_, ownedLegacy := ownedTailscaleServe(serve, target)
		if !ownedFunnel && !ownedLegacy {
			result.Code = "conflict"
			return result
		}
		command := "funnel"
		if ownedLegacy {
			command = "serve"
		}
		if _, _, err := runBoundedLinuxTailscale(parent, path, tailscaleCommandTimeout, command, "--yes", "--https=443", "off"); err != nil {
			return result
		}
		serve, raw, err = readLinuxTailscaleFunnel(parent, path)
		if err != nil || !serveStatusEmpty(serve) {
			return result
		}
		result.Code = "disabled"
		result.ServeStatus = raw
		return result
	case "enable":
		if !serveStatusEmpty(serve) {
			_, ownedFunnel := ownedTailscaleFunnel(serve, target)
			_, ownedLegacy := ownedTailscaleServe(serve, target)
			if !ownedFunnel && !ownedLegacy {
				result.Code = "conflict"
				return result
			}
			if ownedFunnel {
				result.Code = "enabled"
				result.ServeStatus = raw
				result.PubliclyPublished = verifyLinuxPublicFunnel(parent, serve, target)
				return result
			}
		}
		stdout, stderr, commandErr := runBoundedLinuxTailscale(parent, path, 15*time.Second, "funnel", "--bg", "--yes", "--https=443", target)
		if setupURL := tailscaleApprovalURL(string(stdout) + "\n" + string(stderr)); setupURL != "" {
			result.Code = "provider-approval-required"
			result.SetupURL = setupURL
			return result
		}
		if commandErr != nil {
			message := strings.ToLower(string(stdout) + "\n" + string(stderr))
			switch {
			case strings.Contains(message, "not logged"), strings.Contains(message, "logged out"), strings.Contains(message, "needs login"), strings.Contains(message, "no current profile"), strings.Contains(message, "sign in"):
				result.Code = "sign-in-required"
			case strings.Contains(message, "service is not running"), strings.Contains(message, "failed to connect to local tailscaled"), strings.Contains(message, "no backend"), strings.Contains(message, "connection refused"):
				result.Code = "not-running"
			case strings.Contains(message, "unknown command"), strings.Contains(message, "unknown subcommand"), strings.Contains(message, "does not support funnel"):
				result.Code = "unsupported"
			case errors.Is(commandErr, context.DeadlineExceeded):
				after, afterRaw, afterErr := readLinuxTailscaleFunnel(parent, path)
				if afterErr == nil {
					if _, owned := ownedTailscaleFunnel(after, target); owned {
						result.Code = "enabled"
						result.ServeStatus = afterRaw
						result.PubliclyPublished = verifyLinuxPublicFunnel(parent, after, target)
					}
				}
			}
			return result
		}
		serve, raw, err = readLinuxTailscaleFunnel(parent, path)
		if err != nil {
			return result
		}
		if _, owned := ownedTailscaleFunnel(serve, target); !owned {
			return result
		}
		result.Code = "enabled"
		result.ServeStatus = raw
		result.PubliclyPublished = verifyLinuxPublicFunnel(parent, serve, target)
		return result
	}
	return result
}

func trustedRootExecutable(path string) bool {
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0022 != 0 {
		return false
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	return ok && stat.Uid == 0
}

func linuxTailscaleBackendCode(parent context.Context, path string) string {
	stdout, stderr, err := runBoundedLinuxTailscale(parent, path, tailscaleCommandTimeout, "status", "--json")
	if err != nil {
		return classifyLinuxTailscaleBackend(stdout, stderr, err)
	}
	return classifyLinuxTailscaleBackend(stdout, nil, nil)
}

func classifyLinuxTailscaleBackend(stdout, stderr []byte, commandErr error) string {
	message := strings.ToLower(string(stdout) + "\n" + string(stderr))
	if commandErr != nil {
		switch {
		case strings.Contains(message, "service is not running"), strings.Contains(message, "failed to connect to local tailscaled"), strings.Contains(message, "no backend"), strings.Contains(message, "connection refused"):
			return "not-running"
		case strings.Contains(message, "not logged"), strings.Contains(message, "logged out"), strings.Contains(message, "needs login"), strings.Contains(message, "no current profile"), strings.Contains(message, "sign in"):
			return "sign-in-required"
		default:
			return "verification-failed"
		}
	}
	var status struct {
		BackendState string `json:"BackendState"`
	}
	if json.Unmarshal(stdout, &status) != nil {
		return "verification-failed"
	}
	switch status.BackendState {
	case "Running":
		return ""
	case "NeedsLogin", "NoState", "Stopped":
		return "sign-in-required"
	default:
		return "verification-failed"
	}
}

func readLinuxTailscaleFunnel(parent context.Context, path string) (tailscaleServeStatus, json.RawMessage, error) {
	stdout, stderr, err := runBoundedLinuxTailscale(parent, path, tailscaleCommandTimeout, "funnel", "status", "--json")
	if err != nil {
		message := strings.ToLower(string(stdout) + "\n" + string(stderr))
		switch {
		case strings.Contains(message, "unknown command"), strings.Contains(message, "unknown subcommand"), strings.Contains(message, "does not support funnel"):
			return tailscaleServeStatus{}, nil, ErrTailscaleFunnelUnsupported
		case strings.Contains(message, "not logged"), strings.Contains(message, "logged out"), strings.Contains(message, "needs login"), strings.Contains(message, "no current profile"), strings.Contains(message, "sign in"):
			return tailscaleServeStatus{}, nil, ErrTailscaleSignInRequired
		case strings.Contains(message, "service is not running"), strings.Contains(message, "failed to connect to local tailscaled"), strings.Contains(message, "no backend"), strings.Contains(message, "connection refused"):
			return tailscaleServeStatus{}, nil, ErrTailscaleNotRunning
		default:
			return tailscaleServeStatus{}, nil, err
		}
	}
	serve, err := decodeTailscaleServeStatus(stdout)
	if err != nil {
		return tailscaleServeStatus{}, nil, err
	}
	normalized, err := json.Marshal(serve)
	if err != nil || len(normalized) > maximumTailscaleOutput {
		return tailscaleServeStatus{}, nil, ErrTailscaleConfigurationInvalid
	}
	return serve, normalized, nil
}

var lookupLinuxPublicIPv4 = resolveLinuxPublicIPv4
var probeLinuxTrustedTLS = dialLinuxTrustedTLS

func verifyLinuxPublicFunnel(parent context.Context, status tailscaleServeStatus, target string) bool {
	hostname, owned := ownedTailscaleFunnel(status, target)
	if !owned {
		return false
	}
	addresses, err := lookupLinuxPublicIPv4(parent, hostname)
	if err != nil {
		return false
	}
	for index, address := range addresses {
		if index >= 4 {
			break
		}
		if publicIPv4Address(address) && probeLinuxTrustedTLS(parent, hostname, address) {
			return true
		}
	}
	return false
}

func resolveLinuxPublicIPv4(parent context.Context, hostname string) ([]net.IP, error) {
	resolver := &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, network, _ string) (net.Conn, error) {
			var dialer net.Dialer
			return dialer.DialContext(ctx, network, "1.1.1.1:53")
		},
	}
	ctx, cancel := context.WithTimeout(parent, 4*time.Second)
	defer cancel()
	return resolver.LookupIP(ctx, "ip4", hostname)
}

func publicIPv4Address(value net.IP) bool {
	address := value.To4()
	if address == nil || !address.IsGlobalUnicast() || address.IsPrivate() || address.IsLoopback() || address.IsLinkLocalUnicast() {
		return false
	}
	if address[0] == 100 && address[1] >= 64 && address[1] <= 127 {
		return false
	}
	if address[0] == 192 && address[1] == 0 {
		return false
	}
	if address[0] == 198 && (address[1] == 18 || address[1] == 19 || address[1] == 51) {
		return false
	}
	return !(address[0] == 203 && address[1] == 0 && address[2] == 113)
}

func dialLinuxTrustedTLS(parent context.Context, hostname string, address net.IP) bool {
	ctx, cancel := context.WithTimeout(parent, 5*time.Second)
	defer cancel()
	dialer := &tls.Dialer{
		NetDialer: &net.Dialer{},
		Config: &tls.Config{
			MinVersion: tls.VersionTLS12,
			ServerName: hostname,
		},
	}
	connection, err := dialer.DialContext(ctx, "tcp", net.JoinHostPort(address.String(), "443"))
	if err != nil {
		return false
	}
	defer connection.Close()
	tlsConnection, ok := connection.(*tls.Conn)
	if !ok {
		return false
	}
	state := tlsConnection.ConnectionState()
	return state.HandshakeComplete && len(state.VerifiedChains) > 0
}

func runBoundedLinuxTailscale(parent context.Context, path string, timeout time.Duration, arguments ...string) ([]byte, []byte, error) {
	ctx, cancel := context.WithTimeout(parent, timeout)
	defer cancel()
	command := exec.CommandContext(ctx, path, arguments...)
	command.Env = []string{"PATH=/usr/sbin:/usr/bin:/sbin:/bin", "LANG=C", "LC_ALL=C"}
	command.Stdin = nil
	var stdout boundedCommandOutput
	var stderr boundedCommandOutput
	command.Stdout = &stdout
	command.Stderr = &stderr
	err := command.Run()
	if stdout.overflow || stderr.overflow {
		return nil, nil, ErrTailscaleConfigurationInvalid
	}
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return stdout.buffer.Bytes(), stderr.buffer.Bytes(), context.DeadlineExceeded
	}
	return stdout.buffer.Bytes(), stderr.buffer.Bytes(), err
}

func tailscaleApprovalURL(output string) string {
	for _, field := range strings.Fields(output) {
		candidate := strings.TrimRight(field, ".,;:)]}\"'")
		if validTailscaleProviderURL(candidate) {
			return candidate
		}
	}
	return ""
}
