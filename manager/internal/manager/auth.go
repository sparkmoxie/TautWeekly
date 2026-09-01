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
	passwordIterations   = 310000
	maximumIterations    = 2000000
	maximumPasswordBytes = 256
	sessionLifetime      = 8 * time.Hour
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
	if err := validateAdministratorPassword(password); err != nil {
		return session{}, err
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
	return s.setPasswordLockForSession(password, "")
}

func (s *authStore) setPasswordLockForSession(password, preserveSessionToken string) error {
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
	// A password change must not leave sessions created with the prior
	// credential valid. Preserve only the authenticated browser that performed
	// the change so the Settings workflow remains continuous.
	s.mu.Lock()
	for token := range s.sessions {
		if preserveSessionToken == "" || token != preserveSessionToken {
			delete(s.sessions, token)
		}
	}
	s.mu.Unlock()
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
	if err := validateAdministratorPassword(password); err != nil {
		return err
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
	if len(password) < 8 || len(password) > maximumPasswordBytes {
		return false
	}
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

func validateAdministratorPassword(password string) error {
	if len(password) < 8 {
		return errors.New("administrator password must be at least 8 characters")
	}
	if len(password) > maximumPasswordBytes {
		return errors.New("administrator password must be at most 256 UTF-8 bytes")
	}
	return nil
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
	if info, err := os.Lstat(s.bootstrapPath); err == nil {
		if !info.Mode().IsRegular() {
			return "", errors.New("pairing token path is not a regular file; run the local access recovery helper")
		}
		value, err := os.ReadFile(s.bootstrapPath)
		if err != nil {
			return "", fmt.Errorf("read pairing token: %w", err)
		}
		token := string(trimSpace(value))
		if !validRandomToken(token, 24) {
			return "", errors.New("pairing token is invalid; run the local access recovery helper")
		}
		return token, nil
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

// ReadBootstrapToken returns the one-time pairing token only when an
// administrator explicitly runs the local recovery command. Server startup
// and normal diagnostics never print this secret.
func ReadBootstrapToken(dataDir string) (string, error) {
	path := filepath.Join(dataDir, "bootstrap-token.txt")
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return "", errors.New("a bootstrap token is not available; start the unpaired Manager first")
	}
	if err != nil || !info.Mode().IsRegular() {
		return "", errors.New("the bootstrap token could not be read safely")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return "", errors.New("the bootstrap token could not be read")
	}
	token := string(trimSpace(raw))
	if !validRandomToken(token, 24) {
		return "", errors.New("the bootstrap token is invalid; run access-recover and restart the Manager")
	}
	return token, nil
}

// RecoverRequiredAccess removes only Manager authentication material so a
// required-auth runtime can create a new one-time pairing token on restart.
// Newsletter configuration, secrets, schedules, output, and operation history
// are deliberately outside this recovery boundary.
func RecoverRequiredAccess(dataDir string) error {
	resolved, err := filepath.Abs(dataDir)
	if err != nil {
		return fmt.Errorf("resolve Manager data directory: %w", err)
	}
	if err := os.MkdirAll(resolved, 0o700); err != nil {
		return fmt.Errorf("create Manager data directory: %w", err)
	}
	for _, name := range []string{"auth.json", "auth-settings.json", "bootstrap-token.txt"} {
		path := filepath.Join(resolved, name)
		info, err := os.Lstat(path)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return fmt.Errorf("inspect Manager authentication file: %w", err)
		}
		if !info.Mode().IsRegular() {
			return errors.New("Manager authentication recovery stopped because an authentication path is not a regular file")
		}
		if err := os.Remove(path); err != nil {
			return fmt.Errorf("remove Manager authentication file: %w", err)
		}
	}
	return nil
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
		credentials.Iterations < 100000 ||
		credentials.Iterations > maximumIterations {
		return credentialFile{}, errors.New("unsupported credential format")
	}
	salt, saltErr := base64.RawStdEncoding.DecodeString(credentials.Salt)
	hash, hashErr := base64.RawStdEncoding.DecodeString(credentials.Hash)
	if saltErr != nil || hashErr != nil || len(salt) != 16 || len(hash) != 32 {
		return credentialFile{}, errors.New("invalid credential data")
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

func validRandomToken(value string, size int) bool {
	decoded, err := base64.RawURLEncoding.DecodeString(value)
	return err == nil && len(decoded) == size
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
