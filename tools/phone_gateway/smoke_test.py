#!/usr/bin/env python3
"""Smoke test: spawn the gateway over stdio, list tools, call the safe ones.

Usage: python tools/phone_gateway/smoke_test.py
"""

import asyncio
import sys

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

GATEWAY = "tools/phone_gateway/phone_gateway.py"


async def main() -> None:
    params = StdioServerParameters(
        command=sys.executable, args=[GATEWAY]
    )
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            init = await session.initialize()
            print(f"handshake ok: server={init.serverInfo.name} "
                  f"protocol={init.protocolVersion}")
            tools = await session.list_tools()
            names = sorted(t.name for t in tools.tools)
            print(f"tools ({len(names)}): {', '.join(names)}")

            result = await session.call_tool("phone_list_devices", {})
            print(f"phone_list_devices -> {result.content[0].text!r}")

            result = await session.call_tool("phone_battery", {})
            text = result.content[0].text if result.content else ""
            print(f"phone_battery (no device expected) -> "
                  f"isError={result.isError} text={text[:160]!r}")

            print("SMOKE_OK")


if __name__ == "__main__":
    asyncio.run(main())
