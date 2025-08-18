// Package tts - Audio processing component for native Go TTS implementation
//
// This module handles audio signal processing, spectrogram generation,
// and audio file I/O using native Go libraries.

package tts

import (
	"encoding/binary"
	"fmt"
	"math"
	"math/cmplx"
	"os"
)

// AudioProcessor handles audio signal processing and file operations
type AudioProcessor struct {
	sampleRate    int
	frameSize     int
	hopLength     int
	nFFT          int
	melBins       int
	fMin          float64
	fMax          float64
	windowFunc    []float64
	melFilterBank [][]float64
}

// MelSpectrogram represents a mel-scale spectrogram
type MelSpectrogram struct {
	Data     [][]float64 // [time][mel_bin]
	SampleRate int
	HopLength  int
	NMels      int
}

// Waveform represents an audio waveform
type Waveform struct {
	Data       []float64
	SampleRate int
}

// NewAudioProcessor creates a new audio processor with default settings
func NewAudioProcessor() (*AudioProcessor, error) {
	ap := &AudioProcessor{
		sampleRate: 22050,  // Standard TTS sample rate
		frameSize:  1024,   // Frame size for STFT
		hopLength:  256,    // Hop length for STFT
		nFFT:       1024,   // FFT size
		melBins:    80,     // Number of mel filter banks
		fMin:       0.0,    // Minimum frequency
		fMax:       8000.0, // Maximum frequency (Nyquist for 22kHz)
	}

	// Initialize window function (Hann window)
	ap.windowFunc = makeHannWindow(ap.frameSize)

	// Initialize mel filter bank
	ap.melFilterBank = ap.createMelFilterBank()

	return ap, nil
}

// MelSpectrogramToWaveform converts mel-spectrogram to audio waveform using Griffin-Lim
func (ap *AudioProcessor) MelSpectrogramToWaveform(melSpec *MelSpectrogram) (*Waveform, error) {
	// Step 1: Convert mel-spectrogram to linear spectrogram
	linearSpec, err := ap.melToLinearSpectrogram(melSpec)
	if err != nil {
		return nil, fmt.Errorf("mel to linear conversion failed: %w", err)
	}

	// Step 2: Convert magnitude spectrogram to complex spectrogram using Griffin-Lim
	waveform, err := ap.griffinLim(linearSpec)
	if err != nil {
		return nil, fmt.Errorf("Griffin-Lim reconstruction failed: %w", err)
	}

	return &Waveform{
		Data:       waveform,
		SampleRate: ap.sampleRate,
	}, nil
}

// SaveWaveformToFile saves waveform to WAV file
func (ap *AudioProcessor) SaveWaveformToFile(waveform *Waveform, filename string) error {
	return ap.saveWAV(waveform.Data, filename, waveform.SampleRate)
}

// melToLinearSpectrogram converts mel-spectrogram back to linear frequency spectrogram
func (ap *AudioProcessor) melToLinearSpectrogram(melSpec *MelSpectrogram) ([][]float64, error) {
	nFrames := len(melSpec.Data)
	nFreqs := ap.nFFT/2 + 1
	
	linearSpec := make([][]float64, nFrames)
	for i := range linearSpec {
		linearSpec[i] = make([]float64, nFreqs)
	}

	// Pseudo-inverse of mel filter bank (simplified approximation)
	for t := 0; t < nFrames; t++ {
		for f := 0; f < nFreqs; f++ {
			for m := 0; m < ap.melBins; m++ {
				if m < len(melSpec.Data[t]) && f < len(ap.melFilterBank[m]) {
					linearSpec[t][f] += melSpec.Data[t][m] * ap.melFilterBank[m][f]
				}
			}
		}
	}

	return linearSpec, nil
}

// griffinLim implements Griffin-Lim algorithm for phase reconstruction
func (ap *AudioProcessor) griffinLim(magnitude [][]float64) ([]float64, error) {
	nFrames := len(magnitude)
	nFreqs := len(magnitude[0])
	
	// Initialize with random phase
	phase := make([][]float64, nFrames)
	for t := range phase {
		phase[t] = make([]float64, nFreqs)
		for f := range phase[t] {
			// Simple pseudo-random phase initialization
			phase[t][f] = math.Pi * (2.0*float64((t*nFreqs+f)%1000)/1000.0 - 1.0)
		}
	}

	// Griffin-Lim iterations
	iterations := 60 // Standard number of iterations
	
	for iter := 0; iter < iterations; iter++ {
		// Convert magnitude + phase to time domain
		signal := ap.istft(magnitude, phase)
		
		// Convert back to frequency domain
		newMagnitude, newPhase := ap.stft(signal)
		
		// Keep original magnitude, update phase
		phase = newPhase
		
		// Optional: early stopping if convergence is detected
		_ = newMagnitude // Suppress unused variable warning
	}

	// Final reconstruction
	signal := ap.istft(magnitude, phase)
	return signal, nil
}

// stft performs Short-Time Fourier Transform
func (ap *AudioProcessor) stft(signal []float64) ([][]float64, [][]float64) {
	nFrames := (len(signal)-ap.frameSize)/ap.hopLength + 1
	nFreqs := ap.nFFT/2 + 1
	
	magnitude := make([][]float64, nFrames)
	phase := make([][]float64, nFrames)
	
	for t := 0; t < nFrames; t++ {
		magnitude[t] = make([]float64, nFreqs)
		phase[t] = make([]float64, nFreqs)
		
		// Extract frame
		start := t * ap.hopLength
		end := start + ap.frameSize
		if end > len(signal) {
			end = len(signal)
		}
		
		frame := make([]float64, ap.frameSize)
		copy(frame, signal[start:end])
		
		// Apply window
		for i := range frame {
			if i < len(ap.windowFunc) {
				frame[i] *= ap.windowFunc[i]
			}
		}
		
		// Zero-pad to nFFT size
		if len(frame) < ap.nFFT {
			padded := make([]float64, ap.nFFT)
			copy(padded, frame)
			frame = padded
		}
		
		// Compute FFT
		spectrum := ap.realFFT(frame)
		
		// Extract magnitude and phase
		for f := 0; f < nFreqs && f < len(spectrum); f++ {
			magnitude[t][f] = cmplx.Abs(spectrum[f])
			phase[t][f] = cmplx.Phase(spectrum[f])
		}
	}
	
	return magnitude, phase
}

// istft performs Inverse Short-Time Fourier Transform
func (ap *AudioProcessor) istft(magnitude, phase [][]float64) []float64 {
	nFrames := len(magnitude)
	nFreqs := len(magnitude[0])
	
	signalLength := (nFrames-1)*ap.hopLength + ap.frameSize
	signal := make([]float64, signalLength)
	window := make([]float64, signalLength)
	
	for t := 0; t < nFrames; t++ {
		// Reconstruct complex spectrum
		spectrum := make([]complex128, ap.nFFT)
		for f := 0; f < nFreqs && f < len(magnitude[t]); f++ {
			mag := magnitude[t][f]
			ph := phase[t][f]
			spectrum[f] = complex(mag*math.Cos(ph), mag*math.Sin(ph))
		}
		
		// Mirror for negative frequencies (real signal)
		for f := 1; f < nFreqs-1 && f < ap.nFFT/2; f++ {
			spectrum[ap.nFFT-f] = cmplx.Conj(spectrum[f])
		}
		
		// Inverse FFT
		frame := ap.inverseFFT(spectrum)
		
		// Apply window and overlap-add
		start := t * ap.hopLength
		for i := 0; i < ap.frameSize && start+i < len(signal); i++ {
			if i < len(ap.windowFunc) {
				signal[start+i] += real(frame[i]) * ap.windowFunc[i]
				window[start+i] += ap.windowFunc[i] * ap.windowFunc[i]
			}
		}
	}
	
	// Normalize by window function
	for i := range signal {
		if window[i] > 1e-8 {
			signal[i] /= window[i]
		}
	}
	
	return signal
}

// realFFT computes FFT of real signal
func (ap *AudioProcessor) realFFT(signal []float64) []complex128 {
	n := len(signal)
	if n != ap.nFFT {
		// Pad or truncate to nFFT size
		padded := make([]float64, ap.nFFT)
		copy(padded, signal)
		signal = padded
		n = ap.nFFT
	}
	
	// Convert to complex
	complexSignal := make([]complex128, n)
	for i, v := range signal {
		complexSignal[i] = complex(v, 0)
	}
	
	// Simple DFT implementation (can be optimized with FFT algorithms)
	result := make([]complex128, n/2+1)
	for k := 0; k < len(result); k++ {
		sum := complex(0, 0)
		for t := 0; t < n; t++ {
			angle := -2.0 * math.Pi * float64(k*t) / float64(n)
			sum += complexSignal[t] * complex(math.Cos(angle), math.Sin(angle))
		}
		result[k] = sum
	}
	
	return result
}

// inverseFFT computes inverse FFT
func (ap *AudioProcessor) inverseFFT(spectrum []complex128) []complex128 {
	n := len(spectrum)
	result := make([]complex128, n)
	
	// Simple IDFT implementation
	for t := 0; t < n; t++ {
		sum := complex(0, 0)
		for k := 0; k < n; k++ {
			angle := 2.0 * math.Pi * float64(k*t) / float64(n)
			sum += spectrum[k] * complex(math.Cos(angle), math.Sin(angle))
		}
		result[t] = sum / complex(float64(n), 0)
	}
	
	return result
}

// createMelFilterBank creates mel-scale filter bank
func (ap *AudioProcessor) createMelFilterBank() [][]float64 {
	nFreqs := ap.nFFT/2 + 1
	filters := make([][]float64, ap.melBins)
	
	// Convert frequency limits to mel scale
	melMin := ap.hzToMel(ap.fMin)
	melMax := ap.hzToMel(ap.fMax)
	
	// Create equally spaced mel frequencies
	melPoints := make([]float64, ap.melBins+2)
	for i := range melPoints {
		melPoints[i] = melMin + (melMax-melMin)*float64(i)/float64(ap.melBins+1)
	}
	
	// Convert back to Hz
	hzPoints := make([]float64, len(melPoints))
	for i, mel := range melPoints {
		hzPoints[i] = ap.melToHz(mel)
	}
	
	// Convert Hz to FFT bin numbers
	binPoints := make([]int, len(hzPoints))
	for i, hz := range hzPoints {
		binPoints[i] = int(math.Round(hz * float64(ap.nFFT) / float64(ap.sampleRate)))
		if binPoints[i] >= nFreqs {
			binPoints[i] = nFreqs - 1
		}
	}
	
	// Create triangular filters
	for m := 0; m < ap.melBins; m++ {
		filters[m] = make([]float64, nFreqs)
		
		left := binPoints[m]
		center := binPoints[m+1]
		right := binPoints[m+2]
		
		// Left slope
		for f := left; f < center; f++ {
			if center > left {
				filters[m][f] = float64(f-left) / float64(center-left)
			}
		}
		
		// Right slope
		for f := center; f < right; f++ {
			if right > center {
				filters[m][f] = float64(right-f) / float64(right-center)
			}
		}
	}
	
	return filters
}

// hzToMel converts frequency in Hz to mel scale
func (ap *AudioProcessor) hzToMel(hz float64) float64 {
	return 2595.0 * math.Log10(1.0+hz/700.0)
}

// melToHz converts mel scale to frequency in Hz
func (ap *AudioProcessor) melToHz(mel float64) float64 {
	return 700.0 * (math.Pow(10.0, mel/2595.0) - 1.0)
}

// makeHannWindow creates a Hann window function
func makeHannWindow(size int) []float64 {
	window := make([]float64, size)
	for i := 0; i < size; i++ {
		window[i] = 0.5 * (1.0 - math.Cos(2.0*math.Pi*float64(i)/float64(size-1)))
	}
	return window
}

// saveWAV saves audio data to WAV file
func (ap *AudioProcessor) saveWAV(data []float64, filename string, sampleRate int) error {
	file, err := os.Create(filename)
	if err != nil {
		return fmt.Errorf("failed to create WAV file: %w", err)
	}
	defer file.Close()

	// WAV header
	dataSize := len(data) * 2 // 16-bit samples
	fileSize := 36 + dataSize

	// RIFF header
	file.WriteString("RIFF")
	binary.Write(file, binary.LittleEndian, uint32(fileSize))
	file.WriteString("WAVE")

	// Format chunk
	file.WriteString("fmt ")
	binary.Write(file, binary.LittleEndian, uint32(16))    // chunk size
	binary.Write(file, binary.LittleEndian, uint16(1))     // PCM format
	binary.Write(file, binary.LittleEndian, uint16(1))     // mono
	binary.Write(file, binary.LittleEndian, uint32(sampleRate))
	binary.Write(file, binary.LittleEndian, uint32(sampleRate*2)) // byte rate
	binary.Write(file, binary.LittleEndian, uint16(2))     // block align
	binary.Write(file, binary.LittleEndian, uint16(16))    // bits per sample

	// Data chunk
	file.WriteString("data")
	binary.Write(file, binary.LittleEndian, uint32(dataSize))

	// Convert float64 to 16-bit PCM and write
	for _, sample := range data {
		// Clamp and scale to 16-bit range
		if sample > 1.0 {
			sample = 1.0
		} else if sample < -1.0 {
			sample = -1.0
		}
		pcmSample := int16(sample * 32767.0)
		binary.Write(file, binary.LittleEndian, pcmSample)
	}

	return nil
}