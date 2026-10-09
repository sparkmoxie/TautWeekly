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
	excludedIDs, idsKnown := productionExclusionRules(values["ExcludedUserIds"])
	excludedEmails, emailsKnown := productionExclusionRules(values["ExcludedEmails"])
	if !idsKnown || !emailsKnown {
		return nil
	}
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

// The renderer compares exclusions case-insensitively without trimming them.
// Preserve legacy config-file whitespace instead of applying UI normalization.
func productionExclusionRules(value any) (map[string]struct{}, bool) {
	rules := make(map[string]struct{})
	switch entries := value.(type) {
	case nil:
	case string:
		rules[strings.ToLower(entries)] = struct{}{}
	case []string:
		for _, entry := range entries {
			rules[strings.ToLower(entry)] = struct{}{}
		}
	case []any:
		for _, entry := range entries {
			text, ok := entry.(string)
			if !ok {
				return nil, false
			}
			rules[strings.ToLower(text)] = struct{}{}
		}
	default:
		return nil, false
	}
	return rules, true
}
