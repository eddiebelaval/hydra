"""
observations.py — Shared utilities for bridge daemon output.

write_observations() — Append synthesis results to .blind-spots/ files
build_summary()      — Build one-line Telegram summary from synthesis

Usage in heredoc:
    sys.path.insert(0, os.path.expanduser('~/.hydra/lib'))
    from observations import write_observations, build_summary
"""

import json
import os
from datetime import datetime


def write_observations(staging_file, target_file, header, subtitle, section_map):
    """Append synthesized observations to a .blind-spots/ markdown file.

    Args:
        staging_file: Path to the synthesis JSON file
        target_file: Path to the target .blind-spots/ markdown file
        header: File header (e.g., "Dae Observations")
        subtitle: File subtitle lines (e.g., "*Synthesized from...*")
        section_map: List of (json_key, display_label) tuples
    """
    date = datetime.now().strftime('%Y-%m-%d')

    try:
        with open(staging_file) as f:
            synthesis = json.load(f)
    except (IOError, json.JSONDecodeError) as e:
        print(f"Could not read synthesis: {e}")
        return

    if 'error' in synthesis:
        print(f"Synthesis had error: {synthesis['error']}")
        return

    # Derive sync name from header (e.g., "Dae" from "Dae Observations")
    daemon_name = header.split()[0]
    lines = [f"\n### {daemon_name} Sync \u2014 {date}\n"]

    for key, label in section_map:
        items = synthesis.get(key, [])
        if items:
            lines.append(f"**{label}:**")
            for item in items:
                lines.append(f"- {item}")
            lines.append("")

    if len(lines) > 1:
        entry = '\n'.join(lines)

        try:
            with open(target_file) as f:
                existing = f.read()
        except FileNotFoundError:
            existing = f"# {header}\n\n{subtitle}\n\n---\n"

        with open(target_file, 'w') as f:
            f.write(existing + entry)

        print(f"Wrote {len(lines)} observation lines")
    else:
        print("No observations to write")


def build_summary(staging_file, prefix, keys):
    """Build a one-line Telegram summary from synthesis JSON.

    Args:
        staging_file: Path to the synthesis JSON file
        prefix: Message prefix (e.g., "Dae sync")
        keys: List of section keys to count (e.g., ['money_updates', 'blind_spots'])

    Returns:
        Summary string for Telegram notification
    """
    try:
        with open(staging_file) as f:
            s = json.load(f)
        parts = []
        for key in keys:
            items = s.get(key, [])
            if items:
                parts.append(f'{key}: {len(items)} observations')
        if parts:
            return f'{prefix}: ' + ', '.join(parts)
        else:
            return f'{prefix}: no new observations this week'
    except Exception:
        return f'{prefix}: complete (check logs)'
