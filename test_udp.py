import asyncio
import socket

async def test_udp_response():
    """Test if UDP responses can be received"""
    loop = asyncio.get_event_loop()

    # Create UDP socket
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setblocking(False)
    sock.bind(('0.0.0.0', 0))
    local_port = sock.getsockname()[1]
    print(f"Listening on port {local_port}")

    # Send to Google STUN server
    stun_addr = ('stun.l.google.com', 3478)
    # STUN Binding Request (minimal)
    stun_request = bytes([
        0x00, 0x01,  # Binding Request
        0x00, 0x00,  # Length: 0
        0x21, 0x12, 0xA4, 0x42,  # Magic cookie
        0x00, 0x00, 0x00, 0x00,  # Transaction ID
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    ])

    sock.sendto(stun_request, stun_addr)
    print(f"Sent STUN request to {stun_addr}")

    # Wait for response with timeout
    try:
        data, addr = await asyncio.wait_for(
            loop.sock_recvfrom(sock, 1024),
            timeout=5.0
        )
        print(f"✓ Received {len(data)} bytes from {addr}")
        print(f"  Response type: 0x{data[0]:02x}{data[1]:02x}")
    except asyncio.TimeoutError:
        print("✗ No response received (timeout 5s)")
        print("  → UDP inbound is blocked by firewall/router/ISP")
    finally:
        sock.close()

asyncio.run(test_udp_response())
