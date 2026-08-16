package manager

import (
	"runtime"
	"strings"
)

const (
	runtimeModeWindows = "windows"
	runtimeModeNAS     = "nas"
)

// Capabilities describes the package that owns the shared Manager core. The
// browser uses this contract instead of guessing from GOOS and accidentally
// presenting controls that cannot work in the current package.
type Capabilities struct {
	RuntimeMode       string   `json:"runtimeMode"`
	Platform          string   `json:"platform"`
	AccessLabel       string   `json:"accessLabel"`
	NetworkScope      string   `json:"networkScope"`
	Authentication    string   `json:"authentication"`
	ScheduleProvider  string   `json:"scheduleProvider"`
	ScheduleActions   []string `json:"scheduleActions"`
	LifecycleProvider string   `json:"lifecycleProvider"`
	UpdateProvider    string   `json:"updateProvider"`
	PathStyle         string   `json:"pathStyle"`
	SupportsStartup   bool     `json:"supportsStartup"`
	SupportsTray      bool     `json:"supportsTray"`
	OpensBrowser      bool     `json:"opensBrowser"`
	SecureCookies     bool     `json:"secureCookies"`
}

func normalizedRuntimeMode(value string) string {
	value = strings.ToLower(strings.TrimSpace(value))
	if value == runtimeModeNAS {
		return runtimeModeNAS
	}
	return runtimeModeWindows
}

func capabilitiesFor(options Options) Capabilities {
	mode := normalizedRuntimeMode(options.RuntimeMode)
	if mode == runtimeModeNAS {
		return Capabilities{
			RuntimeMode:       runtimeModeNAS,
			Platform:          runtime.GOOS,
			AccessLabel:       "Container access",
			NetworkScope:      "trusted-lan",
			Authentication:    "required",
			ScheduleProvider:  "embedded-container",
			ScheduleActions:   []string{"enable", "disable"},
			LifecycleProvider: "container-host",
			UpdateProvider:    "container-host",
			PathStyle:         "container-volume",
			SecureCookies:     options.SecureCookies,
		}
	}
	return Capabilities{
		RuntimeMode:       runtimeModeWindows,
		Platform:          runtime.GOOS,
		AccessLabel:       "Browser access",
		NetworkScope:      "loopback",
		Authentication:    "optional",
		ScheduleProvider:  "windows-task-scheduler",
		ScheduleActions:   []string{"install", "enable", "disable", "remove"},
		LifecycleProvider: "windows-manager",
		UpdateProvider:    "windows-installer",
		PathStyle:         "windows-local",
		SupportsStartup:   runtime.GOOS == "windows",
		SupportsTray:      runtime.GOOS == "windows",
		OpensBrowser:      runtime.GOOS == "windows",
		SecureCookies:     options.SecureCookies,
	}
}

func containsCapabilityAction(actions []string, action string) bool {
	for _, candidate := range actions {
		if candidate == action {
			return true
		}
	}
	return false
}
