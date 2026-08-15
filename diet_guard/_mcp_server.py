"""The MCP server singleton and its shared tool annotations.

Extracted from :mod:`diet_guard._mcp` to hold the repo's 250-line cap.  It has
to be a *separate* module rather than a section of ``_mcp``: the tool modules
need ``mcp`` at import time to register themselves with ``@mcp.tool``, so
keeping the singleton alongside them would make every split a circular import.

Also the single place stdio logging is configured, which is load-bearing:
STDOUT carries the MCP JSON-RPC protocol frames, so a stray write there
corrupts the stream and kills the session.  Everything logs to STDERR.
"""

from __future__ import annotations

import logging
import sys

from mcp.server import MCPServer
from mcp.types import ToolAnnotations

# Log to STDERR only -- STDOUT carries the MCP JSON-RPC protocol frames, so a
# single stray stdout write would corrupt the stream and kill the session.
logging.basicConfig(
    level=logging.INFO,
    stream=sys.stderr,
    format="%(asctime)s [%(levelname)s] diet-guard-mcp: %(message)s",
)
logger = logging.getLogger("diet_guard._mcp")

mcp = MCPServer("diet-guard")

# Machine-readable versions of what the docstrings already say, so a client
# can decide what to run unattended. The day a "read" tool starts writing,
# these annotations are what has to change with it.
READS_ONLY = ToolAnnotations(
    read_only_hint=True,
    idempotent_hint=True,
    open_world_hint=False,
)
# log_meal is the one tool that writes. It appends and never rewrites or
# deletes, so it is not destructive; it is not idempotent either, because a
# second confirmed call logs a second meal. It reaches Open Food Facts when
# macros are not supplied, which is exactly what open_world means.
APPENDS = ToolAnnotations(
    read_only_hint=False,
    destructive_hint=False,
    idempotent_hint=False,
    open_world_hint=True,
)
