package main

import (
	"bytes"
	"errors"
	"log"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"testing"
)

func assertLogDiskBound(t *testing.T, root string, maximum int64, count int) {
	t.Helper()
	entries, err := os.ReadDir(root)
	if err != nil {
		t.Fatal(err)
	}
	var total int64
	if len(entries) > count {
		t.Fatalf("got %d files, bound is %d", len(entries), count)
	}
	for _, entry := range entries {
		info, err := entry.Info()
		if err != nil {
			t.Fatal(err)
		}
		if !info.Mode().IsRegular() || info.Size() > maximum {
			t.Fatalf("file exceeded regular/size contract: %s %d", entry.Name(), info.Size())
		}
		total += info.Size()
	}
	if total > maximum*int64(count) {
		t.Fatalf("retained bytes %d exceeded %d", total, maximum*int64(count))
	}
}

func TestRotatingManagerLogBoundsContinuousSessionAndRecentBytes(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "manager.log")
	writer, err := newRotatingLogWriter(path, 64, 3)
	if err != nil {
		t.Fatal(err)
	}
	defer writer.Close()
	var input []byte
	for index := 0; index < 100; index++ {
		line := []byte(strconv.Itoa(index) + " fixture log record\n")
		input = append(input, line...)
		if count, err := writer.Write(line); err != nil || count != len(line) {
			t.Fatalf("write: %d %v", count, err)
		}
		assertLogDiskBound(t, root, 64, 4)
	}
	var retained []byte
	for index := 3; index >= 0; index-- {
		name := path
		if index > 0 {
			name += "." + strconv.Itoa(index)
		}
		data, err := os.ReadFile(name)
		if err != nil {
			t.Fatal(err)
		}
		retained = append(retained, data...)
	}
	if !bytes.HasSuffix(input, retained) {
		t.Fatal("rotation lost or reordered the recent log tail")
	}
	if len(retained) < 192 {
		t.Fatal("rotation discarded recent backups prematurely")
	}
	t.Logf("100 writes in one session: retained %d bytes across 4 files, each <=64 bytes", len(retained))
}

func TestRotatingManagerLogBoundsLegacyFilesAndHugeWrites(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "manager.log")
	legacy := bytes.Repeat([]byte("old log record\n"), 100)
	for _, suffix := range []string{"", ".1", ".2", ".3", ".99"} {
		if err := os.WriteFile(path+suffix, legacy, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	writer, err := newRotatingLogWriter(path, 64, 3)
	if err != nil {
		t.Fatal(err)
	}
	defer writer.Close()
	assertLogDiskBound(t, root, 64, 4)
	for _, suffix := range []string{"", ".1", ".2", ".3"} {
		data, err := os.ReadFile(path + suffix)
		if err != nil || !bytes.Equal(data, legacy[len(legacy)-64:]) {
			t.Fatalf("legacy tail changed: %s %v", suffix, err)
		}
	}
	huge := bytes.Repeat([]byte("huge-line"), 100)
	if count, err := writer.Write(huge); err != nil || count != len(huge) {
		t.Fatalf("huge write: %d %v", count, err)
	}
	assertLogDiskBound(t, root, 64, 4)
}

func TestRotatingManagerLogConcurrentWritesAndReplacedPath(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "manager.log")
	writer, err := newRotatingLogWriter(path, 64, 3)
	if err != nil {
		t.Fatal(err)
	}
	var workers sync.WaitGroup
	for index := 0; index < 20; index++ {
		workers.Go(func() {
			if _, err := writer.Write([]byte("fixture concurrent record\n")); err != nil {
				t.Error(err)
			}
		})
	}
	workers.Wait()
	assertLogDiskBound(t, root, 64, 4)
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := writer.Write([]byte("closed")); !errors.Is(err, os.ErrClosed) {
		t.Fatalf("closed writer: %v", err)
	}
	if runtime.GOOS == "windows" {
		return
	} // Windows does not permit renaming an open file.
	writer, err = newRotatingLogWriter(path, 64, 3)
	if err != nil {
		t.Fatal(err)
	}
	defer writer.Close()
	if err := os.Rename(path, path+".external"); err != nil {
		t.Fatal(err)
	}
	before, err := os.ReadFile(path + ".external")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := writer.Write([]byte("new inode\n")); err != nil {
		t.Fatal(err)
	}
	after, err := os.ReadFile(path + ".external")
	if err != nil || !bytes.Equal(before, after) {
		t.Fatal("writer kept appending to an externally renamed inode")
	}
}

func TestRotatingManagerLogRefusesLinksAndPreservesUnrelatedFiles(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "manager.log")
	private := filepath.Join(root, "private-config.json")
	want := []byte("unrelated fixture data")
	if err := os.WriteFile(private, want, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Link(private, path); err != nil {
		t.Fatal(err)
	}
	if _, err := newRotatingLogWriter(path, 64, 3); err == nil {
		t.Fatal("hard-linked log accepted")
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(path, 0o700); err != nil {
		t.Fatal(err)
	}
	if _, err := newRotatingLogWriter(path, 64, 3); err == nil {
		t.Fatal("directory accepted as a log")
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(private, path); err == nil {
		if _, err := newRotatingLogWriter(path, 64, 3); err == nil {
			t.Fatal("symlink accepted as a log")
		}
		if err := os.Remove(path); err != nil {
			t.Fatal(err)
		}
	} else {
		t.Log("symlink creation unavailable; hard-link/directory refusal remains covered")
	}
	writer, err := newRotatingLogWriter(path, 64, 3)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := writer.Write(bytes.Repeat([]byte("new log"), 100)); err != nil {
		t.Fatal(err)
	}
	_ = writer.Close()
	got, err := os.ReadFile(private)
	if err != nil || !bytes.Equal(got, want) {
		t.Fatal("unrelated file changed")
	}
}

func TestRotatingManagerLogRetainsStartupFailureAndRestoresConsole(t *testing.T) {
	root := t.TempDir()
	blockedData := filepath.Join(root, "not-a-state-directory")
	if err := os.WriteFile(blockedData, []byte("fixture"), 0o600); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, "manager.log")
	previous := log.Writer()
	err := serve([]string{"--runtime-mode", "linux", "--listen", "127.0.0.1:0", "--tautweekly-root", root, "--runtime-root", root, "--data-dir", blockedData, "--log-file", path})
	if err == nil {
		t.Fatal("fixture startup failure unexpectedly succeeded")
	}
	if log.Writer() != previous {
		t.Fatal("serve failure did not restore the existing console logger")
	}
	data, readErr := os.ReadFile(path)
	if readErr != nil || !strings.Contains(string(data), "ERROR:") {
		t.Fatalf("startup failure missing from bounded file: %v", readErr)
	}
	if len(data) > int(managerLogMaximumBytes) {
		t.Fatal("startup error exceeded the Manager log cap")
	}
}
