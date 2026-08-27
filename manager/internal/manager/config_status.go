package manager

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"time"
)

const (
	configurationStatusSchemaVersion = 1
	maximumConfigurationStatusBytes  = 16 << 10
)

var (
	errConfigurationStatusRevision = errors.New("configuration status revision does not match")
	configurationStatusSteps       = []string{"choices", "lan", "smtp", "previews"}
	configurationStatusWaitingCopy = map[string]string{
		"choices":  "Waiting to load saved Tautulli libraries and users.",
		"lan":      "Waiting to verify the saved Tautulli and Plex connections.",
		"smtp":     "Waiting to run the non-sending SMTP preflight.",
		"previews": "Waiting to prepare the six local preview states.",
	}
	configurationStatusNotRunCopy = map[string]string{
		"choices":  "Libraries and users have not been loaded for this configuration.",
		"lan":      "Tautulli and Plex have not been verified for this configuration.",
		"smtp":     "SMTP preflight has not been run for this configuration.",
		"previews": "Local previews have not been prepared for this configuration.",
	}
)

type ConfigurationStatusStep struct {
	State        string `json:"state"`
	Summary      string `json:"summary"`
	UpdatedAtUTC string `json:"updatedAtUtc,omitempty"`
}

type ConfigurationStatus struct {
	SchemaVersion    int                                `json:"schemaVersion"`
	Available        bool                               `json:"available"`
	ConfigRevision   string                             `json:"configRevision,omitempty"`
	Running          bool                               `json:"running"`
	UpdatedAtUTC     string                             `json:"updatedAtUtc,omitempty"`
	Steps            map[string]ConfigurationStatusStep `json:"steps"`
	LastVerification *IntegrationCheckResult            `json:"lastVerification,omitempty"`
	LastSMTPCheck    *SMTPNetworkCheckResult            `json:"lastSmtpCheck,omitempty"`
	Cache            *DeletedItemCacheStatus            `json:"cache,omitempty"`
}

type configurationStatusStore struct {
	mu   sync.Mutex
	path string
	now  func() time.Time
}

func newConfigurationStatusStore(dataDir string, now func() time.Time) *configurationStatusStore {
	if now == nil {
		now = time.Now
	}
	return &configurationStatusStore{
		path: filepath.Join(dataDir, "configuration-status.json"),
		now:  now,
	}
}

func unavailableConfigurationStatus() ConfigurationStatus {
	return ConfigurationStatus{SchemaVersion: configurationStatusSchemaVersion, Available: false, Steps: map[string]ConfigurationStatusStep{}}
}

func newConfigurationStatus(revision, state string, now time.Time) ConfigurationStatus {
	status := ConfigurationStatus{
		SchemaVersion:  configurationStatusSchemaVersion,
		Available:      true,
		ConfigRevision: revision,
		Running:        state == "waiting",
		Steps:          make(map[string]ConfigurationStatusStep, len(configurationStatusSteps)),
	}
	status.UpdatedAtUTC = now.UTC().Format(time.RFC3339)
	for _, name := range configurationStatusSteps {
		summary := configurationStatusNotRunCopy[name]
		if state == "waiting" {
			summary = configurationStatusWaitingCopy[name]
		}
		status.Steps[name] = ConfigurationStatusStep{State: state, Summary: summary, UpdatedAtUTC: status.UpdatedAtUTC}
	}
	return status
}

func (s *configurationStatusStore) Reset(revision string) error {
	return s.reset(revision, "waiting")
}

func (s *configurationStatusStore) ResetNotRun(revision string) error {
	return s.reset(revision, "not-run")
}

// Rebase moves only evidence whose normalized inputs did not change. The plan
// is updated to report what was actually retained, never merely what was
// eligible for retention.
func (s *configurationStatusStore) Rebase(previousRevision, nextRevision string, plan *ConfigPostSavePlan) error {
	if !validConfigRevision(nextRevision) || plan == nil {
		return errConfigurationStatusRevision
	}
	now := s.now().UTC().Format(time.RFC3339)
	s.mu.Lock()
	defer s.mu.Unlock()

	previous, hasPrevious := ConfigurationStatus{}, false
	if validConfigRevision(previousRevision) {
		previous, hasPrevious = s.readLocked(previousRevision)
	}
	next := newConfigurationStatus(nextRevision, "not-run", s.now())
	next.UpdatedAtUTC = now

	retainStep := func(name string, allowed bool) bool {
		if !allowed || !hasPrevious {
			return false
		}
		step, ok := previous.Steps[name]
		if !ok || step.State == "waiting" || step.State == "running" || step.State == "not-run" {
			return false
		}
		next.Steps[name] = step
		return true
	}
	waitFor := func(name string, required bool) {
		if !required {
			return
		}
		next.Steps[name] = ConfigurationStatusStep{State: "waiting", Summary: configurationStatusWaitingCopy[name], UpdatedAtUTC: now}
	}

	if !plan.RunDiscovery && plan.RetainedDiscovery {
		plan.RetainedDiscovery = retainStep("choices", true)
	} else {
		plan.RetainedDiscovery = false
	}
	waitFor("choices", plan.RunDiscovery)

	if !plan.RunIntegration && hasPrevious && previous.LastVerification != nil {
		retained := *previous.LastVerification
		retained.ConfigRevision = nextRevision
		if clean, ok := cleanStoredIntegrationCheck(nextRevision, retained); ok {
			next.LastVerification = &clean
			plan.RetainedIntegration = retainStep("lan", true)
		}
	}
	waitFor("lan", plan.RunIntegration)

	if !plan.RunSMTP && hasPrevious && previous.LastSMTPCheck != nil {
		retained := *previous.LastSMTPCheck
		retained.ConfigRevision = nextRevision
		if clean, ok := cleanStoredSMTPCheck(nextRevision, retained); ok {
			next.LastSMTPCheck = &clean
			plan.RetainedSMTP = retainStep("smtp", true)
		}
	}
	waitFor("smtp", plan.RunSMTP)

	if !plan.GeneratePreviews {
		plan.RetainedPreviews = retainStep("previews", true)
	}
	waitFor("previews", plan.GeneratePreviews)

	next.Running = false
	for _, step := range next.Steps {
		if step.State == "waiting" || step.State == "running" {
			next.Running = true
			break
		}
	}
	return writePrivateJSON(s.path, next)
}

func (s *configurationStatusStore) reset(revision, state string) error {
	if !validConfigRevision(revision) {
		return errConfigurationStatusRevision
	}
	status := newConfigurationStatus(revision, state, s.now())
	s.mu.Lock()
	defer s.mu.Unlock()
	return writePrivateJSON(s.path, status)
}

func (s *configurationStatusStore) Load(revision string) ConfigurationStatus {
	if !validConfigRevision(revision) {
		return unavailableConfigurationStatus()
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if status, ok := s.readLocked(revision); ok {
		return status
	}
	return newConfigurationStatus(revision, "not-run", s.now())
}

func (s *configurationStatusStore) Update(revision, name, state, summary string) error {
	if !validConfigRevision(revision) || !validConfigurationStatusStep(name) || !validConfigurationStatusState(state) {
		return errConfigurationStatusRevision
	}
	summary = sanitizeEvidence(summary, 240)
	if summary == "" {
		return errConfigurationStatusRevision
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if storedRevision, ok := s.storedRevisionLocked(); ok && storedRevision != revision {
		return errConfigurationStatusRevision
	}
	status, ok := s.readLocked(revision)
	if !ok {
		status = newConfigurationStatus(revision, "not-run", s.now())
	}
	now := s.now().UTC().Format(time.RFC3339)
	status.Steps[name] = ConfigurationStatusStep{State: state, Summary: summary, UpdatedAtUTC: now}
	status.UpdatedAtUTC = now
	status.Running = false
	for _, step := range status.Steps {
		if step.State == "waiting" || step.State == "running" {
			status.Running = true
			break
		}
	}
	return writePrivateJSON(s.path, status)
}

func (s *configurationStatusStore) StoreIntegrationCheck(revision string, result IntegrationCheckResult) error {
	clean, ok := cleanStoredIntegrationCheck(revision, result)
	if !ok {
		return errConfigurationStatusRevision
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if storedRevision, exists := s.storedRevisionLocked(); exists && storedRevision != revision {
		return errConfigurationStatusRevision
	}
	status, exists := s.readLocked(revision)
	if !exists {
		status = newConfigurationStatus(revision, "not-run", s.now())
	}
	status.LastVerification = &clean
	status.UpdatedAtUTC = s.now().UTC().Format(time.RFC3339)
	return writePrivateJSON(s.path, status)
}

func (s *configurationStatusStore) StoreSMTPCheck(revision string, result SMTPNetworkCheckResult) error {
	clean, ok := cleanStoredSMTPCheck(revision, result)
	if !ok {
		return errConfigurationStatusRevision
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if storedRevision, exists := s.storedRevisionLocked(); exists && storedRevision != revision {
		return errConfigurationStatusRevision
	}
	status, exists := s.readLocked(revision)
	if !exists {
		status = newConfigurationStatus(revision, "not-run", s.now())
	}
	status.LastSMTPCheck = &clean
	status.UpdatedAtUTC = s.now().UTC().Format(time.RFC3339)
	return writePrivateJSON(s.path, status)
}

func (s *configurationStatusStore) storedRevisionLocked() (string, bool) {
	info, err := os.Stat(s.path)
	if err != nil || !info.Mode().IsRegular() || info.Size() > maximumConfigurationStatusBytes {
		return "", false
	}
	raw, err := os.ReadFile(s.path)
	if err != nil || len(raw) > maximumConfigurationStatusBytes {
		return "", false
	}
	var stored struct {
		SchemaVersion  int    `json:"schemaVersion"`
		ConfigRevision string `json:"configRevision"`
	}
	if json.Unmarshal(raw, &stored) != nil || stored.SchemaVersion != configurationStatusSchemaVersion || !validConfigRevision(stored.ConfigRevision) {
		return "", false
	}
	return stored.ConfigRevision, true
}

func (s *configurationStatusStore) readLocked(revision string) (ConfigurationStatus, bool) {
	info, err := os.Stat(s.path)
	if err != nil || !info.Mode().IsRegular() || info.Size() > maximumConfigurationStatusBytes {
		return ConfigurationStatus{}, false
	}
	raw, err := os.ReadFile(s.path)
	if err != nil || len(raw) > maximumConfigurationStatusBytes {
		return ConfigurationStatus{}, false
	}
	var stored ConfigurationStatus
	if json.Unmarshal(raw, &stored) != nil || stored.SchemaVersion != configurationStatusSchemaVersion || !stored.Available || stored.ConfigRevision != revision {
		return ConfigurationStatus{}, false
	}
	if _, err := time.Parse(time.RFC3339, stored.UpdatedAtUTC); err != nil {
		return ConfigurationStatus{}, false
	}
	clean := ConfigurationStatus{
		SchemaVersion:  configurationStatusSchemaVersion,
		Available:      true,
		ConfigRevision: revision,
		Running:        stored.Running,
		UpdatedAtUTC:   stored.UpdatedAtUTC,
		Steps:          make(map[string]ConfigurationStatusStep, len(configurationStatusSteps)),
	}
	for _, name := range configurationStatusSteps {
		step, exists := stored.Steps[name]
		if !exists || !validConfigurationStatusState(step.State) {
			return ConfigurationStatus{}, false
		}
		summary := sanitizeEvidence(step.Summary, 240)
		if summary == "" {
			return ConfigurationStatus{}, false
		}
		if step.UpdatedAtUTC != "" {
			if _, err := time.Parse(time.RFC3339, step.UpdatedAtUTC); err != nil {
				return ConfigurationStatus{}, false
			}
		}
		clean.Steps[name] = ConfigurationStatusStep{State: step.State, Summary: summary, UpdatedAtUTC: step.UpdatedAtUTC}
	}
	if stored.LastVerification != nil {
		result, valid := cleanStoredIntegrationCheck(revision, *stored.LastVerification)
		if !valid {
			return ConfigurationStatus{}, false
		}
		clean.LastVerification = &result
	}
	if stored.LastSMTPCheck != nil {
		result, valid := cleanStoredSMTPCheck(revision, *stored.LastSMTPCheck)
		if !valid {
			return ConfigurationStatus{}, false
		}
		clean.LastSMTPCheck = &result
	}
	return clean, true
}

func cleanStoredIntegrationCheck(revision string, result IntegrationCheckResult) (IntegrationCheckResult, bool) {
	if result.ConfigRevision != revision || result.Mode != "real-lan" || result.NetworkBoundary != "private-and-loopback-only" || !validStoredCheckState(result.Overall) {
		return IntegrationCheckResult{}, false
	}
	if _, err := time.Parse(time.RFC3339, result.StartedAtUTC); err != nil {
		return IntegrationCheckResult{}, false
	}
	if _, err := time.Parse(time.RFC3339, result.CompletedAtUTC); err != nil {
		return IntegrationCheckResult{}, false
	}
	steps := make(map[string]IntegrationCheckStep, 2)
	for _, step := range result.Steps {
		if (step.Service != "tautulli" && step.Service != "plex") || !validStoredCheckState(step.State) {
			return IntegrationCheckResult{}, false
		}
		summary := sanitizeEvidence(step.Summary, 240)
		if summary == "" {
			return IntegrationCheckResult{}, false
		}
		if _, exists := steps[step.Service]; exists {
			return IntegrationCheckResult{}, false
		}
		steps[step.Service] = IntegrationCheckStep{Service: step.Service, State: step.State, Summary: summary}
	}
	if len(steps) != 2 {
		return IntegrationCheckResult{}, false
	}
	result.Steps = []IntegrationCheckStep{steps["tautulli"], steps["plex"]}
	return result, true
}

func cleanStoredSMTPCheck(revision string, result SMTPNetworkCheckResult) (SMTPNetworkCheckResult, bool) {
	if result.ConfigRevision != revision || result.Mode != "smtp-network" || !validStoredCheckState(result.Overall) || !validStoredCheckState(result.State) {
		return SMTPNetworkCheckResult{}, false
	}
	if _, err := time.Parse(time.RFC3339, result.CompletedAtUTC); err != nil {
		return SMTPNetworkCheckResult{}, false
	}
	switch result.Security {
	case "starttls-validated", "plaintext-configured", "not-established":
	default:
		return SMTPNetworkCheckResult{}, false
	}
	result.Summary = sanitizeEvidence(result.Summary, 240)
	if result.Summary == "" {
		return SMTPNetworkCheckResult{}, false
	}
	return result, true
}

func validStoredCheckState(value string) bool {
	switch value {
	case "passed", "warning", "failed", "skipped":
		return true
	default:
		return false
	}
}

func validConfigurationStatusStep(value string) bool {
	for _, name := range configurationStatusSteps {
		if value == name {
			return true
		}
	}
	return false
}

func validConfigurationStatusState(value string) bool {
	switch value {
	case "not-run", "waiting", "running", "passed", "warning", "failed", "skipped":
		return true
	default:
		return false
	}
}
