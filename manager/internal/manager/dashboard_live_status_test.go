package manager

import (
	"io/fs"
	"strings"
	"testing"
)

func TestDashboardEmbedsLiveDeliveryAndTimelineStates(t *testing.T) {
	tests := []struct {
		name     string
		required []string
	}{
		{
			name: "web/index.html",
			required: []string{
				`id="delivery-status-icon"`,
				`id="timeline-upcoming-card"`,
				`id="timeline-last-attempt-card"`,
				`id="timeline-previews-card"`,
			},
		},
		{
			name: "web/app.js",
			required: []string{
				`productionDeliveryIsRunning`,
				`pollDeliveryStatus`,
				`deliveryRunning ? "Running"`,
				`"timeline-ready", scheduleHasUpcomingRun(snapshot)`,
				`"timeline-success", rendererEvidence && !deliveryRunning && snapshot.delivery.result === "smtp-accepted"`,
				`"timeline-ready", state.previews.length > 0`,
			},
		},
		{
			name: "web/app.css",
			required: []string{
				`.delivery-icon-running`,
				`.timeline-card.timeline-ready`,
				`.timeline-card.timeline-success`,
				`prefers-reduced-motion:reduce`,
			},
		},
	}
	for _, test := range tests {
		raw, err := fs.ReadFile(embeddedWeb, test.name)
		if err != nil {
			t.Fatalf("read %s: %v", test.name, err)
		}
		text := string(raw)
		for _, required := range test.required {
			if !strings.Contains(text, required) {
				t.Errorf("%s does not contain %q", test.name, required)
			}
		}
	}
}
