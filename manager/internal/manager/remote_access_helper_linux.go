//go:build linux

package manager

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
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
// peer, and exposes only the fixed Manager Serve actions and target.
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
	if !linuxTailscaleRunning(parent, path) {
		result.Code = "sign-in-required"
		return result
	}
	serve, raw, err := readLinuxTailscaleServe(parent, path)
	if err != nil {
		return result
	}

	switch action {
	case "inspect":
		result.Code = "inspected"
		result.ServeStatus = raw
		return result
	case "disable":
		if serveStatusEmpty(serve) {
			result.Code = "disabled"
			result.ServeStatus = raw
			return result
		}
		if _, owned := ownedTailscaleServe(serve, target); !owned {
			result.Code = "conflict"
			return result
		}
		if _, _, err := runBoundedLinuxTailscale(parent, path, tailscaleCommandTimeout, "serve", "--yes", "--https=443", "off"); err != nil {
			return result
		}
		serve, raw, err = readLinuxTailscaleServe(parent, path)
		if err != nil || !serveStatusEmpty(serve) {
			return result
		}
		result.Code = "disabled"
		result.ServeStatus = raw
		return result
	case "enable":
		if !serveStatusEmpty(serve) {
			if _, owned := ownedTailscaleServe(serve, target); !owned {
				result.Code = "conflict"
				return result
			}
			result.Code = "enabled"
			result.ServeStatus = raw
			return result
		}
		stdout, stderr, commandErr := runBoundedLinuxTailscale(parent, path, 15*time.Second, "serve", "--bg", "--yes", "--https=443", target)
		if setupURL := tailscaleApprovalURL(string(stdout) + "\n" + string(stderr)); setupURL != "" {
			result.Code = "provider-approval-required"
			result.SetupURL = setupURL
			return result
		}
		if commandErr != nil {
			return result
		}
		serve, raw, err = readLinuxTailscaleServe(parent, path)
		if err != nil {
			return result
		}
		if _, owned := ownedTailscaleServe(serve, target); !owned {
			return result
		}
		result.Code = "enabled"
		result.ServeStatus = raw
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

func linuxTailscaleRunning(parent context.Context, path string) bool {
	stdout, _, err := runBoundedLinuxTailscale(parent, path, tailscaleCommandTimeout, "status", "--json")
	if err != nil {
		return false
	}
	var status struct {
		BackendState string `json:"BackendState"`
	}
	return json.Unmarshal(stdout, &status) == nil && status.BackendState == "Running"
}

func readLinuxTailscaleServe(parent context.Context, path string) (tailscaleServeStatus, json.RawMessage, error) {
	stdout, _, err := runBoundedLinuxTailscale(parent, path, tailscaleCommandTimeout, "serve", "status", "--json")
	if err != nil {
		return tailscaleServeStatus{}, nil, err
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
