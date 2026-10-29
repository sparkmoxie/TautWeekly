//go:build !windows

package main

import (
	"os"
	"syscall"
)

func logFileHasMultipleLinks(file *os.File) (bool, error) {
	info, err := file.Stat()
	if err != nil {
		return false, err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	return ok && stat.Nlink > 1, nil
}
