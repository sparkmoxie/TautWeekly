//go:build !uninstaller

package main

import "embed"

// The release builder generates the ignored payload files before compiling the
// installer. Embedding the directory, which always contains README.txt, keeps
// ordinary unit tests buildable from a clean source checkout.
//
//go:embed payload
var payloadFiles embed.FS

var (
	payload, _          = payloadFiles.ReadFile("payload/TautWeekly-windows.zip")
	payloadHashBytes, _ = payloadFiles.ReadFile("payload/TautWeekly-windows.zip.sha256")
	payloadHashText     = string(payloadHashBytes)
	applicationIcon, _  = payloadFiles.ReadFile("payload/tautweekly.ico")
)

const uninstallerOnly = false
