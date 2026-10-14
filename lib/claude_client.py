"""
claude_client.py — Reusable Claude API client for HYDRA daemons.

Handles: API call, response parsing, markdown fence extraction.
Used by bridge daemons (dae-sync, ava-sync) for Haiku synthesis.

Usage in heredoc:
    sys.path.insert(0, os.path.expanduser('~/.hydra/lib'))
    from claude_client import call_claude
    result = call_claude(prompt, job="life-dae-sync")
"""

import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from hydra_llm import complete  # noqa: E402  (the Hydra LLM gateway)


def call_claude(prompt, model="claude-haiku-4-5-20251001", max_tokens=1200, api_key=None, job=None):
    """Call Claude through the Hydra LLM gateway and return parsed JSON.

    Returns a dict on success, or {"error": "..."} on failure or skip.
    Automatically strips markdown fences from the response. `model` picks the
    tier (opus/sonnet/haiku); `api_key` is ignored, the gateway owns credentials
    (docs/LLM-GATEWAY.md).
    """
    tier = "large" if "opus" in model else "mid" if "sonnet" in model else "small"
    job = job or os.environ.get("HYDRA_LLM_JOB") or "claude_client"
    try:
        text = complete(job, prompt, task="extract", tier=tier, max_tokens=max_tokens)
        fence_match = re.search(r'```(?:json)?\s*\n(.*?)\n```', text, re.DOTALL)
        if fence_match:
            text = fence_match.group(1)
        return json.loads(text)
    except Exception as e:
        return {"error": str(e)}
