package manager

import (
	"encoding/json"
	"image"
	_ "image/png"
	"io/fs"
	"testing"
)

func TestEmbeddedBrandImagesAreTransparentAndVisible(t *testing.T) {
	for _, name := range []string{
		"web/tautweekly-logo.png",
		"web/tautweekly-icon-180.png",
		"web/tautweekly-icon-192.png",
		"web/tautweekly-icon-512.png",
	} {
		file, err := embeddedWeb.Open(name)
		if err != nil {
			t.Fatalf("open %s: %v", name, err)
		}
		decoded, _, err := image.Decode(file)
		_ = file.Close()
		if err != nil {
			t.Fatalf("decode %s: %v", name, err)
		}
		bounds := decoded.Bounds()
		for _, point := range []image.Point{
			bounds.Min,
			{X: bounds.Max.X - 1, Y: bounds.Min.Y},
			{X: bounds.Min.X, Y: bounds.Max.Y - 1},
			{X: bounds.Max.X - 1, Y: bounds.Max.Y - 1},
		} {
			_, _, _, alpha := decoded.At(point.X, point.Y).RGBA()
			if alpha != 0 {
				t.Fatalf("%s has an opaque corner at %v", name, point)
			}
		}
		visible := false
		for y := bounds.Min.Y; y < bounds.Max.Y && !visible; y++ {
			for x := bounds.Min.X; x < bounds.Max.X; x++ {
				_, _, _, alpha := decoded.At(x, y).RGBA()
				if alpha > 0x7fff {
					visible = true
					break
				}
			}
		}
		if !visible {
			t.Fatalf("%s contains no visible artwork", name)
		}
	}
}

func TestEmbeddedManifestReferencesLocalBrandImages(t *testing.T) {
	raw, err := fs.ReadFile(embeddedWeb, "web/manifest.webmanifest")
	if err != nil {
		t.Fatal(err)
	}
	var manifest struct {
		Icons []struct {
			Source string `json:"src"`
		} `json:"icons"`
	}
	if err := json.Unmarshal(raw, &manifest); err != nil {
		t.Fatal(err)
	}
	if len(manifest.Icons) != 2 {
		t.Fatalf("manifest icon count = %d, want 2", len(manifest.Icons))
	}
	for _, icon := range manifest.Icons {
		if len(icon.Source) < 2 || icon.Source[0] != '/' {
			t.Fatalf("manifest icon is not a local absolute path: %q", icon.Source)
		}
		if _, err := fs.Stat(embeddedWeb, "web"+icon.Source); err != nil {
			t.Fatalf("manifest icon %q is not embedded: %v", icon.Source, err)
		}
	}
}
