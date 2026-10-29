package manager

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io/fs"
	"math"
	"mime"
	"net/http"
	"path"
	"strconv"
	"strings"
	"time"
)

type staticVariant struct {
	File   string `json:"file"`
	Bytes  int64  `json:"bytes"`
	SHA256 string `json:"sha256"`
}

type staticAsset struct {
	SHA256 string         `json:"sha256"`
	Bytes  int64          `json:"bytes"`
	Gzip   *staticVariant `json:"gzip,omitempty"`
	Brotli *staticVariant `json:"br,omitempty"`
}

type staticAssetManifest struct {
	SchemaVersion int                    `json:"schemaVersion"`
	Assets        map[string]staticAsset `json:"assets"`
}

func readStaticAssetManifest(root fs.FS) staticAssetManifest {
	raw, err := fs.ReadFile(root, "precompressed/manifest.json")
	if err != nil {
		panic(fmt.Errorf("read embedded static asset manifest: %w", err))
	}
	var manifest staticAssetManifest
	if err := json.Unmarshal(raw, &manifest); err != nil || manifest.SchemaVersion != 1 || len(manifest.Assets) == 0 {
		panic("invalid embedded static asset manifest; run node scripts/precompress-manager-assets.mjs")
	}
	return manifest
}

// Only public embedded files receive fingerprints. The application document is
// adapted per request and remains no-store, as do APIs and generated previews.
func versionStaticAssetURLs(document []byte, manifest staticAssetManifest) []byte {
	result := string(document)
	for name, asset := range manifest.Assets {
		for _, attribute := range []string{"src", "href"} {
			old := attribute + "=\"/" + name + "\""
			replacement := attribute + "=\"/" + name + "?v=" + asset.SHA256 + "\""
			result = strings.ReplaceAll(result, old, replacement)
		}
	}
	return []byte(result)
}

// Honor explicit refusals and quality preferences. In the absence of an
// explicit identity preference, an acceptable compression precedes identity.
func negotiateStaticEncoding(header string, asset staticAsset) (string, bool) {
	if strings.TrimSpace(header) == "" {
		return "identity", true
	}
	qualities := make(map[string]float64)
	for _, item := range strings.Split(header, ",") {
		parts := strings.Split(item, ";")
		coding := strings.ToLower(strings.TrimSpace(parts[0]))
		if coding == "" {
			continue
		}
		quality := 1.0
		for _, parameter := range parts[1:] {
			key, value, ok := strings.Cut(strings.TrimSpace(parameter), "=")
			if !ok || !strings.EqualFold(strings.TrimSpace(key), "q") {
				continue
			}
			parsed, err := strconv.ParseFloat(strings.TrimSpace(value), 64)
			if err != nil || math.IsNaN(parsed) || math.IsInf(parsed, 0) || parsed < 0 || parsed > 1 {
				quality = 0
			} else {
				quality = parsed
			}
		}
		// Repeated declarations cannot bypass an explicit q=0 refusal.
		if previous, exists := qualities[coding]; !exists || quality < previous {
			qualities[coding] = quality
		}
	}
	best, bestQuality := "", -1.0
	for _, coding := range []string{"br", "gzip", "identity"} {
		if coding == "br" && asset.Brotli == nil || coding == "gzip" && asset.Gzip == nil {
			continue
		}
		quality, present := qualities[coding]
		if !present {
			wildcard, hasWildcard := qualities["*"]
			if coding == "identity" {
				// Implicit identity is the fallback, not a fabricated q-value
				// that could outrank a small but accepted coding preference.
				quality = 1
				if best != "" || (hasWildcard && wildcard == 0) {
					quality = 0
				}
			} else if hasWildcard {
				quality = wildcard
			} else {
				quality = 0
			}
		}
		if quality > 0 && quality > bestQuality {
			best, bestQuality = coding, quality
		}
	}
	return best, best != ""
}

func serveStaticAsset(w http.ResponseWriter, r *http.Request, root fs.FS, manifest staticAssetManifest, name string) bool {
	asset, exists := manifest.Assets[name]
	if !exists {
		return false
	}
	w.Header().Add("Vary", "Accept-Encoding")
	encoding, acceptable := negotiateStaticEncoding(strings.Join(r.Header.Values("Accept-Encoding"), ","), asset)
	if !acceptable {
		w.Header().Set("Cache-Control", "no-store")
		http.Error(w, "No acceptable content encoding is available.", http.StatusNotAcceptable)
		return true
	}
	filename, digest := name, asset.SHA256
	if encoding != "identity" {
		variant := asset.Brotli
		if encoding == "gzip" {
			variant = asset.Gzip
		}
		filename, digest = variant.File, variant.SHA256
		w.Header().Set("Content-Encoding", encoding)
	}
	raw, err := fs.ReadFile(root, filename)
	if err != nil {
		w.Header().Del("Content-Encoding")
		w.Header().Set("Cache-Control", "no-store")
		http.Error(w, "Static asset is unavailable.", http.StatusInternalServerError)
		return true
	}
	if r.URL.Query().Get("v") == asset.SHA256 {
		w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
	} else {
		w.Header().Set("Cache-Control", "public, max-age=0, must-revalidate")
	}
	w.Header().Set("ETag", "\""+digest+"-"+encoding+"\"")
	if path.Ext(name) == ".ico" {
		w.Header().Set("Content-Type", "image/x-icon")
	} else if contentType := mime.TypeByExtension(path.Ext(name)); contentType != "" {
		w.Header().Set("Content-Type", contentType)
	}
	w.Header().Set("Content-Length", strconv.Itoa(len(raw)))
	http.ServeContent(w, r, name, time.Time{}, bytes.NewReader(raw))
	return true
}
