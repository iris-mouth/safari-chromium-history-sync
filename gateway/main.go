// The gateway owns TLS and Tailscale owner verification. The sandboxed history reader
// only receives requests over a private, inherited Unix listener.
package main

/*
#cgo LDFLAGS: -framework Security -framework CoreFoundation
#include <Security/Security.h>
#include <libproc.h>
#include <arpa/inet.h>
#include <stdlib.h>
static int tailscalePeer(int pid) {
    CFNumberRef value = CFNumberCreate(NULL, kCFNumberIntType, &pid);
    const void *keys[] = { kSecGuestAttributePid };
    const void *values[] = { value };
    CFDictionaryRef attrs = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    SecCodeRef code = NULL;
    SecRequirementRef requirement = NULL;
    OSStatus status = SecCodeCopyGuestWithAttributes(NULL, attrs, kSecCSDefaultFlags, &code);
    if (status == errSecSuccess)
        status = SecRequirementCreateWithString(CFSTR("anchor apple generic and identifier \"io.tailscale.ipn.macos.network-extension\" and certificate leaf[field.1.2.840.113635.100.6.1.9] exists"), 0, &requirement);
    if (status == errSecSuccess)
        status = SecCodeCheckValidity(code, kSecCSDefaultFlags, requirement);
    if (requirement) CFRelease(requirement);
    if (code) CFRelease(code);
    CFRelease(attrs);
    CFRelease(value);
    return status == errSecSuccess;
}
// Match both loopback endpoints on a socket held by the signed extension.
static int ownsForward(int pid, int senderPort, int listenerPort) {
    int bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
    if (bytes <= 0) return 0;
    bytes += 32 * sizeof(struct proc_fdinfo);
    struct proc_fdinfo *fds = malloc(bytes);
    if (!fds) return 0;
    int n = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, bytes);
    int match = 0;
    for (int i = 0; i < n / (int)sizeof(*fds); i++) {
        if (fds[i].proc_fdtype != PROX_FDTYPE_SOCKET) continue;
        struct socket_fdinfo fd;
        if (proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDSOCKETINFO, &fd, sizeof(fd)) != sizeof(fd)) continue;
        if (fd.psi.soi_kind != SOCKINFO_TCP || fd.psi.soi_family != AF_INET) continue;
        struct in_sockinfo *ip = &fd.psi.soi_proto.pri_tcp.tcpsi_ini;
        if (ntohs(ip->insi_lport) == senderPort && ntohs(ip->insi_fport) == listenerPort &&
            ntohl(ip->insi_laddr.ina_46.i46a_addr4.s_addr) == INADDR_LOOPBACK &&
            ntohl(ip->insi_faddr.ina_46.i46a_addr4.s_addr) == INADDR_LOOPBACK) {
            match = 1;
            break;
        }
    }
    free(fds);
    return match && tailscalePeer(pid);
}
*/
import "C"

import (
	"bufio"
	"bytes"
	"context"
	"crypto/tls"
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const cli = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"

type settings struct{ Origin, Owner, Viewer, Database, Assets string }

type readinessReply struct {
	Request uint64 `json:"request"`
	Ready   bool   `json:"ready"`
}

func viewerReady(ctx context.Context, client *http.Client, owner string) bool {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, "http://localhost/api/ready", nil)
	if err != nil {
		return false
	}
	request.Header.Set("Tailscale-User-Login", owner)
	response, err := client.Do(request)
	if err != nil {
		return false
	}
	defer response.Body.Close()
	_, err = io.Copy(io.Discard, io.LimitReader(response.Body, 16*1024))
	return err == nil && response.StatusCode == http.StatusOK
}

func reportReadiness(input io.Reader, output io.Writer, client *http.Client, owner string) {
	requests := bufio.NewScanner(input)
	requests.Buffer(make([]byte, 64), 64)
	encoder := json.NewEncoder(output)
	for requests.Scan() {
		request, err := strconv.ParseUint(requests.Text(), 10, 64)
		if err != nil {
			continue
		}
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		ready := viewerReady(ctx, client, owner)
		cancel()
		if encoder.Encode(readinessReply{Request: request, Ready: ready}) != nil {
			return
		}
	}
}

func fromTailscale(c net.Conn) bool {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	candidates, err := exec.CommandContext(ctx, "/usr/bin/pgrep", "-x", "IPNExtension").Output()
	if err != nil {
		return false
	}
	remote := c.RemoteAddr().(*net.TCPAddr)
	local := c.LocalAddr().(*net.TCPAddr)
	for _, field := range strings.Fields(string(candidates)) {
		pid, err := strconv.Atoi(field)
		if err == nil && C.ownsForward(C.int(pid), C.int(remote.Port), C.int(local.Port)) != 0 {
			return true
		}
	}
	return false
}

func ts(ctx context.Context, args ...string) ([]byte, error) {
	c := exec.CommandContext(ctx, cli, args...)
	c.Env = append(os.Environ(), "TAILSCALE_BE_CLI=1")
	return c.Output()
}
func currentOwner(ctx context.Context, ip string) (string, error) {
	b, e := ts(ctx, "whois", "--json", ip)
	if e != nil {
		return "", e
	}
	var data struct {
		UserProfile struct{ LoginName string }
		Node        struct{ Tags []string }
	}
	e = json.Unmarshal(b, &data)
	if e != nil || len(data.Node.Tags) > 0 {
		return "", errors.New("no user identity")
	}
	return data.UserProfile.LoginName, nil
}

// Serve prepends a PROXY v2 IPv4 or IPv6 stream address before the TLS handshake.
func peer(c net.Conn) (string, error) {
	var h [16]byte
	if _, e := io.ReadFull(c, h[:]); e != nil {
		return "", e
	}
	if !bytes.Equal(h[:12], []byte("\r\n\r\n\x00\r\nQUIT\n")) || h[12] != 0x21 {
		return "", errors.New("invalid proxy header")
	}
	n := int(binary.BigEndian.Uint16(h[14:]))
	width := 0
	switch h[13] {
	case 0x11:
		width = 4
	case 0x21:
		width = 16
	default:
		return "", errors.New("invalid address")
	}
	if n < width*2+4 || n > 1024 {
		return "", errors.New("invalid address length")
	}
	b := make([]byte, n)
	if _, e := io.ReadFull(c, b); e != nil {
		return "", e
	}
	return net.IP(b[:width]).String(), nil
}

type access struct {
	settings
	proxy http.Handler
}

func (a *access) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	origin, _ := url.Parse(a.Origin)
	if !strings.EqualFold(r.Host, origin.Host) {
		http.Error(w, "Invalid host", 403)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Referrer-Policy", "no-referrer")
	if r.Method != http.MethodGet {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if r.URL.Path == "/api/ready" {
		http.NotFound(w, r)
		return
	}
	a.proxy.ServeHTTP(w, r)
}
func run() error {
	var cfg settings
	var port int
	flag.StringVar(&cfg.Origin, "origin", "", "")
	flag.StringVar(&cfg.Owner, "owner", "", "")
	flag.StringVar(&cfg.Viewer, "viewer", "", "")
	flag.StringVar(&cfg.Database, "database", "", "")
	flag.StringVar(&cfg.Assets, "assets", "", "")
	flag.IntVar(&port, "port", 8767, "")
	flag.Parse()
	u, e := url.Parse(cfg.Origin)
	if e != nil || u.Scheme != "https" || u.Hostname() == "" || cfg.Owner == "" {
		return errors.New("invalid settings")
	}
	cfg.Origin = "https://" + u.Host
	syscall.Umask(0077)
	work, e := os.MkdirTemp("/private/tmp", "schs-")
	if e != nil {
		return e
	}
	defer os.RemoveAll(work)
	sock := filepath.Join(work, "view.sock")
	backend, e := net.ListenUnix("unix", &net.UnixAddr{Name: sock, Net: "unix"})
	if e != nil {
		return e
	}
	defer backend.Close()
	file, e := backend.File()
	if e != nil {
		return e
	}
	defer file.Close()
	child := exec.Command(cfg.Viewer, "--listen-fd", "3", "--database", cfg.Database, "--owner", cfg.Owner, "--assets", cfg.Assets, "--owned-stdin")
	child.ExtraFiles = []*os.File{file}
	pipe, e := child.StdinPipe()
	if e != nil {
		return e
	}
	defer pipe.Close()
	if e = child.Start(); e != nil {
		return e
	}
	defer child.Process.Kill()
	stopped := make(chan struct{}, 1)
	go func() { child.Wait(); stopped <- struct{}{} }()
	target := &url.URL{Scheme: "http", Host: "localhost"}
	transport := &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "unix", sock)
	}}
	defer transport.CloseIdleConnections()
	proxy := &httputil.ReverseProxy{Rewrite: func(r *httputil.ProxyRequest) {
		r.SetURL(target)
		r.Out.Header.Del("Cookie")
		r.Out.Header.Set("Tailscale-User-Login", cfg.Owner)
	}, Transport: transport}
	a := &access{settings: cfg, proxy: proxy}
	var mu sync.Mutex
	var cert *tls.Certificate
	getCert := func(*tls.ClientHelloInfo) (*tls.Certificate, error) {
		mu.Lock()
		defer mu.Unlock()
		if cert != nil && time.Until(cert.Leaf.NotAfter) > 24*time.Hour {
			return cert, nil
		}
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		pem, e := ts(ctx, "cert", "--cert-file=-", "--key-file=-", u.Hostname())
		if e != nil {
			return nil, e
		}
		pair, e := tls.X509KeyPair(pem, pem)
		clear(pem)
		if e != nil {
			return nil, e
		}
		cert = &pair
		return cert, nil
	}
	tlsConfig := &tls.Config{MinVersion: tls.VersionTLS12, GetCertificate: getCert}
	ln, e := net.Listen("tcp4", fmt.Sprintf("127.0.0.1:%d", port))
	if e != nil {
		return e
	}
	defer ln.Close()
	requests := make(chan net.Conn)
	done := make(chan struct{})

	srv := http.Server{Handler: a, ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 20 * time.Second, MaxHeaderBytes: 32768}
	l := &verifiedListener{ln, requests, done}
	go srv.Serve(l)
	defer func() { close(done); srv.Close() }()
	go func() {
		client := &http.Client{Transport: transport, CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
			return http.ErrUseLastResponse
		}}
		reportReadiness(os.Stdin, os.Stdout, client, cfg.Owner)
		stopped <- struct{}{}
	}()
	slots := make(chan struct{}, 32)
	go func() {
		for {
			c, e := ln.Accept()
			if e != nil {
				return
			}
			select {
			case slots <- struct{}{}:
			default:
				c.Close()
				continue
			}
			go func() {
				defer func() { <-slots }()
				c.SetDeadline(time.Now().Add(12 * time.Second))
				if !fromTailscale(c) {
					c.Close()
					return
				}
				ip, e := peer(c)
				if e != nil {
					c.Close()
					return
				}
				ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
				owner, e := currentOwner(ctx, ip)
				cancel()
				if e != nil || owner != cfg.Owner {
					c.Close()
					return
				}
				c.SetDeadline(time.Time{})
				select {
				case requests <- tls.Server(c, tlsConfig):
				case <-done:
					c.Close()
				}
			}()
		}
	}()
	<-stopped
	return nil
}

type verifiedListener struct {
	net.Listener
	conns chan net.Conn
	done  chan struct{}
}

func (l *verifiedListener) Accept() (net.Conn, error) {
	select {
	case c := <-l.conns:
		return c, nil
	case <-l.done:
		return nil, net.ErrClosed
	}
}
func main() {
	if e := run(); e != nil {
		fmt.Fprintln(os.Stderr, "Viewer gateway unavailable")
		os.Exit(1)
	}
}
