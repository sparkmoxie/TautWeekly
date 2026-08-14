package manager

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"
)

const (
	passwordIterations = 310000
	sessionLifetime    = 8 * time.Hour
)

type credentialFile struct {
	Version    int    `json:"version"`
	Algorithm  string `json:"algorithm"`
	Iterations int    `json:"iterations"`
	Salt       string `json:"salt"`
	Hash       string `json:"hash"`
}

type accessFile struct {
	Version             int  `json:"version"`
	PasswordLockEnabled bool `json:"passwordLockEnabled"`
}

type session struct {
	Token     string
	CSRFToken string
	ExpiresAt time.Time
}

type attemptLimiter struct {
	mu       sync.Mutex
	now      func() time.Time
	window   time.Duration
	maximum  int
	failures []time.Time
}

type authStore struct {
	dataDir         string
	credentialPath  string
	accessPath      string
	bootstrapPath   string
	bootstrapToken  string
	runtimeRequired bool
	now             func() time.Time

	mu                  sync.Mutex
	pairMu              sync.Mutex
	accessMu            sync.RWMutex
	passwordLockEnabled bool
	sessions            map[string]session
}

func newAuthStore(dataDir string, now func() time.Time, runtimeRequired bool) (*authStore, error) {
	if now == nil {
		now = time.Now
	}
	if err := os.MkdirAll(dataDir, 0o700); err != nil {
		return nil, fmt.Errorf("create manager data directory: %w", err)
	}
	if err := os.Chmod(dataDir, 0o700); err != nil && !errors.Is(err, os.ErrPermission) {
		return nil, fmt.Errorf("protect manager data directory: %w", err)
	}

	store := &authStore{
		dataDir:         dataDir,
		credentialPath:  filepath.Join(dataDir, "auth.json"),
		accessPath:      filepath.Join(dataDir, "auth-settings.json"),
		bootstrapPath:   filepath.Join(dataDir, "bootstrap-token.txt"),
		runtimeRequired: runtimeRequired,
		now:             now,
		sessions:        make(map[string]session),
	}
	settings, err := store.readAccessFile()
	if err != nil {
		return nil, err
	}
	store.passwordLockEnabled = settings.PasswordLockEnabled

	if store.passwordLockEnabled && !store.paired() {
		return nil, errors.New("Manager password lock is enabled, but its credential file is unavailable; run the local access reset helper")
	}
	if store.pairingRequired() {
		token, err := store.loadOrCreateBootstrapToken()
		if err != nil {
			return nil, err
		}
		store.bootstrapToken = token
	} else if err := os.Remove(store.bootstrapPath); err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, fmt.Errorf("remove obsolete pairing token: %w", err)
	}
	return store, nil
}

func (s *authStore) paired() bool {
	_, err := os.Stat(s.credentialPath)
	return err == nil
}

func (s *authStore) passwordConfigured() bool {
	return s.paired()
}

func (s *authStore) authenticationRequired() bool {
	s.accessMu.RLock()
	defer s.accessMu.RUnlock()
	return s.runtimeRequired || s.passwordLockEnabled
}

func (s *authStore) localPasswordLockEnabled() bool {
	s.accessMu.RLock()
	defer s.accessMu.RUnlock()
	return s.passwordLockEnabled
}

func (s *authStore) pairingRequired() bool {
	return s.runtimeRequired && !s.paired()
}

func (s *authStore) pair(token, password string) (session, error) {
	s.pairMu.Lock()
	defer s.pairMu.Unlock()

	if !s.pairingRequired() {
		return session{}, errors.New("pairing is not required for this Manager")
	}
	if s.paired() {
		return session{}, errors.New("manager is already paired")
	}
	if len(password) < 8 {
		return session{}, errors.New("administrator password must be at least 8 characters")
	}

	expected, err := os.ReadFile(s.bootstrapPath)
	if err != nil {
		return session{}, errors.New("pairing token is unavailable")
	}
	if subtle.ConstantTimeCompare([]byte(token), trimSpace(expected)) != 1 {
		return session{}, errors.New("pairing token is invalid")
	}

	if err := s.writePassword(password); err != nil {
		return session{}, err
	}
	if err := os.Remove(s.bootstrapPath); err != nil && !errors.Is(err, os.ErrNotExist) {
		return session{}, fmt.Errorf("invalidate pairing token: %w", err)
	}
	s.bootstrapToken = ""
	return s.newSession()
}

func (s *authStore) login(password string) (session, error) {
	if !s.authenticationRequired() || !s.passwordConfigured() {
		return session{}, errors.New("password authentication is not enabled")
	}
	if !s.verifyPassword(password) {
		return session{}, errors.New("password is invalid")
	}
	return s.newSession()
}

func (s *authStore) setPasswordLock(password string) error {
	s.pairMu.Lock()
	defer s.pairMu.Unlock()
	if err := s.writePassword(password); err != nil {
		return err
	}
	if err := writePrivateJSON(s.accessPath, accessFile{Version: 1, PasswordLockEnabled: true}); err != nil {
		return err
	}
	s.accessMu.Lock()
	s.passwordLockEnabled = true
	s.accessMu.Unlock()
	if err := os.Remove(s.bootstrapPath); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("invalidate pairing token: %w", err)
	}
	s.bootstrapToken = ""
	return nil
}

func (s *authStore) disablePasswordLock() error {
	if s.runtimeRequired {
		return errors.New("password authentication is required for this Manager mode")
	}
	if err := writePrivateJSON(s.accessPath, accessFile{Version: 1, PasswordLockEnabled: false}); err != nil {
		return err
	}
	s.accessMu.Lock()
	s.passwordLockEnabled = false
	s.accessMu.Unlock()
	return nil
}

func (s *authStore) writePassword(password string) error {
	if len(password) < 8 {
		return errors.New("administrator password must be at least 8 characters")
	}
	salt := make([]byte, 16)
	if _, err := rand.Read(salt); err != nil {
		return fmt.Errorf("generate password salt: %w", err)
	}
	hash := pbkdf2SHA256([]byte(password), salt, passwordIterations, 32)
	return writePrivateJSON(s.credentialPath, credentialFile{
		Version:    1,
		Algorithm:  "PBKDF2-HMAC-SHA256",
		Iterations: passwordIterations,
		Salt:       base64.RawStdEncoding.EncodeToString(salt),
		Hash:       base64.RawStdEncoding.EncodeToString(hash),
	})
}

func (s *authStore) verifyPassword(password string) bool {
	credentials, err := s.readCredentials()
	if err != nil {
		return false
	}
	salt, err := base64.RawStdEncoding.DecodeString(credentials.Salt)
	if err != nil {
		return false
	}
	expected, err := base64.RawStdEncoding.DecodeString(credentials.Hash)
	if err != nil {
		return false
	}
	actual := pbkdf2SHA256([]byte(password), salt, credentials.Iterations, len(expected))
	return subtle.ConstantTimeCompare(actual, expected) == 1
}

func (s *authStore) authenticate(token string) (session, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()

	current, ok := s.sessions[token]
	if !ok {
		return session{}, false
	}
	if !s.now().Before(current.ExpiresAt) {
		delete(s.sessions, token)
		return session{}, false
	}
	return current, true
}

func (s *authStore) logout(token string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.sessions, token)
}

func (s *authStore) newSession() (session, error) {
	token, err := randomToken(32)
	if err != nil {
		return session{}, err
	}
	csrf, err := randomToken(24)
	if err != nil {
		return session{}, err
	}
	current := session{
		Token:     token,
		CSRFToken: csrf,
		ExpiresAt: s.now().Add(sessionLifetime),
	}
	s.mu.Lock()
	for token, existing := range s.sessions {
		if !s.now().Before(existing.ExpiresAt) {
			delete(s.sessions, token)
		}
	}
	if len(s.sessions) >= 64 {
		var oldestToken string
		var oldestExpiry time.Time
		for token, existing := range s.sessions {
			if oldestToken == "" || existing.ExpiresAt.Before(oldestExpiry) {
				oldestToken = token
				oldestExpiry = existing.ExpiresAt
			}
		}
		delete(s.sessions, oldestToken)
	}
	s.sessions[token] = current
	s.mu.Unlock()
	return current, nil
}

func newAttemptLimiter(now func() time.Time) *attemptLimiter {
	if now == nil {
		now = time.Now
	}
	return &attemptLimiter{
		now:     now,
		window:  5 * time.Minute,
		maximum: 5,
	}
}

func (l *attemptLimiter) allow() bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.prune()
	return len(l.failures) < l.maximum
}

func (l *attemptLimiter) recordFailure() {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.prune()
	l.failures = append(l.failures, l.now())
}

func (l *attemptLimiter) reset() {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.failures = nil
}

func (l *attemptLimiter) prune() {
	cutoff := l.now().Add(-l.window)
	firstCurrent := 0
	for firstCurrent < len(l.failures) && l.failures[firstCurrent].Before(cutoff) {
		firstCurrent++
	}
	l.failures = append([]time.Time(nil), l.failures[firstCurrent:]...)
}

func (s *authStore) loadOrCreateBootstrapToken() (string, error) {
	if value, err := os.ReadFile(s.bootstrapPath); err == nil {
		return string(trimSpace(value)), nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return "", fmt.Errorf("read pairing token: %w", err)
	}

	token, err := randomToken(24)
	if err != nil {
		return "", err
	}
	if err := os.WriteFile(s.bootstrapPath, []byte(token+"\n"), 0o600); err != nil {
		return "", fmt.Errorf("write pairing token: %w", err)
	}
	if err := os.Chmod(s.bootstrapPath, 0o600); err != nil && !errors.Is(err, os.ErrPermission) {
		return "", fmt.Errorf("protect pairing token: %w", err)
	}
	return token, nil
}

func (s *authStore) readAccessFile() (accessFile, error) {
	settings := accessFile{Version: 1}
	raw, err := os.ReadFile(s.accessPath)
	if errors.Is(err, os.ErrNotExist) {
		return settings, nil
	}
	if err != nil {
		return accessFile{}, fmt.Errorf("read Manager access settings: %w", err)
	}
	if err := json.Unmarshal(raw, &settings); err != nil || settings.Version != 1 {
		return accessFile{}, errors.New("Manager access settings are invalid; run the local access reset helper")
	}
	return settings, nil
}

// ResetLocalAccess disables only the optional local password lock. It does not
// alter TautWeekly configuration, credentials, previews, history, or schedules.
// Runtimes that mandate authentication continue to require the preserved
// credential; trusted-local Windows mode becomes passwordless again.
func ResetLocalAccess(dataDir string) error {
	resolved, err := filepath.Abs(dataDir)
	if err != nil {
		return fmt.Errorf("resolve Manager data directory: %w", err)
	}
	if err := os.MkdirAll(resolved, 0o700); err != nil {
		return fmt.Errorf("create Manager data directory: %w", err)
	}
	if err := writePrivateJSON(filepath.Join(resolved, "auth-settings.json"), accessFile{Version: 1, PasswordLockEnabled: false}); err != nil {
		return err
	}
	if err := os.Remove(filepath.Join(resolved, "bootstrap-token.txt")); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("remove pairing token: %w", err)
	}
	return nil
}

func (s *authStore) readCredentials() (credentialFile, error) {
	var credentials credentialFile
	raw, err := os.ReadFile(s.credentialPath)
	if err != nil {
		return credentials, err
	}
	if err := json.Unmarshal(raw, &credentials); err != nil {
		return credentials, err
	}
	if credentials.Version != 1 ||
		credentials.Algorithm != "PBKDF2-HMAC-SHA256" ||
		credentials.Iterations < 100000 {
		return credentialFile{}, errors.New("unsupported credential format")
	}
	return credentials, nil
}

func randomToken(size int) (string, error) {
	value := make([]byte, size)
	if _, err := rand.Read(value); err != nil {
		return "", fmt.Errorf("generate random token: %w", err)
	}
	return base64.RawURLEncoding.EncodeToString(value), nil
}

func writePrivateJSON(path string, value any) error {
	temp, err := os.CreateTemp(filepath.Dir(path), ".manager-private-*.tmp")
	if err != nil {
		return fmt.Errorf("create private temporary file: %w", err)
	}
	tempPath := temp.Name()
	defer os.Remove(tempPath)

	if err := temp.Chmod(0o600); err != nil {
		temp.Close()
		return fmt.Errorf("protect private temporary file: %w", err)
	}
	encoder := json.NewEncoder(temp)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(value); err != nil {
		temp.Close()
		return fmt.Errorf("encode private state: %w", err)
	}
	if err := temp.Sync(); err != nil {
		temp.Close()
		return fmt.Errorf("flush private state: %w", err)
	}
	if err := temp.Close(); err != nil {
		return fmt.Errorf("close private state: %w", err)
	}
	if err := hardenPrivateFile(tempPath); err != nil {
		return fmt.Errorf("restrict private state permissions: %w", err)
	}
	if err := os.Rename(tempPath, path); err != nil {
		return fmt.Errorf("install private state: %w", err)
	}
	return nil
}

func trimSpace(value []byte) []byte {
	start := 0
	end := len(value)
	for start < end && (value[start] == ' ' || value[start] == '\t' || value[start] == '\r' || value[start] == '\n') {
		start++
	}
	for end > start && (value[end-1] == ' ' || value[end-1] == '\t' || value[end-1] == '\r' || value[end-1] == '\n') {
		end--
	}
	return value[start:end]
}

func pbkdf2SHA256(password, salt []byte, iterations, keyLength int) []byte {
	const hashLength = 32
	blocks := (keyLength + hashLength - 1) / hashLength
	output := make([]byte, 0, blocks*hashLength)
	counter := make([]byte, 4)

	for block := 1; block <= blocks; block++ {
		binary.BigEndian.PutUint32(counter, uint32(block))
		mac := hmac.New(sha256.New, password)
		mac.Write(salt)
		mac.Write(counter)
		u := mac.Sum(nil)
		value := append([]byte(nil), u...)

		for iteration := 1; iteration < iterations; iteration++ {
			mac = hmac.New(sha256.New, password)
			mac.Write(u)
			u = mac.Sum(nil)
			for index := range value {
				value[index] ^= u[index]
			}
		}
		output = append(output, value...)
	}
	return output[:keyLength]
}
