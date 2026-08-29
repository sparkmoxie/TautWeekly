package manager

import (
	"bufio"
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"
)

const (
	diagnosticSchemaVersion = 1
	diagnosticHistoryLimit  = 20
	diagnosticRetention     = "count-only-fifo"
	maximumDiagnosticLine   = 4 << 10
)

var diagnosticSummaries = map[string]string{
	"config-request-invalid":           "The Manager rejected an invalid configuration request.",
	"config-conflict":                  "Configuration changed before the requested action could finish.",
	"config-invalid-source":            "The existing configuration is invalid or unreadable.",
	"config-save-failed":               "Configuration could not be saved safely.",
	"config-validation-failed":         "Configuration validation found fields that need attention.",
	"config-saved":                     "Configuration was validated, backed up when needed, and saved.",
	"config-status-write-failed":       "Configuration was saved, but its sanitized setup-status record could not be updated.",
	"backup-request-invalid":           "The Manager rejected an invalid backup restore request.",
	"backup-not-found":                 "The selected configuration backup was unavailable.",
	"backup-validation-failed":         "The selected backup did not pass the current configuration schema.",
	"backup-invalid":                   "The selected backup was not a valid configuration document.",
	"backup-restore-failed":            "The selected backup could not be restored safely.",
	"backup-restored":                  "A configuration backup was validated and restored.",
	"backup-delete-failed":             "The selected configuration backup could not be deleted safely.",
	"backup-deleted":                   "A selected configuration backup was deleted permanently.",
	"verification-request-invalid":     "The Manager rejected an invalid connection-verification request.",
	"verification-not-ready":           "Connection verification could not start because configuration is incomplete.",
	"verification-conflict":            "Configuration changed before connection verification could start.",
	"verification-failed":              "Connection verification could not be completed safely.",
	"verification-config-changed":      "Configuration changed while connection verification was running.",
	"verification-passed":              "Tautulli and direct Plex verification passed.",
	"verification-passed-plex-skipped": "Tautulli verification passed; optional direct Plex verification was skipped because a complete URL and token were not available.",
	"verification-warning":             "Connection verification completed with a warning.",
	"verification-result-failed":       "One or more connection-verification checks failed.",
	"verification-tautulli-failed":     "Tautulli verification failed; review the current sanitized evidence under Verify.",
	"verification-plex-failed":         "Direct Plex verification failed; review the current sanitized evidence under Verify.",
	"verification-multiple-failed":     "Tautulli and direct Plex verification failed; review the current sanitized evidence under Verify.",
	"smtp-request-invalid":             "The Manager rejected an invalid SMTP preflight request.",
	"smtp-not-ready":                   "SMTP preflight could not start because configuration is incomplete.",
	"smtp-conflict":                    "Configuration changed before SMTP preflight could start.",
	"smtp-preflight-failed":            "SMTP preflight could not be completed safely.",
	"smtp-config-changed":              "Configuration changed while SMTP preflight was running.",
	"smtp-passed":                      "SMTP connectivity and STARTTLS validation passed.",
	"smtp-warning":                     "SMTP preflight completed with a warning.",
	"smtp-result-failed":               "SMTP connectivity or protocol validation failed.",
	"discovery-request-invalid":        "The Manager rejected an invalid Tautulli lookup request.",
	"discovery-not-ready":              "Tautulli choices could not load because configuration is incomplete.",
	"discovery-conflict":               "Configuration changed before Tautulli choices could load.",
	"discovery-boundary":               "The configured Tautulli destination was outside the private or loopback network boundary.",
	"discovery-failed":                 "Tautulli choices could not be loaded from the saved connection.",
	"discovery-config-changed":         "Configuration changed while Tautulli choices were loading.",
	"discovery-cache-failed":           "Tautulli choices loaded, but their local cache could not be updated.",
	"discovery-completed":              "Tautulli library and user choices were loaded and retained locally.",
	"startup-request-invalid":          "The Manager rejected an invalid sign-in startup request.",
	"startup-unsupported":              "Manager sign-in startup is unavailable on this platform.",
	"startup-entry-conflict":           "A same-named Windows sign-in entry was not owned by this TautWeekly installation and was left unchanged.",
	"startup-update-failed":            "Windows could not save the requested Manager sign-in settings.",
	"startup-disabled":                 "Manager sign-in startup was disabled for the current Windows user.",
	"startup-enabled":                  "Manager sign-in startup was enabled for the current Windows user.",
	"startup-enabled-dashboard":        "Manager sign-in startup and one-time Dashboard opening were enabled for the current Windows user.",
}

var remoteAccessDiagnosticSummaries = map[string]string{
	"remote-access-request-invalid":         "The Manager rejected an invalid private remote access request.",
	"remote-access-unsupported":             "Private remote access is unavailable for this package.",
	"tailscale-serve-conflict":              "An existing Tailscale Serve configuration was not owned by TautWeekly and was left unchanged.",
	"tailscale-disable-incomplete":          "The private hostname was blocked locally, but the owned Tailscale Serve route still needs cleanup.",
	"tailscale-unavailable":                 "Tailscale was not installed, connected, or available to the Manager user.",
	"tailscale-approval-required":           "Windows administrator approval was required to inspect or change Tailscale Serve.",
	"tailscale-host-authorization-required": "The native Linux host has not authorized TautWeekly's fixed Tailscale adapter.",
	"tailscale-approval-declined":           "Windows administrator approval was cancelled before Tailscale Serve changed.",
	"tailscale-provider-approval-required":  "Tailscale required one-time provider approval before private HTTPS Serve could be enabled.",
	"tailscale-sign-in-required":            "Tailscale must be signed in before private Serve access can be configured.",
	"tailscale-verification-failed":         "Tailscale did not retain the exact private HTTPS route expected by TautWeekly.",
	"remote-access-state-write-failed":      "The private remote access setting could not be saved safely.",
	"tailscale-disabled":                    "Private Tailscale access was disabled.",
	"tailscale-enabled":                     "Private Tailscale access was enabled and verified.",
	"tailscale-verified":                    "Tailscale Serve status was explicitly inspected without changing it.",
	"tailscale-funnel-verified":             "Tailscale Funnel status was explicitly inspected without changing it.",
	"tailscale-funnel-publication-pending":  "The exact Funnel route is configured locally, but Tailscale has not confirmed public control-plane publication.",
	"manager-password-required":             "Public Funnel enablement was blocked because the Manager password lock was not active.",
	"tailscale-not-running":                 "The official Tailscale Windows service was not running.",
	"tailscale-funnel-unsupported":          "The installed Tailscale Windows client did not support Funnel.",
	"tailscale-password-disable-blocked":    "The Manager password lock stayed enabled because public Funnel shutdown could not be verified.",
	"tailscale-funnel-needs-attention":      "The saved public Funnel did not match the exact TautWeekly loopback route.",
	"tailscale-funnel-disabled":             "The TautWeekly-owned public Funnel was disabled and verified.",
	"tailscale-funnel-enabled":              "The TautWeekly-owned public Funnel was enabled and verified.",
}

func diagnosticSummary(code string) (string, bool) {
	if summary, ok := diagnosticSummaries[code]; ok {
		return summary, true
	}
	summary, ok := remoteAccessDiagnosticSummaries[code]
	return summary, ok
}

type DiagnosticEvent struct {
	SchemaVersion int    `json:"schemaVersion"`
	RecordedAtUTC string `json:"recordedAtUtc"`
	Area          string `json:"area"`
	Outcome       string `json:"outcome"`
	Code          string `json:"code"`
	Summary       string `json:"summary"`
}

type DiagnosticHistory struct {
	Events          []DiagnosticEvent `json:"events"`
	MaximumEntries  int               `json:"maximumEntries"`
	RetentionPolicy string            `json:"retentionPolicy"`
}

type diagnosticStore struct {
	mu   sync.Mutex
	path string
	now  func() time.Time
}

func newDiagnosticStore(dataDir string, now func() time.Time) *diagnosticStore {
	if now == nil {
		now = time.Now
	}
	store := &diagnosticStore{path: filepath.Join(dataDir, "diagnostic-history.jsonl"), now: now}
	store.mu.Lock()
	_ = store.pruneLocked()
	store.mu.Unlock()
	return store
}

func (s *diagnosticStore) Record(area, outcome, code string) {
	summary, ok := diagnosticSummary(code)
	if !ok || !validDiagnosticArea(area) || !validDiagnosticOutcome(outcome) {
		return
	}
	event := DiagnosticEvent{
		SchemaVersion: diagnosticSchemaVersion,
		RecordedAtUTC: s.now().UTC().Format(time.RFC3339),
		Area:          area,
		Outcome:       outcome,
		Code:          code,
		Summary:       summary,
	}
	encoded, err := json.Marshal(event)
	if err != nil {
		return
	}
	encoded = append(encoded, '\n')

	s.mu.Lock()
	defer s.mu.Unlock()
	if writePrivateFile(s.path, encoded, os.O_CREATE|os.O_APPEND) == nil {
		_ = s.pruneLocked()
	}
}

func (s *diagnosticStore) History() DiagnosticHistory {
	s.mu.Lock()
	defer s.mu.Unlock()
	_ = s.pruneLocked()
	return DiagnosticHistory{
		Events:          s.readLocked(),
		MaximumEntries:  diagnosticHistoryLimit,
		RetentionPolicy: diagnosticRetention,
	}
}

func (s *diagnosticStore) readLocked() []DiagnosticEvent {
	file, err := os.Open(s.path)
	if err != nil {
		return []DiagnosticEvent{}
	}
	defer file.Close()
	events := []DiagnosticEvent{}
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 1024), maximumDiagnosticLine)
	for scanner.Scan() {
		var event DiagnosticEvent
		if json.Unmarshal(scanner.Bytes(), &event) == nil && validDiagnosticEvent(event) {
			events = append(events, event)
		}
	}
	sort.SliceStable(events, func(i, j int) bool {
		return events[i].RecordedAtUTC > events[j].RecordedAtUTC
	})
	return events
}

func (s *diagnosticStore) pruneLocked() error {
	events := s.readLocked()
	kept := make([]DiagnosticEvent, 0, len(events))
	for _, event := range events {
		kept = append(kept, event)
		if len(kept) == diagnosticHistoryLimit {
			break
		}
	}
	if len(kept) == len(events) {
		return nil
	}
	sort.SliceStable(kept, func(i, j int) bool {
		return kept[i].RecordedAtUTC < kept[j].RecordedAtUTC
	})
	var buffer bytes.Buffer
	for _, event := range kept {
		encoded, err := json.Marshal(event)
		if err == nil {
			buffer.Write(encoded)
			buffer.WriteByte('\n')
		}
	}
	return writePrivateBytes(s.path, buffer.Bytes())
}

func validDiagnosticEvent(event DiagnosticEvent) bool {
	summary, ok := diagnosticSummary(event.Code)
	if event.SchemaVersion != diagnosticSchemaVersion || !ok || event.Summary != summary {
		return false
	}
	if !validDiagnosticArea(event.Area) || !validDiagnosticOutcome(event.Outcome) {
		return false
	}
	_, err := time.Parse(time.RFC3339, event.RecordedAtUTC)
	return err == nil
}

func validDiagnosticArea(area string) bool {
	switch area {
	case "configuration", "recovery", "lan-verification", "smtp-preflight", "tautulli-discovery", "startup", "remote-access":
		return true
	default:
		return false
	}
}

func validDiagnosticOutcome(outcome string) bool {
	return outcome == "passed" || outcome == "warning" || outcome == "failed"
}

func diagnosticOutcome(result string) string {
	if validDiagnosticOutcome(result) {
		return result
	}
	return "failed"
}

func diagnosticResultCode(result string) string {
	switch result {
	case "passed", "warning":
		return result
	default:
		return "result-failed"
	}
}
