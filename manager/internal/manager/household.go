package manager

import (
	"context"
	"encoding/json"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

const maximumHouseholdCopies = 20

func validateUserBccAddresses(raw json.RawMessage, value any) (any, string) {
	items, ok := value.(map[string]any)
	if !ok || len(items) > maximumUserEmailOverrides || hasDuplicateUserEmailOverrideKeys(raw) {
		return nil, "Submit at most 2000 unique source-user assignments."
	}
	result := make(map[string][]string)
	seenIDs := make(map[string]bool)
	for rawID, item := range items {
		id := strings.TrimSpace(rawID)
		if !validTautulliUserID(id) {
			return nil, "Choose a nonzero numeric Tautulli user ID."
		}
		number, err := strconv.ParseUint(id, 10, 64)
		if err != nil || number == 0 {
			return nil, "Choose a nonzero numeric Tautulli user ID."
		}
		id = strconv.FormatUint(number, 10)
		if seenIDs[id] {
			return nil, "Each source user may appear only once."
		}
		seenIDs[id] = true
		addresses, ok := item.([]any)
		if !ok || len(addresses) > maximumHouseholdCopies {
			return nil, "Assign at most 20 copy addresses per source user."
		}
		seen := make(map[string]bool)
		for _, item := range addresses {
			address, ok := item.(string)
			if !ok || strings.IndexFunc(address, unicode.IsControl) >= 0 {
				return nil, "Enter bare email addresses without control characters."
			}
			address = strings.ToLower(strings.TrimSpace(address))
			if address == "" {
				continue
			}
			if utf8.RuneCountInString(address) > maximumDeliveryEmailRunes || !validEmail(address) {
				return nil, "Enter a valid bare email address of at most 254 characters."
			}
			if !seen[address] {
				result[id] = append(result[id], address)
				seen[address] = true
			}
		}
	}
	return result, ""
}

// The selected address is deliberately never written to discovery or diagnostics.
func (s *Server) handleHouseholdPrimary(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	var request struct {
		ExpectedRevision string `json:"expectedRevision"`
		UserID           string `json:"userId"`
	}
	if decodeJSON(r, &request) != nil || !validTautulliUserID(request.UserID) {
		writeAPIError(w, http.StatusBadRequest, "invalid-request", "Choose a valid source user.")
		return
	}
	if !s.verificationRunMu.TryLock() {
		writeAPIError(w, http.StatusConflict, "verification-running", "Another service lookup is running.")
		return
	}
	defer s.verificationRunMu.Unlock()
	values, raw, exists, state := readConfigDocument(s.options.RuntimeRoot)
	if state != "ready" || !exists || request.ExpectedRevision == "" || request.ExpectedRevision != configRevision(raw, exists) {
		writeAPIError(w, http.StatusConflict, "config-conflict", "Refresh the saved configuration before viewing an address.")
		return
	}
	base, err := parseLANBaseURL(configMapString(values, "TautulliUrl"))
	if err != nil {
		writeAPIError(w, http.StatusUnprocessableEntity, "lookup-boundary", "The saved service must be on a private or loopback network.")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	var detail map[string]any
	err = tautulliCommandWithParams(ctx, newLANOnlyHTTPClient(), base, configMapString(values, "ApiKey"), "get_user", url.Values{"user_id": {request.UserID}}, &detail)
	if err != nil || discoveryUserID(detail["user_id"]) != request.UserID {
		writeAPIError(w, http.StatusBadGateway, "lookup-unavailable", "The selected user could not be verified.")
		return
	}
	address := discoveredUserEmail(detail)
	source := "native"
	if address == "" {
		address = configUserEmailOverride(values["UserEmailOverrides"], request.UserID)
		source = "fallback"
	}
	if address == "" {
		source = "missing"
	}
	if address != "" && (!validEmail(address) || strings.IndexFunc(address, unicode.IsControl) >= 0 || len(address) > 254) {
		writeAPIError(w, http.StatusBadGateway, "lookup-invalid", "The selected user's delivery address is invalid.")
		return
	}
	s.configMu.Lock()
	defer s.configMu.Unlock()
	if ReadConfigEditor(s.options.RuntimeRoot).Revision != request.ExpectedRevision {
		writeAPIError(w, http.StatusConflict, "config-conflict", "Configuration changed during lookup. Refresh and try again.")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"userId": request.UserID, "address": address, "source": source})
}
