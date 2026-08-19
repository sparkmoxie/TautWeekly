//go:build linux

package manager

import (
	"bufio"
	"context"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"testing"
)

func TestLinuxTailscaleRunnerUsesOnlyAuthorizedSocketProtocol(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "tailscale")
	if err := os.WriteFile(path, []byte("fixture"), 0o700); err != nil {
		t.Fatal(err)
	}
	socket := filepath.Join(root, "adapter.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()

	requests := make(chan tailscaleHelperRequest, 1)
	go func() {
		connection, acceptErr := listener.Accept()
		if acceptErr != nil {
			return
		}
		defer connection.Close()
		var request tailscaleHelperRequest
		if json.NewDecoder(bufio.NewReader(connection)).Decode(&request) != nil {
			return
		}
		requests <- request
		_ = json.NewEncoder(connection).Encode(tailscaleHelperResult{
			SchemaVersion: 1,
			Nonce:         request.Nonce,
			Code:          "inspected",
			ServeStatus:   json.RawMessage(`{}`),
		})
	}()

	runner := &linuxTailscaleRunner{socket: socket, target: linuxRemoteAccessTarget, tailscalePath: path}
	if runner.Availability() != "available" || !runner.Available() {
		t.Fatalf("authorized fixture runner was unavailable: %s", runner.Availability())
	}
	raw, err := runner.Run(context.Background(), "serve", "status", "--json")
	if err != nil || string(raw) != `{}` {
		t.Fatalf("authorized inspect failed: raw=%q err=%v", raw, err)
	}
	request := <-requests
	if request.Action != "inspect" || request.Target != linuxRemoteAccessTarget || !validHelperNonce(request.Nonce) {
		t.Fatalf("unexpected helper request: %+v", request)
	}
	if _, err := runner.Run(context.Background(), "serve", "reset"); err == nil {
		t.Fatal("Linux runner accepted a destructive or arbitrary Tailscale command")
	}
}

func TestLinuxTailscaleRunnerDistinguishesInstallationAndHostAuthorization(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "tailscale")
	runner := &linuxTailscaleRunner{socket: filepath.Join(root, "missing.sock"), target: linuxRemoteAccessTarget, tailscalePath: path}
	if runner.Availability() != "not-installed" {
		t.Fatalf("missing CLI availability: %s", runner.Availability())
	}
	if err := os.WriteFile(path, []byte("fixture"), 0o700); err != nil {
		t.Fatal(err)
	}
	if runner.Availability() != "authorization-required" || runner.Available() {
		t.Fatalf("missing adapter authorization availability: %s", runner.Availability())
	}
}

func TestLinuxRuntimeSelectsIntegratedAdapterOnlyForFixedNativeService(t *testing.T) {
	integrated := newPlatformRemoteAccessController(Options{
		RuntimeMode: runtimeModeLinux, ListenAddress: "127.0.0.1:8788", DataDir: t.TempDir(),
	})
	if _, ok := integrated.(*tailscaleRemoteAccessController); !ok {
		t.Fatalf("fixed native Linux service did not receive the integrated adapter: %T", integrated)
	}

	for _, options := range []Options{
		{RuntimeMode: runtimeModeLinux, ListenAddress: "127.0.0.1:9876", DataDir: t.TempDir()},
		{RuntimeMode: runtimeModeNAS, ListenAddress: "0.0.0.0:8080", PackageKind: packageKindNAS, DataDir: t.TempDir()},
		{RuntimeMode: runtimeModeNAS, ListenAddress: "0.0.0.0:8080", PackageKind: packageKindQNAP, DataDir: t.TempDir()},
		{RuntimeMode: runtimeModeNAS, ListenAddress: "0.0.0.0:8080", PackageKind: packageKindUnraid, DataDir: t.TempDir()},
		{RuntimeMode: runtimeModeNAS, ListenAddress: "0.0.0.0:8080", PackageKind: packageKindFreeBSD, DataDir: t.TempDir()},
		{RuntimeMode: runtimeModeMac, ListenAddress: "0.0.0.0:8080", PackageKind: packageKindMac, DataDir: t.TempDir()},
	} {
		controller := newPlatformRemoteAccessController(options)
		if _, ok := controller.(*externalTailscaleRemoteAccessController); !ok {
			t.Errorf("host-managed package %s/%s did not receive the external adapter: %T", options.RuntimeMode, options.PackageKind, controller)
		}
	}
}
