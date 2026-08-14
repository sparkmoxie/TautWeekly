//go:build !windows

package main

import (
	"errors"
	"log"
	"os/exec"
)

func registerUninstaller(options) error { return errors.New("Windows-only operation") }
func chooseInstallDirectory(string) (string, bool, error) {
	return "", false, errors.New("Windows-only operation")
}
func preferredInstallDirectory(value string) string     { return value }
func hideProcessWindow(*exec.Cmd)                       {}
func unregisterUninstaller() error                      { return errors.New("Windows-only operation") }
func createShortcuts(options, *log.Logger) error        { return errors.New("Windows-only operation") }
func removeShortcuts() error                            { return errors.New("Windows-only operation") }
func stopInstalledManager(string, bool) (bool, error)   { return false, nil }
func applyVerifiedUpdate(options, string, string) error { return errors.New("Windows-only operation") }
func removeInstalledSchedule(string, bool) error        { return nil }
func scheduleSelfRemoval(string, string) error          { return errors.New("Windows-only operation") }
func confirmAction(string, string, bool) (bool, error)  { return true, nil }
func showCompletion(string, string, bool) error         { return nil }
func showFailure(string, string, bool) error            { return nil }
