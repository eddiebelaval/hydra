"""
claude_client.py — Reusable Claude API client for HYDRA daemons.

Handles: API call, response parsing, markdown fence extraction.
Used by bridge daemons (dae-sync, ava-sync) for Haiku synthesis.

Usage in heredoc:
    sys.path.insert(0, os.path.expanduser('~/.hydra/lib'))
    from claude_client import call_claude
    result = call_claude(prompt, api_key="sk-...")
"""

import json
import re
import urllib.request
import urllib.error
import os


def call_claude(prompt, model="claude-haiku-4-5-20251001", max_tokens=1200, api_key=None):
    """Call Claude API and return parsed JSON response.

    Returns a dict on success, or {"error": "..."} on failure.
    Automatically strips markdown fences from the response.
    """
    if api_key is None:
        api_key = os.environ.get("ANTHROPIC_API_KEY", "")

    data = json.dumps({
        "model": model,
        "max_tokens": max_tokens,
        "messages": [{"role": "user", "content": prompt}]
    }).encode()

    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages",
        data=data,
        headers={
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json"
        }
    )

    try:
        with urllib.request.urlopen(req) as resp:
            result = json.loads(resp.read())
            text = result['content'][0]['text']
            # Extract JSON from markdown fences if present
            fence_match = re.search(r'```(?:json)?\s*\n(.*?)\n```', text, re.DOTALL)
            if fence_match:
                text = fence_match.group(1)
            return json.loads(text)
    except (urllib.error.URLError, json.JSONDecodeError, KeyError, IndexError) as e:
        return {"error": str(e)}
