//go:build !windows

package manager

import "os"

func hardenPrivateFile(path string) error {
	return os.Chmod(path, 0o600)
}
