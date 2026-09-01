package main

import (
	"context"
	"errors"
	"os"
	"syscall"
	"testing"
	"time"
)

func TestShutdownSignalRetriesUntilFunnelIsVerifiedInactive(t *testing.T) {
	signals := make(chan os.Signal, 2)
	reported := make(chan error, 1)
	requested := make(chan struct{}, 1)
	attempts := 0
	verificationFailure := errors.New("synthetic verification failure")

	go waitForVerifiedShutdownSignal(
		signals,
		func(context.Context) error {
			attempts++
			if attempts == 1 {
				return verificationFailure
			}
			return nil
		},
		func() { requested <- struct{}{} },
		func(err error) { reported <- err },
	)

	signals <- syscall.SIGTERM
	select {
	case err := <-reported:
		if !errors.Is(err, verificationFailure) {
			t.Fatalf("reported error = %v, want the sanitized verification failure", err)
		}
	case <-requested:
		t.Fatal("the first signal shut down despite failed Funnel verification")
	case <-time.After(2 * time.Second):
		t.Fatal("the first shutdown signal was not handled")
	}
	if attempts != 1 {
		t.Fatalf("verification attempts after first signal = %d, want 1", attempts)
	}

	signals <- syscall.SIGTERM
	select {
	case <-requested:
	case <-time.After(2 * time.Second):
		t.Fatal("the verified retry did not request shutdown")
	}
	if attempts != 2 {
		t.Fatalf("verification attempts after retry = %d, want 2", attempts)
	}
}
