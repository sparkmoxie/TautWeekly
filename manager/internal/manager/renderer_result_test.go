package manager

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestRendererResultAcceptsSanitizedPreviewAllContract(t *testing.T) {
	path := filepath.Join(t.TempDir(), "result.json")
	result := validPreviewAllRendererResult()
	encoded, err := json.Marshal(result)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, encoded, 0o600); err != nil {
		t.Fatal(err)
	}
	decoded, err := readRendererResult(path, "PreviewAll")
	if err != nil {
		t.Fatal(err)
	}
	if decoded.Outcome != "succeeded" || decoded.DeliveryScope != "none" || decoded.DurationMS != 1250 || len(decoded.GeneratedPreviewFiles) != 7 {
		t.Fatalf("unexpected structured result: %+v", decoded)
	}
}

func TestRendererResultRejectsUnknownPrivateAndInconsistentFields(t *testing.T) {
	valid := validPreviewAllRendererResult()
	cases := []struct {
		name   string
		mutate func(*rendererResult)
	}{
		{name: "wrong mode", mutate: func(result *rendererResult) { result.Mode = "SendAll" }},
		{name: "delivery scope", mutate: func(result *rendererResult) { result.DeliveryScope = "production" }},
		{name: "smtp count", mutate: func(result *rendererResult) { result.SMTPAcceptedCount = 1 }},
		{name: "path traversal", mutate: func(result *rendererResult) { result.GeneratedPreviewFiles[0] = `..\private.html` }},
		{name: "missing preview", mutate: func(result *rendererResult) { result.GeneratedPreviewFiles = result.GeneratedPreviewFiles[:6] }},
		{name: "negative count", mutate: func(result *rendererResult) { result.FailedCount = -1 }},
		{name: "time reversal", mutate: func(result *rendererResult) { result.FinishedAtUTC = "2031-04-18T16:29:59Z" }},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			result := valid
			result.GeneratedPreviewFiles = append([]string{}, valid.GeneratedPreviewFiles...)
			test.mutate(&result)
			if validRendererResult(result, "PreviewAll") {
				t.Fatalf("invalid structured result was accepted: %+v", result)
			}
		})
	}

	path := filepath.Join(t.TempDir(), "unknown.json")
	raw := `{"schemaVersion":1,"mode":"PreviewAll","outcome":"failed","deliveryScope":"none","startedAtUtc":"2031-04-18T16:30:00Z","finishedAtUtc":"2031-04-18T16:30:01Z","durationMs":1000,"smtpAcceptedCount":0,"skippedCount":0,"failedCount":0,"generatedPreviewFiles":[],"recipientEmail":"private@example.org"}`
	if err := os.WriteFile(path, []byte(raw), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := readRendererResult(path, "PreviewAll"); err == nil {
		t.Fatal("structured result with an unknown recipient field was accepted")
	}
}

func TestRendererResultValidatesSendTestAllAggregateContract(t *testing.T) {
	started := time.Date(2031, 4, 18, 16, 30, 0, 0, time.UTC)
	valid := rendererResult{
		SchemaVersion:     1,
		Mode:              "SendTestAll",
		Outcome:           "succeeded",
		DeliveryScope:     "test",
		StartedAtUTC:      started.Format(time.RFC3339Nano),
		FinishedAtUTC:     started.Add(2 * time.Second).Format(time.RFC3339Nano),
		DurationMS:        2000,
		SMTPAcceptedCount: 6,
	}
	if !validRendererResult(valid, "SendTestAll") {
		t.Fatalf("valid SendTestAll result was rejected: %+v", valid)
	}

	cases := []struct {
		name   string
		mutate func(*rendererResult)
	}{
		{name: "wrong accepted count", mutate: func(result *rendererResult) { result.SMTPAcceptedCount = 5 }},
		{name: "recipient preview", mutate: func(result *rendererResult) { result.GeneratedPreviewFiles = []string{"preview-private.html"} }},
		{name: "wrong delivery scope", mutate: func(result *rendererResult) { result.DeliveryScope = "production" }},
		{name: "unexpected skip", mutate: func(result *rendererResult) { result.SkippedCount = 1 }},
		{name: "reported failure", mutate: func(result *rendererResult) { result.FailedCount = 1 }},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			result := valid
			test.mutate(&result)
			if validRendererResult(result, "SendTestAll") {
				t.Fatalf("invalid SendTestAll result was accepted: %+v", result)
			}
		})
	}
}

func validPreviewAllRendererResult() rendererResult {
	started := time.Date(2031, 4, 18, 16, 30, 0, 0, time.UTC)
	return rendererResult{
		SchemaVersion: 1,
		Mode:          "PreviewAll",
		Outcome:       "succeeded",
		DeliveryScope: "none",
		StartedAtUTC:  started.Format(time.RFC3339Nano),
		FinishedAtUTC: started.Add(1250 * time.Millisecond).Format(time.RFC3339Nano),
		DurationMS:    1250,
		GeneratedPreviewFiles: []string{
			"preview-all-00-INDEX.html",
			"preview-all-01-manual-welcome.html",
			"preview-all-02-new-user-no-history.html",
			"preview-all-03-new-user-with-history.html",
			"preview-all-04-normal-newsletter.html",
			"preview-all-05-established-quiet.html",
			"preview-all-06-established-warmup.html",
		},
	}
}
