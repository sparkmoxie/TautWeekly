package manager

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const maximumRendererResultBytes = 64 << 10

var errRendererResultInvalid = errors.New("renderer result is invalid")

type rendererResult struct {
	SchemaVersion         int      `json:"schemaVersion"`
	Mode                  string   `json:"mode"`
	Outcome               string   `json:"outcome"`
	ErrorCategory         string   `json:"errorCategory,omitempty"`
	DeliveryScope         string   `json:"deliveryScope"`
	StartedAtUTC          string   `json:"startedAtUtc"`
	FinishedAtUTC         string   `json:"finishedAtUtc"`
	DurationMS            int64    `json:"durationMs"`
	SMTPAcceptedCount     int      `json:"smtpAcceptedCount"`
	SkippedCount          int      `json:"skippedCount"`
	FailedCount           int      `json:"failedCount"`
	GeneratedPreviewFiles []string `json:"generatedPreviewFiles"`
}

func readRendererResult(path, expectedMode string) (rendererResult, error) {
	var result rendererResult
	file, err := os.Open(path)
	if err != nil {
		return result, errRendererResultInvalid
	}
	defer file.Close()
	raw, err := io.ReadAll(io.LimitReader(file, maximumRendererResultBytes+1))
	if err != nil || len(raw) > maximumRendererResultBytes {
		return result, errRendererResultInvalid
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&result) != nil || decoder.Decode(&struct{}{}) != io.EOF {
		return rendererResult{}, errRendererResultInvalid
	}
	if !validRendererResult(result, expectedMode) {
		return rendererResult{}, errRendererResultInvalid
	}
	return result, nil
}

func validRendererResult(result rendererResult, expectedMode string) bool {
	if result.SchemaVersion != 1 || result.Mode != expectedMode || expectedDeliveryScope(result.Mode) == "" {
		return false
	}
	if result.Outcome != "succeeded" && result.Outcome != "partial" && result.Outcome != "failed" {
		return false
	}
	if result.ErrorCategory != "" {
		if result.Outcome != "failed" || !validRendererErrorCategory(result.ErrorCategory) {
			return false
		}
	}
	if result.DeliveryScope != expectedDeliveryScope(result.Mode) {
		return false
	}
	started, startErr := time.Parse(time.RFC3339Nano, result.StartedAtUTC)
	finished, finishErr := time.Parse(time.RFC3339Nano, result.FinishedAtUTC)
	if startErr != nil || finishErr != nil || finished.Before(started) || result.DurationMS < 0 || result.DurationMS > int64((24*time.Hour)/time.Millisecond) {
		return false
	}
	for _, count := range []int{result.SMTPAcceptedCount, result.SkippedCount, result.FailedCount} {
		if count < 0 || count > 1_000_000 {
			return false
		}
	}
	if len(result.GeneratedPreviewFiles) > 20 {
		return false
	}
	seen := make(map[string]struct{}, len(result.GeneratedPreviewFiles))
	for _, name := range result.GeneratedPreviewFiles {
		if name == "" || filepath.Base(name) != name || !strings.EqualFold(filepath.Ext(name), ".html") || !strings.HasPrefix(strings.ToLower(name), "preview") {
			return false
		}
		key := strings.ToLower(name)
		if _, duplicate := seen[key]; duplicate {
			return false
		}
		seen[key] = struct{}{}
	}
	switch result.Mode {
	case "PreviewAll":
		if result.SMTPAcceptedCount != 0 || result.SkippedCount != 0 || result.FailedCount != 0 {
			return false
		}
		if result.Outcome == "succeeded" && !previewAllResultFilesValid(seen) {
			return false
		}
	case "Preview":
		if result.SMTPAcceptedCount != 0 || result.SkippedCount != 0 || result.FailedCount != 0 || (result.Outcome == "succeeded" && len(seen) != 1) {
			return false
		}
	case "SendTest":
		if len(seen) != 0 || result.SkippedCount != 0 || (result.Outcome == "succeeded" && (result.SMTPAcceptedCount != 1 || result.FailedCount != 0)) {
			return false
		}
	case "SendTestAll":
		if len(seen) != 0 || result.SkippedCount != 0 || (result.Outcome == "succeeded" && (result.SMTPAcceptedCount != 6 || result.FailedCount != 0)) {
			return false
		}
	case "SendWelcome":
		if len(seen) != 0 || result.SkippedCount != 0 || (result.Outcome == "succeeded" && (result.SMTPAcceptedCount != 1 || result.FailedCount != 0)) {
			return false
		}
	case "SendAll":
		if len(seen) != 0 || (result.Outcome == "succeeded" && result.FailedCount != 0) || (result.Outcome == "partial" && (result.SMTPAcceptedCount == 0 || result.FailedCount == 0)) {
			return false
		}
	case "ListUsers", "VerifyPlex":
		if len(seen) != 0 || result.SMTPAcceptedCount != 0 || result.SkippedCount != 0 || result.FailedCount != 0 || result.Outcome == "partial" {
			return false
		}
	}
	return true
}

func validRendererErrorCategory(category string) bool {
	switch category {
	case "operation-busy",
		"configuration-invalid",
		"tautulli-unavailable",
		"plex-unavailable",
		"asset-unavailable",
		"render-failed",
		"output-failed",
		"smtp-failed",
		"renderer-failed":
		return true
	default:
		return false
	}
}

func expectedDeliveryScope(mode string) string {
	switch mode {
	case "SendTest", "SendTestAll":
		return "test"
	case "SendWelcome":
		return "welcome"
	case "SendAll":
		return "production"
	case "Preview", "PreviewAll", "ListUsers", "VerifyPlex":
		return "none"
	default:
		return ""
	}
}

func previewAllResultFilesValid(files map[string]struct{}) bool {
	expected := []string{
		"preview-all-00-index.html",
		"preview-all-01-manual-welcome.html",
		"preview-all-02-new-user-no-history.html",
		"preview-all-03-new-user-with-history.html",
		"preview-all-04-normal-newsletter.html",
		"preview-all-05-established-quiet.html",
		"preview-all-06-established-warmup.html",
	}
	if len(files) != len(expected) {
		return false
	}
	for _, name := range expected {
		if _, exists := files[name]; !exists {
			return false
		}
	}
	return true
}
