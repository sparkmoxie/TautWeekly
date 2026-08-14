//go:build windows

package manager

import (
	"syscall"
	"unsafe"
)

const plexRegistryPath = `Software\Plex, Inc.\Plex Media Server`

func platformPlexToken() string {
	for _, registryView := range []uint32{syscall.KEY_WOW64_64KEY, syscall.KEY_WOW64_32KEY, 0} {
		if token := readRegistryString(syscall.HKEY_CURRENT_USER, plexRegistryPath, "PlexOnlineToken", registryView); configValueConfigured(token) {
			return token
		}
	}
	return ""
}

func readRegistryString(root syscall.Handle, path, name string, registryView uint32) string {
	subkey, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return ""
	}
	var key syscall.Handle
	if err := syscall.RegOpenKeyEx(root, subkey, 0, syscall.KEY_QUERY_VALUE|registryView, &key); err != nil {
		return ""
	}
	defer syscall.RegCloseKey(key)

	valueName, err := syscall.UTF16PtrFromString(name)
	if err != nil {
		return ""
	}
	var valueType uint32
	var byteCount uint32
	if err := syscall.RegQueryValueEx(key, valueName, nil, &valueType, nil, &byteCount); err != nil || valueType != syscall.REG_SZ || byteCount < 2 || byteCount > 64<<10 {
		return ""
	}
	buffer := make([]byte, byteCount)
	if err := syscall.RegQueryValueEx(key, valueName, nil, &valueType, &buffer[0], &byteCount); err != nil {
		return ""
	}
	words := unsafe.Slice((*uint16)(unsafe.Pointer(&buffer[0])), int(byteCount)/2)
	return syscall.UTF16ToString(words)
}
