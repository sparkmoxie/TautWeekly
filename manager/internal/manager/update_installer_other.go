//go:build !windows

package manager

func newPlatformUpdateInstaller(_ string) updateInstallController {
	return disabledUpdateInstaller{}
}
