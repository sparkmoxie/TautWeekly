package main

import (
	"crypto/sha256"
	"encoding/hex"
	"path/filepath"
	"strings"
)

type managerInstance interface {
	ShutdownRequested() <-chan struct{}
	Close() error
}

func managerInstanceID(address, root string) string {
	canonicalRoot, err := filepath.Abs(root)
	if err != nil {
		canonicalRoot = filepath.Clean(root)
	}
	canonicalRoot = strings.ToLower(filepath.Clean(canonicalRoot))
	digest := sha256.Sum256([]byte(strings.ToLower(strings.TrimSpace(address)) + "\x00" + canonicalRoot))
	return hex.EncodeToString(digest[:12])
}
