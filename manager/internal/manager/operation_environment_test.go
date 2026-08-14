package manager

import (
	"slices"
	"testing"
)

func TestOperationEnvironmentFiltersCredentialsAndProxiesOnEveryPlatform(t *testing.T) {
	input := []string{
		"Path=C:\\Windows",
		"plex_token=private",
		"TAUTWEEKLY_CONFIG=C:\\private\\config.json",
		"HTTP_PROXY=http://127.0.0.1:1",
		"https_proxy=http://127.0.0.1:2",
		"ALL_PROXY=socks5://127.0.0.1:3",
		"no_proxy=localhost",
		"SAFE_VALUE=kept",
	}

	got := operationEnvironment(input)
	want := []string{"Path=C:\\Windows", "SAFE_VALUE=kept"}
	if !slices.Equal(got, want) {
		t.Fatalf("operationEnvironment() = %#v, want %#v", got, want)
	}
}
