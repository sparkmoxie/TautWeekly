package main

import (
	"fmt"
	"net"
	"net/url"
	"strings"
)

func validateLocalBrowserURL(target string) error {
	parsed, err := url.Parse(target)
	if err != nil {
		return fmt.Errorf("parse local browser URL: %w", err)
	}
	if parsed.Scheme != "http" || parsed.User != nil || parsed.RawQuery != "" || parsed.Hostname() == "" || parsed.Port() == "" {
		return fmt.Errorf("refuse non-local Manager URL")
	}
	host := parsed.Hostname()
	if !strings.EqualFold(host, "localhost") {
		ip := net.ParseIP(host)
		if ip == nil || !ip.IsLoopback() {
			return fmt.Errorf("refuse non-loopback Manager URL")
		}
	}
	return nil
}
