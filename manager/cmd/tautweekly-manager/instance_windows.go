//go:build windows

package main

import (
	"errors"
	"fmt"
	"sync"
	"syscall"
	"unsafe"
)

const (
	managerEventModifyState = 0x0002
	managerWaitObject0      = 0x00000000
	managerInfinite         = 0xffffffff
)

var (
	instanceKernel32        = syscall.NewLazyDLL("kernel32.dll")
	instanceCreateMutex     = instanceKernel32.NewProc("CreateMutexW")
	instanceCreateEvent     = instanceKernel32.NewProc("CreateEventW")
	instanceOpenEvent       = instanceKernel32.NewProc("OpenEventW")
	instanceSetEvent        = instanceKernel32.NewProc("SetEvent")
	instanceWaitSingle      = instanceKernel32.NewProc("WaitForSingleObject")
	instanceCloseHandle     = instanceKernel32.NewProc("CloseHandle")
	managerInstanceNameBase = "Local\\TautWeeklyManager-"
)

type windowsManagerInstance struct {
	mutex     uintptr
	event     uintptr
	shutdown  chan struct{}
	closeOnce sync.Once
}

func acquireManagerInstance(address, root string) (managerInstance, bool, error) {
	id := managerInstanceID(address, root)
	mutexName, err := syscall.UTF16PtrFromString(managerInstanceNameBase + id)
	if err != nil {
		return nil, false, err
	}
	mutex, _, callErr := instanceCreateMutex.Call(0, 0, uintptr(unsafe.Pointer(mutexName)))
	if mutex == 0 {
		return nil, false, fmt.Errorf("create Manager instance mutex: %w", callErr)
	}
	if errors.Is(callErr, syscall.ERROR_ALREADY_EXISTS) {
		instanceCloseHandle.Call(mutex)
		return nil, false, nil
	}
	eventName, err := syscall.UTF16PtrFromString(managerInstanceNameBase + id + "-Shutdown")
	if err != nil {
		instanceCloseHandle.Call(mutex)
		return nil, false, err
	}
	event, _, eventErr := instanceCreateEvent.Call(0, 1, 0, uintptr(unsafe.Pointer(eventName)))
	if event == 0 {
		instanceCloseHandle.Call(mutex)
		return nil, false, fmt.Errorf("create Manager shutdown event: %w", eventErr)
	}
	instance := &windowsManagerInstance{mutex: mutex, event: event, shutdown: make(chan struct{})}
	go func() {
		result, _, _ := instanceWaitSingle.Call(event, managerInfinite)
		if result == managerWaitObject0 {
			close(instance.shutdown)
		}
	}()
	return instance, true, nil
}

func signalManagerShutdown(address, root string) error {
	name, err := syscall.UTF16PtrFromString(managerInstanceNameBase + managerInstanceID(address, root) + "-Shutdown")
	if err != nil {
		return err
	}
	event, _, callErr := instanceOpenEvent.Call(managerEventModifyState, 0, uintptr(unsafe.Pointer(name)))
	if event == 0 {
		if errors.Is(callErr, syscall.ERROR_FILE_NOT_FOUND) {
			return errors.New("the installed Manager is not running")
		}
		return fmt.Errorf("open Manager shutdown event: %w", callErr)
	}
	defer instanceCloseHandle.Call(event)
	result, _, setErr := instanceSetEvent.Call(event)
	if result == 0 {
		return fmt.Errorf("signal Manager shutdown: %w", setErr)
	}
	return nil
}

func (i *windowsManagerInstance) ShutdownRequested() <-chan struct{} { return i.shutdown }

func (i *windowsManagerInstance) Close() error {
	i.closeOnce.Do(func() {
		instanceSetEvent.Call(i.event)
		instanceCloseHandle.Call(i.event)
		instanceCloseHandle.Call(i.mutex)
	})
	return nil
}
