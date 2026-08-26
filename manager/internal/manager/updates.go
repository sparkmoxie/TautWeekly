package manager

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"mime"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	updateStatusSchemaVersion = 2
	updateCacheSchemaVersion  = 1
	maximumUpdateCacheBytes   = 16 << 10
	maximumReleaseBytes       = 256 << 10
	currentHostAdapterAPI     = "3"
	stableReleaseEndpoint     = "https://api.github.com/repos/sparkmoxie/TautWeekly/releases/latest"
	stableReleaseBaseURL      = "https://github.com/sparkmoxie/TautWeekly/releases/tag/v"
	stableReleaseDownloadURL  = "https://github.com/sparkmoxie/TautWeekly/releases/download/v"
	updateTimestampLayout     = "2006-01-02T15:04:05.000Z07:00"
	updateCheckMinimumDelay   = 5 * time.Minute
	updateFailureMinimumDelay = 30 * time.Second
	updateFailureMaximumDelay = 10 * time.Minute
	updateBackgroundMaxAge    = 24 * time.Hour
)

const (
	packageKindWindows          = "windows-installer"
	packageKindLinux            = "linux-native"
	packageKindMac              = "mac-docker"
	packageKindMacRegistry      = "mac-docker-registry"
	packageKindFreeBSD          = "freebsd-podman"
	packageKindNAS              = "nas-docker"
	packageKindQNAP             = "qnap-container-station"
	packageKindUnraid           = "unraid"
	packageKindCompatibleDocker = "docker-compatible"
)

var updateFailureMessages = map[string]string{
	"offline":                "The stable release service could not be reached. The Manager and newsletter continue to work offline.",
	"timeout":                "The stable release check timed out. The Manager and newsletter continue to work normally.",
	"upstream-status":        "The stable release service returned an unexpected response.",
	"upstream-rate-limited":  "The stable release service temporarily limited update checks.",
	"invalid-metadata":       "The stable release metadata did not pass TautWeekly's validation rules.",
	"unsupported-channel":    "This package is configured with an unsupported update channel.",
	"check-failed":           "The stable release check could not be completed safely.",
	"install-start-failed":   "The verified Windows updater could not be started.",
	"install-process-failed": "The verified Windows updater stopped before completing. No success is assumed.",
	"cache-write-failed":     "The update result was checked, but its sanitized local cache could not be saved.",
}

type UpdateFailure struct {
	Action        string `json:"action"`
	OccurredAtUTC string `json:"occurredAtUtc"`
	Code          string `json:"code"`
	Message       string `json:"message"`
}

type UpdateGuidance struct {
	Owner   string   `json:"owner"`
	Summary string   `json:"summary"`
	Command string   `json:"command,omitempty"`
	Steps   []string `json:"steps"`
	DocsURL string   `json:"docsUrl"`
}

type UpdateStatus struct {
	SchemaVersion              int            `json:"schemaVersion"`
	ObservedAtUTC              string         `json:"observedAtUtc"`
	State                      string         `json:"state"`
	ManagerVersion             string         `json:"managerVersion,omitempty"`
	ApplicationVersion         string         `json:"applicationVersion,omitempty"`
	PackageVersion             string         `json:"packageVersion,omitempty"`
	ImageVersion               string         `json:"imageVersion,omitempty"`
	PackageKind                string         `json:"packageKind"`
	PackageLabel               string         `json:"packageLabel"`
	HostAdapterVersion         string         `json:"hostAdapterVersion,omitempty"`
	HostAdapterState           string         `json:"hostAdapterState"`
	UpdateChannel              string         `json:"updateChannel"`
	LatestStableVersion        string         `json:"latestStableVersion,omitempty"`
	UpdateAvailable            bool           `json:"updateAvailable"`
	InstallSupported           bool           `json:"installSupported"`
	InstallState               string         `json:"installState"`
	CheckInProgress            bool           `json:"checkInProgress"`
	BackgroundCheckRecommended bool           `json:"backgroundCheckRecommended"`
	LastSuccessfulCheckUTC     string         `json:"lastSuccessfulCheckUtc,omitempty"`
	LastFailure                *UpdateFailure `json:"lastFailure,omitempty"`
	ReleaseNotesURL            string         `json:"releaseNotesUrl,omitempty"`
	NextCheckAllowedAtUTC      string         `json:"nextCheckAllowedAtUtc,omitempty"`
	Guidance                   UpdateGuidance `json:"guidance"`
}

type updateCache struct {
	SchemaVersion          int            `json:"schemaVersion"`
	LatestStableVersion    string         `json:"latestStableVersion,omitempty"`
	ReleaseNotesURL        string         `json:"releaseNotesUrl,omitempty"`
	LastSuccessfulCheckUTC string         `json:"lastSuccessfulCheckUtc,omitempty"`
	LastFailure            *UpdateFailure `json:"lastFailure,omitempty"`
	FailureCount           int            `json:"failureCount,omitempty"`
	NextCheckAllowedAtUTC  string         `json:"nextCheckAllowedAtUtc,omitempty"`
}

type updateRelease struct {
	Version         string
	ReleaseNotesURL string
}

type updateReleaseChecker interface {
	Check(context.Context, string, string) (updateRelease, error)
}

type updateInstallController interface {
	Supported() bool
	Start() (<-chan error, error)
}

type disabledUpdateInstaller struct{}

func (disabledUpdateInstaller) Supported() bool { return false }
func (disabledUpdateInstaller) Start() (<-chan error, error) {
	return nil, errors.New("update install is unsupported")
}

type updateCheckError struct{ code string }

func (e updateCheckError) Error() string { return e.code }

type updateCoordinator struct {
	mu                  sync.Mutex
	options             Options
	checker             updateReleaseChecker
	installer           updateInstallController
	cachePath           string
	cache               updateCache
	checking            bool
	installState        string
	nextCheckAllowed    time.Time
	minimumCheckDelay   time.Duration
	minimumFailureDelay time.Duration
	maximumFailureDelay time.Duration
}

func newUpdateCoordinator(options Options) *updateCoordinator {
	checker := options.updateChecker
	if checker == nil {
		checker = newGitHubReleaseChecker()
	}
	installer := options.updateInstaller
	if installer == nil {
		installer = newPlatformUpdateInstaller(options.TautWeeklyRoot)
	}
	minimumDelay := options.updateMinimumCheckDelay
	if minimumDelay <= 0 {
		minimumDelay = updateCheckMinimumDelay
	}
	minimumFailureDelay := options.updateMinimumFailureDelay
	if minimumFailureDelay <= 0 {
		minimumFailureDelay = updateFailureMinimumDelay
	}
	maximumDelay := options.updateMaximumFailureDelay
	if maximumDelay <= 0 {
		maximumDelay = updateFailureMaximumDelay
	}
	coordinator := &updateCoordinator{
		options:             options,
		checker:             checker,
		installer:           installer,
		cachePath:           filepath.Join(options.DataDir, "update-status.json"),
		installState:        "idle",
		minimumCheckDelay:   minimumDelay,
		minimumFailureDelay: minimumFailureDelay,
		maximumFailureDelay: maximumDelay,
	}
	coordinator.cache = coordinator.readCache()
	if coordinator.cache.NextCheckAllowedAtUTC != "" {
		coordinator.nextCheckAllowed, _ = time.Parse(time.RFC3339, coordinator.cache.NextCheckAllowedAtUTC)
	}
	return coordinator
}

func (c *updateCoordinator) Status() UpdateStatus {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.statusLocked(c.now())
}

func (c *updateCoordinator) CheckNow(ctx context.Context) (UpdateStatus, error) {
	now := c.now()
	c.mu.Lock()
	if c.checking {
		status := c.statusLocked(now)
		c.mu.Unlock()
		return status, updateCheckError{code: "check-in-progress"}
	}
	if now.Before(c.nextCheckAllowed) {
		status := c.statusLocked(now)
		c.mu.Unlock()
		return status, updateCheckError{code: "check-backoff"}
	}
	c.checking = true
	packageKind := normalizedPackageKind(c.options.PackageKind, c.options.RuntimeMode)
	channel := normalizedUpdateChannel(c.options.UpdateChannel)
	c.mu.Unlock()

	checkContext, cancel := context.WithTimeout(ctx, 8*time.Second)
	release, checkErr := c.checker.Check(checkContext, channel, expectedReleaseAsset(packageKind))
	cancel()
	if checkErr == nil && !validCheckedRelease(release) {
		checkErr = updateCheckError{code: "invalid-metadata"}
	}
	completedAt := c.now().UTC()

	c.mu.Lock()
	defer c.mu.Unlock()
	c.checking = false
	if checkErr != nil {
		code := updateCheckErrorCode(checkErr)
		c.cache.FailureCount++
		c.cache.LastFailure = newUpdateFailure("check", completedAt, code)
		c.nextCheckAllowed = completedAt.Add(c.failureDelayLocked())
	} else {
		c.cache.SchemaVersion = updateCacheSchemaVersion
		c.cache.LatestStableVersion = release.Version
		c.cache.ReleaseNotesURL = release.ReleaseNotesURL
		c.cache.LastSuccessfulCheckUTC = completedAt.Format(time.RFC3339)
		c.cache.FailureCount = 0
		c.nextCheckAllowed = completedAt.Add(c.minimumCheckDelay)
	}
	c.cache.NextCheckAllowedAtUTC = c.nextCheckAllowed.UTC().Format(updateTimestampLayout)
	if err := writePrivateJSON(c.cachePath, c.cache); err != nil {
		c.cache.LastFailure = newUpdateFailure("check", completedAt, "cache-write-failed")
	}
	return c.statusLocked(completedAt), nil
}

func (c *updateCoordinator) Install() (UpdateStatus, error) {
	now := c.now()
	c.mu.Lock()
	status := c.statusLocked(now)
	if !status.InstallSupported {
		c.mu.Unlock()
		return status, updateCheckError{code: "install-unsupported"}
	}
	if c.installState == "starting" || c.installState == "running" {
		c.mu.Unlock()
		return status, updateCheckError{code: "install-in-progress"}
	}
	if status.State != "update-available" || !status.UpdateAvailable || status.LastSuccessfulCheckUTC == "" {
		c.mu.Unlock()
		return status, updateCheckError{code: "install-not-ready"}
	}
	checkedAt, err := time.Parse(time.RFC3339, status.LastSuccessfulCheckUTC)
	if err != nil || now.Sub(checkedAt) > time.Hour || now.Before(checkedAt.Add(-time.Minute)) {
		c.mu.Unlock()
		return status, updateCheckError{code: "install-check-stale"}
	}
	c.installState = "starting"
	c.mu.Unlock()

	result, startErr := c.installer.Start()
	c.mu.Lock()
	if startErr != nil {
		c.installState = "failed"
		c.cache.LastFailure = newUpdateFailure("install", c.now().UTC(), "install-start-failed")
		_ = writePrivateJSON(c.cachePath, c.cache)
		status = c.statusLocked(c.now())
		c.mu.Unlock()
		return status, updateCheckError{code: "install-start-failed"}
	}
	c.installState = "running"
	status = c.statusLocked(c.now())
	c.mu.Unlock()

	go c.waitForInstaller(result)
	return status, nil
}

func (c *updateCoordinator) waitForInstaller(result <-chan error) {
	err, ok := <-result
	c.mu.Lock()
	defer c.mu.Unlock()
	if !ok || err == nil {
		c.installState = "completed"
		return
	}
	c.installState = "failed"
	c.cache.LastFailure = newUpdateFailure("install", c.now().UTC(), "install-process-failed")
	_ = writePrivateJSON(c.cachePath, c.cache)
}

func (c *updateCoordinator) statusLocked(now time.Time) UpdateStatus {
	packageKind := normalizedPackageKind(c.options.PackageKind, c.options.RuntimeMode)
	applicationVersion := normalizedLocalVersion(c.options.Version)
	packageVersion := normalizedLocalVersion(c.options.PackageVersion)
	if packageVersion == "" {
		packageVersion = normalizedLocalVersion(readRepositoryVersion(c.options.TautWeeklyRoot))
	}
	channel := normalizedUpdateChannel(c.options.UpdateChannel)
	hostAdapter := normalizedHostAdapterVersion(c.options.HostAdapterVersion)
	hostAdapterState := "not-applicable"
	if requiresHostAdapter(packageKind) {
		hostAdapterState = "current"
		if hostAdapter != currentHostAdapterAPI {
			hostAdapterState = "legacy"
		}
	}
	status := UpdateStatus{
		SchemaVersion:              updateStatusSchemaVersion,
		ObservedAtUTC:              now.UTC().Format(time.RFC3339),
		State:                      "unknown",
		ManagerVersion:             applicationVersion,
		ApplicationVersion:         applicationVersion,
		PackageVersion:             packageVersion,
		PackageKind:                packageKind,
		PackageLabel:               packageLabel(packageKind),
		HostAdapterVersion:         hostAdapter,
		HostAdapterState:           hostAdapterState,
		UpdateChannel:              channel,
		LatestStableVersion:        c.cache.LatestStableVersion,
		InstallSupported:           packageKind == packageKindWindows && c.installer.Supported(),
		InstallState:               c.installState,
		CheckInProgress:            c.checking,
		BackgroundCheckRecommended: c.backgroundCheckRecommendedLocked(now, channel),
		LastSuccessfulCheckUTC:     c.cache.LastSuccessfulCheckUTC,
		LastFailure:                cloneUpdateFailure(c.cache.LastFailure),
		ReleaseNotesURL:            c.cache.ReleaseNotesURL,
		Guidance:                   updateGuidance(packageKind),
	}
	if isContainerPackage(packageKind) {
		status.ImageVersion = applicationVersion
	}
	if now.Before(c.nextCheckAllowed) {
		status.NextCheckAllowedAtUTC = c.nextCheckAllowed.UTC().Format(updateTimestampLayout)
	}
	status.State, status.UpdateAvailable = classifyUpdateStatus(status)
	if status.State != "update-available" {
		status.InstallSupported = false
	}
	return status
}

func (c *updateCoordinator) backgroundCheckRecommendedLocked(now time.Time, channel string) bool {
	if c.checking || channel != "stable" || now.Before(c.nextCheckAllowed) {
		return false
	}
	if c.cache.LastSuccessfulCheckUTC == "" {
		return true
	}
	checkedAt, err := time.Parse(time.RFC3339, c.cache.LastSuccessfulCheckUTC)
	if err != nil || checkedAt.After(now.Add(time.Minute)) {
		return true
	}
	return !now.Before(checkedAt.Add(updateBackgroundMaxAge))
}

func classifyUpdateStatus(status UpdateStatus) (string, bool) {
	if status.UpdateChannel != "stable" || status.LastSuccessfulCheckUTC == "" {
		return "unknown", false
	}
	application, ok := parseSemanticVersion(status.ApplicationVersion)
	if !ok {
		return "unknown", false
	}
	latest, ok := parseSemanticVersion(status.LatestStableVersion)
	if !ok || latest.prerelease != "" {
		return "unknown", false
	}
	if status.HostAdapterState == "legacy" {
		return "legacy", compareSemanticVersions(application, latest) < 0
	}
	if status.PackageVersion != "" {
		packaged, valid := parseSemanticVersion(status.PackageVersion)
		if !valid {
			return "unknown", false
		}
		if compareSemanticVersions(packaged, application) != 0 {
			available := compareSemanticVersions(application, latest) < 0 || compareSemanticVersions(packaged, latest) < 0
			return "mismatched", available
		}
	}
	comparison := compareSemanticVersions(application, latest)
	if comparison < 0 {
		return "update-available", true
	}
	if comparison > 0 {
		return "newer", false
	}
	return "current", false
}

func (c *updateCoordinator) failureDelayLocked() time.Duration {
	delay := c.minimumFailureDelay
	for attempt := 1; attempt < c.cache.FailureCount && delay < c.maximumFailureDelay; attempt++ {
		delay *= 2
	}
	if delay > c.maximumFailureDelay {
		return c.maximumFailureDelay
	}
	return delay
}

func (c *updateCoordinator) now() time.Time {
	if c.options.Now == nil {
		return time.Now()
	}
	return c.options.Now()
}

func (c *updateCoordinator) readCache() updateCache {
	file, err := os.Open(c.cachePath)
	if err != nil {
		return updateCache{SchemaVersion: updateCacheSchemaVersion}
	}
	defer file.Close()
	raw, err := io.ReadAll(io.LimitReader(file, maximumUpdateCacheBytes+1))
	if err != nil || len(raw) > maximumUpdateCacheBytes {
		return updateCache{SchemaVersion: updateCacheSchemaVersion}
	}
	var cached updateCache
	if json.Unmarshal(raw, &cached) != nil || !validUpdateCache(cached) {
		return updateCache{SchemaVersion: updateCacheSchemaVersion}
	}
	return cached
}

func validUpdateCache(cached updateCache) bool {
	if cached.SchemaVersion != updateCacheSchemaVersion || cached.FailureCount < 0 || cached.FailureCount > 32 {
		return false
	}
	if cached.LatestStableVersion == "" {
		if cached.ReleaseNotesURL != "" || cached.LastSuccessfulCheckUTC != "" {
			return false
		}
	} else {
		version, ok := parseSemanticVersion(cached.LatestStableVersion)
		if !ok || version.prerelease != "" || cached.ReleaseNotesURL != stableReleaseBaseURL+cached.LatestStableVersion || cached.LastSuccessfulCheckUTC == "" {
			return false
		}
	}
	if cached.LastSuccessfulCheckUTC != "" {
		if _, err := time.Parse(time.RFC3339, cached.LastSuccessfulCheckUTC); err != nil {
			return false
		}
	}
	if cached.NextCheckAllowedAtUTC != "" {
		if _, err := time.Parse(time.RFC3339, cached.NextCheckAllowedAtUTC); err != nil {
			return false
		}
	}
	return validUpdateFailure(cached.LastFailure)
}

func validUpdateFailure(failure *UpdateFailure) bool {
	if failure == nil {
		return true
	}
	if failure.Action != "check" && failure.Action != "install" {
		return false
	}
	message, ok := updateFailureMessages[failure.Code]
	if !ok || failure.Message != message {
		return false
	}
	_, err := time.Parse(time.RFC3339, failure.OccurredAtUTC)
	return err == nil
}

func newUpdateFailure(action string, now time.Time, code string) *UpdateFailure {
	message, ok := updateFailureMessages[code]
	if !ok {
		code = "check-failed"
		message = updateFailureMessages[code]
	}
	return &UpdateFailure{Action: action, OccurredAtUTC: now.UTC().Format(time.RFC3339), Code: code, Message: message}
}

func cloneUpdateFailure(failure *UpdateFailure) *UpdateFailure {
	if failure == nil {
		return nil
	}
	copy := *failure
	return &copy
}

func updateCheckErrorCode(err error) string {
	var typed updateCheckError
	if errors.As(err, &typed) {
		if _, ok := updateFailureMessages[typed.code]; ok {
			return typed.code
		}
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return "timeout"
	}
	return "offline"
}

type githubReleaseChecker struct{ client *http.Client }

func newGitHubReleaseChecker() githubReleaseChecker {
	return githubReleaseChecker{client: &http.Client{
		Timeout: 8 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return errors.New("release metadata redirected")
		},
	}}
}

func (c githubReleaseChecker) Check(ctx context.Context, channel, expectedAsset string) (updateRelease, error) {
	if channel != "stable" {
		return updateRelease{}, updateCheckError{code: "unsupported-channel"}
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, stableReleaseEndpoint, nil)
	if err != nil {
		return updateRelease{}, updateCheckError{code: "check-failed"}
	}
	request.Header.Set("Accept", "application/vnd.github+json")
	request.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	request.Header.Set("User-Agent", "TautWeekly-Manager-update-check")
	response, err := c.client.Do(request)
	if err != nil {
		if errors.Is(err, context.DeadlineExceeded) || errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return updateRelease{}, updateCheckError{code: "timeout"}
		}
		return updateRelease{}, updateCheckError{code: "offline"}
	}
	defer response.Body.Close()
	if response.StatusCode == http.StatusForbidden || response.StatusCode == http.StatusTooManyRequests {
		return updateRelease{}, updateCheckError{code: "upstream-rate-limited"}
	}
	if response.StatusCode != http.StatusOK {
		return updateRelease{}, updateCheckError{code: "upstream-status"}
	}
	mediaType, _, err := mime.ParseMediaType(response.Header.Get("Content-Type"))
	if err != nil || (mediaType != "application/json" && mediaType != "application/vnd.github+json") {
		return updateRelease{}, updateCheckError{code: "invalid-metadata"}
	}
	raw, err := io.ReadAll(io.LimitReader(response.Body, maximumReleaseBytes+1))
	if err != nil {
		return updateRelease{}, updateCheckError{code: "offline"}
	}
	if len(raw) > maximumReleaseBytes {
		return updateRelease{}, updateCheckError{code: "invalid-metadata"}
	}
	return parseStableReleaseMetadata(raw, expectedAsset)
}

func parseStableReleaseMetadata(raw []byte, expectedAsset string) (updateRelease, error) {
	var payload struct {
		TagName    string `json:"tag_name"`
		HTMLURL    string `json:"html_url"`
		Draft      bool   `json:"draft"`
		Prerelease bool   `json:"prerelease"`
		Assets     []struct {
			Name               string `json:"name"`
			BrowserDownloadURL string `json:"browser_download_url"`
		} `json:"assets"`
	}
	decoder := json.NewDecoder(strings.NewReader(string(raw)))
	if err := decoder.Decode(&payload); err != nil {
		return updateRelease{}, updateCheckError{code: "invalid-metadata"}
	}
	if decoder.Decode(&struct{}{}) != io.EOF || payload.Draft || payload.Prerelease {
		return updateRelease{}, updateCheckError{code: "invalid-metadata"}
	}
	version := strings.TrimPrefix(strings.TrimSpace(payload.TagName), "v")
	parsed, ok := parseSemanticVersion(version)
	if !ok || parsed.prerelease != "" || strings.Contains(version, "+") || payload.TagName != "v"+version {
		return updateRelease{}, updateCheckError{code: "invalid-metadata"}
	}
	releaseURL := stableReleaseBaseURL + version
	if payload.HTMLURL != releaseURL || !validHTTPSURL(payload.HTMLURL, "github.com") {
		return updateRelease{}, updateCheckError{code: "invalid-metadata"}
	}
	required := map[string]int{"SHA256SUMS.txt": 0}
	if expectedAsset != "" {
		required[expectedAsset] = 0
	}
	for _, asset := range payload.Assets {
		if _, wanted := required[asset.Name]; !wanted {
			continue
		}
		expectedURL := stableReleaseDownloadURL + version + "/" + asset.Name
		if asset.BrowserDownloadURL != expectedURL || !validHTTPSURL(asset.BrowserDownloadURL, "github.com") {
			return updateRelease{}, updateCheckError{code: "invalid-metadata"}
		}
		required[asset.Name]++
	}
	for _, count := range required {
		if count != 1 {
			return updateRelease{}, updateCheckError{code: "invalid-metadata"}
		}
	}
	return updateRelease{Version: version, ReleaseNotesURL: releaseURL}, nil
}

func validHTTPSURL(value, expectedHost string) bool {
	parsed, err := url.Parse(value)
	return err == nil && parsed.Scheme == "https" && parsed.Host == expectedHost && parsed.User == nil && parsed.RawQuery == "" && parsed.Fragment == ""
}

func validCheckedRelease(release updateRelease) bool {
	version, ok := parseSemanticVersion(release.Version)
	return ok && version.prerelease == "" && !strings.Contains(release.Version, "+") && release.ReleaseNotesURL == stableReleaseBaseURL+release.Version
}

type semanticVersion struct {
	major      int
	minor      int
	patch      int
	prerelease string
}

func parseSemanticVersion(value string) (semanticVersion, bool) {
	value = strings.TrimSpace(strings.TrimPrefix(value, "v"))
	if plus := strings.IndexByte(value, '+'); plus >= 0 {
		if plus == len(value)-1 || !validSemanticIdentifiers(value[plus+1:]) {
			return semanticVersion{}, false
		}
		value = value[:plus]
	}
	prerelease := ""
	if dash := strings.IndexByte(value, '-'); dash >= 0 {
		prerelease = value[dash+1:]
		value = value[:dash]
		if !validSemanticIdentifiers(prerelease) {
			return semanticVersion{}, false
		}
		for _, identifier := range strings.Split(prerelease, ".") {
			if len(identifier) > 1 && identifier[0] == '0' {
				if _, numeric := numericSemanticIdentifier(identifier[1:]); numeric {
					return semanticVersion{}, false
				}
			}
		}
	}
	parts := strings.Split(value, ".")
	if len(parts) != 3 {
		return semanticVersion{}, false
	}
	numbers := [3]int{}
	for index, part := range parts {
		if part == "" || (len(part) > 1 && part[0] == '0') {
			return semanticVersion{}, false
		}
		number, err := strconv.Atoi(part)
		if err != nil || number < 0 || number > 1_000_000 {
			return semanticVersion{}, false
		}
		numbers[index] = number
	}
	return semanticVersion{major: numbers[0], minor: numbers[1], patch: numbers[2], prerelease: prerelease}, true
}

func validSemanticIdentifiers(value string) bool {
	if value == "" {
		return false
	}
	for _, identifier := range strings.Split(value, ".") {
		if identifier == "" {
			return false
		}
		for _, character := range identifier {
			if (character < 'a' || character > 'z') && (character < 'A' || character > 'Z') && (character < '0' || character > '9') && character != '-' {
				return false
			}
		}
	}
	return true
}

func compareSemanticVersions(left, right semanticVersion) int {
	for _, values := range [][2]int{{left.major, right.major}, {left.minor, right.minor}, {left.patch, right.patch}} {
		if values[0] < values[1] {
			return -1
		}
		if values[0] > values[1] {
			return 1
		}
	}
	if left.prerelease == right.prerelease {
		return 0
	}
	if left.prerelease == "" {
		return 1
	}
	if right.prerelease == "" {
		return -1
	}
	leftParts := strings.Split(left.prerelease, ".")
	rightParts := strings.Split(right.prerelease, ".")
	for index := 0; index < len(leftParts) && index < len(rightParts); index++ {
		leftNumber, leftNumeric := numericSemanticIdentifier(leftParts[index])
		rightNumber, rightNumeric := numericSemanticIdentifier(rightParts[index])
		switch {
		case leftNumeric && rightNumeric && leftNumber != rightNumber:
			if leftNumber < rightNumber {
				return -1
			}
			return 1
		case leftNumeric != rightNumeric:
			if leftNumeric {
				return -1
			}
			return 1
		case leftParts[index] < rightParts[index]:
			return -1
		case leftParts[index] > rightParts[index]:
			return 1
		}
	}
	if len(leftParts) < len(rightParts) {
		return -1
	}
	if len(leftParts) > len(rightParts) {
		return 1
	}
	return 0
}

func numericSemanticIdentifier(value string) (int, bool) {
	if value == "" || (len(value) > 1 && value[0] == '0') {
		return 0, false
	}
	for _, character := range value {
		if character < '0' || character > '9' {
			return 0, false
		}
	}
	number, err := strconv.Atoi(value)
	return number, err == nil
}

func normalizedLocalVersion(value string) string {
	value = strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(value), "v"))
	if _, ok := parseSemanticVersion(value); !ok {
		return ""
	}
	return value
}

func normalizedUpdateChannel(value string) string {
	value = strings.ToLower(strings.TrimSpace(value))
	if value == "" {
		return "stable"
	}
	if value == "stable" {
		return value
	}
	return "unsupported"
}

func normalizedHostAdapterVersion(value string) string {
	value = strings.TrimSpace(value)
	if value == "" || len(value) > 8 {
		return ""
	}
	for _, character := range value {
		if character < '0' || character > '9' {
			return ""
		}
	}
	return value
}

func normalizedPackageKind(value, mode string) string {
	value = strings.ToLower(strings.TrimSpace(value))
	switch normalizedRuntimeMode(mode) {
	case runtimeModeLinux:
		return packageKindLinux
	case runtimeModeMac:
		if value == packageKindMacRegistry {
			return value
		}
		return packageKindMac
	case runtimeModeNAS:
		switch value {
		case packageKindFreeBSD, packageKindNAS, packageKindQNAP, packageKindUnraid, packageKindCompatibleDocker:
			return value
		}
		return packageKindCompatibleDocker
	default:
		return packageKindWindows
	}
}

func isContainerPackage(kind string) bool {
	switch kind {
	case packageKindMac, packageKindMacRegistry, packageKindFreeBSD, packageKindNAS, packageKindQNAP, packageKindUnraid, packageKindCompatibleDocker:
		return true
	default:
		return false
	}
}

func requiresHostAdapter(kind string) bool {
	switch kind {
	case packageKindMac, packageKindMacRegistry, packageKindFreeBSD, packageKindNAS, packageKindQNAP, packageKindUnraid:
		return true
	default:
		return false
	}
}

func expectedReleaseAsset(kind string) string {
	switch kind {
	case packageKindWindows:
		return "TautWeekly-windows.zip"
	case packageKindLinux:
		return "TautWeekly-linux.tar.gz"
	case packageKindMac:
		return "TautWeekly-mac-docker.tar.gz"
	case packageKindMacRegistry:
		return "TautWeekly-mac-compose.yaml"
	case packageKindFreeBSD:
		return "TautWeekly-freebsd-podman.tar.gz"
	case packageKindNAS, packageKindQNAP:
		return "TautWeekly-nas-docker.tar.gz"
	default:
		return ""
	}
}

func packageLabel(kind string) string {
	switch kind {
	case packageKindWindows:
		return "Windows installer package"
	case packageKindLinux:
		return "Native Linux package"
	case packageKindMac:
		return "macOS Docker Desktop package"
	case packageKindMacRegistry:
		return "macOS registry Compose deployment"
	case packageKindFreeBSD:
		return "FreeBSD Podman package"
	case packageKindNAS:
		return "Docker Compose host package"
	case packageKindQNAP:
		return "QNAP Container Station package"
	case packageKindUnraid:
		return "Unraid Community Apps template"
	default:
		return "Compatible Docker deployment"
	}
}

func updateGuidance(kind string) UpdateGuidance {
	const docsBase = "https://sparkmoxie.github.io/TautWeekly/"
	switch kind {
	case packageKindWindows:
		return UpdateGuidance{Owner: "TautWeekly Windows updater", Summary: "The Manager can start the existing checksum- and manifest-verified Windows updater. Windows requests administrator approval before package files or Task Scheduler state can change.", Steps: []string{"Back up private data.", "Review the stable release notes.", "Choose Install update and approve the Windows prompt."}, DocsURL: docsBase + "windows/#updates"}
	case packageKindLinux:
		return UpdateGuidance{Owner: "Linux host administrator", Summary: "The web process does not elevate or change systemd files. Run the verified package updater from the host.", Command: "sudo tautweekly update", Steps: []string{"Back up /var/lib/tautweekly.", "Run the host command.", "Return here to verify the new application and package versions."}, DocsURL: docsBase + "linux/#updates"}
	case packageKindMac:
		return UpdateGuidance{Owner: "Mac administrator and Docker Desktop", Summary: "Docker Desktop and the extracted Mac package own updates; the containerized web process cannot change the host.", Command: "./tautweekly.sh update", Steps: []string{"Back up the package data directory.", "Run the command in the extracted package directory.", "Return here after Docker Desktop recreates the service."}, DocsURL: docsBase + "mac/#updates"}
	case packageKindMacRegistry:
		return UpdateGuidance{Owner: "Mac administrator and Docker Desktop", Summary: "The standalone Compose file pins the registry image. The containerized web process cannot pull images or change the host deployment.", Command: "docker compose pull tautweekly && docker compose up -d --force-recreate tautweekly", Steps: []string{"Back up the persistent /data volume or mount.", "Replace the image reference with the reviewed full-semver tag or digest.", "Pull and recreate the service, then return here to verify the running image and schedule."}, DocsURL: docsBase + "mac/#registry-updates"}
	case packageKindFreeBSD:
		return UpdateGuidance{Owner: "FreeBSD host administrator", Summary: "The root-owned rc.d/Podman wrapper owns package and image updates. The Manager never invokes sudo or Podman.", Command: "sudo tautweekly update", Steps: []string{"Back up /var/db/tautweekly.", "Run the host command.", "Return through the SSH tunnel or TLS proxy to verify the result."}, DocsURL: docsBase + "freebsd/#updates"}
	case packageKindQNAP:
		return UpdateGuidance{Owner: "QNAP Container Station administrator", Summary: "Use Container Station to observe the application and run the verified release-package update from the trusted NAS host; the container cannot mutate QNAP.", Command: "./tautweekly.sh update", Steps: []string{"Back up the persistent data share.", "Run the command over trusted SSH from the extracted NAS package directory.", "Confirm the recreated application is healthy in Container Station, then return here."}, DocsURL: docsBase + "nas-docker/#updates"}
	case packageKindUnraid:
		return UpdateGuidance{Owner: "Unraid Docker / Apps", Summary: "Unraid owns image and saved-template updates. No container-side or Manager-side install is available.", Steps: []string{"Open Unraid Docker and choose Check for Updates.", "Apply the TautWeekly update through Docker or Apps.", "Edit the app and compare the current Community Apps template when the host adapter is legacy."}, DocsURL: docsBase + "nas-docker/#updates"}
	case packageKindNAS:
		return UpdateGuidance{Owner: "Docker Compose host administrator", Summary: "The release wrapper verifies and advances the host package and image together. The container cannot invoke Docker or change host files.", Command: "./tautweekly.sh update", Steps: []string{"Back up the persistent data directory or volume.", "Run the command in the extracted NAS package directory.", "Return here after Compose recreates the service."}, DocsURL: docsBase + "nas-docker/#updates"}
	default:
		return UpdateGuidance{Owner: "Container host administrator", Summary: "Use the deployment tool that created this container. Preserve /data and recreate the service with the stable image; the Manager has no host control plane.", Command: "docker compose pull tautweekly && docker compose up -d --no-build --force-recreate tautweekly", Steps: []string{"Back up the persistent /data mount.", "Pull and recreate through the original host deployment tool.", "Do not add a Docker socket, privileged helper, or root web process."}, DocsURL: docsBase + "nas-docker/#updates"}
	}
}

func readRepositoryVersion(root string) string {
	raw, err := os.ReadFile(filepath.Join(root, "RELEASE-METADATA.txt"))
	if err != nil || len(raw) > 16<<10 {
		return ""
	}
	for _, line := range strings.Split(strings.ReplaceAll(string(raw), "\r\n", "\n"), "\n") {
		if strings.HasPrefix(line, "Repository version:") {
			return strings.TrimSpace(strings.TrimPrefix(line, "Repository version:"))
		}
	}
	return ""
}

func updateHTTPError(code string) (int, string, string) {
	switch code {
	case "check-in-progress":
		return http.StatusConflict, code, "An update check is already running."
	case "check-backoff":
		return http.StatusTooManyRequests, code, "Update checks are temporarily limited after the previous attempt."
	case "install-unsupported":
		return http.StatusConflict, code, "This package keeps update installation under the host platform."
	case "install-in-progress":
		return http.StatusConflict, code, "The verified Windows updater is already running."
	case "install-not-ready":
		return http.StatusConflict, code, "Check for a stable update before starting installation."
	case "install-check-stale":
		return http.StatusConflict, code, "The successful update check is too old. Check again before installing."
	case "install-start-failed":
		return http.StatusInternalServerError, code, updateFailureMessages[code]
	default:
		return http.StatusInternalServerError, "update-action-failed", "The update action could not be completed safely."
	}
}

func (s *Server) handleUpdateStatus(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, s.updates.Status())
}

func (s *Server) handleUpdateCheck(w http.ResponseWriter, r *http.Request) {
	status, err := s.updates.CheckNow(r.Context())
	if err != nil {
		var typed updateCheckError
		if errors.As(err, &typed) {
			httpStatus, code, message := updateHTTPError(typed.code)
			writeAPIError(w, httpStatus, code, message)
			return
		}
		writeAPIError(w, http.StatusInternalServerError, "update-check-failed", "The update check could not be completed safely.")
		return
	}
	writeJSON(w, http.StatusOK, status)
}

func (s *Server) handleUpdateInstall(w http.ResponseWriter, _ *http.Request) {
	status, err := s.updates.Install()
	if err != nil {
		var typed updateCheckError
		if errors.As(err, &typed) {
			httpStatus, code, message := updateHTTPError(typed.code)
			writeAPIError(w, httpStatus, code, message)
			return
		}
		writeAPIError(w, http.StatusInternalServerError, "update-install-failed", "The verified Windows updater could not be started.")
		return
	}
	writeJSON(w, http.StatusAccepted, status)
}
