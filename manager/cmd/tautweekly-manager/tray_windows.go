//go:build windows

package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"runtime"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"
)

const (
	trayCallbackMessage = 0x8001
	trayUpdateMessage   = 0x8002
	trayCloseMessage    = 0x8003
	trayIconID          = 1
	trayStatusMenuID    = 1001
	trayExitMenuID      = 1002

	trayNIMAdd        = 0x00000000
	trayNIMModify     = 0x00000001
	trayNIMDelete     = 0x00000002
	trayNIMSetVersion = 0x00000004
	trayNIFMessage    = 0x00000001
	trayNIFIcon       = 0x00000002
	trayNIFTip        = 0x00000004
	trayNotifyVersion = 4

	trayWMDestroy       = 0x0002
	trayWMNull          = 0x0000
	trayWMLButtonUp     = 0x0202
	trayWMRButtonUp     = 0x0205
	trayWMContextMenu   = 0x007b
	trayNINSelect       = 0x0400
	trayNINKeySelect    = 0x0401
	trayMFString        = 0x0000
	trayMFGray          = 0x0001
	trayMFDisabled      = 0x0002
	trayMFSeparator     = 0x0800
	trayMIIMBitmap      = 0x0080
	trayTPMRightButton  = 0x0002
	trayTPMNonotify     = 0x0080
	trayTPMReturnCmd    = 0x0100
	trayImageIcon       = 1
	trayLRLoadFromFile  = 0x0010
	trayLRDefaultSize   = 0x0040
	trayColorMenu       = 4
	trayPS_Solid        = 0
	traySMCXMenuCheck   = 71
	traySMCYMenuCheck   = 72
	trayDefaultIconSize = 16
)

var (
	trayUser32                 = syscall.NewLazyDLL("user32.dll")
	trayShell32                = syscall.NewLazyDLL("shell32.dll")
	trayKernel32               = syscall.NewLazyDLL("kernel32.dll")
	trayGDI32                  = syscall.NewLazyDLL("gdi32.dll")
	trayRegisterClassEx        = trayUser32.NewProc("RegisterClassExW")
	trayUnregisterClass        = trayUser32.NewProc("UnregisterClassW")
	trayCreateWindowEx         = trayUser32.NewProc("CreateWindowExW")
	trayDestroyWindow          = trayUser32.NewProc("DestroyWindow")
	trayDefaultWindowProc      = trayUser32.NewProc("DefWindowProcW")
	trayGetMessage             = trayUser32.NewProc("GetMessageW")
	trayTranslateMessage       = trayUser32.NewProc("TranslateMessage")
	trayDispatchMessage        = trayUser32.NewProc("DispatchMessageW")
	trayPostMessage            = trayUser32.NewProc("PostMessageW")
	trayPostQuitMessage        = trayUser32.NewProc("PostQuitMessage")
	trayRegisterWindowMessage  = trayUser32.NewProc("RegisterWindowMessageW")
	trayLoadImage              = trayUser32.NewProc("LoadImageW")
	trayDestroyIcon            = trayUser32.NewProc("DestroyIcon")
	trayCreatePopupMenu        = trayUser32.NewProc("CreatePopupMenu")
	trayAppendMenu             = trayUser32.NewProc("AppendMenuW")
	traySetMenuItemInfo        = trayUser32.NewProc("SetMenuItemInfoW")
	trayTrackPopupMenu         = trayUser32.NewProc("TrackPopupMenu")
	trayDestroyMenu            = trayUser32.NewProc("DestroyMenu")
	trayGetCursorPos           = trayUser32.NewProc("GetCursorPos")
	traySetForegroundWindow    = trayUser32.NewProc("SetForegroundWindow")
	trayGetDC                  = trayUser32.NewProc("GetDC")
	trayReleaseDC              = trayUser32.NewProc("ReleaseDC")
	trayFillRect               = trayUser32.NewProc("FillRect")
	trayGetSysColorBrush       = trayUser32.NewProc("GetSysColorBrush")
	trayGetSystemMetrics       = trayUser32.NewProc("GetSystemMetrics")
	trayShellNotifyIcon        = trayShell32.NewProc("Shell_NotifyIconW")
	trayExtractIconEx          = trayShell32.NewProc("ExtractIconExW")
	trayGetModuleHandle        = trayKernel32.NewProc("GetModuleHandleW")
	trayCreateCompatibleDC     = trayGDI32.NewProc("CreateCompatibleDC")
	trayDeleteDC               = trayGDI32.NewProc("DeleteDC")
	trayCreateCompatibleBitmap = trayGDI32.NewProc("CreateCompatibleBitmap")
	traySelectObject           = trayGDI32.NewProc("SelectObject")
	trayCreateSolidBrush       = trayGDI32.NewProc("CreateSolidBrush")
	trayCreatePen              = trayGDI32.NewProc("CreatePen")
	trayEllipse                = trayGDI32.NewProc("Ellipse")
	trayDeleteObject           = trayGDI32.NewProc("DeleteObject")
	trayWindowCallback         = syscall.NewCallback(managerTrayWindowProc)
	trayWindowRegistry         sync.Map
)

type trayPoint struct {
	X int32
	Y int32
}

type trayMessage struct {
	Window  uintptr
	Message uint32
	WParam  uintptr
	LParam  uintptr
	Time    uint32
	Point   trayPoint
	Private uint32
}

type trayWindowClass struct {
	Size        uint32
	Style       uint32
	WindowProc  uintptr
	ClassExtra  int32
	WindowExtra int32
	Instance    uintptr
	Icon        uintptr
	Cursor      uintptr
	Background  uintptr
	MenuName    *uint16
	ClassName   *uint16
	SmallIcon   uintptr
}

type trayNotifyIconData struct {
	Size            uint32
	Window          uintptr
	ID              uint32
	Flags           uint32
	CallbackMessage uint32
	Icon            uintptr
	Tip             [128]uint16
	State           uint32
	StateMask       uint32
	Info            [256]uint16
	Version         uint32
	InfoTitle       [64]uint16
	InfoFlags       uint32
	GUID            [16]byte
	BalloonIcon     uintptr
}

type trayMenuItemInfo struct {
	Size            uint32
	Mask            uint32
	Type            uint32
	State           uint32
	ID              uint32
	SubMenu         uintptr
	CheckedBitmap   uintptr
	UncheckedBitmap uintptr
	ItemData        uintptr
	TypeData        *uint16
	TextLength      uint32
	ItemBitmap      uintptr
}

type trayRect struct {
	Left   int32
	Top    int32
	Right  int32
	Bottom int32
}

type windowsManagerTray struct {
	options        trayOptions
	instance       uintptr
	window         atomic.Uintptr
	icon           uintptr
	className      *uint16
	taskbarMessage uint32
	health         atomic.Uint32
	lastOpen       atomic.Int64
	stop           chan struct{}
	done           chan struct{}
	closeOnce      sync.Once
	exitOnce       sync.Once
}

func startManagerTray(options trayOptions) (managerTray, error) {
	tray := &windowsManagerTray{options: options, stop: make(chan struct{}), done: make(chan struct{})}
	tray.health.Store(uint32(trayNeedsAttentionIndex))
	ready := make(chan error, 1)
	go tray.run(ready)
	if err := <-ready; err != nil {
		return nil, err
	}
	go tray.refreshStatus()
	return tray, nil
}

const (
	trayHealthyIndex = iota
	trayNeedsAttentionIndex
	trayFailedIndex
)

func (t *windowsManagerTray) run(ready chan<- error) {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	defer close(t.done)

	instance, _, instanceErr := trayGetModuleHandle.Call(0)
	if instance == 0 {
		ready <- fmt.Errorf("load Manager module for notification icon: %w", instanceErr)
		return
	}
	t.instance = instance
	className, err := syscall.UTF16PtrFromString(fmt.Sprintf("TautWeeklyManagerTray-%d", os.Getpid()))
	if err != nil {
		ready <- err
		return
	}
	t.className = className
	windowClass := trayWindowClass{WindowProc: trayWindowCallback, Instance: instance, ClassName: className}
	windowClass.Size = uint32(unsafe.Sizeof(windowClass))
	registered, _, registerErr := trayRegisterClassEx.Call(uintptr(unsafe.Pointer(&windowClass)))
	if registered == 0 {
		ready <- fmt.Errorf("register notification-area window: %w", registerErr)
		return
	}
	defer trayUnregisterClass.Call(uintptr(unsafe.Pointer(className)), instance)

	taskbarName, _ := syscall.UTF16PtrFromString("TaskbarCreated")
	taskbarMessage, _, _ := trayRegisterWindowMessage.Call(uintptr(unsafe.Pointer(taskbarName)))
	t.taskbarMessage = uint32(taskbarMessage)
	title, _ := syscall.UTF16PtrFromString("TautWeekly for Plex")
	window, _, windowErr := trayCreateWindowEx.Call(0, uintptr(unsafe.Pointer(className)), uintptr(unsafe.Pointer(title)), 0, 0, 0, 0, 0, 0, 0, instance, 0)
	if window == 0 {
		ready <- fmt.Errorf("create notification-area window: %w", windowErr)
		return
	}
	t.window.Store(window)
	trayWindowRegistry.Store(window, t)
	defer trayWindowRegistry.Delete(window)

	icon, err := loadManagerTrayIcon(t.options.IconPath)
	if err != nil {
		trayDestroyWindow.Call(window)
		ready <- err
		return
	}
	t.icon = icon
	defer trayDestroyIcon.Call(icon)
	if err := t.addIcon(); err != nil {
		trayDestroyWindow.Call(window)
		ready <- err
		return
	}
	ready <- nil

	var message trayMessage
	for {
		result, _, messageErr := trayGetMessage.Call(uintptr(unsafe.Pointer(&message)), 0, 0, 0)
		if int32(result) == -1 {
			_ = messageErr
			break
		}
		if result == 0 {
			break
		}
		trayTranslateMessage.Call(uintptr(unsafe.Pointer(&message)))
		trayDispatchMessage.Call(uintptr(unsafe.Pointer(&message)))
	}
}

func (t *windowsManagerTray) addIcon() error {
	data := t.notificationData(trayNIFMessage | trayNIFIcon | trayNIFTip)
	result, _, callErr := trayShellNotifyIcon.Call(trayNIMAdd, uintptr(unsafe.Pointer(&data)))
	if result == 0 {
		return fmt.Errorf("add TautWeekly notification-area icon: %w", callErr)
	}
	data.Flags = 0
	data.Version = trayNotifyVersion
	trayShellNotifyIcon.Call(trayNIMSetVersion, uintptr(unsafe.Pointer(&data)))
	return nil
}

func (t *windowsManagerTray) notificationData(flags uint32) trayNotifyIconData {
	data := trayNotifyIconData{
		Window:          t.window.Load(),
		ID:              trayIconID,
		Flags:           flags,
		CallbackMessage: trayCallbackMessage,
		Icon:            t.icon,
	}
	data.Size = uint32(unsafe.Sizeof(data))
	tip, _ := syscall.UTF16FromString("TautWeekly for Plex — " + t.currentHealth().label())
	copy(data.Tip[:], tip)
	return data
}

func (t *windowsManagerTray) refreshStatus() {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()
	for {
		t.updateStatus()
		select {
		case <-ticker.C:
		case <-t.stop:
			return
		}
	}
}

func (t *windowsManagerTray) updateStatus() {
	if t.options.Status == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	health := t.options.Status(ctx)
	cancel()
	t.setHealth(health)
	if window := t.window.Load(); window != 0 {
		trayPostMessage.Call(window, trayUpdateMessage, 0, 0)
	}
}

func (t *windowsManagerTray) setHealth(health trayHealth) {
	switch health {
	case trayHealthy:
		t.health.Store(trayHealthyIndex)
	case trayFailed:
		t.health.Store(trayFailedIndex)
	default:
		t.health.Store(trayNeedsAttentionIndex)
	}
}

func (t *windowsManagerTray) currentHealth() trayHealth {
	switch t.health.Load() {
	case trayHealthyIndex:
		return trayHealthy
	case trayFailedIndex:
		return trayFailed
	default:
		return trayNeedsAttention
	}
}

func (t *windowsManagerTray) modifyTip() {
	data := t.notificationData(trayNIFTip)
	trayShellNotifyIcon.Call(trayNIMModify, uintptr(unsafe.Pointer(&data)))
}

func (t *windowsManagerTray) removeIcon() {
	data := t.notificationData(0)
	trayShellNotifyIcon.Call(trayNIMDelete, uintptr(unsafe.Pointer(&data)))
}

func (t *windowsManagerTray) showMenu() {
	menu, _, _ := trayCreatePopupMenu.Call()
	if menu == 0 {
		return
	}
	defer trayDestroyMenu.Call(menu)
	statusLabel, _ := syscall.UTF16PtrFromString(t.currentHealth().label())
	exitLabel, _ := syscall.UTF16PtrFromString("Exit TautWeekly for Plex")
	trayAppendMenu.Call(menu, trayMFString|trayMFGray|trayMFDisabled, trayStatusMenuID, uintptr(unsafe.Pointer(statusLabel)))
	trayAppendMenu.Call(menu, trayMFSeparator, 0, 0)
	trayAppendMenu.Call(menu, trayMFString, trayExitMenuID, uintptr(unsafe.Pointer(exitLabel)))
	bitmap := createTrayStatusBitmap(t.currentHealth())
	if bitmap != 0 {
		defer trayDeleteObject.Call(bitmap)
		item := trayMenuItemInfo{Mask: trayMIIMBitmap, ItemBitmap: bitmap}
		item.Size = uint32(unsafe.Sizeof(item))
		traySetMenuItemInfo.Call(menu, trayStatusMenuID, 0, uintptr(unsafe.Pointer(&item)))
	}
	var point trayPoint
	if result, _, _ := trayGetCursorPos.Call(uintptr(unsafe.Pointer(&point))); result == 0 {
		return
	}
	window := t.window.Load()
	traySetForegroundWindow.Call(window)
	command, _, _ := trayTrackPopupMenu.Call(menu, trayTPMRightButton|trayTPMNonotify|trayTPMReturnCmd, uintptr(point.X), uintptr(point.Y), 0, window, 0)
	trayPostMessage.Call(window, trayWMNull, 0, 0)
	if command == trayExitMenuID {
		t.exitOnce.Do(func() {
			if t.options.Exit != nil {
				go t.options.Exit()
			}
		})
	}
}

func (t *windowsManagerTray) openDashboard() {
	now := time.Now().UnixMilli()
	if previous := t.lastOpen.Swap(now); previous != 0 && now-previous < 500 {
		return
	}
	if t.options.Open != nil {
		go t.options.Open()
	}
}

func (t *windowsManagerTray) Close() error {
	t.closeOnce.Do(func() {
		close(t.stop)
		if window := t.window.Load(); window != 0 {
			trayPostMessage.Call(window, trayCloseMessage, 0, 0)
		}
	})
	select {
	case <-t.done:
		return nil
	case <-time.After(5 * time.Second):
		return errors.New("notification-area icon did not close promptly")
	}
}

func managerTrayWindowProc(window uintptr, message uint32, wParam, lParam uintptr) uintptr {
	value, exists := trayWindowRegistry.Load(window)
	if exists {
		tray := value.(*windowsManagerTray)
		switch {
		case tray.taskbarMessage != 0 && message == tray.taskbarMessage:
			_ = tray.addIcon()
			return 0
		case message == trayUpdateMessage:
			tray.modifyTip()
			return 0
		case message == trayCloseMessage:
			tray.removeIcon()
			tray.window.Store(0)
			trayDestroyWindow.Call(window)
			return 0
		case message == trayCallbackMessage:
			event := uint32(lParam & 0xffff)
			switch event {
			case trayWMLButtonUp, trayNINSelect, trayNINKeySelect:
				tray.openDashboard()
			case trayWMRButtonUp, trayWMContextMenu:
				tray.showMenu()
			}
			return 0
		case message == trayWMDestroy:
			tray.window.Store(0)
			trayPostQuitMessage.Call(0)
			return 0
		}
	}
	result, _, _ := trayDefaultWindowProc.Call(window, uintptr(message), wParam, lParam)
	return result
}

func loadManagerTrayIcon(iconPath string) (uintptr, error) {
	if iconPath != "" {
		path, err := syscall.UTF16PtrFromString(iconPath)
		if err == nil {
			icon, _, _ := trayLoadImage.Call(0, uintptr(unsafe.Pointer(path)), trayImageIcon, 0, 0, trayLRLoadFromFile|trayLRDefaultSize)
			if icon != 0 {
				return icon, nil
			}
		}
	}
	executable, err := os.Executable()
	if err == nil {
		path, pointerErr := syscall.UTF16PtrFromString(executable)
		if pointerErr == nil {
			var largeIcon uintptr
			var smallIcon uintptr
			count, _, _ := trayExtractIconEx.Call(uintptr(unsafe.Pointer(path)), 0, uintptr(unsafe.Pointer(&largeIcon)), uintptr(unsafe.Pointer(&smallIcon)), 1)
			if count > 0 {
				if largeIcon != 0 {
					trayDestroyIcon.Call(largeIcon)
				}
				if smallIcon != 0 {
					return smallIcon, nil
				}
			}
		}
	}
	return 0, errors.New("the packaged TautWeekly notification-area icon is unavailable")
}

func createTrayStatusBitmap(health trayHealth) uintptr {
	width, _, _ := trayGetSystemMetrics.Call(traySMCXMenuCheck)
	height, _, _ := trayGetSystemMetrics.Call(traySMCYMenuCheck)
	if width < trayDefaultIconSize {
		width = trayDefaultIconSize
	}
	if height < trayDefaultIconSize {
		height = trayDefaultIconSize
	}
	screen, _, _ := trayGetDC.Call(0)
	if screen == 0 {
		return 0
	}
	defer trayReleaseDC.Call(0, screen)
	memory, _, _ := trayCreateCompatibleDC.Call(screen)
	if memory == 0 {
		return 0
	}
	defer trayDeleteDC.Call(memory)
	bitmap, _, _ := trayCreateCompatibleBitmap.Call(screen, width, height)
	if bitmap == 0 {
		return 0
	}
	previous, _, _ := traySelectObject.Call(memory, bitmap)
	defer traySelectObject.Call(memory, previous)
	rectangle := trayRect{Right: int32(width), Bottom: int32(height)}
	menuBrush, _, _ := trayGetSysColorBrush.Call(trayColorMenu)
	trayFillRect.Call(memory, uintptr(unsafe.Pointer(&rectangle)), menuBrush)
	color := trayStatusColor(health)
	brush, _, _ := trayCreateSolidBrush.Call(uintptr(color))
	pen, _, _ := trayCreatePen.Call(trayPS_Solid, 1, uintptr(color))
	if brush == 0 || pen == 0 {
		if brush != 0 {
			trayDeleteObject.Call(brush)
		}
		if pen != 0 {
			trayDeleteObject.Call(pen)
		}
		trayDeleteObject.Call(bitmap)
		return 0
	}
	defer trayDeleteObject.Call(brush)
	defer trayDeleteObject.Call(pen)
	oldBrush, _, _ := traySelectObject.Call(memory, brush)
	oldPen, _, _ := traySelectObject.Call(memory, pen)
	inset := int32(4)
	trayEllipse.Call(memory, uintptr(inset), uintptr(inset), uintptr(int32(width)-inset), uintptr(int32(height)-inset))
	traySelectObject.Call(memory, oldBrush)
	traySelectObject.Call(memory, oldPen)
	return bitmap
}

func trayStatusColor(health trayHealth) uint32 {
	switch health {
	case trayHealthy:
		return windowsRGB(56, 168, 91)
	case trayFailed:
		return windowsRGB(220, 72, 72)
	default:
		return windowsRGB(229, 160, 13)
	}
}

func windowsRGB(red, green, blue uint32) uint32 {
	return red | green<<8 | blue<<16
}
