//go:build !windows

package main

type noManagerTray struct{}

func startManagerTray(trayOptions) (managerTray, error) { return noManagerTray{}, nil }
func (noManagerTray) Close() error                      { return nil }
