package main

import (
	"fmt"
	"image"
	"image/color"
	_ "image/jpeg" // Register JPEG format decoder
	_ "image/png"  // Register PNG format decoder
	"os"
	"strconv"
)

func main() {
	if len(os.Args) != 4 {
		// Usage: <program> <png_path> <fuzz_percent> <threshold>
		// Example: ./detect_blank_go /path/to/image.png 5 0.005
		fmt.Fprintf(os.Stderr, "Usage: %s <png_path> <fuzz_percent> <threshold>\n", os.Args[0])
		os.Exit(2) // Exit code 2 for arguments/internal errors
	}

	pngPath := os.Args[1]
	fuzzPercentStr := os.Args[2]
	thresholdStr := os.Args[3]

	fuzzPercent, err := strconv.ParseFloat(fuzzPercentStr, 64)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error parsing fuzz_percent '%s': %v\n", fuzzPercentStr, err)
		os.Exit(2)
	}
	threshold, err := strconv.ParseFloat(thresholdStr, 64)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error parsing threshold '%s': %v\n", thresholdStr, err)
		os.Exit(2)
	}

	file, err := os.Open(pngPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error opening image '%s': %v\n", pngPath, err)
		os.Exit(2)
	}
	defer file.Close()

	img, _, err := image.Decode(file)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error decoding image '%s': %v\n", pngPath, err)
		os.Exit(2)
	}

	bounds := img.Bounds()
	totalPixels := bounds.Dx() * bounds.Dy()
	if totalPixels == 0 {
		// An empty image can't be blank or non-blank; treat as not blank
		os.Exit(1)
	}

	// Calculate the luminance threshold for "near white" based on fuzz_percent.
	// For 8-bit grayscale (0-255), fuzz_value = 255 * (fuzz_percent / 100)
	// Pixels with luminance <= (255 - fuzz_value) are "non-white" pixels we count.
	fuzzValue8Bit := 255.0 * (fuzzPercent / 100.0)
	nonWhiteCutoff8Bit := uint8(255.0 - fuzzValue8Bit) // Cast to uint8 for direct comparison

	nonWhiteCount := 0
	for y := bounds.Min.Y; y < bounds.Max.Y; y++ {
		for x := bounds.Min.X; x < bounds.Max.X; x++ {
			c := img.At(x, y)
			// Convert to grayscale luminance (0-255).
			gray := color.GrayModel.Convert(c).(color.Gray).Y
			if gray <= nonWhiteCutoff8Bit {
				nonWhiteCount++
			}
		}
	}

	nonWhiteRatio := float64(nonWhiteCount) / float64(totalPixels)

	if nonWhiteRatio <= threshold {
		os.Exit(0) // Blank
	} else {
		os.Exit(1) // Not blank
	}
}
