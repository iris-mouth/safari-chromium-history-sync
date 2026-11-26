package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestDirectViewer(t *testing.T) {
	a := access{settings: settings{Origin: "https://fixture.test"}, proxy: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) })}
	for _, tc := range []struct {
		method, url string
		status      int
	}{
		{"GET", "https://fixture.test/", 204}, {"GET", "https://fixture.test/api/status", 204}, {"GET", "https://fixture.test/api/ready", 404}, {"POST", "https://fixture.test/pair", 405}, {"GET", "https://other.test/", 403},
	} {
		w := httptest.NewRecorder()
		a.ServeHTTP(w, httptest.NewRequest(tc.method, tc.url, nil))
		if w.Code != tc.status || len(w.Result().Cookies()) != 0 {
			t.Errorf("unexpected response for %s %s: %d", tc.method, tc.url, w.Code)
		}
	}
}

func TestReadinessReportsOnlyCurrentRequestAndResult(t *testing.T) {
	statuses := []int{http.StatusOK, http.StatusServiceUnavailable}
	client := &http.Client{Transport: readinessTransport(func(r *http.Request) (*http.Response, error) {
		if r.Method != http.MethodGet || r.URL.Path != "/api/ready" || r.Header.Get("Tailscale-User-Login") != "owner@example.test" {
			t.Error("incorrect private Viewer request")
		}
		if len(statuses) == 0 {
			t.Fatal("unexpected extra readiness request")
		}
		status := statuses[0]
		statuses = statuses[1:]
		return &http.Response{StatusCode: status, Body: io.NopCloser(strings.NewReader("Private backend data"))}, nil
	})}
	var output bytes.Buffer
	reportReadiness(strings.NewReader("7\ninvalid\n8\n"), &output, client, "owner@example.test")
	decoder := json.NewDecoder(bytes.NewReader(output.Bytes()))
	for _, want := range []readinessReply{{Request: 7, Ready: true}, {Request: 8, Ready: false}} {
		var actual readinessReply
		if err := decoder.Decode(&actual); err != nil || actual != want {
			t.Fatalf("got %+v, %v, want %+v, output %s", actual, err, want, output.String())
		}
	}
	if decoder.More() || strings.Contains(output.String(), "Private backend data") {
		t.Fatal("unexpected private data or readiness report")
	}
}

type readinessTransport func(*http.Request) (*http.Response, error)

func (probe readinessTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	return probe(r)
}

func TestReadinessTimesOut(t *testing.T) {
	client := &http.Client{Transport: readinessTransport(func(r *http.Request) (*http.Response, error) {
		<-r.Context().Done()
		return nil, r.Context().Err()
	})}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	if viewerReady(ctx, client, "owner@example.test") {
		t.Fatal("unresponsive Viewer was reported ready")
	}
}

func TestLocalClientIsNotTailscale(t *testing.T) {
	ln, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	client, err := net.Dial("tcp4", ln.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	conn, err := ln.Accept()
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if fromTailscale(conn) {
		t.Fatal("local connection treated as Tailscale")
	}
}
