"""Local HTTPS regression for the managed engine's macOS native trust policy.

Only disposable hosts may install the temporary localhost-only test anchor.
The real engine must accept it through SecTrust, reject the old CA-file
override, and still reject an untrusted chain and a mismatched hostname.
"""
import hashlib
import http.server
import pathlib
import ssl
import subprocess
import threading
import uuid

from local_signing import require_disposable_test_host


PAYLOAD = b"ChopChop native macOS TLS verification fixture\n" * 32


class TLSHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        start, end = 0, len(PAYLOAD) - 1
        requested = self.headers.get("Range")
        if requested:
            first, last = requested.removeprefix("bytes=").split("-", 1)
            start = int(first)
            if last:
                end = min(end, int(last))
        self.send_response(206 if requested else 200)
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("Accept-Ranges", "bytes")
        if requested:
            self.send_header("Content-Range", f"bytes {start}-{end}/{len(PAYLOAD)}")
        self.end_headers()
        self.wfile.write(PAYLOAD[start:end + 1])

    def log_message(self, *_args):
        pass


def run_native_tls_checks(root, rpc, wait_for):
    require_disposable_test_host()
    directory = pathlib.Path(root) / "native-tls"
    directory.mkdir()
    name = "ChopChop TLS fixture " + uuid.uuid4().hex
    ca = directory / "ca.pem"
    ca_key = directory / "ca.key"
    leaf = directory / "server.pem"
    leaf_key = directory / "server.key"
    request = directory / "server.csr"
    config = directory / "certificates.cnf"
    config.write_text("""[req]
distinguished_name = dn
[dn]
[ca]
basicConstraints = critical,CA:TRUE
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
[server]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:localhost
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
""")

    def run(*args, check=True):
        return subprocess.run([str(arg) for arg in args], check=check,
                              capture_output=True, text=True, timeout=30)

    run("/usr/bin/openssl", "req", "-new", "-x509", "-newkey", "rsa:2048",
        "-nodes", "-sha256", "-days", "2", "-subj", "/CN=" + name,
        "-config", config, "-extensions", "ca", "-keyout", ca_key, "-out", ca)
    run("/usr/bin/openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes",
        "-sha256", "-subj", "/CN=localhost", "-config", config,
        "-keyout", leaf_key, "-out", request)
    run("/usr/bin/openssl", "x509", "-req", "-in", request, "-CA", ca,
        "-CAkey", ca_key, "-set_serial", "1", "-days", "2", "-sha256",
        "-extfile", config, "-extensions", "server", "-out", leaf)
    chain = directory / "chain.pem"
    chain.write_text(leaf.read_text() + ca.read_text())
    fingerprint = hashlib.sha1(ssl.PEM_cert_to_DER_cert(ca.read_text())).hexdigest().upper()
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(chain, leaf_key)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), TLSHandler)
    server.daemon_threads = True
    server.socket = context.wrap_socket(server.socket, server_side=True)
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    url = f"https://localhost:{server.server_port}/fixture.bin"

    def download(label, source=url, extra=None, succeeds=False):
        options = {"dir": str(directory), "out": label + ".bin", "pause": "false",
                   "check-certificate": "true", "max-tries": "1",
                   "connect-timeout": "3", "timeout": "3", **(extra or {})}
        gid = rpc("addUri", [source], options)
        result = wait_for(lambda: (task if (task := rpc("tellStatus", gid))["status"]
                                  in ("complete", "error") else None), timeout=15)
        if succeeds:
            assert result["status"] == "complete", result
            assert (directory / (label + ".bin")).read_bytes() == PAYLOAD
        else:
            assert result["status"] == "error" and result["completedLength"] == "0", result
            assert "certificate" in result.get("errorMessage", "").lower(), result
        rpc("removeDownloadResult", gid)

    trust_attempted = False
    trust_installed = False
    try:
        # This CA was just generated and has not been trusted anywhere.
        download("unknown-issuer")
        trust_attempted = True
        run("sudo", "-n", "/usr/bin/security", "add-trusted-cert", "-d",
            "-r", "trustRoot", "-p", "ssl", "-s", "localhost",
            "-k", "/Library/Keychains/System.keychain", ca)
        trust_installed = True
        run("/usr/bin/security", "verify-cert", "-p", "ssl", "-s", "localhost",
            "-L", "-c", leaf, "-c", ca)
        # A trusted native anchor is absent from the static PEM file, reproducing
        # the application's old launch policy without relying on an external site.
        download("old-static-ca", extra={"ca-certificate": "/etc/ssl/cert.pem"})
        download("native-trust", succeeds=True)
        download("wrong-hostname", source=f"https://127.0.0.1:{server.server_port}/fixture.bin")
        print("PASS native TLS: system-trusted CA accepted, old CA-file override rejected; unknown issuer and wrong hostname rejected")
    finally:
        server.shutdown()
        server.server_close()
        worker.join(timeout=5)
        if trust_attempted:
            # Remove only this unique test anchor and its certificate, even when
            # a transfer fails. No existing trust settings are replaced.
            removed = run("sudo", "-n", "/usr/bin/security", "remove-trusted-cert",
                          "-d", ca, check=False)
            deleted = run("sudo", "-n", "/usr/bin/security", "delete-certificate",
                          "-Z", fingerprint, "/Library/Keychains/System.keychain", check=False)
            if trust_installed:
                removed.check_returncode()
                deleted.check_returncode()
