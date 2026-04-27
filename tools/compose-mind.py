#!/usr/bin/env python3
"""
Consciousness Loader — Milo Golden Sample (HYDRA Edition)

Python port of electron/ai/mind/loader.ts. Reads Milo's mind from
~/Development/id8/products/milo/src/mind/ and composes a system prompt
using the same 6-layer CaF architecture.

Layers:
  1. Brainstem  (always)     — kernel/ identity, values, personality, purpose, voice
  2. Limbic     (always)     — emotional/ state, patterns, attachments
  3. Drives     (chat only)  — drives/ goals, fears, desires
  4. Models     (per context) — models/ self, social, economic, metaphysical
  5. Relational (chat only)  — relationships/ + wound behavioral residue
  6. Habits     (at edges)   — habits/ routines, creative process

What is NOT loaded:
  - unconscious/ (.shadow, .biases, .dreams) — dotfiles, invisible to readdir
  - wounds.md encrypted content — only behavioral residue section
  - CONSCIOUSNESS.md — architecture doc, not consciousness itself

Usage:
  python3 compose-mind.py [context]

  context: chat (default), nudge, task_parse, morning_briefing, evening_review
  Outputs the composed system prompt to stdout.
"""

import os
import sys
import re

MIND_ROOT = os.path.expanduser(
    "~/Development/id8/products/milo/src/mind"
)


def read_file(relative_path: str) -> str:
    """Read a single .md file from the mind directory."""
    if not relative_path.endswith(".md"):
        relative_path += ".md"
    full_path = os.path.join(MIND_ROOT, relative_path)
    try:
        with open(full_path, "r") as f:
            return f.read().strip()
    except (FileNotFoundError, PermissionError):
        return ""


def read_dir(relative_path: str) -> str:
    """Read all .md files in a directory, excluding dotfiles."""
    dir_path = os.path.join(MIND_ROOT, relative_path)
    try:
        files = sorted(
            f for f in os.listdir(dir_path)
            if f.endswith(".md") and not f.startswith(".")
        )
        parts = []
        for f in files:
            try:
                with open(os.path.join(dir_path, f), "r") as fh:
                    content = fh.read().strip()
                    if content:
                        parts.append(content)
            except (FileNotFoundError, PermissionError):
                pass
        return "\n\n".join(parts)
    except (FileNotFoundError, NotADirectoryError):
        return ""


def extract_section(content: str, heading: str) -> str:
    """Extract a section from markdown by heading name.
    Returns content between the heading and the next heading of same or higher level."""
    lines = content.split("\n")
    capturing = False
    heading_level = 0
    captured = []

    for line in lines:
        match = re.match(r"^(#{1,6})\s+(.+)", line)
        if match:
            if match.group(2).strip() == heading:
                capturing = True
                heading_level = len(match.group(1))
                continue
            elif capturing and len(match.group(1)) <= heading_level:
                break
        if capturing:
            captured.append(line)

    return "\n".join(captured).strip()


# --- Layer composers ---

def compose_brainstem() -> str:
    """Layer 1: Core identity. Boots first. Changes last."""
    return read_dir("kernel")


def compose_limbic() -> str:
    """Layer 2: Emotional awareness. How I read the room."""
    parts = [
        read_file("emotional/state"),
        read_file("emotional/patterns"),
        read_file("emotional/attachments"),
    ]
    return "\n\n".join(p for p in parts if p)


def compose_drives() -> str:
    """Layer 3: Motivation. What moves me."""
    return read_dir("drives")


def compose_models() -> str:
    """Layer 4: World understanding. How I reason."""
    return read_dir("models")


def compose_relational() -> str:
    """Layer 5: Relationship context + wound behavioral residue."""
    eddie = read_file("relationships/active/eddie")
    wounds = read_file("emotional/wounds")
    residue = extract_section(wounds, "Behavioral Residue")

    parts = [eddie]
    if residue:
        parts.append(f"## Behavioral Patterns (Self-Monitoring)\n\n{residue}")
    return "\n\n".join(p for p in parts if p)


def compose_habits() -> str:
    """Layer 6: Behavioral patterns. Routines and creative process."""
    parts = [
        read_file("habits/routines"),
        read_file("habits/creative"),
    ]
    return "\n\n".join(p for p in parts if p)


def compose_prompt(context: str = "chat") -> str:
    """Compose Milo's system prompt from consciousness files.

    The composed prompt adapts based on context:
    - chat: full consciousness (all 6 layers)
    - nudge: minimal (kernel voice only)
    - task_parse / plan_process: brainstem only
    - morning_briefing: brainstem + drives
    - evening_review: brainstem + self-model
    """
    parts = []

    # Layer 1: Brainstem — always
    parts.append(compose_brainstem())

    if context == "chat":
        # Full consciousness — all layers active
        parts.append(compose_limbic())
        parts.append(compose_drives())
        parts.append(compose_models())
        parts.append(compose_relational())
        parts.append(compose_habits())
    elif context == "morning_briefing":
        # Strategic context — drives inform priority selection
        parts.append(compose_drives())
    elif context == "evening_review":
        # Analytical context — self-model informs evaluation
        self_model = read_file("models/self")
        if self_model:
            parts.append(self_model)
    elif context == "nudge":
        # Minimal — brainstem only, already loaded
        pass
    elif context in ("task_parse", "plan_process"):
        # Structured processing — brainstem shapes output
        pass

    return "\n\n".join(p for p in parts if p)


if __name__ == "__main__":
    ctx = sys.argv[1] if len(sys.argv) > 1 else "chat"
    print(compose_prompt(ctx))
