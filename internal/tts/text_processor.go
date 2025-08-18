// Package tts - Text processing component for native Go TTS implementation
//
// This module handles text preprocessing, normalization, and phoneme conversion
// without relying on external Python libraries.

package tts

import (
	"regexp"
	"strings"
)

// TextProcessor handles text preprocessing and phoneme conversion
type TextProcessor struct {
	phoneDict    map[string][]string
	abbrevDict   map[string]string
	normalizers  []TextNormalizer
}

// Phoneme represents a phonetic unit
type Phoneme struct {
	Symbol   string
	Duration float32 // In milliseconds
}

// TextNormalizer interface for text normalization functions
type TextNormalizer interface {
	Normalize(text string) string
}

// NumberNormalizer converts numbers to words
type NumberNormalizer struct{}

// AbbreviationNormalizer expands abbreviations
type AbbreviationNormalizer struct {
	abbreviations map[string]string
}

// SymbolNormalizer handles special symbols
type SymbolNormalizer struct{}

// NewTextProcessor creates a new text processor with default settings
func NewTextProcessor() (*TextProcessor, error) {
	tp := &TextProcessor{
		phoneDict:  makeBasicPhonemeDict(),
		abbrevDict: makeAbbreviationDict(),
	}

	// Initialize normalizers
	tp.normalizers = []TextNormalizer{
		&NumberNormalizer{},
		&AbbreviationNormalizer{abbreviations: tp.abbrevDict},
		&SymbolNormalizer{},
	}

	return tp, nil
}

// TextToPhonemes converts text to phoneme sequence
func (tp *TextProcessor) TextToPhonemes(text string) ([]Phoneme, error) {
	// Step 1: Normalize text
	normalizedText := tp.normalizeText(text)

	// Step 2: Convert to phonemes
	phonemes := tp.convertToPhonemes(normalizedText)

	return phonemes, nil
}

// normalizeText applies all text normalizers
func (tp *TextProcessor) normalizeText(text string) string {
	result := text
	for _, normalizer := range tp.normalizers {
		result = normalizer.Normalize(result)
	}
	
	// Additional cleanup
	result = strings.TrimSpace(result)
	result = regexp.MustCompile(`\s+`).ReplaceAllString(result, " ")
	
	return result
}

// convertToPhonemes converts normalized text to phoneme sequence
func (tp *TextProcessor) convertToPhonemes(text string) []Phoneme {
	var phonemes []Phoneme
	words := strings.Fields(text)

	for _, word := range words {
		wordPhonemes := tp.wordToPhonemes(word)
		phonemes = append(phonemes, wordPhonemes...)
		
		// Add word boundary
		phonemes = append(phonemes, Phoneme{Symbol: " ", Duration: 100.0})
	}

	return phonemes
}

// wordToPhonemes converts a single word to phonemes
func (tp *TextProcessor) wordToPhonemes(word string) []Phoneme {
	word = strings.ToLower(word)
	word = regexp.MustCompile(`[^a-z]`).ReplaceAllString(word, "")

	// Check dictionary first
	if phoneSeq, exists := tp.phoneDict[word]; exists {
		var phonemes []Phoneme
		for _, phone := range phoneSeq {
			phonemes = append(phonemes, Phoneme{
				Symbol:   phone,
				Duration: 80.0, // Default duration
			})
		}
		return phonemes
	}

	// Fallback: letter-by-letter pronunciation
	return tp.letterToPhonemes(word)
}

// letterToPhonemes provides letter-by-letter fallback
func (tp *TextProcessor) letterToPhonemes(word string) []Phoneme {
	var phonemes []Phoneme
	letterToPhone := map[rune]string{
		'a': "AE", 'b': "B", 'c': "K", 'd': "D", 'e': "IH",
		'f': "F", 'g': "G", 'h': "HH", 'i': "IH", 'j': "JH",
		'k': "K", 'l': "L", 'm': "M", 'n': "N", 'o': "OW",
		'p': "P", 'q': "K", 'r': "R", 's': "S", 't': "T",
		'u': "UH", 'v': "V", 'w': "W", 'x': "K S", 'y': "Y", 'z': "Z",
	}

	for _, char := range word {
		if phone, exists := letterToPhone[char]; exists {
			if strings.Contains(phone, " ") {
				// Handle multi-phoneme letters like 'x'
				for _, p := range strings.Split(phone, " ") {
					phonemes = append(phonemes, Phoneme{Symbol: p, Duration: 80.0})
				}
			} else {
				phonemes = append(phonemes, Phoneme{Symbol: phone, Duration: 80.0})
			}
		}
	}

	return phonemes
}

// Normalize methods for different normalizers

// Normalize numbers to words
func (nn *NumberNormalizer) Normalize(text string) string {
	// Simple number normalization - can be enhanced
	numberRegex := regexp.MustCompile(`\b\d+\b`)
	
	return numberRegex.ReplaceAllStringFunc(text, func(match string) string {
		// Basic number to word conversion
		switch match {
		case "0": return "zero"
		case "1": return "one"
		case "2": return "two"
		case "3": return "three"
		case "4": return "four"
		case "5": return "five"
		case "6": return "six"
		case "7": return "seven"
		case "8": return "eight"
		case "9": return "nine"
		case "10": return "ten"
		default: return match // Keep as-is for now
		}
	})
}

// Normalize abbreviations
func (an *AbbreviationNormalizer) Normalize(text string) string {
	result := text
	for abbrev, expansion := range an.abbreviations {
		// Case-insensitive replacement
		re := regexp.MustCompile(`(?i)\b` + regexp.QuoteMeta(abbrev) + `\b`)
		result = re.ReplaceAllString(result, expansion)
	}
	return result
}

// Normalize symbols
func (sn *SymbolNormalizer) Normalize(text string) string {
	symbolMap := map[string]string{
		"&":  "and",
		"@":  "at",
		"%":  "percent",
		"$":  "dollar",
		"#":  "hash",
		"+":  "plus",
		"=":  "equals",
		"<":  "less than",
		">":  "greater than",
		"/":  "slash",
		"\\": "backslash",
		"|":  "pipe",
		"*":  "asterisk",
		"^":  "caret",
		"~":  "tilde",
	}

	result := text
	for symbol, word := range symbolMap {
		result = strings.ReplaceAll(result, symbol, " "+word+" ")
	}

	// Clean up extra spaces
	result = regexp.MustCompile(`\s+`).ReplaceAllString(result, " ")
	return strings.TrimSpace(result)
}

// makeBasicPhonemeDict creates a basic phoneme dictionary
func makeBasicPhonemeDict() map[string][]string {
	return map[string][]string{
		"hello":  {"HH", "AH", "L", "OW"},
		"world":  {"W", "ER", "L", "D"},
		"the":    {"DH", "AH"},
		"and":    {"AE", "N", "D"},
		"a":      {"AH"},
		"an":     {"AE", "N"},
		"is":     {"IH", "Z"},
		"are":    {"AA", "R"},
		"was":    {"W", "AH", "Z"},
		"were":   {"W", "ER"},
		"have":   {"HH", "AE", "V"},
		"has":    {"HH", "AE", "Z"},
		"had":    {"HH", "AE", "D"},
		"will":   {"W", "IH", "L"},
		"would":  {"W", "UH", "D"},
		"could":  {"K", "UH", "D"},
		"should": {"SH", "UH", "D"},
		"can":    {"K", "AE", "N"},
		"cannot": {"K", "AE", "N", "AA", "T"},
		"with":   {"W", "IH", "TH"},
		"this":   {"DH", "IH", "S"},
		"that":   {"DH", "AE", "T"},
		"these":  {"DH", "IY", "Z"},
		"those":  {"DH", "OW", "Z"},
		"for":    {"F", "ER"},
		"from":   {"F", "R", "AH", "M"},
		"to":     {"T", "UW"},
		"in":     {"IH", "N"},
		"on":     {"AA", "N"},
		"at":     {"AE", "T"},
		"by":     {"B", "AY"},
		"of":     {"AH", "V"},
		"as":     {"AE", "Z"},
		"but":    {"B", "AH", "T"},
		"or":     {"ER"},
		"not":    {"N", "AA", "T"},
		"it":     {"IH", "T"},
		"be":     {"B", "IY"},
		"do":     {"D", "UW"},
		"go":     {"G", "OW"},
		"get":    {"G", "EH", "T"},
		"make":   {"M", "EY", "K"},
		"take":   {"T", "EY", "K"},
		"come":   {"K", "AH", "M"},
		"give":   {"G", "IH", "V"},
		"know":   {"N", "OW"},
		"think":  {"TH", "IH", "NG", "K"},
		"see":    {"S", "IY"},
		"look":   {"L", "UH", "K"},
		"use":    {"Y", "UW", "Z"},
		"find":   {"F", "AY", "N", "D"},
		"work":   {"W", "ER", "K"},
		"say":    {"S", "EY"},
		"tell":   {"T", "EH", "L"},
		"ask":    {"AE", "S", "K"},
		"try":    {"T", "R", "AY"},
		"need":   {"N", "IY", "D"},
		"want":   {"W", "AA", "N", "T"},
		"like":   {"L", "AY", "K"},
		"love":   {"L", "AH", "V"},
		"help":   {"HH", "EH", "L", "P"},
		"good":   {"G", "UH", "D"},
		"bad":    {"B", "AE", "D"},
		"new":    {"N", "UW"},
		"old":    {"OW", "L", "D"},
		"big":    {"B", "IH", "G"},
		"small":  {"S", "M", "AO", "L"},
		"long":   {"L", "AO", "NG"},
		"short":  {"SH", "AO", "R", "T"},
		"high":   {"HH", "AY"},
		"low":    {"L", "OW"},
		"right":  {"R", "AY", "T"},
		"left":   {"L", "EH", "F", "T"},
		"first":  {"F", "ER", "S", "T"},
		"last":   {"L", "AE", "S", "T"},
		"next":   {"N", "EH", "K", "S", "T"},
		"other":  {"AH", "DH", "ER"},
		"same":   {"S", "EY", "M"},
		"different": {"D", "IH", "F", "ER", "AH", "N", "T"},
		"important": {"IH", "M", "P", "AO", "R", "T", "AH", "N", "T"},
		"little": {"L", "IH", "T", "AH", "L"},
		"great":  {"G", "R", "EY", "T"},
	}
}

// makeAbbreviationDict creates a basic abbreviation dictionary
func makeAbbreviationDict() map[string]string {
	return map[string]string{
		"Dr.":   "Doctor",
		"Mr.":   "Mister",
		"Mrs.":  "Missus",
		"Ms.":   "Miss",
		"Prof.": "Professor",
		"St.":   "Saint",
		"Ave.":  "Avenue",
		"Blvd.": "Boulevard",
		"Rd.":   "Road",
		"St":    "Street",
		"Inc.":  "Incorporated",
		"Corp.": "Corporation",
		"Ltd.":  "Limited",
		"Co.":   "Company",
		"etc.":  "etcetera",
		"vs.":   "versus",
		"i.e.":  "that is",
		"e.g.":  "for example",
		"cf.":   "compare",
		"ca.":   "circa",
		"Vol.":  "Volume",
		"No.":   "Number",
		"pp.":   "pages",
		"Fig.":  "Figure",
		"Ref.":  "Reference",
		"USA":   "United States of America",
		"UK":    "United Kingdom",
		"CPU":   "C P U",
		"GPU":   "G P U",
		"API":   "A P I",
		"URL":   "U R L",
		"HTTP":  "H T T P",
		"HTML":  "H T M L",
		"XML":   "X M L",
		"JSON":  "J S O N",
		"PDF":   "P D F",
		"FAQ":   "F A Q",
		"CEO":   "C E O",
		"CTO":   "C T O",
		"CFO":   "C F O",
	}
}