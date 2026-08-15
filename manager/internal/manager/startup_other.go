//go:build !windows

package manager

type unsupportedStartupController struct{}

func newPlatformStartupController(_, _ string) startupSettingsController {
	return unsupportedStartupController{}
}

func (unsupportedStartupController) Status() StartupSettings {
	return StartupSettings{Supported: false, State: "unsupported", ErrorCode: "platform-unsupported"}
}

func (unsupportedStartupController) Update(_, _ bool) (StartupSettings, error) {
	return StartupSettings{Supported: false, State: "unsupported", ErrorCode: "platform-unsupported"}, ErrStartupUnsupported
}
