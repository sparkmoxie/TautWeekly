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
