package main

import (
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestDirectViewer(t *testing.T) {
	a := access{settings: settings{Origin: "https://fixture.test"}, proxy: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) })}
	for _, tc := range []struct {
		method, url string
		status      int
	}{
		{"GET", "https://fixture.test/", 204}, {"GET", "https://fixture.test/api/status", 204}, {"POST", "https://fixture.test/pair", 405}, {"GET", "https://other.test/", 403},
	} {
		w := httptest.NewRecorder()
		a.ServeHTTP(w, httptest.NewRequest(tc.method, tc.url, nil))
		if w.Code != tc.status || len(w.Result().Cookies()) != 0 {
			t.Errorf("unexpected response for %s %s: %d", tc.method, tc.url, w.Code)
		}
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
