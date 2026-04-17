#!/bin/bash
# mermaid-preview plugin · PostToolUse hook
#
# Fires on Write|Edit|MultiEdit|NotebookEdit. For markdown-ish files
# containing ```mermaid fenced blocks, renders a self-contained preview HTML
# (Mermaid bundle inlined — no network, no file:// load policy concerns) into
# ~/.claude/previews/ and opens it in the default browser.
#
# Subsequent writes update the same preview HTML; an in-page poller compares
# content hashes and reloads the browser tab automatically.

set +e

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
VENDOR="$PLUGIN_ROOT/vendor/mermaid.min.js"
PREVIEWS_DIR="$HOME/.claude/previews"

mkdir -p "$PREVIEWS_DIR"
exec 2>>"$PREVIEWS_DIR/preview.log"

# Stale artifacts from older personal hook iterations (symlink or copy).
# No longer needed since the bundle is inlined into each preview HTML.
rm -f "$PREVIEWS_DIR/mermaid.min.js" 2>/dev/null

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >&2; }

input=$(cat 2>/dev/null)

if command -v jq >/dev/null 2>&1; then
  file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.filePath // .tool_input.notebook_path // empty' 2>/dev/null)
else
  file_path=$(printf '%s' "$input" | grep -o '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"file_path"[[:space:]]*:[[:space:]]*"//;s/"$//')
fi

if [ -z "$file_path" ] || [ ! -f "$file_path" ]; then
  exit 0
fi

case "$file_path" in
  *.md|*.mmd|*.mdx|*.markdown|*.ipynb) ;;
  *) exit 0 ;;
esac

grep -q '```mermaid' "$file_path" 2>/dev/null || exit 0

slug=$(printf '%s' "$file_path" | shasum -a 256 | cut -c1-12)
preview="$PREVIEWS_DIR/preview-$slug.html"

python3 - "$file_path" "$VENDOR" "$preview" <<'PYEOF'
import hashlib
import html
import json
import os
import re
import sys

file_path, vendor, preview_path = sys.argv[1], sys.argv[2], sys.argv[3]

try:
    src = open(file_path, encoding="utf-8", errors="replace").read()
except Exception as e:
    sys.stderr.write(f"read error: {e}\n")
    sys.exit(1)

blocks = re.findall(
    r"^```mermaid[^\n]*\n(.*?)^```\s*$",
    src,
    re.DOTALL | re.MULTILINE,
)
if not blocks:
    sys.exit(1)

# JSON is a subset of JS literals; escape "</" so stray closing tags inside
# mermaid source cannot terminate the surrounding <script> element.
blocks_json = json.dumps(blocks).replace("</", "<\\/")
title = html.escape(os.path.basename(file_path))
full_path = html.escape(file_path)
content_hash = hashlib.sha256(src.encode("utf-8")).hexdigest()[:16]

# Inline the Mermaid bundle: Chromium's file:// same-origin policy blocks
# classic <script src> loads in edge cases (symlinks, cross-directory,
# recent tightening). Inlining sidesteps every variant.
if os.path.exists(vendor):
    with open(vendor, encoding="utf-8", errors="replace") as fh:
        mermaid_js = fh.read()
    # "</script" can legitimately appear inside JS string/regex literals in a
    # minified bundle; escaping it to "<\/script" keeps those contexts valid
    # without changing code semantics elsewhere.
    mermaid_js = mermaid_js.replace("</script", "<\\/script")
    script_tag = f"<script>{mermaid_js}</script>"
    vendor_label = "yes (inlined)"
else:
    script_tag = (
        '<script src="https://cdn.jsdelivr.net/npm/mermaid@11.4.1/'
        'dist/mermaid.min.js"></script>'
    )
    vendor_label = "no (CDN fallback)"

html_out = f"""<!DOCTYPE html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Mermaid — {title}</title>
<style>
  :root {{ color-scheme: light dark; }}
  body {{ font-family: -apple-system, system-ui, sans-serif; margin: 2rem; background: #fafafa; color: #222; }}
  header {{ margin-bottom: 1.5rem; font-size: 0.95rem; }}
  header code {{ background: #e8e8e8; padding: 2px 6px; border-radius: 3px; font-size: 0.9em; }}
  .chart {{ background: white; padding: 2rem; border-radius: 8px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); margin: 1rem 0; overflow-x: auto; }}
  .chart pre.mermaid {{ margin: 0; }}
  .error {{ background: #fee; border-left: 4px solid #c33; padding: 1rem; border-radius: 4px; color: #800; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; white-space: pre-wrap; }}
  footer {{ margin-top: 2rem; font-size: 0.75rem; opacity: 0.55; }}
  @media (prefers-color-scheme: dark) {{
    body {{ background: #1a1a1a; color: #e4e4e4; }}
    header code {{ background: #333; color: #e4e4e4; }}
    .chart {{ background: #262626; box-shadow: 0 1px 3px rgba(0,0,0,0.4); }}
    .error {{ background: #3a1a1a; color: #f88; border-color: #c66; }}
  }}
</style>
</head><body data-hash="{content_hash}">
<header>Source: <code>{full_path}</code></header>
<main id="charts"></main>
<footer>Mermaid: {vendor_label} · hash <code>{content_hash}</code></footer>
{script_tag}
<script>
  const sources = {blocks_json};
  const container = document.getElementById('charts');
  sources.forEach((src) => {{
    const wrap = document.createElement('div');
    wrap.className = 'chart';
    const pre = document.createElement('pre');
    pre.className = 'mermaid';
    pre.textContent = src;
    wrap.appendChild(pre);
    container.appendChild(wrap);
  }});

  function showError(msg) {{
    const err = document.createElement('div');
    err.className = 'error';
    err.textContent = msg;
    container.appendChild(err);
  }}

  if (typeof mermaid !== 'undefined') {{
    const dark = matchMedia('(prefers-color-scheme: dark)').matches;
    mermaid.initialize({{
      startOnLoad: false,
      theme: dark ? 'dark' : 'default',
      securityLevel: 'loose',
    }});
    mermaid.run().catch((e) => showError('Mermaid error: ' + (e && e.message ? e.message : e)));
  }} else {{
    showError('Mermaid library failed to load (vendor missing and CDN unreachable).');
  }}

  // Auto-reload: poll self, compare the data-hash on <body>. Only reloads
  // when content actually changed, so scroll/zoom are preserved otherwise.
  const h0 = document.body.dataset.hash;
  setInterval(async () => {{
    try {{
      const r = await fetch(location.href, {{ cache: 'no-store' }});
      const t = await r.text();
      const m = t.match(/data-hash="([^"]+)"/);
      if (m && m[1] !== h0) location.reload();
    }} catch (_) {{ /* manual reload still works if file:// fetch is blocked */ }}
  }}, 1500);
</script>
</body></html>
"""

with open(preview_path, "w", encoding="utf-8") as fh:
    fh.write(html_out)
PYEOF

if [ $? -ne 0 ]; then
  log "skip: no mermaid blocks or render failed for $file_path"
  exit 0
fi

# LRU prune — keep newest 20 preview files
ls -t "$PREVIEWS_DIR"/preview-*.html 2>/dev/null | tail -n +21 | xargs rm -f 2>/dev/null

log "rendered $file_path -> $preview"

# Open in default browser (non-blocking). Platform-specific command; macOS
# today, others as the plugin expands.
case "$(uname)" in
  Darwin) open "$preview" >/dev/null 2>&1 & ;;
  Linux)  command -v xdg-open >/dev/null 2>&1 && xdg-open "$preview" >/dev/null 2>&1 & ;;
  *)      log "no opener known for $(uname); preview at $preview" ;;
esac

exit 0
