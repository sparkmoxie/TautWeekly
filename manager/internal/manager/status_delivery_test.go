package manager

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestLatestRendererResultProvidesTruthfulDeliveryEvidence(t *testing.T) {
	root := t.TempDir()
	started := time.Date(2031, 4, 18, 16, 30, 0, 0, time.UTC)
	result := rendererResult{
		SchemaVersion:     2,
		Mode:              "SendAll",
		Outcome:           "succeeded",
		DeliveryScope:     "production",
		StartedAtUTC:      started.Format(time.RFC3339Nano),
		FinishedAtUTC:     started.Add(3 * time.Second).Format(time.RFC3339Nano),
		DurationMS:        3000,
		SMTPAcceptedCount: 3,
		SkippedCount:      1,
		SkipReasonCounts:  &DeliverySkipReasonCounts{ExcludedUserID: 1},
	}
	writeRendererResultFixture(t, root, result)
	snapshot := StatusSnapshot{Delivery: DeliveryStatus{Result: "task-result-0", Evidence: "task-scheduler"}}
	applyLatestRendererDelivery(&snapshot, root)
	if snapshot.Delivery.Result != "smtp-accepted" || snapshot.Delivery.Evidence != "renderer-result" || snapshot.Delivery.SMTPAcceptedCount != 3 || snapshot.Delivery.SkippedCount != 1 || snapshot.Delivery.FailedCount != 0 {
		t.Fatalf("unexpected delivery evidence: %+v", snapshot.Delivery)
	}
	if snapshot.Delivery.LastAttemptUTC != result.StartedAtUTC || snapshot.Delivery.LastSuccessUTC != result.FinishedAtUTC {
		t.Fatalf("unexpected delivery timestamps: %+v", snapshot.Delivery)
	}
	if snapshot.Delivery.SkipReasonCounts == nil || snapshot.Delivery.SkipReasonCounts.ExcludedUserID != 1 {
		t.Fatalf("sanitized skip evidence was not surfaced: %+v", snapshot.Delivery)
	}
}

func TestLatestRendererResultDistinguishesPartialFailureAndNoAcceptedDelivery(t *testing.T) {
	root := t.TempDir()
	started := time.Date(2031, 4, 18, 16, 30, 0, 0, time.UTC)
	base := rendererResult{
		SchemaVersion: 1,
		Mode:          "SendAll",
		DeliveryScope: "production",
		StartedAtUTC:  started.Format(time.RFC3339Nano),
		FinishedAtUTC: started.Add(time.Second).Format(time.RFC3339Nano),
		DurationMS:    1000,
	}
	partial := base
	partial.Outcome = "partial"
	partial.SMTPAcceptedCount = 2
	partial.FailedCount = 1
	writeRendererResultFixture(t, root, partial)
	snapshot := StatusSnapshot{Delivery: DeliveryStatus{Result: "not-recorded", Evidence: "none"}}
	applyLatestRendererDelivery(&snapshot, root)
	if snapshot.Delivery.Result != "partial-smtp-accepted" || snapshot.Delivery.LastSuccessUTC == "" {
		t.Fatalf("partial delivery was not distinguished: %+v", snapshot.Delivery)
	}

	noAccepted := base
	noAccepted.Outcome = "succeeded"
	noAccepted.SkippedCount = 4
	writeRendererResultFixture(t, root, noAccepted)
	snapshot = StatusSnapshot{Delivery: DeliveryStatus{Result: "not-recorded", Evidence: "none"}}
	applyLatestRendererDelivery(&snapshot, root)
	if snapshot.Delivery.Result != "completed-no-accepted-deliveries" || snapshot.Delivery.LastSuccessUTC != "" {
		t.Fatalf("zero-acceptance run was presented as a successful send: %+v", snapshot.Delivery)
	}

	noEligible := base
	noEligible.SchemaVersion = 2
	noEligible.Outcome = "failed"
	noEligible.ErrorCategory = "no-eligible-recipients"
	noEligible.SkippedCount = 2
	noEligible.SkipReasonCounts = &DeliverySkipReasonCounts{ExcludedUserID: 1, ExcludedEmail: 1}
	writeRendererResultFixture(t, root, noEligible)
	snapshot = StatusSnapshot{Delivery: DeliveryStatus{Result: "not-recorded", Evidence: "none"}}
	applyLatestRendererDelivery(&snapshot, root)
	if snapshot.Delivery.Result != "failed" || snapshot.Delivery.ErrorCategory != "no-eligible-recipients" || snapshot.Delivery.SkipReasonCounts == nil {
		t.Fatalf("zero-eligible result was not surfaced explicitly: %+v", snapshot.Delivery)
	}

	rateLimited := base
	rateLimited.SchemaVersion = 3
	rateLimited.Outcome = "failed"
	rateLimited.ErrorCategory = "smtp-rate-limited"
	rateLimited.FailedCount = 1
	rateLimited.SkipReasonCounts = &DeliverySkipReasonCounts{}
	rateLimited.SMTPFailure = &SMTPFailureEvidence{Category: "smtp-rate-limited", Stage: "greeting", ResponseCode: 421, ResponseClass: 4, BatchFatal: true, Acceptance: "not-attempted"}
	writeRendererResultFixture(t, root, rateLimited)
	snapshot = StatusSnapshot{Delivery: DeliveryStatus{Result: "not-recorded", Evidence: "none"}}
	applyLatestRendererDelivery(&snapshot, root)
	if snapshot.Delivery.Result != "failed" || snapshot.Delivery.ErrorCategory != "smtp-rate-limited" || snapshot.Delivery.SMTPFailure == nil || snapshot.Delivery.SMTPFailure.ResponseCode != 421 {
		t.Fatalf("sanitized SMTP circuit-breaker evidence was not surfaced: %+v", snapshot.Delivery)
	}
}

func TestMalformedLatestRendererResultDoesNotReplaceTaskEvidence(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "last-run.json"), []byte(`{"recipientEmail":"private@example.org"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	snapshot := StatusSnapshot{Delivery: DeliveryStatus{Result: "task-result-1", Evidence: "task-scheduler", LastAttemptUTC: "2031-04-18T16:30:00Z"}}
	applyLatestRendererDelivery(&snapshot, root)
	if snapshot.Delivery.Result != "task-result-1" || snapshot.Delivery.Evidence != "task-scheduler" {
		t.Fatalf("malformed renderer result replaced task evidence: %+v", snapshot.Delivery)
	}
}

func TestWindowsTaskRunningSignalRequiresOwnedActiveTask(t *testing.T) {
	runningCode := windowsTaskRunningResult
	for _, test := range []struct {
		name  string
		probe windowsTaskProbe
		want  bool
	}{
		{name: "live state", probe: windowsTaskProbe{Installed: true, Owned: true, State: "Running", LastRunUTC: "2031-04-18T16:30:00Z"}, want: true},
		{name: "scheduler result", probe: windowsTaskProbe{Installed: true, Owned: true, State: "Ready", LastTaskResult: &runningCode, LastRunUTC: "2031-04-18T16:30:00Z"}, want: true},
		{name: "foreign task", probe: windowsTaskProbe{Installed: true, Owned: false, State: "Running", LastTaskResult: &runningCode}, want: false},
		{name: "completed task", probe: windowsTaskProbe{Installed: true, Owned: true, State: "Ready"}, want: false},
	} {
		t.Run(test.name, func(t *testing.T) {
			signal := windowsTaskDeliveryRunSignal(test.probe)
			if signal.Running != test.want {
				t.Fatalf("running=%t, want %t for %+v", signal.Running, test.want, test.probe)
			}
			if test.want && (signal.StartedAtUTC != test.probe.LastRunUTC || signal.Evidence != "task-scheduler") {
				t.Fatalf("unexpected running signal: %+v", signal)
			}
		})
	}
}

func TestActiveDeliveryOverridesStaleCompletedRendererEvidence(t *testing.T) {
	root := t.TempDir()
	started := time.Date(2031, 4, 18, 16, 0, 0, 0, time.UTC)
	writeRendererResultFixture(t, root, rendererResult{
		SchemaVersion:     2,
		Mode:              "SendAll",
		Outcome:           "succeeded",
		DeliveryScope:     "production",
		StartedAtUTC:      started.Format(time.RFC3339Nano),
		FinishedAtUTC:     started.Add(5 * time.Minute).Format(time.RFC3339Nano),
		DurationMS:        300000,
		SMTPAcceptedCount: 12,
	})
	snapshot := StatusSnapshot{Delivery: DeliveryStatus{
		Result:         "not-recorded",
		Evidence:       "none",
		LastSuccessUTC: started.Add(5 * time.Minute).Format(time.RFC3339Nano),
	}}
	applyLatestRendererDelivery(&snapshot, root)
	activeStart := started.Add(7 * 24 * time.Hour).Format(time.RFC3339Nano)
	applyActiveDelivery(&snapshot, deliveryRunSignal{Running: true, StartedAtUTC: activeStart, Evidence: "task-scheduler"})
	if !snapshot.Delivery.Running || snapshot.Delivery.Result != "running" || snapshot.Delivery.Evidence != "task-scheduler" || snapshot.Delivery.LastAttemptUTC != activeStart {
		t.Fatalf("active delivery did not replace stale completion: %+v", snapshot.Delivery)
	}
	if snapshot.Delivery.SMTPAcceptedCount != 0 || snapshot.Delivery.ExitCode != nil || snapshot.Delivery.SMTPFailure != nil || snapshot.Delivery.ErrorCategory != "" {
		t.Fatalf("active delivery retained stale terminal evidence: %+v", snapshot.Delivery)
	}
	if snapshot.Delivery.LastSuccessUTC == "" {
		t.Fatal("active delivery should retain the prior accepted-run timestamp")
	}
}

func writeRendererResultFixture(t *testing.T, root string, result rendererResult) {
	t.Helper()
	encoded, err := json.Marshal(result)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "last-run.json"), encoded, 0o600); err != nil {
		t.Fatal(err)
	}
}
