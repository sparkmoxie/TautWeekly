package main

import "testing"

func TestManagerInstanceIDIsStableAndScoped(t *testing.T) {
	first := managerInstanceID("127.0.0.1:8788", `C:\TautWeekly`)
	if first == "" || first != managerInstanceID("127.0.0.1:8788", `c:\tautweekly`) {
		t.Fatalf("instance identity was not stable across Windows path casing: %q", first)
	}
	if first == managerInstanceID("127.0.0.1:8789", `C:\TautWeekly`) || first == managerInstanceID("127.0.0.1:8788", `C:\Other`) {
		t.Fatal("instance identity did not separate address and application root")
	}
}

func TestTrayHealthUsesThreeTruthfulStates(t *testing.T) {
	for overall, expected := range map[string]trayHealth{
		"healthy":      trayHealthy,
		"blocked":      trayFailed,
		"unconfigured": trayNeedsAttention,
		"degraded":     trayNeedsAttention,
	} {
		if actual := trayHealthFromOverall(overall); actual != expected {
			t.Fatalf("trayHealthFromOverall(%q) = %q, want %q", overall, actual, expected)
		}
	}
	for health, expected := range map[trayHealth]string{
		trayHealthy:        "Healthy",
		trayNeedsAttention: "Needs attention",
		trayFailed:         "Failed",
	} {
		if actual := health.label(); actual != expected {
			t.Fatalf("tray label for %q = %q, want %q", health, actual, expected)
		}
	}
}
