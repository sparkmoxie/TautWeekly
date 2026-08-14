package manager

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

const maxPreviewBytes = 12 << 20

type Preview struct {
	ID          string    `json:"id"`
	Name        string    `json:"name"`
	ModifiedUTC time.Time `json:"modifiedUtc"`
	SizeBytes   int64     `json:"sizeBytes"`
}

func listPreviews(root string) ([]Preview, map[string]string) {
	outputRoot := filepath.Join(root, "output")
	entries, err := os.ReadDir(outputRoot)
	if err != nil {
		return []Preview{}, map[string]string{}
	}

	previews := make([]Preview, 0)
	paths := make(map[string]string)
	for _, entry := range entries {
		if entry.IsDir() || !strings.EqualFold(filepath.Ext(entry.Name()), ".html") || !strings.HasPrefix(strings.ToLower(entry.Name()), "preview") {
			continue
		}
		info, err := entry.Info()
		if err != nil || !info.Mode().IsRegular() || info.Size() > maxPreviewBytes {
			continue
		}
		id := previewID(entry.Name())
		previews = append(previews, Preview{
			ID:          id,
			Name:        strings.TrimSuffix(entry.Name(), filepath.Ext(entry.Name())),
			ModifiedUTC: info.ModTime().UTC(),
			SizeBytes:   info.Size(),
		})
		paths[id] = filepath.Join(outputRoot, entry.Name())
	}
	sort.Slice(previews, func(left, right int) bool {
		return previews[left].ModifiedUTC.After(previews[right].ModifiedUTC)
	})
	return previews, paths
}

func previewID(name string) string {
	sum := sha256.Sum256([]byte(strings.ToLower(name)))
	return hex.EncodeToString(sum[:12])
}

func servePreview(w http.ResponseWriter, path string) {
	file, err := os.Open(path)
	if err != nil {
		writeAPIError(w, http.StatusNotFound, "preview-not-found", "Preview is unavailable.")
		return
	}
	defer file.Close()

	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() > maxPreviewBytes {
		writeAPIError(w, http.StatusNotFound, "preview-not-found", "Preview is unavailable.")
		return
	}
	raw, err := io.ReadAll(io.LimitReader(file, maxPreviewBytes+1))
	if err != nil || len(raw) > maxPreviewBytes {
		writeAPIError(w, http.StatusInternalServerError, "preview-read-failed", "Preview could not be read.")
		return
	}

	body := injectPreviewBase(raw)
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Security-Policy", "sandbox allow-same-origin; default-src 'none'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; font-src 'self' data:; frame-ancestors 'self'")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(body)
}

func injectPreviewBase(raw []byte) []byte {
	text := string(raw)
	base := `<base href="/preview-content/output/">`
	lower := strings.ToLower(text)
	if index := strings.Index(lower, "<head>"); index >= 0 {
		position := index + len("<head>")
		return []byte(text[:position] + base + text[position:])
	}
	return []byte(base + text)
}

func servePreviewAsset(w http.ResponseWriter, r *http.Request, root, requested string) {
	requested = filepath.FromSlash(strings.TrimPrefix(requested, "/"))
	cleaned := filepath.Clean(requested)
	if cleaned == "." || filepath.IsAbs(cleaned) || cleaned == ".." || strings.HasPrefix(cleaned, ".."+string(filepath.Separator)) {
		writeAPIError(w, http.StatusNotFound, "asset-not-found", "Preview asset is unavailable.")
		return
	}
	parts := strings.SplitN(cleaned, string(filepath.Separator), 2)
	if len(parts) != 2 || parts[1] == "" {
		writeAPIError(w, http.StatusNotFound, "asset-not-found", "Preview asset is unavailable.")
		return
	}
	var assetRoot string
	switch strings.ToLower(parts[0]) {
	case "output":
		assetRoot = filepath.Join(root, "output")
	case "assets":
		assetRoot = filepath.Join(root, "assets")
	default:
		writeAPIError(w, http.StatusNotFound, "asset-not-found", "Preview asset is unavailable.")
		return
	}
	assetRoot, err := filepath.Abs(assetRoot)
	if err != nil {
		writeAPIError(w, http.StatusNotFound, "asset-not-found", "Preview asset is unavailable.")
		return
	}
	target, err := filepath.Abs(filepath.Join(assetRoot, parts[1]))
	if err != nil || (target != assetRoot && !strings.HasPrefix(target, assetRoot+string(filepath.Separator))) {
		writeAPIError(w, http.StatusNotFound, "asset-not-found", "Preview asset is unavailable.")
		return
	}
	if !allowedPreviewAsset(filepath.Ext(target)) {
		writeAPIError(w, http.StatusNotFound, "asset-not-found", "Preview asset is unavailable.")
		return
	}
	resolvedRoot, err := filepath.EvalSymlinks(assetRoot)
	if err != nil {
		writeAPIError(w, http.StatusNotFound, "asset-not-found", "Preview asset is unavailable.")
		return
	}
	resolvedTarget, err := filepath.EvalSymlinks(target)
	if err != nil || !pathWithinRoot(resolvedRoot, resolvedTarget) {
		writeAPIError(w, http.StatusNotFound, "asset-not-found", "Preview asset is unavailable.")
		return
	}
	file, err := os.Open(resolvedTarget)
	if err != nil {
		writeAPIError(w, http.StatusNotFound, "asset-not-found", "Preview asset is unavailable.")
		return
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() > maxPreviewBytes {
		writeAPIError(w, http.StatusNotFound, "asset-not-found", "Preview asset is unavailable.")
		return
	}

	w.Header().Set("Cache-Control", "private, max-age=300")
	w.Header().Set("Content-Security-Policy", "default-src 'none'")
	http.ServeContent(w, r, filepath.Base(resolvedTarget), info.ModTime(), file)
}

func pathWithinRoot(root, target string) bool {
	root, err := filepath.Abs(root)
	if err != nil {
		return false
	}
	target, err = filepath.Abs(target)
	if err != nil {
		return false
	}
	relative, err := filepath.Rel(root, target)
	return err == nil && relative != ".." && !filepath.IsAbs(relative) && !strings.HasPrefix(relative, ".."+string(filepath.Separator))
}

func allowedPreviewAsset(extension string) bool {
	switch strings.ToLower(extension) {
	case ".gif", ".jpg", ".jpeg", ".png", ".webp":
		return true
	default:
		return false
	}
}

func previewSummary(previews []Preview) string {
	if len(previews) == 0 {
		return "No generated previews"
	}
	if len(previews) == 1 {
		return "1 generated preview"
	}
	return fmt.Sprintf("%d generated previews", len(previews))
}
