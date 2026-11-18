# /// script
# requires-python = ">=3.11"
# ///
"""Model providers' logos (docs/accounts.md), from LobeHub's icons (github.com/lobehub/lobe-icons, MIT), into the app's
asset catalog (ios/Tau/Assets.xcassets/Providers, vector, a template unless in color) and the web client's
(web/src/tau/assets/providers). Which provider shows which logo on which color is the apps' own
(ios/Tau/Accounts/ProviderIcon.swift, web/src/tau/api/providerIcons.ts). Usage: uv run scripts/provider-icons.py
"""

import json
import re
import shutil
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = "https://unpkg.com/@lobehub/icons-static-svg@1/icons/{}.svg"
# One color, drawn in the app's color for it; or in their own colors
MONO = [
    "openai", "githubcopilot", "xai", "deepseek", "mistral", "kimi", "openrouter", "fireworks", "groq", "together",
    "cerebras", "meta", "minimax", "zai", "nvidia", "huggingface", "bedrock", "azure", "vertexai", "cloudflare",
    "vercel", "qwen", "xiaomimimo", "baseten", "opencode",
]
COLOR = ["claude-color", "gemini-color"]


def normalized(svg: str, template: bool) -> str:
    """A fixed size for Xcode's vector import, no inline style, and black for the template's mask."""
    svg = re.sub(r'\s(height|width)="1em"', "", svg)
    svg = re.sub(r'\sstyle="[^"]*"', "", svg)
    svg = re.sub(r"<title>.*?</title>", "", svg)
    svg = svg.replace("<svg ", '<svg width="24" height="24" ', 1)
    if template:
        svg = svg.replace('fill="currentColor"', 'fill="#000000"')
    return svg


def main() -> None:
    catalog = ROOT / "ios/Tau/Assets.xcassets/Providers"
    web = ROOT / "web/src/tau/assets/providers"
    for directory in (catalog, web):
        shutil.rmtree(directory, ignore_errors=True)
        directory.mkdir(parents=True)
    (catalog / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}, "properties": {"provides-namespace": True}}) + "\n")
    for name in MONO + COLOR:
        template = name in MONO
        svg = normalized(urllib.request.urlopen(SOURCE.format(name)).read().decode(), template)
        imageset = catalog / f"{name}.imageset"
        imageset.mkdir()
        (imageset / f"{name}.svg").write_text(svg)
        properties = {"preserves-vector-representation": True, "template-rendering-intent": "template" if template else "original"}
        (imageset / "Contents.json").write_text(json.dumps({"images": [{"filename": f"{name}.svg", "idiom": "universal"}], "info": {"author": "xcode", "version": 1}, "properties": properties}) + "\n")
        (web / f"{name}.svg").write_text(svg)
        print(name)


if __name__ == "__main__":
    main()
