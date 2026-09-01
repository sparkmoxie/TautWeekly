//go:build !windows && !linux

package manager

func newPlatformRemoteAccessController(options Options) remoteAccessController {
	return newPublicFunnelController(options.DataDir, options.ListenAddress, "platform-funnel.json", false, nil)
}
