//go:build windows

package manager

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

type fixtureWindowsFunnelRunner struct {
	available         bool
	hostname          string
	target            string
	observed          []byte
	commands          []string
	errors            map[string]error
	responses         map[string][]byte
	publiclyPublished bool
}

func (f *fixtureWindowsFunnelRunner) Available() bool        { return f.available }
func (f *fixtureWindowsFunnelRunner) RequiresApproval() bool { return true }
func (f *fixtureWindowsFunnelRunner) Run(context.Context, ...string) ([]byte, error) {
	return nil, errors.New("an unelevated Tailscale command was not expected")
}
func (f *fixtureWindowsFunnelRunner) RunFunnelPrivileged(_ context.Context, action, target string) (windowsFunnelObservation, error) {
	f.commands = append(f.commands, action+" "+target)
	if err := f.errors[action]; err != nil {
		return windowsFunnelObservation{}, err
	}
	if response, ok := f.responses[action]; ok {
		status, err := decodeTailscaleServeStatus(slices.Clone(response))
		return windowsFunnelObservation{ServeStatus: status, PubliclyPublished: f.publiclyPublished}, err
	}
	if target != f.target {
		return windowsFunnelObservation{}, errors.New("unexpected fixed target")
	}
	var raw []byte
	switch action {
	case "inspect":
		raw = slices.Clone(f.observed)
	case "enable":
		f.observed = ownedTailscaleFunnelJSON(f.hostname, f.target)
		raw = slices.Clone(f.observed)
	case "disable":
		f.observed = []byte(`{}`)
		raw = slices.Clone(f.observed)
	default:
		return windowsFunnelObservation{}, errors.New("unexpected allowlisted action")
	}
	status, err := decodeTailscaleServeStatus(raw)
	return windowsFunnelObservation{ServeStatus: status, PubliclyPublished: f.publiclyPublished}, err
}

func ownedTailscaleFunnelJSON(hostname, target string) []byte {
	value := map[string]any{
		"TCP": map[string]any{"443": map[string]any{"HTTPS": true}},
		"Web": map[string]any{hostname + ":443": map[string]any{
			"Handlers": map[string]any{"/": map[string]any{"Proxy": target}},
		}},
		"AllowFunnel": map[string]any{hostname + ":443": true},
	}
	raw, _ := json.Marshal(value)
	return raw
}

func TestWindowsFunnelLifecycleUsesOnlyFixedPrivilegedOperations(t *testing.T) {
	const (
		hostname = "tautweekly.example-tailnet.ts.net"
		target   = "http://127.0.0.1:18788"
	)
	runner := &fixtureWindowsFunnelRunner{available: true, hostname: hostname, target: target, observed: []byte(`{}`), errors: map[string]error{}, publiclyPublished: true}
	dataDir := t.TempDir()
	controller := newWindowsFunnelController(dataDir, "127.0.0.1:18788", true, runner)

	initial := controller.Status(context.Background())
	if initial.State != "approval-required" || initial.Enabled || initial.Active || len(runner.commands) != 0 {
		t.Fatalf("passive status changed Tailscale: status=%+v commands=%v", initial, runner.commands)
	}
	enabled, err := controller.Update(context.Background(), true, "https://attacker.invalid", true)
	if err != nil || !enabled.Enabled || !enabled.Active || enabled.State != "active" || enabled.URL != "https://"+hostname {
		t.Fatalf("enable: status=%+v err=%v", enabled, err)
	}
	if !slices.Equal(runner.commands, []string{"enable " + target}) {
		t.Fatalf("unexpected privileged operation: %v", runner.commands)
	}
	if !controller.AllowsHost(hostname) || controller.AllowsHost("other.ts.net") {
		t.Fatal("the verified Funnel hostname was not admitted exactly")
	}

	restarted := newWindowsFunnelController(dataDir, "127.0.0.1:18788", true, runner)
	passive := restarted.Status(context.Background())
	if !passive.Enabled || passive.Active || passive.State != "approval-required" || passive.URL != "https://"+hostname {
		t.Fatalf("persistent Funnel preference did not survive restart: %+v", passive)
	}
	verified, err := restarted.Verify(context.Background())
	if err != nil || !verified.Active || verified.State != "active" {
		t.Fatalf("restart verification: status=%+v err=%v", verified, err)
	}
	disabled, err := restarted.EnsureInactive(context.Background())
	if err != nil || disabled.Enabled || disabled.Active || disabled.State != "inactive" || restarted.AllowsHost(hostname) {
		t.Fatalf("disable: status=%+v err=%v", disabled, err)
	}
	if !slices.Equal(runner.commands, []string{"enable " + target, "inspect " + target, "disable " + target}) {
		t.Fatalf("unexpected lifecycle operations: %v", runner.commands)
	}
}

func TestWindowsFunnelMigratesLegacyPrivateServeOnlyAfterExplicitEnable(t *testing.T) {
	const (
		hostname = "legacy.example-tailnet.ts.net"
		target   = "http://127.0.0.1:8788"
	)
	dataDir := t.TempDir()
	if err := writePrivateJSON(filepath.Join(dataDir, remoteAccessStateFile), remoteAccessFile{SchemaVersion: remoteAccessSchemaVersion, Enabled: true, Hostname: hostname}); err != nil {
		t.Fatal(err)
	}
	runner := &fixtureWindowsFunnelRunner{available: true, hostname: hostname, target: target, observed: ownedTailscaleServeJSON(hostname, target), errors: map[string]error{}, publiclyPublished: true}
	controller := newWindowsFunnelController(dataDir, "127.0.0.1:8788", true, runner)
	status := controller.Status(context.Background())
	if status.State != "migration-required" || !status.Installed || !status.CleanupRequired || controller.AllowsHost(hostname) {
		t.Fatalf("legacy private Serve was not blocked pending explicit migration: %+v", status)
	}
	enabled, err := controller.Update(context.Background(), true, "", false)
	if err != nil || !enabled.Active || enabled.NetworkKind != "public-funnel" {
		t.Fatalf("legacy migration: status=%+v err=%v", enabled, err)
	}
	if _, err := os.Stat(filepath.Join(dataDir, remoteAccessStateFile)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("legacy state was not retired after verified Funnel migration: %v", err)
	}
}

func TestWindowsFunnelShutdownFailurePreservesPasswordSafetyState(t *testing.T) {
	const (
		hostname = "shutdown.example-tailnet.ts.net"
		target   = "http://127.0.0.1:8788"
	)
	runner := &fixtureWindowsFunnelRunner{available: true, hostname: hostname, target: target, observed: ownedTailscaleFunnelJSON(hostname, target), errors: map[string]error{}, publiclyPublished: true}
	controller := newWindowsFunnelController(t.TempDir(), "127.0.0.1:8788", true, runner)
	if _, err := controller.Update(context.Background(), true, "", false); err != nil {
		t.Fatal(err)
	}
	runner.errors["disable"] = ErrTailscaleNotRunning
	status, err := controller.EnsureInactive(context.Background())
	if !errors.Is(err, ErrTailscaleDisableIncomplete) || !status.Enabled || !status.CleanupRequired || !controller.AllowsHost(hostname) {
		t.Fatalf("failed shutdown discarded the protected exposure state: status=%+v err=%v", status, err)
	}
}

func TestWindowsFunnelObservedConfigurationMustBeExact(t *testing.T) {
	const (
		hostname = "exact.example-tailnet.ts.net"
		target   = "http://127.0.0.1:8788"
	)
	valid := ownedTailscaleFunnelJSON(hostname, target)
	var base map[string]any
	if err := json.Unmarshal(valid, &base); err != nil {
		t.Fatal(err)
	}
	cases := map[string]func(map[string]any){
		"Funnel false": func(value map[string]any) { value["AllowFunnel"] = map[string]any{hostname + ":443": false} },
		"wrong target": func(value map[string]any) {
			value["Web"].(map[string]any)[hostname+":443"].(map[string]any)["Handlers"].(map[string]any)["/"].(map[string]any)["Proxy"] = "http://127.0.0.1:9999"
		},
		"extra service": func(value map[string]any) { value["Services"] = map[string]any{"svc:other": map[string]any{}} },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			raw, _ := json.Marshal(base)
			var value map[string]any
			_ = json.Unmarshal(raw, &value)
			mutate(value)
			observed, _ := json.Marshal(value)
			decoded, err := decodeTailscaleServeStatus(observed)
			if err != nil {
				t.Fatal(err)
			}
			if _, owned := ownedTailscaleFunnel(decoded, target); owned {
				t.Fatal("unsafe Funnel configuration was accepted")
			}
		})
	}
}

func TestWindowsFunnelStateNeverStoresCommandOrTailnetInventory(t *testing.T) {
	const (
		hostname = "privacy.example-tailnet.ts.net"
		target   = "http://127.0.0.1:8788"
	)
	dataDir := t.TempDir()
	runner := &fixtureWindowsFunnelRunner{available: true, hostname: hostname, target: target, observed: []byte(`{}`), errors: map[string]error{}, publiclyPublished: true}
	controller := newWindowsFunnelController(dataDir, "127.0.0.1:8788", true, runner)
	if _, err := controller.Update(context.Background(), true, "", false); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(filepath.Join(dataDir, windowsFunnelStateFile))
	if err != nil {
		t.Fatal(err)
	}
	text := string(raw)
	for _, forbidden := range []string{"authkey", "serve --", "funnel --", "100.", "device", target} {
		if strings.Contains(strings.ToLower(text), strings.ToLower(forbidden)) {
			t.Fatalf("private Funnel state contained forbidden detail %q: %s", forbidden, text)
		}
	}
}

func TestWindowsFunnelSanitizesUnavailableAndFailedCLIStates(t *testing.T) {
	const target = "http://127.0.0.1:8788"
	unavailable := newWindowsFunnelController(t.TempDir(), "127.0.0.1:8788", true, &fixtureWindowsFunnelRunner{errors: map[string]error{}})
	status := unavailable.Status(context.Background())
	if status.State != "tailscale-required" || status.Installed || status.URL != "" || status.ErrorCode != "tailscale-required" {
		t.Fatalf("missing Tailscale state was not sanitized: %+v", status)
	}
	unsupported := newWindowsFunnelController(t.TempDir(), "127.0.0.1:8788", false, nil).Status(context.Background())
	if unsupported.State != "unsupported" || unsupported.ErrorCode != "platform-unsupported" || unsupported.URL != "" {
		t.Fatalf("unsupported state was not sanitized: %+v", unsupported)
	}

	for name, expected := range map[string]error{
		"sign-in":    ErrTailscaleSignInRequired,
		"stopped":    ErrTailscaleNotRunning,
		"old-client": ErrTailscaleFunnelUnsupported,
	} {
		t.Run(name, func(t *testing.T) {
			runner := &fixtureWindowsFunnelRunner{available: true, target: target, errors: map[string]error{"inspect": expected}}
			controller := newWindowsFunnelController(t.TempDir(), "127.0.0.1:8788", true, runner)
			verified, err := controller.Verify(context.Background())
			if !errors.Is(err, expected) || verified.URL != "" || verified.NetworkKind != "public-funnel" {
				t.Fatalf("failed CLI state leaked or changed shape: status=%+v err=%v", verified, err)
			}
		})
	}
}

func TestWindowsFunnelRejectsStaleAndMalformedCLIResponses(t *testing.T) {
	const (
		hostname = "stale.example-tailnet.ts.net"
		target   = "http://127.0.0.1:8788"
	)
	runner := &fixtureWindowsFunnelRunner{
		available: true, hostname: hostname, target: target, observed: []byte(`{}`), publiclyPublished: true,
		errors: map[string]error{}, responses: map[string][]byte{"enable": []byte(`{"AllowFunnel":`)},
	}
	controller := newWindowsFunnelController(t.TempDir(), "127.0.0.1:8788", true, runner)
	status, err := controller.Update(context.Background(), true, "https://attacker.invalid", true)
	if !errors.Is(err, ErrTailscaleConfigurationInvalid) || status.Enabled || controller.PublicExposureConfigured() {
		t.Fatalf("malformed enable response was adopted: status=%+v err=%v", status, err)
	}

	delete(runner.responses, "enable")
	if _, err := controller.Update(context.Background(), true, "", false); err != nil {
		t.Fatal(err)
	}
	runner.responses["disable"] = ownedTailscaleFunnelJSON(hostname, target)
	status, err = controller.EnsureInactive(context.Background())
	if !errors.Is(err, ErrTailscaleDisableIncomplete) || !status.Enabled || !status.CleanupRequired || !controller.AllowsHost(hostname) {
		t.Fatalf("stale disable response discarded fail-closed state: status=%+v err=%v", status, err)
	}
}

func TestWindowsFunnelHostnameValidationRejectsURLAndAuthorityInjection(t *testing.T) {
	valid := []string{"manager.example-tailnet.ts.net", "MANAGER.EXAMPLE-TAILNET.TS.NET."}
	invalid := []string{
		"https://manager.example-tailnet.ts.net", "manager.example-tailnet.ts.net:443", "manager.example-tailnet.ts.net/path",
		"manager.example-tailnet.ts.net.attacker.invalid", "-manager.example-tailnet.ts.net", "manager_example.ts.net", "ts.net",
	}
	for _, value := range valid {
		if !validTailscaleHostname(value) {
			t.Fatalf("valid Funnel hostname rejected: %q", value)
		}
	}
	for _, value := range invalid {
		if validTailscaleHostname(value) {
			t.Fatalf("unsafe Funnel hostname accepted: %q", value)
		}
	}
}

func TestWindowsFunnelEnableRollsBackIfLegacyStateCannotBeRetired(t *testing.T) {
	const (
		hostname = "rollback.example-tailnet.ts.net"
		target   = "http://127.0.0.1:8788"
	)
	dataDir := t.TempDir()
	if err := os.Mkdir(filepath.Join(dataDir, remoteAccessStateFile), 0o700); err != nil {
		t.Fatal(err)
	}
	runner := &fixtureWindowsFunnelRunner{available: true, hostname: hostname, target: target, observed: []byte(`{}`), errors: map[string]error{}, responses: map[string][]byte{}, publiclyPublished: true}
	controller := newWindowsFunnelController(dataDir, "127.0.0.1:8788", true, runner)
	status, err := controller.Update(context.Background(), true, "", false)
	if err == nil || controller.AllowsHost(hostname) || status.Enabled || status.Active {
		t.Fatalf("failed legacy retirement left the new Funnel admitted: status=%+v err=%v", status, err)
	}
	if !slices.Equal(runner.commands, []string{"enable " + target, "disable " + target}) {
		t.Fatalf("enable rollback did not use the fixed shutdown operation: %v", runner.commands)
	}
}

func TestWindowsFunnelDoesNotReportActiveBeforePublicPublication(t *testing.T) {
	const (
		hostname = "pending.example-tailnet.ts.net"
		target   = "http://127.0.0.1:8788"
	)
	runner := &fixtureWindowsFunnelRunner{available: true, hostname: hostname, target: target, observed: []byte(`{}`), errors: map[string]error{}}
	controller := newWindowsFunnelController(t.TempDir(), "127.0.0.1:8788", true, runner)

	pending, err := controller.Update(context.Background(), true, "", false)
	if err != nil || !pending.Enabled || pending.Active || pending.State != "starting" || pending.ErrorCode != "tailscale-funnel-publication-pending" || pending.URL != "https://"+hostname {
		t.Fatalf("local Funnel was falsely reported public: status=%+v err=%v", pending, err)
	}
	restarted := newWindowsFunnelController(filepath.Dir(controller.statePath), "127.0.0.1:8788", true, runner)
	stillPending := restarted.Status(context.Background())
	if !stillPending.Enabled || stillPending.Active || stillPending.State != "starting" || stillPending.URL != "https://"+hostname {
		t.Fatalf("publication-pending state did not survive restart: %+v", stillPending)
	}
	runner.publiclyPublished = true
	active, err := restarted.Verify(context.Background())
	if err != nil || !active.Active || active.State != "active" || active.ErrorCode != "" {
		t.Fatalf("published Funnel was not promoted to active: status=%+v err=%v", active, err)
	}
}

func TestWindowsFunnelSchemaOneUpgradeRequiresFreshPublicVerification(t *testing.T) {
	const hostname = "upgrade.example-tailnet.ts.net"
	dataDir := t.TempDir()
	legacy := []byte(`{"schemaVersion":1,"enabled":true,"hostname":"` + hostname + `"}`)
	if err := os.WriteFile(filepath.Join(dataDir, windowsFunnelStateFile), legacy, 0o600); err != nil {
		t.Fatal(err)
	}
	runner := &fixtureWindowsFunnelRunner{available: true, errors: map[string]error{}}
	status := newWindowsFunnelController(dataDir, "127.0.0.1:8788", true, runner).Status(context.Background())
	if !status.Enabled || status.Active || status.State != "starting" || status.ErrorCode != "tailscale-funnel-publication-pending" {
		t.Fatalf("schema-one local route bypassed fresh public verification: %+v", status)
	}
}
