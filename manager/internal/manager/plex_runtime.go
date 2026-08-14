package manager

import (
	"os"
	"strings"
)

func runtimePlexToken(values map[string]any) string {
	if token := strings.TrimSpace(configMapString(values, "PlexToken")); configValueConfigured(token) {
		return token
	}
	if token := strings.TrimSpace(os.Getenv("PLEX_TOKEN")); configValueConfigured(token) {
		return token
	}
	return strings.TrimSpace(platformPlexToken())
}
