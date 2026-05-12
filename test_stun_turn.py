"""
Test STUN/TURN connectivity from VPS.
Chạy trên VPS: python test_stun_turn.py
Chỉ dùng thư viện chuẩn Python (socket, struct, hashlib, hmac, os)
"""

import socket
import struct
import hashlib
import hmac
import os
import sys

MAGIC_COOKIE = 0x2112A442


def stun_binding_test(server, port=3478):
    """Test STUN Binding Request - lấy IP public"""
    print(f"\n  STUN: {server}:{port} ...")

    txn_id = os.urandom(12)
    header = struct.pack("!HHI", 0x0001, 0, MAGIC_COOKIE) + txn_id

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(5)
    try:
        sock.sendto(header, (server, port))
        data, addr = sock.recvfrom(1024)

        resp_type = struct.unpack("!H", data[:2])[0]
        if resp_type != 0x0101:
            print(f"    Response type: 0x{resp_type:04x} (expected 0x0101)")
            return None

        # Parse attributes
        offset = 20
        attrs = {}
        msg_len = struct.unpack("!H", data[2:4])[0]
        while offset < 20 + msg_len:
            atype, alen = struct.unpack("!HH", data[offset:offset+4])
            attrs[atype] = data[offset+4:offset+4+alen]
            offset += 4 + alen
            if alen % 4:
                offset += 4 - (alen % 4)

        # XOR-MAPPED-ADDRESS (0x0020)
        if 0x0020 in attrs:
            val = attrs[0x0020]
            family = val[1]
            xport = struct.unpack("!H", val[2:4])[0] ^ (MAGIC_COOKIE >> 16)
            if family == 0x01:  # IPv4
                xip = struct.unpack("!I", val[4:8])[0] ^ MAGIC_COOKIE
                ip = socket.inet_ntoa(struct.pack("!I", xip))
                print(f"    Public IP: {ip}:{xport}")
                return ip
        # MAPPED-ADDRESS (0x0001)
        elif 0x0001 in attrs:
            val = attrs[0x0001]
            family = val[1]
            port = struct.unpack("!H", val[2:4])[0]
            if family == 0x01:
                ip = socket.inet_ntoa(val[4:8])
                print(f"    Public IP: {ip}:{port}")
                return ip

        print(f"    No mapped address found in response")
        return "unknown"
    except socket.timeout:
        print(f"    TIMEOUT")
        return None
    except Exception as e:
        print(f"    Error: {e}")
        return None
    finally:
        sock.close()


def turn_allocate_test(server, port=80, username="", credential=""):
    """Test TURN Allocate - tạo relay endpoint"""
    print(f"\n  TURN: {server}:{port} (user={username[:10]}...) ...")

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(5)

    try:
        # Step 1: Allocate Request (no auth) để lấy nonce
        txn_id = os.urandom(12)
        # REQUESTED-TRANSPORT = UDP (17)
        attrs = struct.pack("!HH", 0x0019, 4) + struct.pack("!BBBB", 17, 0, 0, 0)
        msg = struct.pack("!HHI", 0x0003, len(attrs), MAGIC_COOKIE) + txn_id + attrs
        sock.sendto(msg, (server, port))

        data, addr = sock.recvfrom(1024)
        resp_type = struct.unpack("!H", data[:2])[0]

        if resp_type != 0x0113:  # Expected 401 Unauthorized
            if resp_type == 0x0103:
                print(f"    Allocate success without auth!")
                return True
            print(f"    Unexpected response: 0x{resp_type:04x}")
            return False

        # Parse nonce and realm
        msg_len = struct.unpack("!H", data[2:4])[0]
        resp_txn = data[8:20]
        offset = 20
        resp_attrs = {}
        while offset < 20 + msg_len:
            atype, alen = struct.unpack("!HH", data[offset:offset+4])
            resp_attrs[atype] = data[offset+4:offset+4+alen]
            offset += 4 + alen
            if alen % 4:
                offset += 4 - (alen % 4)

        nonce = resp_attrs.get(0x0015, b"").decode(errors='replace')
        realm = resp_attrs.get(0x0014, b"").decode(errors='replace')
        print(f"    401 OK, realm={realm}")

        # Step 2: Allocate with auth
        txn_id2 = os.urandom(12)

        def pad4(b):
            return b + b'\x00' * ((4 - len(b) % 4) % 4)

        attrs2 = b""
        # REQUESTED-TRANSPORT
        attrs2 += struct.pack("!HH", 0x0019, 4) + struct.pack("!BBBB", 17, 0, 0, 0)
        # NONCE
        nonce_b = nonce.encode()
        attrs2 += struct.pack("!HH", 0x0015, len(nonce_b)) + pad4(nonce_b)
        # REALM
        realm_b = realm.encode()
        attrs2 += struct.pack("!HH", 0x0014, len(realm_b)) + pad4(realm_b)
        # USERNAME
        user_b = username.encode()
        attrs2 += struct.pack("!HH", 0x0006, len(user_b)) + pad4(user_b)

        # Build message for HMAC (with placeholder for MESSAGE-INTEGRITY)
        integrity_placeholder = struct.pack("!HH", 0x0008, 20) + b'\x00' * 20
        msg_for_hmac = struct.pack("!HHI", 0x0003, len(attrs2) + 24, MAGIC_COOKIE) + txn_id2 + attrs2 + integrity_placeholder

        # HMAC-SHA1 with long-term credentials
        ha1 = hashlib.md5(f"{username}:{realm}:{credential}".encode()).digest()
        integrity = hmac.new(ha1, msg_for_hmac[:-24], hashlib.sha1).digest()

        final_msg = struct.pack("!HHI", 0x0003, len(attrs2) + 24, MAGIC_COOKIE) + txn_id2 + attrs2
        final_msg += struct.pack("!HH", 0x0008, 20) + integrity

        sock.sendto(final_msg, (server, port))
        data2, addr2 = sock.recvfrom(1024)
        resp_type2 = struct.unpack("!H", data2[:2])[0]

        if resp_type2 == 0x0103:  # 200 Allocate Success
            msg_len2 = struct.unpack("!H", data2[2:4])[0]
            offset2 = 20
            attrs2_resp = {}
            while offset2 < 20 + msg_len2:
                atype, alen = struct.unpack("!HH", data2[offset2:offset2+4])
                attrs2_resp[atype] = data2[offset2+4:offset2+4+alen]
                offset2 += 4 + alen
                if alen % 4:
                    offset2 += 4 - (alen % 4)

            # XOR-RELAYED-ADDRESS (0x0016)
            relayed = attrs2_resp.get(0x0016)
            if relayed:
                family = relayed[1]
                rport = struct.unpack("!H", relayed[2:4])[0] ^ (MAGIC_COOKIE >> 16)
                if family == 0x01:
                    rip = struct.unpack("!I", relayed[4:8])[0] ^ MAGIC_COOKIE
                    rip_str = socket.inet_ntoa(struct.pack("!I", rip))
                    print(f"    Relay IP: {rip_str}:{rport}")
            print(f"    TURN Allocate SUCCESS")
            return True
        else:
            # Parse error
            msg_len2 = struct.unpack("!H", data2[2:4])[0]
            offset2 = 20
            attrs2_resp = {}
            while offset2 < 20 + msg_len2:
                atype, alen = struct.unpack("!HH", data2[offset2:offset2+4])
                attrs2_resp[atype] = data2[offset2+4:offset2+4+alen]
                offset2 += 4 + alen
                if alen % 4:
                    offset2 += 4 - (alen % 4)

            err = attrs2_resp.get(0x0009, b"")
            if len(err) >= 4:
                code = err[2] * 100 + err[3]
                reason = err[4:].decode(errors='replace')
                print(f"    Error {code}: {reason}")
            else:
                print(f"    Response: 0x{resp_type2:04x}")
            return False

    except socket.timeout:
        print(f"    TIMEOUT")
        return False
    except Exception as e:
        print(f"    Error: {e}")
        import traceback
        traceback.print_exc()
        return False
    finally:
        sock.close()


def port_reachability_test():
    """Test xem các port STUN/TURN có reach được không"""
    print("\n  Port reachability:")
    targets = [
        ("stun.relay.metered.ca", 80, "STUN"),
        ("stun.relay.metered.ca", 3478, "STUN alt"),
        ("asia.relay.metered.ca", 80, "TURN"),
        ("asia.relay.metered.ca", 443, "TURN TLS"),
        ("asia.relay.metered.ca", 3478, "TURN alt"),
    ]
    for host, port, label in targets:
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            sock.settimeout(3)
            sock.sendto(b'\x00', (host, port))
            sock.close()
            print(f"    {label} {host}:{port} - UDP send OK")
        except socket.timeout:
            print(f"    {label} {host}:{port} - TIMEOUT")
        except Exception as e:
            print(f"    {label} {host}:{port} - {e}")


def main():
    print("=" * 60)
    print("  STUN/TURN CONNECTIVITY TEST FROM VPS")
    print("=" * 60)

    results = {}

    # Test port reachability
    port_reachability_test()

    # Test STUN
    print("\n" + "=" * 60)
    print("  TEST 1: STUN Binding")
    print("=" * 60)
    for server in ["stun.relay.metered.ca", "stun.l.google.com"]:
        for port in [80, 3478, 19302]:
            result = stun_binding_test(server, port)
            if result:
                results[f"STUN {server}:{port}"] = True
                break
            results[f"STUN {server}:{port}"] = False

    # Test TURN
    print("\n" + "=" * 60)
    print("  TEST 2: TURN Allocate")
    print("=" * 60)
    turn_servers = [
        ("asia.relay.metered.ca", 80),
        ("asia.relay.metered.ca", 443),
        ("asia.relay.metered.ca", 3478),
    ]
    for server, port in turn_servers:
        result = turn_allocate_test(
            server, port,
            username="cc84af1584a60af7a8aae396",
            credential="DYooULJ9XzeVTjwa"
        )
        results[f"TURN {server}:{port}"] = result
        if result:
            break

    # Summary
    print("\n" + "=" * 60)
    print("  RESULTS SUMMARY")
    print("=" * 60)
    any_stun = False
    any_turn = False
    for name, ok in results.items():
        status = "PASS" if ok else "FAIL"
        print(f"  {status}  {name}")
        if ok and "STUN" in name:
            any_stun = True
        if ok and "TURN" in name:
            any_turn = True

    print()
    if not any_stun:
        print("  STUN ALL FAIL -> Firewall VPS block UDP outbound?")
    if not any_turn:
        print("  TURN ALL FAIL -> Check credentials or firewall")
    if any_stun and any_turn:
        print("  Both OK -> aiortc should work. Check aiortc version.")


if __name__ == "__main__":
    main()
