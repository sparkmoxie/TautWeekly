//go:build !windows

package main

import "errors"

type unrestrictedManagerInstance struct{}

func acquireManagerInstance(_, _ string) (managerInstance, bool, error) {
	return unrestrictedManagerInstance{}, true, nil
}

func signalManagerShutdown(_, _ string) error {
	return errors.New("Manager shutdown signaling is available only on Windows")
}

func (unrestrictedManagerInstance) ShutdownRequested() <-chan struct{} { return nil }
func (unrestrictedManagerInstance) Close() error                       { return nil }
