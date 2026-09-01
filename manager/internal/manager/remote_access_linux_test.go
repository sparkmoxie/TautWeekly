//go:build linux

package manager

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"net"
	"os"
	"path/filepath"
	"testing"
)

func TestLinuxTailscaleBackendClassificationIsSanitized(t *testing.T) {
	tests := []struct {
		name       string
		stdout     string
		stderr     string
		commandErr error
		want       string
	}{
		{name: "running", stdout: `{"BackendState":"Running"}`},
		{name: "needs login", stdout: `{"BackendState":"NeedsLogin"}`, want: "sign-in-required"},
		{name: "stopped profile", stdout: `{"BackendState":"Stopped"}`, want: "sign-in-required"},
		{name: "daemon offline", stderr: "failed to connect to local tailscaled", commandErr: errors.New("exit"), want: "not-running"},
		{name: "malformed", stdout: `{"BackendState":`, want: "verification-failed"},
		{name: "unexpected failure", stderr: "private fixture detail", commandErr: errors.New("exit"), want: "verification-failed"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := classifyLinuxTailscaleBackend([]byte(test.stdout), []byte(test.stderr), test.commandErr); got != test.want {
				t.Fatalf("backend code: got %q, want %q", got, test.want)
			}
		})
	}
}

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
			SchemaVersion:     1,
			Nonce:             request.Nonce,
			Code:              "inspected",
			ServeStatus:       json.RawMessage(`{}`),
			PubliclyPublished: true,
		})
	}()

	runner := &linuxTailscaleRunner{socket: socket, target: linuxRemoteAccessTarget, tailscalePath: path}
	if runner.Availability() != "available" || !runner.Available() {
		t.Fatalf("authorized fixture runner was unavailable: %s", runner.Availability())
	}
	observation, err := runner.RunPublicRoute(context.Background(), "inspect", linuxRemoteAccessTarget)
	if err != nil || observation.PubliclyPublished || observation.RouteState != publicRemoteAccessRouteEmpty {
		t.Fatalf("authorized inspect failed: observation=%+v err=%v", observation, err)
	}
	request := <-requests
	if request.Action != "inspect" || request.Target != linuxRemoteAccessTarget || !validHelperNonce(request.Nonce) {
		t.Fatalf("unexpected helper request: %+v", request)
	}
	if _, err := runner.RunPublicRoute(context.Background(), "reset", linuxRemoteAccessTarget); err == nil {
		t.Fatal("Linux runner accepted a destructive or arbitrary Tailscale command")
	}
	if _, err := runner.RunPublicRoute(context.Background(), "enable", "http://127.0.0.1:9999"); err == nil {
		t.Fatal("Linux runner accepted a browser-selected target")
	}
}

func TestLinuxTailscaleRunnerDistinguishesInstallationAndHostAuthorization(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "tailscale")
	runner := &linuxTailscaleRunner{
		socket: filepath.Join(root, "missing.sock"), target: linuxRemoteAccessTarget,
		tailscalePath: path, requireLocalCLI: true,
	}
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

func TestLinuxRuntimeSelectsIntegratedFunnelAdaptersForFixedNativeAndContainerServices(t *testing.T) {
	root := t.TempDir()
	tailscalePath := filepath.Join(root, "tailscale")
	if err := os.WriteFile(tailscalePath, []byte("fixture"), 0o700); err != nil {
		t.Fatal(err)
	}
	originalFind := findFixedLinuxTailscalePath
	findFixedLinuxTailscalePath = func() string { return tailscalePath }
	t.Cleanup(func() { findFixedLinuxTailscalePath = originalFind })

	integrated := newPlatformRemoteAccessController(Options{
		RuntimeMode: runtimeModeLinux, ListenAddress: "127.0.0.1:8788", DataDir: t.TempDir(),
	})
	if _, ok := integrated.(*publicFunnelController); !ok {
		t.Fatalf("fixed native Linux service did not receive the integrated adapter: %T", integrated)
	}
	status := integrated.Status(context.Background())
	if status.NetworkKind != "public-funnel" || status.Management != "integrated" || !status.HostAuthorizationRequired {
		t.Fatalf("native Linux Funnel capability was not fail-closed before host authorization: %+v", status)
	}

	unsupported := newPlatformRemoteAccessController(Options{
		RuntimeMode: runtimeModeLinux, ListenAddress: "127.0.0.1:9876", DataDir: t.TempDir(),
	})
	if status := unsupported.Status(context.Background()); status.Supported || status.NetworkKind != "public-funnel" {
		t.Fatalf("non-fixed native service did not fail closed as unsupported Funnel: %+v", status)
	}

	for _, options := range []Options{
		{RuntimeMode: runtimeModeNAS, ListenAddress: "0.0.0.0:8080", PackageKind: packageKindNAS, DataDir: t.TempDir()},
		{RuntimeMode: runtimeModeNAS, ListenAddress: "0.0.0.0:8080", PackageKind: packageKindQNAP, DataDir: t.TempDir()},
		{RuntimeMode: runtimeModeNAS, ListenAddress: "0.0.0.0:8080", PackageKind: packageKindUnraid, DataDir: t.TempDir()},
		{RuntimeMode: runtimeModeNAS, ListenAddress: "0.0.0.0:8080", PackageKind: packageKindFreeBSD, DataDir: t.TempDir()},
		{RuntimeMode: runtimeModeMac, ListenAddress: "0.0.0.0:8080", PackageKind: packageKindMac, DataDir: t.TempDir()},
	} {
		controller := newPlatformRemoteAccessController(options)
		if _, ok := controller.(*publicFunnelController); !ok {
			t.Errorf("container package %s/%s did not receive the public Funnel adapter: %T", options.RuntimeMode, options.PackageKind, controller)
			continue
		}
		status := controller.Status(context.Background())
		if status.NetworkKind != "public-funnel" || status.Management != "integrated" || !status.HostAuthorizationRequired {
			t.Errorf("container package %s/%s did not fail closed before adapter authorization: %+v", options.RuntimeMode, options.PackageKind, status)
		}
	}
}

func TestContainerFunnelAuthorizationCommandsAreFixedByPackage(t *testing.T) {
	tests := map[string]string{
		packageKindFreeBSD: "sudo tautweekly remote-access-authorize",
		packageKindUnraid:  "/opt/tautweekly/bin/tautweekly-funnel login",
		packageKindMac:     "./tautweekly.sh remote-access-login",
		packageKindQNAP:    "./tautweekly.sh remote-access-login",
	}
	for packageKind, want := range tests {
		if got := containerFunnelAuthorizationCommand(packageKind); got != want {
			t.Errorf("authorization command for %s: got %q, want %q", packageKind, got, want)
		}
	}
}

func TestLinuxPublicPublicationRequiresPublicDNSAndTrustedTLS(t *testing.T) {
	const (
		hostname = "tautweekly.example-tailnet.ts.net"
		target   = linuxRemoteAccessTarget
	)
	status := tailscaleServeStatus{
		TCP: map[string]tailscaleTCPHandler{"443": {HTTPS: true}},
		Web: map[string]tailscaleWebServer{hostname + ":443": {
			Handlers: map[string]tailscaleHTTPHandler{"/": {Proxy: target}},
		}},
		AllowFunnel: map[string]bool{hostname + ":443": true},
	}
	originalLookup := lookupLinuxPublicIPv4
	originalProbe := probeLinuxTrustedTLS
	t.Cleanup(func() {
		lookupLinuxPublicIPv4 = originalLookup
		probeLinuxTrustedTLS = originalProbe
	})
	lookupLinuxPublicIPv4 = func(context.Context, string) ([]net.IP, error) {
		return []net.IP{net.ParseIP("100.100.100.100"), net.ParseIP("203.0.113.10"), net.ParseIP("1.1.1.1")}, nil
	}
	probes := 0
	probeLinuxTrustedTLS = func(_ context.Context, gotHostname string, address net.IP) bool {
		probes++
		return gotHostname == hostname && address.Equal(net.ParseIP("1.1.1.1"))
	}
	if !verifyLinuxPublicFunnel(context.Background(), status, target) || probes != 1 {
		t.Fatalf("exact public DNS/TLS fixture did not publish: probes=%d", probes)
	}
	probeLinuxTrustedTLS = func(context.Context, string, net.IP) bool { return false }
	if verifyLinuxPublicFunnel(context.Background(), status, target) {
		t.Fatal("public DNS followed by stalled or untrusted TLS was reported as published")
	}
	probes = 0
	if verifyLinuxPublicFunnel(context.Background(), status, "http://127.0.0.1:9999") || probes != 0 {
		t.Fatal("a non-owned target reached public publication probing")
	}
}
