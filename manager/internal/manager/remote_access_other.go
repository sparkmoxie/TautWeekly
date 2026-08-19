//go:build !windows && !linux

package manager

func newPlatformRemoteAccessController(options Options) remoteAccessController {
	if isManagedServiceRuntimeMode(options.RuntimeMode) {
		return newExternalTailscaleRemoteAccessController(options.DataDir, options.ListenAddress)
	}
	return newTailscaleRemoteAccessController(options.DataDir, options.ListenAddress, false, nil)
}
