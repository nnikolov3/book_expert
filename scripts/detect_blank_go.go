package main

import (
	"fmt"
	"image"
	"image/color"
	_ "image/jpeg" // Register JPEG format decoder
	_ "image/png"  // Register PNG format decoder
	"os"
	"strconv"
	"strings"
)

func main() {
	if len(os.Args) != 4 {
		fmt.Fprintf(os.Stderr, "Usage: %s <image_path> <fuzz_percent> <threshold>\n", os.Args[0])
		fmt.Fprintf(os.Stderr, "Example: %s /path/to/image.jpeg 5 0.005\n", os.Args[0])
		os.Exit(2)
	}

	imagePath := os.Args[1]
	fuzzPercentStr := os.Args[2]
	thresholdStr := os.Args[3]

	// Validate file extension
	lowerPath := strings.ToLower(imagePath)
	if !strings.HasSuffix(lowerPath, ".jpeg") && !strings.HasSuffix(lowerPath, ".jpg") && !strings.HasSuffix(lowerPath, ".png") {
		fmt.Fprintf(os.Stderr, "Error: Unsupported file format. Only JPEG and PNG are supported.\n")
		os.Exit(2)
	}

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

	// Validate parameters
	if fuzzPercent < 0 || fuzzPercent > 100 {
		fmt.Fprintf(os.Stderr, "Error: fuzz_percent must be between 0 and 100\n")
		os.Exit(2)
	}

	if threshold < 0 || threshold > 1 {
		fmt.Fprintf(os.Stderr, "Error: threshold must be between 0 and 1\n")
		os.Exit(2)
	}

	file, err := os.Open(imagePath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error opening image '%s': %v\n", imagePath, err)
		os.Exit(2)
	}
	defer file.Close()

	img, format, err := image.Decode(file)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error decoding image '%s': %v\n", imagePath, err)
		os.Exit(2)
	}

	// Verify we got a supported format
	if format != "jpeg" && format != "png" {
		fmt.Fprintf(os.Stderr, "Error: Decoded format '%s' is not supported\n", format)
		os.Exit(2)
	}

	bounds := img.Bounds()
	totalPixels := bounds.Dx() * bounds.Dy()
	if totalPixels == 0 {
		fmt.Fprintf(os.Stderr, "Error: Image has zero pixels\n")
		os.Exit(2)
	}

	// Calculate the luminance threshold for "near white" based on fuzz_percent
	// For 8-bit grayscale (0-255), pixels with luminance <= (255 - fuzz_value) are "non-white"
	fuzzValue := 255.0 * (fuzzPercent / 100.0)
	nonWhiteCutoff := uint8(255.0 - fuzzValue)

	nonWhiteCount := 0
	for y := bounds.Min.Y; y < bounds.Max.Y; y++ {
		for x := bounds.Min.X; x < bounds.Max.X; x++ {
			c := img.At(x, y)
			// Convert to grayscale luminance (0-255)
			gray := color.GrayModel.Convert(c).(color.Gray).Y
			if gray <= nonWhiteCutoff {
				nonWhiteCount++
			}
		}
	}

	nonWhiteRatio := float64(nonWhiteCount) / float64(totalPixels)

	// Exit codes:
	// 0 = blank (non-white ratio <= threshold)
	// 1 = not blank (non-white ratio > threshold)
	// 2 = error
	if nonWhiteRatio <= threshold {
		os.Exit(0) // Blank
	} else {
		os.Exit(1) // Not blank
	}
}