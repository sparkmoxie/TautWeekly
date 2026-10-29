//go:build windows

package main

import (
	"os"
	"syscall"
)

func logFileHasMultipleLinks(file *os.File) (bool, error) {
	var info syscall.ByHandleFileInformation
	if err := syscall.GetFileInformationByHandle(syscall.Handle(file.Fd()), &info); err != nil {
		return false, err
	}
	return info.NumberOfLinks > 1, nil
}
