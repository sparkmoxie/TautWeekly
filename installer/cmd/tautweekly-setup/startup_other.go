//go:build !windows

package main

type managerStartupPreference struct {
	Enabled       bool
	OpenDashboard bool
	InstallRoot   string
	DataRoot      string
}

func captureManagerStartup(bool) (managerStartupPreference, error) {
	return managerStartupPreference{}, nil
}

func reconcileManagerStartup(managerStartupPreference, options, bool) error { return nil }
func removeManagerStartup(string, bool) error                               { return nil }
