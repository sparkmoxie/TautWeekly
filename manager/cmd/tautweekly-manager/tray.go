package main

import "context"

type trayHealth string

const (
	trayHealthy        trayHealth = "healthy"
	trayNeedsAttention trayHealth = "needs-attention"
	trayFailed         trayHealth = "failed"
)

type trayOptions struct {
	IconPath string
	Status   func(context.Context) trayHealth
	Open     func()
	Exit     func()
}

type managerTray interface {
	Close() error
}

type disabledManagerTray struct{}

func (disabledManagerTray) Close() error { return nil }

func trayHealthFromOverall(overall string) trayHealth {
	switch overall {
	case "healthy":
		return trayHealthy
	case "blocked":
		return trayFailed
	default:
		return trayNeedsAttention
	}
}

func (health trayHealth) label() string {
	switch health {
	case trayHealthy:
		return "Healthy"
	case trayFailed:
		return "Failed"
	default:
		return "Needs attention"
	}
}
