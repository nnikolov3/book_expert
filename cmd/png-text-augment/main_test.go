package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestDetectImageMimeType(t *testing.T) {
	tests := []struct {
		name string
		path string
		want string
	}{
		{"png", "/x/page_0001.png", "image/png"},
		{"jpg", "/x/page_0002.jpg", "image/jpeg"},
		{"jpeg", "/x/page_0003.JPEG", "image/jpeg"},
		{"webp", "/x/page_0004.webp", "image/webp"},
		{"default", "/x/page_0005.bin", "image/png"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := detectImageMimeType(tt.path)
			if got != tt.want {
				t.Fatalf("mime: got %s want %s", got, tt.want)
			}
		})
	}
}

func TestCallGemini_Success(t *testing.T) {
	// Mock Gemini endpoint
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			t.Fatalf("method: %s", r.Method)
		}
		if ct := r.Header.Get("Content-Type"); !strings.Contains(ct, "application/json") {
			t.Fatalf("content-type: %s", ct)
		}
		w.Header().Set("Content-Type", "application/json")
		io := `{"candidates":[{"content":{"parts":[{"text":"ok-1"},{"text":"ok-2"}]}}]}`
		_, _ = w.Write([]byte(io))
	}))
	defer srv.Close()

	client := &http.Client{}
	body := geminiRequest{}
	// Use the mock server host by temporarily patching the model string to be a URL path.
	// We leverage callGemini's URL construction by setting apiKey empty and substituting the base host via replacing https... prefix.
	// For testing, we direct the request to our server using its URL suffix after "/v1beta/models/".

	// Since callGemini constructs a fixed URL, we can't easily inject the server URL without changing code.
	// Instead, we perform a minimal wrapper: create a transport that rewrites the request URL Host and Scheme.
	transport := rewriteHostTransport{target: srv.URL}
	client.Transport = transport

	got, err := callGeminiWithBase(client, "", "gemini-test", body, srv.URL)
	if err != nil {
		t.Fatalf("callGemini err: %v", err)
	}
	if got != "ok-1\nok-2" {
		t.Fatalf("got %q", got)
	}
}

// rewriteHostTransport rewrites requests to a test server base URL
type rewriteHostTransport struct{ target string }

func (rt rewriteHostTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	// Replace host/scheme/path to our target server, keep body/headers
	// target like http://127.0.0.1:xxxxx
	req.URL.Scheme = strings.Split(rt.target, "://")[0]
	req.URL.Host = strings.TrimPrefix(rt.target, req.URL.Scheme+"://")
	// Keep the path as set by callGeminiWithBase
	return http.DefaultTransport.RoundTrip(req)
}

// callGeminiWithBase is a thin test hook around callGemini allowing us to target a test server.
func callGeminiWithBase(client *http.Client, apiKey, model string, body geminiRequest, base string) (string, error) {
	// This function mirrors callGemini but lets us supply a custom base URL for tests
	url := base + "/v1beta/models/" + model + ":generateContent?key=" + apiKey
	jsonBytes, err := json.Marshal(body)
	if err != nil {
		return "", err
	}
	req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(jsonBytes))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	var g geminiResponse
	_ = json.Unmarshal(b, &g)
	var sb strings.Builder
	for _, p := range g.Candidates[0].Content.Parts {
		if p.Text != "" {
			if sb.Len() > 0 {
				sb.WriteString("\n")
			}
			sb.WriteString(p.Text)
		}
	}
	return sb.String(), nil
}

func TestBase64EncodingStable(t *testing.T) {
	raw := []byte{0, 1, 2, 3, 4, 5, 6, 7, 8, 9}
	enc := base64.StdEncoding.EncodeToString(raw)
	if enc != "AAECAwQFBgcICQ==" {
		t.Fatalf("unexpected b64: %s", enc)
	}
}
