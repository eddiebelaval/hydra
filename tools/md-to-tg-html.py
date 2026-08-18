#!/usr/bin/env python3
"""Convert the Markdown subset Claude emits into Telegram HTML.

Ava's replies come from `claude -p` as CommonMark (**bold**, *italic*, `code`,
### headings, - bullets). Telegram only renders formatting when parse_mode is
set, and neither legacy Markdown nor MarkdownV2 handles `**bold**` without
breaking on stray punctuation. Telegram's HTML mode only needs three characters
escaped (< > &) and degrades gracefully, so we convert to the HTML tag allowlist
(<b> <i> <u> <s> <code> <pre> <a>).

Reads raw text on stdin, writes a JSON-encoded HTML string on stdout (ready to
drop straight into a Telegram sendMessage body). Mirrors the converter in
products/parallax/src/lib/telegram/format.ts so both surfaces render the same.
"""
import json
import re
import sys

PLACEHOLDER = "\x00TGFMT\x00"


def md_to_telegram_html(text: str) -> str:
    out = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

    # Stash code blocks/spans before emphasis so backtick contents are inert.
    slots: list[str] = []

    def stash(html: str) -> str:
        slots.append(html)
        return f"{PLACEHOLDER}{len(slots) - 1}{PLACEHOLDER}"

    out = re.sub(
        r"```(?:[a-zA-Z0-9_-]*)\n?([\s\S]*?)```",
        lambda m: stash(f"<pre>{m.group(1).rstrip(chr(10))}</pre>"),
        out,
    )
    out = re.sub(r"`([^`\n]+)`", lambda m: stash(f"<code>{m.group(1)}</code>"), out)

    # Headings -> bold line. Bullets -> bullet glyph. Both before emphasis so a
    # leading "* " is not mistaken for an italic delimiter.
    out = re.sub(r"(?m)^#{1,6}\s+(.+?)\s*#*$", r"<b>\1</b>", out)
    out = re.sub(r"(?m)^[ \t]*[-*+]\s+", "• ", out)

    # Bold before italic so the double markers win.
    out = re.sub(r"\*\*([^*\n]+?)\*\*", r"<b>\1</b>", out)
    out = re.sub(r"(?<!\w)__([^_\n]+?)__(?!\w)", r"<b>\1</b>", out)

    # Italic, anchored so it's/snake_case don't open emphasis.
    out = re.sub(r"(?<![*\w])\*(?!\s)([^*\n]+?)(?<!\s)\*(?![*\w])", r"<i>\1</i>", out)
    out = re.sub(r"(?<![_\w])_(?!\s)([^_\n]+?)(?<!\s)_(?![_\w])", r"<i>\1</i>", out)

    # Links: [label](http...) -> <a href>.
    out = re.sub(
        r"\[([^\]]+)\]\((https?://[^\s)]+)\)",
        lambda m: f'<a href="{m.group(2)}">{m.group(1)}</a>',
        out,
    )

    out = re.sub(
        re.escape(PLACEHOLDER) + r"(\d+)" + re.escape(PLACEHOLDER),
        lambda m: slots[int(m.group(1))],
        out,
    )
    return out


if __name__ == "__main__":
    html = md_to_telegram_html(sys.stdin.read())
    # Default: JSON-encoded string (drop into a JSON sendMessage body).
    # --raw: bare HTML (for form senders using curl --data-urlencode text=...).
    if "--raw" in sys.argv[1:]:
        sys.stdout.write(html)
    else:
        sys.stdout.write(json.dumps(html))
