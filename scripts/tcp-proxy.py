"""TCP proxy bridging the pod's root network namespace to the sandbox namespace.

The AIQ app runs inside a nested network namespace (10.200.0.2) created by the
OpenShell supervisor. Standard oc port-forward cannot reach it directly. This
proxy listens on the pod's main namespace and forwards to the sandbox.

Usage:
    python3 tcp-proxy.py [listen_port] [target_host] [target_port]
    python3 tcp-proxy.py 8000 10.200.0.2 8000
"""

import asyncio
import contextlib
import sys

LISTEN_HOST = "0.0.0.0"
LISTEN_PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8000
TARGET_HOST = sys.argv[2] if len(sys.argv) > 2 else "10.200.0.2"
TARGET_PORT = int(sys.argv[3]) if len(sys.argv) > 3 else 8000


async def handle(reader, writer):
    try:
        tr, tw = await asyncio.open_connection(TARGET_HOST, TARGET_PORT)
    except Exception:
        writer.close()
        return

    async def pipe(r, w):
        try:
            while True:
                d = await r.read(65536)
                if not d:
                    break
                w.write(d)
                await w.drain()
        except Exception:
            pass
        finally:
            with contextlib.suppress(Exception):
                w.close()

    await asyncio.gather(pipe(reader, tw), pipe(tr, writer))


async def main():
    srv = await asyncio.start_server(handle, LISTEN_HOST, LISTEN_PORT)
    print(
        f"Proxy listening on {LISTEN_HOST}:{LISTEN_PORT} -> {TARGET_HOST}:{TARGET_PORT}",
        flush=True,
    )
    async with srv:
        await srv.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
