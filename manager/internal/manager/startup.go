package manager

import (
	"errors"
	"net/http"
)

var (
	ErrStartupUnsupported = errors.New("Manager startup is unsupported on this platform")
	ErrStartupConflict    = errors.New("the Windows sign-in entry is not owned by this TautWeekly installation")
	ErrStartupUnavailable = errors.New("Manager startup status is unavailable")
)

type StartupSettings struct {
	Supported     bool   `json:"supported"`
	StartManager  bool   `json:"startManager"`
	OpenDashboard bool   `json:"openDashboard"`
	State         string `json:"state"`
	ErrorCode     string `json:"errorCode,omitempty"`
}

type startupSettingsRequest struct {
	StartManager  bool `json:"startManager"`
	OpenDashboard bool `json:"openDashboard"`
}

type startupSettingsController interface {
	Status() StartupSettings
	Update(startManager, openDashboard bool) (StartupSettings, error)
}

func (s *Server) handleStartupSettings(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, s.startup.Status())
}

func (s *Server) handleUpdateStartupSettings(w http.ResponseWriter, r *http.Request) {
	var request startupSettingsRequest
	if err := decodeJSON(r, &request); err != nil {
		s.diagnostics.Record("startup", "failed", "startup-request-invalid")
		writeAPIError(w, http.StatusBadRequest, "invalid-request", "The startup settings request was invalid.")
		return
	}
	if request.OpenDashboard && !request.StartManager {
		s.diagnostics.Record("startup", "failed", "startup-request-invalid")
		writeAPIFieldErrors(w, http.StatusBadRequest, "validation-failed", "Open Dashboard after sign-in requires Manager startup.", map[string]string{
			"openDashboard": "Turn on Start Manager when I sign in first.",
		})
		return
	}
	status, err := s.startup.Update(request.StartManager, request.OpenDashboard)
	if err != nil {
		switch {
		case errors.Is(err, ErrStartupUnsupported):
			s.diagnostics.Record("startup", "failed", "startup-unsupported")
			writeAPIError(w, http.StatusConflict, "platform-unsupported", "Manager sign-in startup is not available on this platform.")
		case errors.Is(err, ErrStartupConflict):
			s.diagnostics.Record("startup", "failed", "startup-entry-conflict")
			writeAPIError(w, http.StatusConflict, "startup-entry-conflict", "The Windows sign-in entry does not match this TautWeekly installation and was left unchanged.")
		case errors.Is(err, ErrStartupUnavailable):
			s.diagnostics.Record("startup", "failed", "startup-update-failed")
			writeAPIError(w, http.StatusInternalServerError, "startup-unavailable", "Windows sign-in startup status could not be read safely.")
		default:
			s.diagnostics.Record("startup", "failed", "startup-update-failed")
			writeAPIError(w, http.StatusInternalServerError, "startup-update-failed", "Windows could not save the Manager sign-in settings.")
		}
		return
	}
	code := "startup-disabled"
	if status.StartManager && status.OpenDashboard {
		code = "startup-enabled-dashboard"
	} else if status.StartManager {
		code = "startup-enabled"
	}
	s.diagnostics.Record("startup", "passed", code)
	writeJSON(w, http.StatusOK, status)
}
