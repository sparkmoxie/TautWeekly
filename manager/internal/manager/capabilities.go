package manager

import (
	"runtime"
	"strings"
)

const (
	runtimeModeWindows = "windows"
	runtimeModeNAS     = "nas"
	runtimeModeLinux   = "linux"
	runtimeModeMac     = "mac"
)

// Capabilities describes the package that owns the shared Manager core. The
// browser uses this contract instead of guessing from GOOS and accidentally
// presenting controls that cannot work in the current package.
type Capabilities struct {
	RuntimeMode       string   `json:"runtimeMode"`
	PackageKind       string   `json:"packageKind"`
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
	if value == runtimeModeNAS || value == runtimeModeLinux || value == runtimeModeMac {
		return value
	}
	return runtimeModeWindows
}

func capabilitiesFor(options Options) Capabilities {
	mode := normalizedRuntimeMode(options.RuntimeMode)
	packageKind := normalizedPackageKind(options.PackageKind, mode)
	if mode == runtimeModeNAS {
		return Capabilities{
			RuntimeMode:       runtimeModeNAS,
			PackageKind:       packageKind,
			Platform:          runtime.GOOS,
			AccessLabel:       "Container access",
			NetworkScope:      "trusted-lan",
			Authentication:    "required",
			ScheduleProvider:  "embedded-container",
			ScheduleActions:   []string{"enable", "disable"},
			LifecycleProvider: "container-host",
			UpdateProvider:    packageKind,
			PathStyle:         "container-volume",
			SecureCookies:     options.SecureCookies,
		}
	}
	if mode == runtimeModeLinux {
		return Capabilities{
			RuntimeMode:       runtimeModeLinux,
			PackageKind:       packageKind,
			Platform:          runtime.GOOS,
			AccessLabel:       "Linux service access",
			NetworkScope:      "host-loopback",
			Authentication:    "required",
			ScheduleProvider:  "embedded-service",
			ScheduleActions:   []string{"enable", "disable"},
			LifecycleProvider: "systemd",
			UpdateProvider:    "linux-package",
			PathStyle:         "linux-service",
			SecureCookies:     options.SecureCookies,
		}
	}
	if mode == runtimeModeMac {
		updateProvider := "mac-package"
		pathStyle := "mac-bind-mount"
		if packageKind == packageKindMacRegistry {
			updateProvider = "mac-registry"
			pathStyle = "container-volume"
		}
		return Capabilities{
			RuntimeMode:       runtimeModeMac,
			PackageKind:       packageKind,
			Platform:          "macos-docker",
			AccessLabel:       "macOS Docker Desktop access",
			NetworkScope:      "host-loopback",
			Authentication:    "required",
			ScheduleProvider:  "embedded-container",
			ScheduleActions:   []string{"enable", "disable"},
			LifecycleProvider: "docker-desktop",
			UpdateProvider:    updateProvider,
			PathStyle:         pathStyle,
			SecureCookies:     options.SecureCookies,
		}
	}
	return Capabilities{
		RuntimeMode:       runtimeModeWindows,
		PackageKind:       packageKind,
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

func isManagedServiceRuntimeMode(mode string) bool {
	mode = normalizedRuntimeMode(mode)
	return mode == runtimeModeNAS || mode == runtimeModeLinux || mode == runtimeModeMac
}

func isContainerRuntimeMode(mode string) bool {
	mode = normalizedRuntimeMode(mode)
	return mode == runtimeModeNAS || mode == runtimeModeMac
}

func containsCapabilityAction(actions []string, action string) bool {
	for _, candidate := range actions {
		if candidate == action {
			return true
		}
	}
	return false
}
