//go:build !linux

package manager

import (
	"errors"
	"os"
)

func RunLinuxRemoteAccessHelper(_, _ *os.File) error {
	return errors.New("the Linux remote-access helper is unavailable on this platform")
}
