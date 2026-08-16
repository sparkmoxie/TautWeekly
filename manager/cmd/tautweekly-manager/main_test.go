package main

import "testing"

func TestRequireLoopback(t *testing.T) {
	t.Parallel()
	for _, address := range []string{"127.0.0.1:8788", "[::1]:8788", "localhost:8788"} {
		if err := requireLoopback(address); err != nil {
			t.Errorf("requireLoopback(%q): %v", address, err)
		}
	}
	for _, address := range []string{"0.0.0.0:8788", "192.0.2.10:8788", "manager.example:8788"} {
		if err := requireLoopback(address); err == nil {
			t.Errorf("requireLoopback(%q) unexpectedly succeeded", address)
		}
	}
}

func TestLocalManagerURLKeepsPairingTokenInFragment(t *testing.T) {
	t.Parallel()
	target := localManagerURL("127.0.0.1:8788", "fictional-token")
	if target != "http://127.0.0.1:8788/#pair=fictional-token" {
		t.Fatalf("localManagerURL() = %q", target)
	}
	if err := validateLocalBrowserURL(target); err != nil {
		t.Fatalf("validate generated URL: %v", err)
	}
}

func TestValidateLocalBrowserURLRejectsExternalOrCredentialedTargets(t *testing.T) {
	t.Parallel()
	for _, target := range []string{
		"https://127.0.0.1:8788/",
		"http://192.0.2.10:8788/",
		"http://manager.example:8788/",
		"http://user:password@127.0.0.1:8788/",
		"http://127.0.0.1:8788/?token=private",
	} {
		if err := validateLocalBrowserURL(target); err == nil {
			t.Errorf("validateLocalBrowserURL(%q) unexpectedly succeeded", target)
		}
	}
}

func TestValidateAllowedHostsAcceptsOnlyBareDNSNames(t *testing.T) {
	t.Parallel()
	for _, value := range []string{"nas.example.test", "nas.example.test,weekly.internal", "NAS-01.local"} {
		if err := validateAllowedHosts(value); err != nil {
			t.Errorf("validateAllowedHosts(%q): %v", value, err)
		}
	}
	for _, value := range []string{
		"https://nas.example.test",
		"nas.example.test:8787",
		"192.0.2.10",
		"nas.example.test/path",
		"*.example.test",
		"user@nas.example.test",
	} {
		if err := validateAllowedHosts(value); err == nil {
			t.Errorf("validateAllowedHosts(%q) unexpectedly succeeded", value)
		}
	}
}
