import asyncio
import logging
from aioice import Connection

logging.basicConfig(level=logging.DEBUG)

async def test():
    tests = [
        {
            "name": "UDP port 3478",
            "turn_server": ("openrelay.metered.ca", 3478),
            "turn_ssl": False,
            "turn_transport": "udp",
        },
        {
            "name": "UDP port 80",
            "turn_server": ("openrelay.metered.ca", 80),
            "turn_ssl": False,
            "turn_transport": "udp",
        },
    ]

    for t in tests:
        print(f"\n--- Testing: {t['name']} ---")
        conn = Connection(
            ice_controlling=True,
            turn_server=t["turn_server"],
            turn_username="openrelayproject",
            turn_password="openrelayproject",
            turn_ssl=t["turn_ssl"],
            turn_transport=t["turn_transport"],
        )
        try:
            await asyncio.wait_for(conn.gather_candidates(), timeout=20)
            print(f"Candidates: {len(conn.local_candidates)}")
            for c in conn.local_candidates:
                print(f"  {c.type}: {c.host}:{c.port}")
        except Exception as e:
            print(f"Error: {e}")
        finally:
            await conn.close()

asyncio.run(test())
