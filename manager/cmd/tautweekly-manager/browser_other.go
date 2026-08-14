//go:build !windows

package main

import "fmt"

func openLocalBrowser(target string) error {
	if err := validateLocalBrowserURL(target); err != nil {
		return err
	}
	return fmt.Errorf("automatic browser opening is not available on this platform")
}
