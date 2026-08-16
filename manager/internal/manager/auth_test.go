package manager

import (
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestPBKDF2SHA256Vector(t *testing.T) {
	t.Parallel()
	actual := pbkdf2SHA256([]byte("password"), []byte("salt"), 2, 32)
	const expected = "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43"
	if hex.EncodeToString(actual) != expected {
		t.Fatalf("derived key mismatch: got %x", actual)
	}
}

func TestAuthPairAndLogin(t *testing.T) {
	t.Parallel()
	now := time.Date(2031, 4, 18, 16, 30, 0, 0, time.UTC)
	store, err := newAuthStore(t.TempDir(), func() time.Time { return now }, true)
	if err != nil {
		t.Fatal(err)
	}
	if store.bootstrapToken == "" {
		t.Fatal("expected first-run pairing token")
	}

	const password = "lock8888"
	first, err := store.pair(store.bootstrapToken, password)
	if err != nil {
		t.Fatal(err)
	}
	if first.Token == "" || first.CSRFToken == "" {
		t.Fatal("pairing did not create a complete session")
	}
	if _, err := os.Stat(store.bootstrapPath); !os.IsNotExist(err) {
		t.Fatalf("bootstrap token should be invalidated, stat error: %v", err)
	}
	raw, err := os.ReadFile(filepath.Join(store.dataDir, "auth.json"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), password) {
		t.Fatal("credential file contains the plaintext password")
	}
	if _, err := store.login("incorrect password"); err == nil {
		t.Fatal("incorrect password was accepted")
	}
	if store.verifyPassword("incorrect password") {
		t.Fatal("incorrect password passed re-authentication")
	}
	if !store.verifyPassword(password) {
		t.Fatal("correct password failed re-authentication")
	}
	if _, err := store.login(password); err != nil {
		t.Fatalf("correct password was rejected: %v", err)
	}
}

func TestTrustedLocalAccessIsDefaultAndPasswordLockPersists(t *testing.T) {
	t.Parallel()
	dataDir := t.TempDir()
	store, err := newAuthStore(dataDir, time.Now, false)
	if err != nil {
		t.Fatal(err)
	}
	if store.authenticationRequired() || store.bootstrapToken != "" {
		t.Fatal("trusted-local mode unexpectedly required authentication or generated a pairing token")
	}
	if err := store.setPasswordLock("1234567"); err == nil || !strings.Contains(err.Error(), "at least 8 characters") {
		t.Fatalf("seven-character password was not rejected with the expected message: %v", err)
	}
	if err := store.setPasswordLock(strings.Repeat("x", maximumPasswordBytes+1)); err == nil || !strings.Contains(err.Error(), "at most 256") {
		t.Fatalf("oversized password was not rejected before hashing: %v", err)
	}
	const password = "lock8888"
	if err := store.setPasswordLock(password); err != nil {
		t.Fatal(err)
	}
	if !store.authenticationRequired() || !store.localPasswordLockEnabled() || !store.verifyPassword(password) {
		t.Fatal("password lock was not enabled completely")
	}
	restarted, err := newAuthStore(dataDir, time.Now, false)
	if err != nil {
		t.Fatal(err)
	}
	if !restarted.authenticationRequired() || !restarted.verifyPassword(password) {
		t.Fatal("password lock did not survive restart")
	}
	if err := restarted.disablePasswordLock(); err != nil {
		t.Fatal(err)
	}
	trustedAgain, err := newAuthStore(dataDir, time.Now, false)
	if err != nil {
		t.Fatal(err)
	}
	if trustedAgain.authenticationRequired() {
		t.Fatal("disabled password lock remained active after restart")
	}
}

func TestResetLocalAccessPreservesCredentialsButDisablesOptionalLock(t *testing.T) {
	t.Parallel()
	dataDir := t.TempDir()
	store, err := newAuthStore(dataDir, time.Now, false)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.setPasswordLock("recoverable local manager password"); err != nil {
		t.Fatal(err)
	}
	if err := ResetLocalAccess(dataDir); err != nil {
		t.Fatal(err)
	}
	restarted, err := newAuthStore(dataDir, time.Now, false)
	if err != nil {
		t.Fatal(err)
	}
	if restarted.authenticationRequired() {
		t.Fatal("local recovery did not disable the optional password lock")
	}
	if !restarted.passwordConfigured() {
		t.Fatal("local recovery deleted the password credential instead of only disabling the lock")
	}
}

func TestAttemptLimiterExpiresFailures(t *testing.T) {
	t.Parallel()
	current := time.Date(2031, 4, 18, 16, 30, 0, 0, time.UTC)
	limiter := newAttemptLimiter(func() time.Time { return current })
	for count := 0; count < limiter.maximum; count++ {
		if !limiter.allow() {
			t.Fatalf("attempt %d was blocked too early", count+1)
		}
		limiter.recordFailure()
	}
	if limiter.allow() {
		t.Fatal("limiter allowed an attempt after the failure ceiling")
	}
	current = current.Add(limiter.window + time.Second)
	if !limiter.allow() {
		t.Fatal("limiter did not expire old failures")
	}
}

func TestRequiredAccessRecoveryRemovesOnlyAuthenticationMaterial(t *testing.T) {
	t.Parallel()
	dataDir := t.TempDir()
	store, err := newAuthStore(dataDir, time.Now, true)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.pair(store.bootstrapToken, "fixture recovery password"); err != nil {
		t.Fatal(err)
	}
	for name, content := range map[string]string{
		"operation.json":            `{"state":"preserve"}`,
		"configuration-status.json": `{"state":"preserve"}`,
	} {
		if err := os.WriteFile(filepath.Join(dataDir, name), []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if err := RecoverRequiredAccess(dataDir); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"auth.json", "auth-settings.json", "bootstrap-token.txt"} {
		if _, err := os.Stat(filepath.Join(dataDir, name)); !os.IsNotExist(err) {
			t.Fatalf("authentication material %q remains after recovery: %v", name, err)
		}
	}
	for name, content := range map[string]string{
		"operation.json":            `{"state":"preserve"}`,
		"configuration-status.json": `{"state":"preserve"}`,
	} {
		raw, err := os.ReadFile(filepath.Join(dataDir, name))
		if err != nil || string(raw) != content {
			t.Fatalf("recovery changed unrelated state %q: content=%q err=%v", name, raw, err)
		}
	}
	restarted, err := newAuthStore(dataDir, time.Now, true)
	if err != nil {
		t.Fatal(err)
	}
	if restarted.bootstrapToken == "" {
		t.Fatal("required-auth restart did not create a fresh one-time pairing token")
	}
	if token, err := ReadBootstrapToken(dataDir); err != nil || token != restarted.bootstrapToken {
		t.Fatalf("explicit bootstrap retrieval failed: tokenMatch=%v err=%v", token == restarted.bootstrapToken, err)
	}
}

func TestRequiredAuthRejectsInvalidBootstrapTokenFile(t *testing.T) {
	t.Parallel()
	dataDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dataDir, "bootstrap-token.txt"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := newAuthStore(dataDir, time.Now, true); err == nil || !strings.Contains(err.Error(), "pairing token is invalid") {
		t.Fatalf("empty bootstrap token was not rejected safely: %v", err)
	}
	if _, err := ReadBootstrapToken(dataDir); err == nil || !strings.Contains(err.Error(), "bootstrap token is invalid") {
		t.Fatalf("explicit retrieval accepted an invalid bootstrap token: %v", err)
	}
}

func TestLoginRejectsUnboundedCredentialWorkFactor(t *testing.T) {
	t.Parallel()
	dataDir := t.TempDir()
	store, err := newAuthStore(dataDir, time.Now, true)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.pair(store.bootstrapToken, "bounded credential password"); err != nil {
		t.Fatal(err)
	}
	credentials, err := store.readCredentials()
	if err != nil {
		t.Fatal(err)
	}
	credentials.Iterations = maximumIterations + 1
	if err := writePrivateJSON(store.credentialPath, credentials); err != nil {
		t.Fatal(err)
	}
	if store.verifyPassword("bounded credential password") {
		t.Fatal("credential metadata above the bounded work factor was accepted")
	}
}
