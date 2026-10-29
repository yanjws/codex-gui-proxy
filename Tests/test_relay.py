"""Exercise the real Swift relay against loopback HTTP, echo and proxy servers."""
import concurrent.futures
import contextlib
import http.server
import select
import socket
import socketserver
import subprocess
import sys
import threading
import time
import uuid


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


class Origin(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.headers.get("Upgrade", "").lower() == "websocket":
            self.send_response(101)
            self.send_header("Upgrade", "websocket")
            self.send_header("Connection", "Upgrade")
            self.end_headers()
            frame = self.rfile.read(6)
            self.wfile.write(frame)
            self.wfile.flush()
            self.close_connection = True
            return
        body = (self.path + ":" + self.headers.get("Proxy-Authorization", "none")).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.headers.get("Transfer-Encoding") == "chunked":
            body = bytearray()
            while True:
                size = int(self.rfile.readline().strip(), 16)
                if not size:
                    self.rfile.readline()
                    break
                body.extend(self.rfile.read(size))
                assert self.rfile.read(2) == b"\r\n"
        else:
            body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)


class Echo(socketserver.BaseRequestHandler):
    def handle(self):
        while data := self.request.recv(65536):
            self.request.sendall(data)


def read_header(sock):
    data = bytearray()
    while b"\r\n\r\n" not in data:
        chunk = sock.recv(65536)
        if not chunk:
            raise EOFError("connection ended before headers")
        data.extend(chunk)
    head, remainder = bytes(data).split(b"\r\n\r\n", 1)
    return head, remainder


class Upstream(socketserver.BaseRequestHandler):
    lock = threading.Lock()
    requests = 0
    reject = False

    def handle(self):
        try:
            header, buffered = read_header(self.request)
            method, authority, _ = header.split(b"\r\n", 1)[0].split(b" ")
            assert method == b"CONNECT"
            host, port = authority.decode().rsplit(":", 1)
            assert host == "127.0.0.1"
            with self.lock:
                type(self).requests += 1
                reject = type(self).reject
            if reject:
                self.request.sendall(b"HTTP/1.1 407 Proxy Authentication Required\r\n\r\n")
                return
            with socket.create_connection((host, int(port)), timeout=4) as remote:
                self.request.sendall(b"HTTP/1.1 200")
                time.sleep(0.01)
                self.request.sendall(b" Connection Established\r\n\r\n")
                if buffered:
                    remote.sendall(buffered)
                readers = [self.request, remote]
                while readers:
                    ready, _, _ = select.select(readers, [], [], 8)
                    if not ready:
                        return
                    for source in ready:
                        destination = remote if source is self.request else self.request
                        data = source.recv(65536)
                        if data:
                            destination.sendall(data)
                        else:
                            readers.remove(source)
                            destination.shutdown(socket.SHUT_WR)
        except (OSError, EOFError):
            pass


@contextlib.contextmanager
def serve(handler):
    server = Server(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server.server_address[1]
    finally:
        server.shutdown()
        server.server_close()


class Driver:
    def __init__(self, binary, port=None):
        self.process = subprocess.Popen([binary] + ([str(port)] if port else []),
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        ready = self.line()
        assert ready.startswith("READY "), ready
        self.port = int(ready.split()[1])

    def line(self):
        readable, _, _ = select.select([self.process.stdout], [], [], 15)
        assert readable, "relay driver timed out"
        return self.process.stdout.readline().strip()

    def command(self, value, success=True):
        self.process.stdin.write(value + "\n")
        self.process.stdin.flush()
        result = self.line()
        assert result.startswith("OK" if success else "ERROR"), result
        return result

    def close(self):
        if self.process.poll() is None:
            self.command("stop")
        self.process.wait(timeout=5)
        assert self.process.returncode == 0


def request(port, raw):
    with socket.create_connection(("127.0.0.1", port), timeout=5) as sock:
        sock.sendall(raw)
        result = bytearray()
        while data := sock.recv(65536):
            result.extend(data)
        return bytes(result)


def tunnel(port, target, early=b""):
    sock = socket.create_connection(("127.0.0.1", port), timeout=5)
    sock.sendall(f"CONNECT 127.0.0.1:{target} HTTP/1.1\r\nHost: ignored\r\n\r\n".encode() + early)
    header, buffered = read_header(sock)
    assert header.startswith(b"HTTP/1.1 200"), header
    return sock, buffered


def receive_exact(sock, size, buffered=b""):
    data = bytearray(buffered)
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        assert chunk, "tunnel ended early"
        data.extend(chunk)
    return bytes(data)


def main(binary, model_binary):
    with serve(Origin) as origin, serve(Echo) as echo, serve(Upstream) as upstream:
        driver = Driver(binary)
        try:
            get = f"GET http://127.0.0.1:{origin}/route?q=1 HTTP/1.1\r\nHost: wrong\r\nProxy-Authorization: secret\r\n\r\n".encode()
            response = request(driver.port, get)
            assert response.endswith(b"/route?q=1:none"), response
            assert Upstream.requests == 0
            print("PASS direct HTTP routing, target rewriting and proxy credential stripping", flush=True)

            for mode in ("direct", f"proxy {upstream}"):
                driver.command(mode)
                payload = bytes(range(256)) * 2048
                sock, buffered = tunnel(driver.port, echo)
                with sock:
                    with concurrent.futures.ThreadPoolExecutor() as pool:
                        reader = pool.submit(receive_exact, sock, len(payload))
                        sock.sendall(payload)
                        assert reader.result(timeout=8) == payload
                    sock.shutdown(socket.SHUT_WR)
                    assert sock.recv(1) == b""
                sock, buffered = tunnel(driver.port, echo, b"early")
                with sock:
                    assert receive_exact(sock, 5, buffered) == b"early"
                assert request(driver.port, get).endswith(b"/route?q=1:none")
                body = b"streaming-body" * 10000
                raw = f"POST http://127.0.0.1:{origin}/ HTTP/1.1\r\nContent-Length: {len(body)}\r\n\r\n".encode() + body
                assert request(driver.port, raw).endswith(body)
                chunked = f"POST http://127.0.0.1:{origin}/ HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".encode() + b"5\r\nhello\r\n0\r\n\r\n"
                assert request(driver.port, chunked).endswith(b"hello")
                with socket.create_connection(("127.0.0.1", driver.port), timeout=5) as sock:
                    sock.sendall(f"GET http://127.0.0.1:{origin}/ws HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n".encode())
                    header, buffered = read_header(sock)
                    assert b"101" in header
                    frame = b"\x81\x04test"
                    sock.sendall(frame)
                    assert receive_exact(sock, len(frame), buffered) == frame
                print(f"PASS {mode.split()[0]} CONNECT, 512 KiB binary data, half-close, early data, POST, chunked and WebSocket upgrade", flush=True)
            assert Upstream.requests > 0

            sock, _ = tunnel(driver.port, echo)
            driver.command("direct")
            with sock:
                try:
                    assert sock.recv(1) == b""
                except ConnectionResetError:
                    pass
            before = Upstream.requests
            assert request(driver.port, get).endswith(b"/route?q=1:none")
            assert Upstream.requests == before
            print("PASS live switch closes old tunnels and new direct traffic bypasses upstream", flush=True)

            driver.command(f"proxy {driver.port}", success=False)
            assert request(driver.port, get).endswith(b"/route?q=1:none")
            malformed = [b"bad\r\n\r\n", b"GET /relative HTTP/1.1\r\n\r\n",
                         f"CONNECT 127.0.0.1:{driver.port} HTTP/1.1\r\n\r\n".encode(),
                         f"POST http://127.0.0.1:{origin}/ HTTP/1.1\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n".encode()]
            for raw in malformed:
                assert request(driver.port, raw).startswith(b"HTTP/1.1 400")
            assert request(driver.port, b"GET http://localhost/ HTTP/1.1\r\nX: " + b"x" * 66000 + b"\r\n\r\n").startswith(b"HTTP/1.1 431")
            print("PASS loop rejection, malformed requests, ambiguous framing and header size limit", flush=True)

            driver.command(f"proxy {upstream}")
            Upstream.reject = True
            assert request(driver.port, get).startswith(b"HTTP/1.1 502")
            Upstream.reject = False
            with socket.socket() as unused:
                unused.bind(("127.0.0.1", 0))
                dead_port = unused.getsockname()[1]
            driver.command(f"proxy {dead_port}")
            assert request(driver.port, get).startswith(b"HTTP/1.1 502")
            print("PASS upstream rejection and unavailable upstream fail without direct fallback", flush=True)
            driver.command("normal")
            print("PASS ordinary-launch configuration has no injected arguments or proxy environment", flush=True)
            port = driver.port
            driver.close()
            driver = Driver(binary, port)
            assert driver.port == port
            assert request(driver.port, get).endswith(b"/route?q=1:none")
            print("PASS stop/restart reclaims the same loopback port", flush=True)
        finally:
            driver.close()

        suite = "org.codex-gui-proxy.validation." + str(uuid.uuid4())
        seeded = subprocess.run([model_binary, suite, "seed", str(upstream)], check=True,
                                capture_output=True, text=True, timeout=15)
        print(seeded.stdout.strip(), flush=True)
        process = subprocess.Popen([model_binary, suite, "restore"], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, text=True)
        try:
            readable, _, _ = select.select([process.stdout], [], [], 15)
            assert readable, "model restoration timed out"
            ready = process.stdout.readline().strip()
            assert ready.startswith("READY "), ready
            assert request(int(ready.split()[1]), get).endswith(b"/route?q=1:none")
            process.stdin.write("stop\n")
            process.stdin.flush()
            process.wait(timeout=5)
            assert process.returncode == 0
            print("PASS restart restores applied proxy despite invalid saved draft; no running app is claimed", flush=True)
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
