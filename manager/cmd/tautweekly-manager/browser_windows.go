//go:build windows

package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

func openLocalBrowser(target string) error {
	if err := validateLocalBrowserURL(target); err != nil {
		return err
	}
	systemRoot := strings.TrimSpace(os.Getenv("SystemRoot"))
	if systemRoot == "" {
		return fmt.Errorf("SystemRoot is unavailable")
	}
	opener := filepath.Join(systemRoot, "System32", "rundll32.exe")
	if info, err := os.Stat(opener); err != nil || !info.Mode().IsRegular() {
		return fmt.Errorf("Windows browser opener is unavailable")
	}
	return exec.Command(opener, "url.dll,FileProtocolHandler", target).Start()
}
