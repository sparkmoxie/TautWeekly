package manager

import (
	"fmt"
	"strconv"
	"strings"
)

// countDiscoveredPrimaryRecipients describes the successful get_users snapshot,
// never live delivery readiness. No addresses or household copies are retained.
// Incomplete or bounded rosters are unknown, not a misleading partial count.
func countDiscoveredPrimaryRecipients(users []map[string]any, values map[string]any) *int {
	if len(users) >= maximumDiscoveryChoices {
		return nil
	}
	excludedIDs := normalizedLegacyExclusionRules(values["ExcludedUserIds"])
	excludedEmails := normalizedLegacyExclusionRules(values["ExcludedEmails"])
	overrides := normalizedDiscoveryUserEmailOverrides(values["UserEmailOverrides"])
	seen := map[string]bool{}
	count := 0
	for _, user := range users {
		rawID := strings.TrimSpace(fmt.Sprint(user["user_id"]))
		if reservedTautulliUserID(rawID) {
			continue
		}
		id := discoveryUserID(user["user_id"])
		if id == "" || seen[id] {
			return nil
		}
		seen[id] = true
		active, err := strconv.Atoi(fmt.Sprint(user["is_active"]))
		if err != nil {
			return nil
		}
		deleted := 0
		if user["deleted_user"] != nil {
			deleted, err = strconv.Atoi(fmt.Sprint(user["deleted_user"]))
			if err != nil {
				return nil
			}
		}
		if active == 0 || deleted > 0 {
			continue
		}
		if _, excluded := excludedIDs[id]; excluded {
			continue
		}
		// Match production: only the native email field is authoritative. A fallback
		// is consulted only when that field is blank; do_notify is intentionally unused.
		if _, present := user["email"]; !present {
			return nil
		}
		email, ok := user["email"].(string)
		if !ok && user["email"] != nil {
			return nil
		}
		if strings.TrimSpace(email) == "" {
			email = overrides[id]
		}
		if strings.TrimSpace(email) == "" {
			continue
		}
		if _, excluded := excludedEmails[strings.ToLower(email)]; excluded {
			continue
		}
		count++
	}
	return &count
}
