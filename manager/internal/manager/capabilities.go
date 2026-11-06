package manager

import (
	"net"
	"runtime"
	"strings"
)

const (
	runtimeModeWindows = "windows"
	runtimeModeNAS     = "nas"
	runtimeModeLinux   = "linux"
	runtimeModeMac     = "mac"

	runtimeProfileDesktop     = "desktop"
	runtimeProfileServer      = "server"
	runtimeProfileUnraid      = "unraid"
	runtimeProfileNativeLinux = "native-linux"
	runtimeProfileWindows     = "native-windows"
)

// Capabilities describes the package that owns the shared Manager core. The
// browser uses this contract instead of guessing from GOOS and accidentally
// presenting controls that cannot work in the current package.
type Capabilities struct {
	RuntimeMode       string   `json:"runtimeMode"`
	RuntimeProfile    string   `json:"runtimeProfile"`
	PackageKind       string   `json:"packageKind"`
	PackageLabel      string   `json:"packageLabel"`
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

func normalizedRuntimeProfile(value, mode, packageKind string) string {
	value = strings.ToLower(strings.TrimSpace(value))
	switch normalizedRuntimeMode(mode) {
	case runtimeModeMac:
		return runtimeProfileDesktop
	case runtimeModeNAS:
		if value == runtimeProfileUnraid || packageKind == packageKindUnraid {
			return runtimeProfileUnraid
		}
		return runtimeProfileServer
	case runtimeModeLinux:
		return runtimeProfileNativeLinux
	default:
		return runtimeProfileWindows
	}
}

func capabilitiesFor(options Options) Capabilities {
	mode := normalizedRuntimeMode(options.RuntimeMode)
	packageKind := normalizedPackageKind(options.PackageKind, mode)
	runtimeProfile := normalizedRuntimeProfile(options.RuntimeProfile, mode, packageKind)
	lifecycleProvider := "container-host"
	if runtimeProfile == runtimeProfileUnraid {
		lifecycleProvider = "unraid-host"
	}
	if packageKind == packageKindFreeBSD {
		lifecycleProvider = "podman-host"
	}
	if mode == runtimeModeNAS {
		return Capabilities{
			RuntimeMode:       runtimeModeNAS,
			PackageKind:       packageKind,
			PackageLabel:      packageLabel(packageKind),
			Platform:          runtime.GOOS,
			AccessLabel:       "Container access",
			NetworkScope:      "deployment-configured",
			RuntimeProfile:    runtimeProfile,
			Authentication:    "required",
			ScheduleProvider:  "embedded-container",
			ScheduleActions:   []string{"enable", "disable"},
			LifecycleProvider: lifecycleProvider,
			UpdateProvider:    packageKind,
			PathStyle:         "container-volume",
			SecureCookies:     options.SecureCookies,
		}
	}
	if mode == runtimeModeLinux {
		networkScope := "listener-configured"
		host, _, _ := net.SplitHostPort(options.ListenAddress)
		if options.ListenAddress == "" || net.ParseIP(host).IsLoopback() {
			networkScope = "host-loopback"
		}
		return Capabilities{
			RuntimeMode:       runtimeModeLinux,
			PackageKind:       packageKind,
			PackageLabel:      packageLabel(packageKind),
			Platform:          runtime.GOOS,
			AccessLabel:       "Linux service access",
			NetworkScope:      networkScope,
			RuntimeProfile:    runtimeProfile,
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
		updateProvider := packageKind
		pathStyle := "container-volume"
		if packageKind == packageKindMac {
			updateProvider = "mac-package"
			pathStyle = "mac-bind-mount"
		} else if packageKind == packageKindMacRegistry {
			updateProvider = "mac-registry"
		}
		lifecycleProvider := "container-host"
		if packageKind == packageKindMac || packageKind == packageKindMacRegistry || packageKind == packageKindContainerDesktop {
			lifecycleProvider = "docker-desktop"
		}
		return Capabilities{
			RuntimeMode:       runtimeModeMac,
			PackageKind:       packageKind,
			PackageLabel:      packageLabel(packageKind),
			Platform:          "macos-docker",
			AccessLabel:       "macOS Docker Desktop access",
			NetworkScope:      "deployment-configured",
			Authentication:    "required",
			RuntimeProfile:    runtimeProfile,
			ScheduleProvider:  "embedded-container",
			ScheduleActions:   []string{"enable", "disable"},
			LifecycleProvider: lifecycleProvider,
			UpdateProvider:    updateProvider,
			PathStyle:         pathStyle,
			SecureCookies:     options.SecureCookies,
		}
	}
	return Capabilities{
		RuntimeMode:       runtimeModeWindows,
		PackageKind:       packageKind,
		PackageLabel:      packageLabel(packageKind),
		Platform:          runtime.GOOS,
		AccessLabel:       "Browser access",
		NetworkScope:      "loopback",
		Authentication:    "optional",
		RuntimeProfile:    runtimeProfile,
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
