package manager

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"
)

type RuntimeStatus struct {
	Manager   string `json:"manager"`
	Preview   string `json:"preview"`
	Scheduler string `json:"scheduler"`
}

type ReadinessStatus struct {
	Configuration string `json:"configuration"`
	PrivateData   string `json:"privateData"`
}

type ScheduleStatus struct {
	Supported    bool   `json:"supported"`
	Provider     string `json:"provider"`
	Installed    bool   `json:"installed"`
	Enabled      bool   `json:"enabled"`
	Owned        bool   `json:"owned"`
	Ownership    string `json:"ownership"`
	State        string `json:"state"`
	NextRunUTC   string `json:"nextRunUtc,omitempty"`
	NextRunLocal string `json:"nextRunLocal,omitempty"`
}

type DeliveryStatus struct {
	LastAttemptUTC    string                    `json:"lastAttemptUtc,omitempty"`
	LastSuccessUTC    string                    `json:"lastSuccessUtc,omitempty"`
	Result            string                    `json:"result"`
	Evidence          string                    `json:"evidence"`
	SMTPAcceptedCount int                       `json:"smtpAcceptedCount"`
	SkippedCount      int                       `json:"skippedCount"`
	FailedCount       int                       `json:"failedCount"`
	SkipReasonCounts  *DeliverySkipReasonCounts `json:"skipReasonCounts,omitempty"`
	ErrorCategory     string                    `json:"errorCategory,omitempty"`
	ExitCode          *int64                    `json:"exitCode,omitempty"`
}

type IntegrationStatus struct {
	Tautulli string `json:"tautulli"`
	Plex     string `json:"plex"`
	SMTP     string `json:"smtp"`
}

type StatusSnapshot struct {
	SchemaVersion  int               `json:"schemaVersion"`
	ObservedAtUTC  string            `json:"observedAtUtc"`
	Overall        string            `json:"overall"`
	Platform       string            `json:"platform"`
	Version        string            `json:"version"`
	Runtime        RuntimeStatus     `json:"runtime"`
	Readiness      ReadinessStatus   `json:"readiness"`
	Schedule       ScheduleStatus    `json:"schedule"`
	Delivery       DeliveryStatus    `json:"delivery"`
	Integrations   IntegrationStatus `json:"integrations"`
	PreviewCount   int               `json:"previewCount"`
	PreviewSummary string            `json:"previewSummary"`
}

type windowsTaskProbe struct {
	Installed      bool   `json:"installed"`
	Enabled        bool   `json:"enabled"`
	Owned          bool   `json:"owned"`
	Ownership      string `json:"ownership"`
	State          string `json:"state"`
	NextRunUTC     string `json:"nextRunUtc"`
	NextRunLocal   string `json:"nextRunLocal"`
	LastRunUTC     string `json:"lastRunUtc"`
	LastTaskResult *int64 `json:"lastTaskResult"`
}

func CollectStatus(ctx context.Context, options Options) StatusSnapshot {
	now := options.Now
	if now == nil {
		now = time.Now
	}
	observed := now().UTC()
	runtimeRoot := options.RuntimeRoot
	if strings.TrimSpace(runtimeRoot) == "" {
		runtimeRoot = options.TautWeeklyRoot
	}
	config := ReadRedactedConfig(runtimeRoot)
	editor := ReadConfigEditor(runtimeRoot)
	previews, _ := listPreviews(runtimeRoot)

	capabilities := capabilitiesFor(options)
	snapshot := StatusSnapshot{
		SchemaVersion: 1,
		ObservedAtUTC: observed.Format(time.RFC3339),
		Overall:       "healthy",
		Platform:      capabilities.Platform,
		Version:       options.Version,
		Runtime: RuntimeStatus{
			Manager:   "healthy",
			Preview:   "empty",
			Scheduler: "not-installed",
		},
		Readiness: ReadinessStatus{
			Configuration: editor.State,
			PrivateData:   dataReadiness(options.DataDir),
		},
		Schedule: ScheduleStatus{
			Supported: capabilities.ScheduleProvider != "unsupported",
			Provider:  capabilities.ScheduleProvider,
			Ownership: "not-installed",
			State:     "not-installed",
		},
		Delivery: DeliveryStatus{
			Result:   "not-recorded",
			Evidence: "none",
		},
		Integrations: IntegrationStatus{
			Tautulli: "not-checked",
			Plex:     "not-checked",
			SMTP:     "not-checked",
		},
		PreviewCount:   len(previews),
		PreviewSummary: previewSummary(previews),
	}

	if len(previews) > 0 {
		snapshot.Runtime.Preview = "ready"
	}
	if !config.Exists || editor.State == "needs-setup" {
		snapshot.Overall = "unconfigured"
	} else if !config.Valid {
		snapshot.Overall = "blocked"
	}

	if capabilities.RuntimeMode == runtimeModeWindows && runtime.GOOS == "windows" {
		taskName := configString(config, "ScheduledTaskName", "TautWeekly for Plex Newsletter")
		probe, err := probeWindowsTask(ctx, taskName, options.TautWeeklyRoot)
		if err != nil {
			snapshot.Runtime.Scheduler = "unknown"
			snapshot.Schedule.State = "probe-failed"
			snapshot.Schedule.Ownership = "unknown"
			if snapshot.Overall == "healthy" {
				snapshot.Overall = "degraded"
			}
		} else if probe.Installed {
			if probe.Owned {
				snapshot.Runtime.Scheduler = strings.ToLower(probe.State)
			} else {
				snapshot.Runtime.Scheduler = "ownership-mismatch"
				if snapshot.Overall == "healthy" {
					snapshot.Overall = "degraded"
				}
			}
			snapshot.Schedule = ScheduleStatus{
				Supported:    true,
				Provider:     capabilities.ScheduleProvider,
				Installed:    true,
				Enabled:      probe.Enabled,
				Owned:        probe.Owned,
				Ownership:    probe.Ownership,
				State:        strings.ToLower(probe.State),
				NextRunUTC:   probe.NextRunUTC,
				NextRunLocal: probe.NextRunLocal,
			}
			snapshot.Delivery.LastAttemptUTC = probe.LastRunUTC
			snapshot.Delivery.ExitCode = probe.LastTaskResult
			if probe.LastTaskResult != nil {
				snapshot.Delivery.Evidence = "task-scheduler"
				snapshot.Delivery.Result = "task-result-" + strconv.FormatInt(*probe.LastTaskResult, 10)
			}
		}
	}
	if isManagedServiceRuntimeMode(capabilities.RuntimeMode) {
		applyEmbeddedScheduleStatus(&snapshot, runtimeRoot, observed, capabilities.ScheduleProvider)
	}
	applyLatestRendererDelivery(&snapshot, runtimeRoot)
	return snapshot
}

type containerSchedulerHeartbeat struct {
	UTC        string `json:"Utc"`
	Local      string `json:"Local"`
	TimeZoneID string `json:"TimeZoneId"`
}

type containerSchedulerState struct {
	LastAttemptUTC string `json:"LastAttemptUtc"`
	LastSuccessUTC string `json:"LastSuccessUtc"`
	LastResult     string `json:"LastResult"`
	LastExitCode   *int64 `json:"LastExitCode"`
}

func applyEmbeddedScheduleStatus(snapshot *StatusSnapshot, runtimeRoot string, observed time.Time, provider string) {
	values, _, exists, state := readConfigDocument(runtimeRoot)
	enabled := exists && state == "ready" && configMapBool(values, "ScheduleEnabled", false)
	snapshot.Schedule = ScheduleStatus{
		Supported: true,
		Provider:  provider,
		Installed: true,
		Enabled:   enabled,
		Owned:     true,
		Ownership: "package-managed",
		State:     "starting",
	}
	snapshot.Runtime.Scheduler = "starting"

	var heartbeat containerSchedulerHeartbeat
	if !readSmallJSON(filepath.Join(runtimeRoot, "scheduler-heartbeat.json"), &heartbeat) {
		if snapshot.Overall == "healthy" {
			snapshot.Overall = "degraded"
		}
	} else if stamp, err := time.Parse(time.RFC3339, heartbeat.UTC); err != nil || observed.Sub(stamp.UTC()) > 90*time.Second || observed.Before(stamp.UTC().Add(-5*time.Second)) {
		snapshot.Schedule.State = "heartbeat-stale"
		snapshot.Runtime.Scheduler = "heartbeat-stale"
		if snapshot.Overall == "healthy" {
			snapshot.Overall = "degraded"
		}
	} else {
		snapshot.Schedule.State = "running"
		snapshot.Runtime.Scheduler = "running"
		snapshot.Schedule.NextRunLocal, snapshot.Schedule.NextRunUTC = nextContainerRun(values, heartbeat.TimeZoneID, observed)
	}

	var schedulerState containerSchedulerState
	if readSmallJSON(filepath.Join(runtimeRoot, "scheduler-state.json"), &schedulerState) {
		snapshot.Delivery.LastAttemptUTC = schedulerState.LastAttemptUTC
		snapshot.Delivery.LastSuccessUTC = schedulerState.LastSuccessUTC
		snapshot.Delivery.ExitCode = schedulerState.LastExitCode
		if strings.TrimSpace(schedulerState.LastResult) != "" {
			snapshot.Delivery.Result = strings.ToLower(strings.ReplaceAll(schedulerState.LastResult, " ", "-"))
			snapshot.Delivery.Evidence = "embedded-scheduler"
		}
	}
}

func readSmallJSON(path string, target any) bool {
	raw, err := os.ReadFile(path)
	if err != nil || len(raw) > 64<<10 {
		return false
	}
	return json.Unmarshal(raw, target) == nil
}

func nextContainerRun(values map[string]any, zoneName string, observed time.Time) (string, string) {
	location, err := time.LoadLocation(strings.TrimSpace(zoneName))
	if err != nil {
		return "", ""
	}
	dayName := strings.ToLower(strings.TrimSpace(configMapString(values, "ScheduleDay")))
	weekdays := map[string]time.Weekday{
		"sunday": time.Sunday, "monday": time.Monday, "tuesday": time.Tuesday,
		"wednesday": time.Wednesday, "thursday": time.Thursday, "friday": time.Friday, "saturday": time.Saturday,
	}
	weekday, ok := weekdays[dayName]
	if !ok {
		return "", ""
	}
	parsed, err := time.Parse("15:04", strings.TrimSpace(configMapString(values, "ScheduleTime")))
	if err != nil {
		return "", ""
	}
	localNow := observed.In(location)
	daysAhead := (int(weekday) - int(localNow.Weekday()) + 7) % 7
	next := time.Date(localNow.Year(), localNow.Month(), localNow.Day()+daysAhead, parsed.Hour(), parsed.Minute(), 0, 0, location)
	if !next.After(localNow) {
		next = next.AddDate(0, 0, 7)
	}
	return next.Format(time.RFC3339), next.UTC().Format(time.RFC3339)
}

func applyLatestRendererDelivery(snapshot *StatusSnapshot, root string) {
	result, err := readRendererResult(filepath.Join(root, "last-run.json"), "SendAll")
	if err != nil {
		return
	}
	snapshot.Delivery.LastAttemptUTC = result.StartedAtUTC
	snapshot.Delivery.Evidence = "renderer-result"
	snapshot.Delivery.SMTPAcceptedCount = result.SMTPAcceptedCount
	snapshot.Delivery.SkippedCount = result.SkippedCount
	snapshot.Delivery.FailedCount = result.FailedCount
	snapshot.Delivery.SkipReasonCounts = result.SkipReasonCounts
	snapshot.Delivery.ErrorCategory = result.ErrorCategory
	switch {
	case result.Outcome == "succeeded" && result.SMTPAcceptedCount > 0:
		snapshot.Delivery.Result = "smtp-accepted"
		snapshot.Delivery.LastSuccessUTC = result.FinishedAtUTC
	case result.Outcome == "succeeded":
		snapshot.Delivery.Result = "completed-no-accepted-deliveries"
	case result.Outcome == "partial":
		snapshot.Delivery.Result = "partial-smtp-accepted"
		if result.SMTPAcceptedCount > 0 {
			snapshot.Delivery.LastSuccessUTC = result.FinishedAtUTC
		}
	default:
		snapshot.Delivery.Result = "failed"
	}
}

func dataReadiness(dataDir string) string {
	if strings.TrimSpace(dataDir) == "" {
		return "not-applicable"
	}
	info, err := os.Stat(dataDir)
	if err == nil && info.IsDir() {
		return "ready"
	}
	if os.IsNotExist(err) {
		return "not-created"
	}
	return "unreadable"
}

func probeWindowsTask(ctx context.Context, taskName, root string) (windowsTaskProbe, error) {
	var result windowsTaskProbe
	script := `$ErrorActionPreference='Stop'
$name=$env:TAUTWEEKLY_MANAGER_TASK_NAME
$root=$env:TAUTWEEKLY_MANAGER_ROOT
$task=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
if ($null -eq $task) {
  [pscustomobject]@{installed=$false;enabled=$false;owned=$false;ownership='not-installed';state='NotInstalled';nextRunUtc='';nextRunLocal='';lastRunUtc='';lastTaskResult=$null} | ConvertTo-Json -Compress
  exit 0
}
$info=$task | Get-ScheduledTaskInfo
$engine=Join-Path $root 'TautWeekly.ps1'
$result=Join-Path $root 'last-run.json'
$expectedArgs='-NoProfile -ExecutionPolicy Bypass -File "{0}" -Mode SendAll -ResultPath "{1}" -ConfirmSendAll' -f $engine,$result
$actions=@($task.Actions)
$owned=$false
if ($actions.Count -eq 1) {
  $action=$actions[0]
  try {
    $working=[IO.Path]::GetFullPath([string]$action.WorkingDirectory).TrimEnd('\')
    $expectedRoot=[IO.Path]::GetFullPath($root).TrimEnd('\')
    $owned=([IO.Path]::GetFileName([string]$action.Execute) -ieq 'powershell.exe') -and ([string]$action.Arguments -ieq $expectedArgs) -and ($working -ieq $expectedRoot) -and ([string]$task.Principal.UserId -ieq 'SYSTEM')
  } catch { $owned=$false }
}
$nextLocal=if ($info.NextRunTime -gt [datetime]'2000-01-01') {$info.NextRunTime.ToString('o')} else {''}
$nextUtc=if ($info.NextRunTime -gt [datetime]'2000-01-01') {$info.NextRunTime.ToUniversalTime().ToString('o')} else {''}
$lastUtc=if ($info.LastRunTime -gt [datetime]'2000-01-01') {$info.LastRunTime.ToUniversalTime().ToString('o')} else {''}
[pscustomobject]@{
  installed=$true
  enabled=([string]$task.State -ne 'Disabled')
  owned=$owned
  ownership=$(if ($owned) {'verified'} else {'foreign-or-modified'})
  state=[string]$task.State
  nextRunUtc=$nextUtc
  nextRunLocal=$nextLocal
  lastRunUtc=$lastUtc
  lastTaskResult=[int64]$info.LastTaskResult
} | ConvertTo-Json -Compress`

	command := exec.CommandContext(ctx, "powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script)
	command.Env = append(operationEnvironment(os.Environ()), "TAUTWEEKLY_MANAGER_TASK_NAME="+taskName, "TAUTWEEKLY_MANAGER_ROOT="+root)
	output, err := command.Output()
	if err != nil {
		return result, fmt.Errorf("query Windows Task Scheduler")
	}
	if err := json.Unmarshal(output, &result); err != nil {
		return result, fmt.Errorf("decode Windows Task Scheduler status")
	}
	return result, nil
}

func readPackageVersion(root string) string {
	raw, err := os.ReadFile(filepath.Join(root, "VERSION.txt"))
	if err != nil {
		return ""
	}
	line := strings.TrimSpace(strings.SplitN(string(raw), "\n", 2)[0])
	return line
}
