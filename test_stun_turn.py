"""
Test STUN/TURN connectivity từ VPS - UDP + TCP version.
Chạy: python test_stun_turn.py
"""

import socket
import struct
import hashlib
import hmac
import os
import ssl
import time

MAGIC_COOKIE = 0x2112A442

# ── Credentials metered.ca ──────────────────────────────────
TURN_USER = "cc84af1584a60af7a8aae396"
TURN_PASS = "DYooULJ9XzeVTjwa"


# ════════════════════════════════════════════════════════════
# HELPERS
# ════════════════════════════════════════════════════════════

def pad4(b: bytes) -> bytes:
    return b + b'\x00' * ((4 - len(b) % 4) % 4)


def build_stun_binding() -> bytes:
    txn_id = os.urandom(12)
    return struct.pack("!HHI", 0x0001, 0, MAGIC_COOKIE) + txn_id


def parse_mapped_address(data: bytes):
    """Trả về (ip, port) hoặc None"""
    if len(data) < 20:
        return None
    msg_len = struct.unpack("!H", data[2:4])[0]
    offset = 20
    while offset < 20 + msg_len:
        if offset + 4 > len(data):
            break
        atype, alen = struct.unpack("!HH", data[offset:offset + 4])
        val = data[offset + 4: offset + 4 + alen]
        offset += 4 + alen + ((4 - alen % 4) % 4)

        if atype == 0x0020 and len(val) >= 8:  # XOR-MAPPED-ADDRESS
            xport = struct.unpack("!H", val[2:4])[0] ^ (MAGIC_COOKIE >> 16)
            xip   = struct.unpack("!I", val[4:8])[0] ^ MAGIC_COOKIE
            return socket.inet_ntoa(struct.pack("!I", xip)), xport
        if atype == 0x0001 and len(val) >= 8:  # MAPPED-ADDRESS
            port = struct.unpack("!H", val[2:4])[0]
            ip   = socket.inet_ntoa(val[4:8])
            return ip, port
    return None


def build_turn_allocate_no_auth() -> bytes:
    txn_id = os.urandom(12)
    attr = struct.pack("!HH", 0x0019, 4) + struct.pack("!BBBB", 17, 0, 0, 0)
    return struct.pack("!HHI", 0x0003, len(attr), MAGIC_COOKIE) + txn_id + attr, txn_id


def build_turn_allocate_auth(nonce: str, realm: str, username: str, credential: str) -> bytes:
    txn_id = os.urandom(12)
    a = b""
    a += struct.pack("!HH", 0x0019, 4) + struct.pack("!BBBB", 17, 0, 0, 0)
    for atype, val in [(0x0015, nonce.encode()), (0x0014, realm.encode()), (0x0006, username.encode())]:
        a += struct.pack("!HH", atype, len(val)) + pad4(val)

    placeholder = struct.pack("!HH", 0x0008, 20) + b'\x00' * 20
    msg_for_hmac = struct.pack("!HHI", 0x0003, len(a) + 24, MAGIC_COOKIE) + txn_id + a + placeholder
    ha1 = hashlib.md5(f"{username}:{realm}:{credential}".encode()).digest()
    integrity = hmac.new(ha1, msg_for_hmac[:-24], hashlib.sha1).digest()

    return struct.pack("!HHI", 0x0003, len(a) + 24, MAGIC_COOKIE) + txn_id + a \
           + struct.pack("!HH", 0x0008, 20) + integrity


def parse_turn_nonce_realm(data: bytes):
    msg_len = struct.unpack("!H", data[2:4])[0]
    offset = 20
    attrs = {}
    while offset < 20 + msg_len:
        if offset + 4 > len(data): break
        atype, alen = struct.unpack("!HH", data[offset:offset + 4])
        attrs[atype] = data[offset + 4: offset + 4 + alen]
        offset += 4 + alen + ((4 - alen % 4) % 4)
    nonce = attrs.get(0x0015, b"").decode(errors='replace')
    realm = attrs.get(0x0014, b"").decode(errors='replace')
    return nonce, realm


def parse_relay_ip(data: bytes):
    msg_len = struct.unpack("!H", data[2:4])[0]
    offset = 20
    while offset < 20 + msg_len:
        if offset + 4 > len(data): break
        atype, alen = struct.unpack("!HH", data[offset:offset + 4])
        val = data[offset + 4: offset + 4 + alen]
        offset += 4 + alen + ((4 - alen % 4) % 4)
        if atype == 0x0016 and len(val) >= 8:  # XOR-RELAYED-ADDRESS
            rport = struct.unpack("!H", val[2:4])[0] ^ (MAGIC_COOKIE >> 16)
            rip   = struct.unpack("!I", val[4:8])[0] ^ MAGIC_COOKIE
            return socket.inet_ntoa(struct.pack("!I", rip)), rport
    return None


# ════════════════════════════════════════════════════════════
# UDP TESTS
# ════════════════════════════════════════════════════════════

def stun_udp(server, port=3478):
    print(f"    UDP STUN {server}:{port} ...", end=" ", flush=True)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(5)
    try:
        sock.sendto(build_stun_binding(), (server, port))
        data, _ = sock.recvfrom(1024)
        if struct.unpack("!H", data[:2])[0] != 0x0101:
            print("BAD RESPONSE"); return False
        result = parse_mapped_address(data)
        if result:
            print(f"OK  →  public {result[0]}:{result[1]}")
            return True
        print("NO ADDRESS"); return False
    except socket.timeout:
        print("TIMEOUT"); return False
    except Exception as e:
        print(f"ERROR: {e}"); return False
    finally:
        sock.close()


def turn_udp(server, port, username, credential):
    print(f"    UDP TURN {server}:{port} ...", end=" ", flush=True)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(5)
    try:
        req, _ = build_turn_allocate_no_auth()
        sock.sendto(req, (server, port))
        data, _ = sock.recvfrom(1024)
        resp_type = struct.unpack("!H", data[:2])[0]
        if resp_type == 0x0103:
            print("OK (no-auth)"); return True
        if resp_type != 0x0113:
            print(f"UNEXPECTED 0x{resp_type:04x}"); return False

        nonce, realm = parse_turn_nonce_realm(data)
        print(f"401 realm={realm} ...", end=" ", flush=True)

        auth_req = build_turn_allocate_auth(nonce, realm, username, credential)
        sock.sendto(auth_req, (server, port))
        data2, _ = sock.recvfrom(1024)
        resp2 = struct.unpack("!H", data2[:2])[0]
        if resp2 == 0x0103:
            relay = parse_relay_ip(data2)
            if relay: print(f"OK  →  relay {relay[0]}:{relay[1]}")
            else:     print("OK")
            return True
        print(f"FAIL 0x{resp2:04x}"); return False
    except socket.timeout:
        print("TIMEOUT"); return False
    except Exception as e:
        print(f"ERROR: {e}"); return False
    finally:
        sock.close()


# ════════════════════════════════════════════════════════════
# TCP TESTS
# ════════════════════════════════════════════════════════════

def stun_tcp(server, port=3478, use_tls=False):
    label = "TLS" if use_tls else "TCP"
    print(f"    {label} STUN {server}:{port} ...", end=" ", flush=True)
    try:
        raw = socket.create_connection((server, port), timeout=5)
        if use_tls:
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            sock = ctx.wrap_socket(raw, server_hostname=server)
        else:
            sock = raw
        sock.settimeout(5)

        msg = build_stun_binding()
        # STUN over TCP cần framing RFC 4571: 2 byte length prefix
        framed = struct.pack("!H", len(msg)) + msg
        sock.sendall(framed)

        # Đọc response
        header = b""
        while len(header) < 2:
            header += sock.recv(2 - len(header))
        rlen = struct.unpack("!H", header)[0]
        data = b""
        while len(data) < rlen:
            data += sock.recv(rlen - len(data))
        sock.close()

        if len(data) < 2 or struct.unpack("!H", data[:2])[0] != 0x0101:
            print("BAD RESPONSE"); return False
        result = parse_mapped_address(data)
        if result:
            print(f"OK  →  public {result[0]}:{result[1]}")
            return True
        print("NO ADDRESS"); return False
    except socket.timeout:
        print("TIMEOUT"); return False
    except ConnectionRefusedError:
        print("REFUSED"); return False
    except Exception as e:
        print(f"ERROR: {e}"); return False


def turn_tcp(server, port, username, credential, use_tls=False):
    label = "TURNS/TLS" if use_tls else "TCP TURN"
    print(f"    {label} {server}:{port} ...", end=" ", flush=True)
    try:
        raw = socket.create_connection((server, port), timeout=8)
        if use_tls:
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            sock = ctx.wrap_socket(raw, server_hostname=server)
        else:
            sock = raw
        sock.settimeout(8)

        def send_recv(msg):
            framed = struct.pack("!H", len(msg)) + msg
            sock.sendall(framed)
            hdr = b""
            while len(hdr) < 2:
                hdr += sock.recv(2 - len(hdr))
            rlen = struct.unpack("!H", hdr)[0]
            buf = b""
            while len(buf) < rlen:
                buf += sock.recv(rlen - len(buf))
            return buf

        # Step 1: no-auth allocate
        req, _ = build_turn_allocate_no_auth()
        data = send_recv(req)
        resp_type = struct.unpack("!H", data[:2])[0]
        if resp_type == 0x0103:
            print("OK (no-auth)"); sock.close(); return True
        if resp_type != 0x0113:
            print(f"UNEXPECTED 0x{resp_type:04x}"); sock.close(); return False

        nonce, realm = parse_turn_nonce_realm(data)
        print(f"401 realm={realm} ...", end=" ", flush=True)

        # Step 2: auth allocate
        auth_req = build_turn_allocate_auth(nonce, realm, username, credential)
        data2 = send_recv(auth_req)
        resp2 = struct.unpack("!H", data2[:2])[0]
        sock.close()
        if resp2 == 0x0103:
            relay = parse_relay_ip(data2)
            if relay: print(f"OK  →  relay {relay[0]}:{relay[1]}")
            else:     print("OK")
            return True
        print(f"FAIL 0x{resp2:04x}"); return False
    except socket.timeout:
        print("TIMEOUT"); return False
    except ConnectionRefusedError:
        print("REFUSED"); return False
    except Exception as e:
        print(f"ERROR: {e}"); return False


# ════════════════════════════════════════════════════════════
# TCP REACHABILITY (nhanh)
# ════════════════════════════════════════════════════════════

def tcp_reach(host, port):
    print(f"    TCP connect {host}:{port} ...", end=" ", flush=True)
    try:
        s = socket.create_connection((host, port), timeout=5)
        s.close()
        print("OK")
        return True
    except Exception as e:
        print(f"FAIL ({e})")
        return False


# ════════════════════════════════════════════════════════════
# MAIN
# ════════════════════════════════════════════════════════════

def main():
    print("=" * 62)
    print("  STUN/TURN CONNECTIVITY TEST  (UDP + TCP + TLS)")
    print("=" * 62)

    results = {}

    # ── 1. TCP reachability ────────────────────────────────
    print("\n[1] TCP Reachability (tầng cơ bản nhất)")
    for host, port in [
        ("asia.relay.metered.ca", 80),
        ("asia.relay.metered.ca", 443),
        ("asia.relay.metered.ca", 3478),
        ("stun.l.google.com", 19302),
    ]:
        results[f"TCP-reach {host}:{port}"] = tcp_reach(host, port)

    # ── 2. STUN UDP ────────────────────────────────────────
    print("\n[2] STUN UDP")
    for srv, port in [("stun.l.google.com", 19302), ("stun.relay.metered.ca", 3478)]:
        ok = stun_udp(srv, port)
        results[f"STUN-UDP {srv}:{port}"] = ok

    # ── 3. STUN TCP ────────────────────────────────────────
    print("\n[3] STUN TCP (bypass UDP block)")
    for srv, port, tls in [
        ("stun.relay.metered.ca", 3478, False),
        ("stun.relay.metered.ca", 443,  True),
    ]:
        ok = stun_tcp(srv, port, use_tls=tls)
        results[f"STUN-{'TLS' if tls else 'TCP'} {srv}:{port}"] = ok

    # ── 4. TURN UDP ────────────────────────────────────────
    print("\n[4] TURN UDP")
    for srv, port in [
        ("asia.relay.metered.ca", 3478),
        ("asia.relay.metered.ca", 80),
    ]:
        ok = turn_udp(srv, port, TURN_USER, TURN_PASS)
        results[f"TURN-UDP {srv}:{port}"] = ok

    # ── 5. TURN TCP / TLS ──────────────────────────────────
    print("\n[5] TURN TCP / TLS  ← quan trọng nhất nếu UDP fail")
    for srv, port, tls in [
        ("asia.relay.metered.ca", 443,  True),   # turns: TLS
        ("asia.relay.metered.ca", 80,   False),  # turn:  TCP
        ("asia.relay.metered.ca", 3478, False),  # turn:  TCP alt
    ]:
        ok = turn_tcp(srv, port, TURN_USER, TURN_PASS, use_tls=tls)
        results[f"TURN-{'TLS' if tls else 'TCP'} {srv}:{port}"] = ok

    # ── Summary ────────────────────────────────────────────
    print("\n" + "=" * 62)
    print("  SUMMARY")
    print("=" * 62)
    for name, ok in results.items():
        print(f"  {'PASS' if ok else 'FAIL'}  {name}")

    stun_ok  = any(v for k, v in results.items() if "STUN" in k)
    turn_ok  = any(v for k, v in results.items() if "TURN" in k)
    tcp_ok   = any(v for k, v in results.items() if "TCP-reach" in k and v)
    turn_tcp_ok = any(v for k, v in results.items() if "TURN-TCP" in k or "TURN-TLS" in k)

    print("\n  ── Chẩn đoán ──")
    if not tcp_ok:
        print("  ❌ TCP cũng không reach được → ISP/Firewall chặn outbound nặng")
    elif not stun_ok and not turn_ok:
        if tcp_ok:
            print("  ⚠️  UDP hoàn toàn bị chặn, TCP hoạt động")
            print("  → Dùng TURN over TCP/TLS trong pipecat config")
        else:
            print("  ❌ Cả UDP lẫn TCP đều fail → Firewall quá chặt")
    if turn_tcp_ok:
        print("  ✅ TURN TCP/TLS OK → Dùng config bên dưới cho pipecat:")
        print("""
  ICE_SERVERS = [
      IceServer(
          urls="turns:asia.relay.metered.ca:443?transport=tcp",
          username="cc84af1584a60af7a8aae396",
          credential="DYooULJ9XzeVTjwa"
      ),
      IceServer(
          urls="turn:asia.relay.metered.ca:80?transport=tcp",
          username="cc84af1584a60af7a8aae396",
          credential="DYooULJ9XzeVTjwa"
      ),
  ]""")
    elif turn_ok:
        print("  ✅ TURN UDP OK → Dùng config UDP bình thường")
    else:
        print("  ❌ TURN ALL FAIL → Xem lỗi cụ thể từng dòng bên trên")


if __name__ == "__main__":
    main()