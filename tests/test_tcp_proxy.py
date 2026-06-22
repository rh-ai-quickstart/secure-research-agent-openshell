"""Tests for scripts/tcp-proxy.py — the network namespace bridge."""

import asyncio

import pytest
from conftest import load_tcp_proxy


@pytest.fixture
async def echo_server():
    """Start a TCP echo server on a random port."""

    async def handler(reader, writer):
        while True:
            data = await reader.read(4096)
            if not data:
                break
            writer.write(data)
            await writer.drain()
        writer.close()

    server = await asyncio.start_server(handler, "127.0.0.1", 0)
    port = server.sockets[0].getsockname()[1]
    yield port
    server.close()
    await server.wait_closed()


@pytest.fixture
async def proxy_server(echo_server):
    """Start the tcp-proxy forwarding to the echo server."""
    mod = load_tcp_proxy()
    mod.TARGET_HOST = "127.0.0.1"
    mod.TARGET_PORT = echo_server
    mod.LISTEN_PORT = 0

    server = await asyncio.start_server(mod.handle, "127.0.0.1", 0)
    proxy_port = server.sockets[0].getsockname()[1]
    yield proxy_port
    server.close()
    await server.wait_closed()


@pytest.mark.asyncio
async def test_proxy_forwards_data(proxy_server):
    """Data sent to the proxy is forwarded to the target and echoed back."""
    reader, writer = await asyncio.open_connection("127.0.0.1", proxy_server)
    writer.write(b"hello proxy")
    await writer.drain()

    data = await asyncio.wait_for(reader.read(4096), timeout=2.0)
    assert data == b"hello proxy"

    writer.close()


@pytest.mark.asyncio
async def test_proxy_handles_large_payload(proxy_server):
    """Proxy correctly forwards a payload larger than the buffer size."""
    payload = b"X" * 100_000
    reader, writer = await asyncio.open_connection("127.0.0.1", proxy_server)
    writer.write(payload)
    await writer.drain()

    received = b""
    while len(received) < len(payload):
        chunk = await asyncio.wait_for(reader.read(65536), timeout=5.0)
        if not chunk:
            break
        received += chunk

    assert received == payload
    writer.close()


@pytest.mark.asyncio
async def test_proxy_handles_connection_refused():
    """Proxy closes client connection gracefully when target is unreachable."""
    mod = load_tcp_proxy()
    mod.TARGET_HOST = "127.0.0.1"
    mod.TARGET_PORT = 1  # unlikely to be listening
    mod.LISTEN_PORT = 0

    server = await asyncio.start_server(mod.handle, "127.0.0.1", 0)
    proxy_port = server.sockets[0].getsockname()[1]

    reader, writer = await asyncio.open_connection("127.0.0.1", proxy_port)
    writer.write(b"test")
    await writer.drain()

    data = await asyncio.wait_for(reader.read(4096), timeout=2.0)
    assert data == b""  # connection closed by proxy

    writer.close()
    server.close()
    await server.wait_closed()
