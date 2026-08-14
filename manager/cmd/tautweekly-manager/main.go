package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/sparkmoxie/TautWeekly/manager/internal/manager"
)

var version = "local"

func main() {
	if err := run(os.Args[1:]); err != nil {
		log.Printf("ERROR: %v", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	command := "serve"
	if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		command = args[0]
		args = args[1:]
	}

	switch command {
	case "serve":
		return serve(args)
	case "access-reset":
		return resetAccess(args)
	case "status":
		return printStatus(args)
	case "version":
		fmt.Printf("TautWeekly Manager %s\n", version)
		return nil
	default:
		return fmt.Errorf("unknown command %q; use serve, access-reset, status, or version", command)
	}
}

func serve(args []string) error {
	root, err := defaultTautWeeklyRoot()
	if err != nil {
		return err
	}

	flags := flag.NewFlagSet("serve", flag.ContinueOnError)
	listen := flags.String("listen", "127.0.0.1:8788", "loopback address for the local manager")
	rootDir := flags.String("tautweekly-root", root, "TautWeekly Windows package directory")
	dataDir := flags.String("data-dir", filepath.Join(root, ".manager-data"), "private manager state directory")
	openBrowserOnStart := flags.Bool("open-browser", false, "open the local Manager after the listener is ready")
	requireAuthentication := flags.Bool("require-auth", false, "require password authentication and pairing for this runtime mode")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if err := requireLoopback(*listen); err != nil {
		return err
	}
	listener, err := net.Listen("tcp", *listen)
	if err != nil {
		return fmt.Errorf("listen on local Manager address: %w", err)
	}

	server, err := manager.New(manager.Options{
		ListenAddress:         *listen,
		DataDir:               *dataDir,
		TautWeeklyRoot:        *rootDir,
		Version:               version,
		RequireAuthentication: *requireAuthentication,
	})
	if err != nil {
		_ = listener.Close()
		return err
	}

	token := server.BootstrapToken()
	startURL := localManagerURL(*listen, token)
	if token != "" {
		log.Printf("First-run pairing URL: %s", startURL)
		log.Printf("The pairing token is local, one-time, and invalidated after setup.")
	}
	log.Printf("TautWeekly Manager %s listening on http://%s", version, *listen)
	if *openBrowserOnStart {
		if err := openLocalBrowser(startURL); err != nil {
			log.Printf("WARNING: the local browser could not be opened automatically: %v", err)
		}
	}

	httpServer := &http.Server{
		Addr:              *listen,
		Handler:           server.Handler(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
	err = httpServer.Serve(listener)
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}

func resetAccess(args []string) error {
	root, err := defaultTautWeeklyRoot()
	if err != nil {
		return err
	}
	flags := flag.NewFlagSet("access-reset", flag.ContinueOnError)
	dataDir := flags.String("data-dir", filepath.Join(root, ".manager-data"), "private manager state directory")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if err := manager.ResetLocalAccess(*dataDir); err != nil {
		return err
	}
	fmt.Println("The optional local Manager password lock is disabled. TautWeekly configuration and runtime data were not changed.")
	return nil
}

func localManagerURL(address, token string) string {
	target := url.URL{Scheme: "http", Host: address, Path: "/"}
	if token != "" {
		target.Fragment = "pair=" + token
	}
	return target.String()
}

func printStatus(args []string) error {
	root, err := defaultTautWeeklyRoot()
	if err != nil {
		return err
	}

	flags := flag.NewFlagSet("status", flag.ContinueOnError)
	rootDir := flags.String("tautweekly-root", root, "TautWeekly Windows package directory")
	if err := flags.Parse(args); err != nil {
		return err
	}

	snapshot := manager.CollectStatus(context.Background(), manager.Options{
		TautWeeklyRoot: *rootDir,
		Version:        version,
	})
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	return encoder.Encode(snapshot)
}

func requireLoopback(address string) error {
	host, _, err := net.SplitHostPort(address)
	if err != nil {
		return fmt.Errorf("invalid listen address: %w", err)
	}
	if strings.EqualFold(host, "localhost") {
		return nil
	}
	ip := net.ParseIP(host)
	if ip == nil || !ip.IsLoopback() {
		return fmt.Errorf("TautWeekly Manager is loopback-only; refusing %q", address)
	}
	return nil
}

func defaultTautWeeklyRoot() (string, error) {
	current, err := os.Getwd()
	if err != nil {
		return "", err
	}
	candidate := filepath.Join(current, "platforms", "windows")
	if _, err := os.Stat(filepath.Join(candidate, "TautWeekly.ps1")); err == nil {
		return candidate, nil
	}
	return current, nil
}
