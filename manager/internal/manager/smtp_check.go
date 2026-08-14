package manager

import (
	"bufio"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"net"
	"strconv"
	"strings"
	"time"
)

var (
	errSMTPHost          = errors.New("SMTP host or port is invalid")
	errSMTPUnsafeAddress = errors.New("SMTP address is unsafe")
	errSMTPConnection    = errors.New("SMTP connection failed or timed out")
	errSMTPProtocol      = errors.New("SMTP protocol negotiation failed")
	errSMTPTLS           = errors.New("SMTP STARTTLS negotiation failed")
)

type SMTPNetworkCheckRequest struct {
	ExpectedRevision   string `json:"expectedRevision"`
	ConfirmRealNetwork bool   `json:"confirmRealNetwork"`
}

type SMTPNetworkCheckResult struct {
	Mode           string `json:"mode"`
	Overall        string `json:"overall"`
	State          string `json:"state"`
	Security       string `json:"security"`
	CompletedAtUTC string `json:"completedAtUtc"`
	ConfigRevision string `json:"configRevision"`
	Summary        string `json:"summary"`
}

type smtpProbeConfig struct {
	Host       string
	Port       int
	EnableTLS  bool
	Timeout    time.Duration
	ClientName string
}

type smtpProbeDependencies struct {
	lookupIP    func(context.Context, string, string) ([]net.IP, error)
	dialContext func(context.Context, string, string) (net.Conn, error)
	tlsConfig   func(string) *tls.Config
}

func defaultSMTPProbeDependencies(timeout time.Duration) smtpProbeDependencies {
	dialer := &net.Dialer{Timeout: timeout, KeepAlive: 15 * time.Second}
	return smtpProbeDependencies{
		lookupIP:    net.DefaultResolver.LookupIP,
		dialContext: dialer.DialContext,
		tlsConfig: func(host string) *tls.Config {
			return &tls.Config{ServerName: host, MinVersion: tls.VersionTLS12}
		},
	}
}

// RunSMTPNetworkCheck performs a deliberately non-sending SMTP preflight. It
// stops after greeting, EHLO, and (when configured) certificate-validated
// STARTTLS. It never sends AUTH, MAIL FROM, RCPT TO, or DATA.
func RunSMTPNetworkCheck(ctx context.Context, root string, request SMTPNetworkCheckRequest, now func() time.Time) (SMTPNetworkCheckResult, error) {
	if !request.ConfirmRealNetwork {
		return SMTPNetworkCheckResult{}, ErrRealCheckConfirmation
	}
	values, raw, exists, state := readConfigDocument(root)
	if state != "ready" || !exists || len(existingConfigIssues(values)) > 0 {
		return SMTPNetworkCheckResult{}, ErrRealCheckNotReady
	}
	revision := configRevision(raw, true)
	if request.ExpectedRevision == "" || request.ExpectedRevision != revision {
		return SMTPNetworkCheckResult{}, ErrConfigConflict
	}
	if now == nil {
		now = time.Now
	}
	timeoutSeconds := configMapInt(values, "SmtpTimeoutSeconds", 30)
	if timeoutSeconds < 5 {
		timeoutSeconds = 5
	}
	if timeoutSeconds > 45 {
		timeoutSeconds = 45
	}
	probeConfig := smtpProbeConfig{
		Host:       configMapString(values, "SmtpHost"),
		Port:       configMapInt(values, "SmtpPort", 587),
		EnableTLS:  configMapBool(values, "SmtpEnableSsl", true),
		Timeout:    time.Duration(timeoutSeconds) * time.Second,
		ClientName: "tautweekly.local",
	}
	result := SMTPNetworkCheckResult{
		Mode:           "smtp-network",
		Overall:        "passed",
		State:          "passed",
		Security:       "starttls-validated",
		CompletedAtUTC: now().UTC().Format(time.RFC3339),
		ConfigRevision: revision,
	}
	checkContext, cancel := context.WithTimeout(ctx, probeConfig.Timeout)
	defer cancel()
	if err := probeSMTPNetwork(checkContext, probeConfig, defaultSMTPProbeDependencies(probeConfig.Timeout)); err != nil {
		result.Overall = "failed"
		result.State = "failed"
		result.Security = "not-established"
		result.Summary = smtpFailureSummary(err)
		return result, nil
	}
	if probeConfig.EnableTLS {
		result.Summary = "TCP, SMTP greeting, EHLO, and certificate-validated STARTTLS succeeded. Authentication, sender permission, and message delivery were not tested."
		return result, nil
	}
	result.Overall = "warning"
	result.State = "warning"
	result.Security = "plaintext-configured"
	result.Summary = "TCP, SMTP greeting, and EHLO succeeded with STARTTLS disabled in the saved configuration. Authentication, sender permission, and message delivery were not tested."
	return result, nil
}

func probeSMTPNetwork(ctx context.Context, config smtpProbeConfig, dependencies smtpProbeDependencies) error {
	host := strings.TrimSpace(config.Host)
	if !validSMTPHost(host) || config.Port < 1 || config.Port > 65535 || config.Port == 465 {
		return errSMTPHost
	}
	if parsed := net.ParseIP(strings.Trim(host, "[]")); parsed != nil {
		host = parsed.String()
	}
	addresses, err := resolveSMTPAddresses(ctx, host, dependencies.lookupIP)
	if err != nil {
		return err
	}
	connection, err := dialSMTPAddresses(ctx, addresses, config.Port, dependencies.dialContext)
	if err != nil {
		return err
	}
	defer func() { _ = connection.Close() }()
	deadline := time.Now().Add(config.Timeout)
	if contextDeadline, ok := ctx.Deadline(); ok && contextDeadline.Before(deadline) {
		deadline = contextDeadline
	}
	if err := connection.SetDeadline(deadline); err != nil {
		return errSMTPConnection
	}
	reader := bufio.NewReaderSize(connection, 4096)
	writer := bufio.NewWriterSize(connection, 4096)
	if _, err := readSMTPResponse(reader, 220); err != nil {
		return errSMTPProtocol
	}
	capabilities, err := smtpEHLO(reader, writer, config.ClientName)
	if err != nil {
		return errSMTPProtocol
	}
	if config.EnableTLS {
		if !smtpAdvertisesSTARTTLS(capabilities) {
			return errSMTPTLS
		}
		if err := writeSMTPCommand(writer, "STARTTLS"); err != nil {
			return errSMTPConnection
		}
		if _, err := readSMTPResponse(reader, 220); err != nil {
			return errSMTPTLS
		}
		tlsConnection := tls.Client(connection, dependencies.tlsConfig(host))
		if err := tlsConnection.HandshakeContext(ctx); err != nil {
			return errSMTPTLS
		}
		connection = tlsConnection
		reader = bufio.NewReaderSize(connection, 4096)
		writer = bufio.NewWriterSize(connection, 4096)
		if _, err := smtpEHLO(reader, writer, config.ClientName); err != nil {
			return errSMTPProtocol
		}
	}
	_ = writeSMTPCommand(writer, "QUIT")
	return nil
}

func resolveSMTPAddresses(ctx context.Context, host string, lookup func(context.Context, string, string) ([]net.IP, error)) ([]net.IP, error) {
	if parsed := net.ParseIP(strings.Trim(host, "[]")); parsed != nil {
		if !allowedSMTPIP(parsed) {
			return nil, errSMTPUnsafeAddress
		}
		return []net.IP{parsed}, nil
	}
	addresses, err := lookup(ctx, "ip", host)
	if err != nil || len(addresses) == 0 {
		return nil, errSMTPConnection
	}
	for _, address := range addresses {
		if !allowedSMTPIP(address) {
			return nil, errSMTPUnsafeAddress
		}
	}
	return addresses, nil
}

func dialSMTPAddresses(ctx context.Context, addresses []net.IP, port int, dial func(context.Context, string, string) (net.Conn, error)) (net.Conn, error) {
	for _, address := range addresses {
		connection, err := dial(ctx, "tcp", net.JoinHostPort(address.String(), strconv.Itoa(port)))
		if err == nil {
			return connection, nil
		}
	}
	return nil, errSMTPConnection
}

func validSMTPHost(host string) bool {
	if host == "" || len(host) > 253 || strings.ContainsAny(host, "/\\@?# \t\r\n") {
		return false
	}
	if net.ParseIP(strings.Trim(host, "[]")) != nil {
		return true
	}
	host = strings.TrimSuffix(host, ".")
	for _, label := range strings.Split(host, ".") {
		if label == "" || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
			return false
		}
		for _, character := range label {
			if character != '-' && (character < '0' || character > '9') && (character < 'A' || character > 'Z') && (character < 'a' || character > 'z') {
				return false
			}
		}
	}
	return true
}

func allowedSMTPIP(ip net.IP) bool {
	return ip.IsLoopback() || ip.IsGlobalUnicast() && !ip.IsLinkLocalUnicast()
}

func smtpEHLO(reader *bufio.Reader, writer *bufio.Writer, clientName string) ([]string, error) {
	if clientName == "" {
		clientName = "tautweekly.local"
	}
	if err := writeSMTPCommand(writer, "EHLO "+clientName); err != nil {
		return nil, errSMTPConnection
	}
	return readSMTPResponse(reader, 250)
}

func writeSMTPCommand(writer *bufio.Writer, command string) error {
	if _, err := writer.WriteString(command + "\r\n"); err != nil {
		return err
	}
	return writer.Flush()
}

func readSMTPResponse(reader *bufio.Reader, expected int) ([]string, error) {
	lines := make([]string, 0, 8)
	for index := 0; index < 100; index++ {
		line, err := reader.ReadString('\n')
		if err != nil || len(line) > 2048 {
			return nil, errSMTPProtocol
		}
		line = strings.TrimRight(line, "\r\n")
		if len(line) < 4 || line[0] < '0' || line[0] > '9' || line[1] < '0' || line[1] > '9' || line[2] < '0' || line[2] > '9' || line[3] != ' ' && line[3] != '-' {
			return nil, errSMTPProtocol
		}
		code, _ := strconv.Atoi(line[:3])
		if code != expected {
			return nil, errSMTPProtocol
		}
		lines = append(lines, line)
		if line[3] == ' ' {
			return lines, nil
		}
	}
	return nil, errSMTPProtocol
}

func smtpAdvertisesSTARTTLS(lines []string) bool {
	for _, line := range lines {
		fields := []string{}
		if len(line) >= 4 {
			fields = strings.Fields(line[4:])
		}
		if len(fields) > 0 && strings.EqualFold(fields[0], "STARTTLS") {
			return true
		}
	}
	return false
}

func smtpFailureSummary(err error) string {
	switch {
	case errors.Is(err, errSMTPHost):
		return "The saved SMTP host or port is invalid. Enter a hostname only, such as smtp.gmail.com, and a STARTTLS port such as 587. No credentials were sent."
	case errors.Is(err, errSMTPUnsafeAddress):
		return "The saved SMTP hostname resolved to an unsafe or non-unicast address. Review local DNS or filtering before retrying. No credentials were sent."
	case errors.Is(err, errSMTPTLS):
		return "The SMTP endpoint did not advertise or complete certificate-validated STARTTLS. No credentials or message content were sent."
	case errors.Is(err, errSMTPProtocol):
		return "The endpoint answered, but did not complete the expected SMTP greeting and EHLO exchange. No credentials or message content were sent."
	default:
		return "The saved SMTP endpoint could not be reached before the preflight timeout. No credentials or message content were sent."
	}
}

func configMapInt(values map[string]any, name string, fallback int) int {
	switch value := values[name].(type) {
	case json.Number:
		parsed, err := strconv.Atoi(value.String())
		if err == nil {
			return parsed
		}
	case float64:
		return int(value)
	case int:
		return value
	case int64:
		return int(value)
	}
	return fallback
}

func configMapBool(values map[string]any, name string, fallback bool) bool {
	value, ok := values[name].(bool)
	if !ok {
		return fallback
	}
	return value
}
