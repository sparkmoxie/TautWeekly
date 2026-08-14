package manager

import "strings"

// operationEnvironment removes ambient credentials and proxy configuration
// before starting any local helper process. Keep this platform-neutral because
// shared status probes use the same boundary even when cross-compiled.
func operationEnvironment(source []string) []string {
	result := make([]string, 0, len(source))
	for _, entry := range source {
		name, _, _ := strings.Cut(entry, "=")
		switch strings.ToUpper(name) {
		case "PLEX_TOKEN", "TAUTWEEKLY_CONFIG", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY":
			continue
		default:
			result = append(result, entry)
		}
	}
	return result
}
