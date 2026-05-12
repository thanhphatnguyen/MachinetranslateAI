import socket
import struct
import hashlib
import hmac
import os

MAGIC = 0x2112A442
SERVER = "103.118.29.243"
PORT = 3478
USERNAME = "test"
PASSWORD = "test123"
REALM_EXPECTED = "myserver"

def pad4(b):
    return b + b'\x00' * ((4 - len(b) % 4) % 4)

print(f"Testing pion TURN: {SERVER}:{PORT}")
print(f"Credentials: {USERNAME} / {PASSWORD}")
print("-" * 40)

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.settimeout(5)

try:
    # Step 1: Allocate no-auth → nhận 401 + nonce/realm
    txn = os.urandom(12)
    attr = struct.pack("!HH", 0x0019, 4) + struct.pack("!BBBB", 17, 0, 0, 0)
    msg = struct.pack("!HHI", 0x0003, len(attr), MAGIC) + txn + attr
    sock.sendto(msg, (SERVER, PORT))
    print("Step 1: Sent Allocate request (no-auth)...")

    data, addr = sock.recvfrom(1024)
    resp_type = struct.unpack("!H", data[:2])[0]
    print(f"Step 1: Response type: 0x{resp_type:04x}", end=" ")

    if resp_type == 0x0113:
        print("(401 Unauthorized - expected)")
    elif resp_type == 0x0103:
        print("(200 OK - no auth needed)")
        print("TURN server reachable!")
        sock.close()
        exit(0)
    else:
        print(f"(unexpected)")
        sock.close()
        exit(1)

    # Parse nonce và realm
    ml = struct.unpack("!H", data[2:4])[0]
    off = 20
    attrs = {}
    while off < 20 + ml:
        t, l = struct.unpack("!HH", data[off:off + 4])
        attrs[t] = data[off + 4:off + 4 + l]
        off += 4 + l + ((4 - l % 4) % 4)

    nonce = attrs.get(0x0015, b"").decode(errors="replace")
    realm = attrs.get(0x0014, b"").decode(errors="replace")
    print(f"Step 1: realm={realm}, nonce={nonce[:30]}...")

    if not nonce or not realm:
        print("ERROR: No nonce/realm in 401 response")
        sock.close()
        exit(1)

    # Step 2: Allocate with auth
    txn2 = os.urandom(12)
    a = b""
    a += struct.pack("!HH", 0x0019, 4) + struct.pack("!BBBB", 17, 0, 0, 0)
    for atype, val in [
        (0x0015, nonce.encode()),
        (0x0014, realm.encode()),
        (0x0006, USERNAME.encode()),
    ]:
        a += struct.pack("!HH", atype, len(val)) + pad4(val)

    placeholder = struct.pack("!HH", 0x0008, 20) + b'\x00' * 20
    msg_hmac = struct.pack("!HHI", 0x0003, len(a) + 24, MAGIC) + txn2 + a + placeholder
    ha1 = hashlib.md5(f"{USERNAME}:{realm}:{PASSWORD}".encode()).digest()
    integrity = hmac.new(ha1, msg_hmac[:-24], hashlib.sha1).digest()

    final = struct.pack("!HHI", 0x0003, len(a) + 24, MAGIC) + txn2 + a
    final += struct.pack("!HH", 0x0008, 20) + integrity

    sock.sendto(final, (SERVER, PORT))
    print("Step 2: Sent Allocate request (with auth)...")

    data2, _ = sock.recvfrom(1024)
    resp2 = struct.unpack("!H", data2[:2])[0]
    print(f"Step 2: Response type: 0x{resp2:04x}", end=" ")

    if resp2 == 0x0103:
        print("(200 OK - ALLOCATE SUCCESS!)")
        # Parse relay IP
        ml2 = struct.unpack("!H", data2[2:4])[0]
        off2 = 20
        while off2 < 20 + ml2:
            t, l = struct.unpack("!HH", data2[off2:off2 + 4])
            val = data2[off2 + 4:off2 + 4 + l]
            if t == 0x0016 and len(val) >= 8:  # XOR-RELAYED-ADDRESS
                rport = struct.unpack("!H", val[2:4])[0] ^ (MAGIC >> 16)
                rip = struct.unpack("!I", val[4:8])[0] ^ MAGIC
                import socket as s
                print(f"Relay address: {s.inet_ntoa(struct.pack('!I', rip))}:{rport}")
            off2 += 4 + l + ((4 - l % 4) % 4)
        print("\n✅ Pion TURN server hoạt động tốt!")
        print("Dùng config sau trong pipecat + Flutter:")
        print(f'  URL: turn:{SERVER}:{PORT}')
        print(f'  username: {USERNAME}')
        print(f'  credential: {PASSWORD}')
    elif resp2 == 0x0113:
        ml2 = struct.unpack("!H", data2[2:4])[0]
        off2 = 20
        attrs2 = {}
        while off2 < 20 + ml2:
            t, l = struct.unpack("!HH", data2[off2:off2 + 4])
            attrs2[t] = data2[off2 + 4:off2 + 4 + l]
            off2 += 4 + l + ((4 - l % 4) % 4)
        err = attrs2.get(0x0009, b"")
        if len(err) >= 4:
            code = err[2] * 100 + err[3]
            reason = err[4:].decode(errors="replace")
            print(f"(401 - Error {code}: {reason})")
        print("❌ Auth failed - kiểm tra lại username/password")
    else:
        print(f"(unexpected response)")

except socket.timeout:
    print("TIMEOUT - pion TURN không nhận được request")
    print("Kiểm tra: server có đang chạy không? Firewall UDP 3478 đã mở chưa?")
except Exception as e:
    print(f"ERROR: {e}")
finally:
    sock.close()