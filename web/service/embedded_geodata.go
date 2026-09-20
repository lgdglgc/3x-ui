package service

import (
	_ "embed"
	"os"
	"path/filepath"

	"github.com/mhsanaei/3x-ui/v3/config"
	"github.com/mhsanaei/3x-ui/v3/logger"
)

//go:embed geosite_myai.dat
var EmbeddedGeositeMyAI []byte

// EnsureEmbeddedGeofiles guarantees that geosite_myai.dat is present in the Xray bin folder.
// If missing or empty, it extracts the embedded geosite_myai.dat compiled into the binary.
func EnsureEmbeddedGeofiles() {
	destPath := filepath.Join(config.GetBinFolderPath(), "geosite_myai.dat")
	info, err := os.Stat(destPath)
	if os.IsNotExist(err) || (err == nil && info.Size() == 0) {
		if err := os.MkdirAll(filepath.Dir(destPath), 0755); err != nil {
			logger.Warning("failed to create bin folder for geosite_myai.dat:", err)
			return
		}
		if err := os.WriteFile(destPath, EmbeddedGeositeMyAI, 0644); err != nil {
			logger.Warning("failed to write embedded geosite_myai.dat:", err)
			return
		}
		logger.Infof("successfully extracted embedded geosite_myai.dat (%d bytes) to %s", len(EmbeddedGeositeMyAI), destPath)
	}
}
