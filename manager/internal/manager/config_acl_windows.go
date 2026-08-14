//go:build windows

package manager

import (
	"fmt"
	"os/exec"
	"os/user"
)

func hardenPrivateFile(path string) error {
	current, err := user.Current()
	if err != nil {
		return err
	}
	identity := "*" + current.Uid
	command := exec.Command("icacls.exe", path, "/inheritance:r", "/grant:r", identity+":(F)", "*S-1-5-18:(F)", "*S-1-5-32-544:(F)")
	if output, err := command.CombinedOutput(); err != nil {
		return fmt.Errorf("icacls: %w: %s", err, output)
	}
	return nil
}
