#!/usr/bin/env python3
"""Copy Telegram-iOS foundation modules verbatim into ios/ThirdParty/Telegram and generate a SwiftPM package for them.

Usage: uv run ios/scripts/vendor_telegram.py [path to a Telegram-iOS checkout, default vendor/Telegram-iOS]

Modules keep their Telegram-iOS paths, so `diff -r` against a checkout shows every local change. The module table below
mirrors each module's Bazel BUILD file (sources, public headers, include roots, defines, deps); keep it in sync when
adding a module. Modeled on Telegram's own build-system/generate_spm.py.
"""
import glob
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SOURCE = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "vendor", "Telegram-iOS")
DEST = os.path.join(ROOT, "ios", "ThirdParty", "Telegram")

# name: (type, path, srcs globs, hdrs globs, include root, defines, deps)
MODULES = {
    "SwiftSignalKit": ("swift", "submodules/SSignalKit/SwiftSignalKit", ["Source/**/*.swift"], [], None, [], []),
    "AsyncDisplayKit": (
        "objc",
        "submodules/AsyncDisplayKit",
        ["Source/**/*.m", "Source/**/*.mm", "Source/*.h"],
        ["Source/PublicHeaders/AsyncDisplayKit/*.h"],
        "Source/PublicHeaders",
        ["MINIMAL_ASDK"],
        [],
    ),
    "ObjCRuntimeUtils": (
        "objc",
        "submodules/ObjCRuntimeUtils",
        ["Source/ObjCRuntimeUtils/*.m"],
        ["Source/ObjCRuntimeUtils/*.h"],
        "Source",
        [],
        [],
    ),
    "UIKitRuntimeUtils": (
        "objc",
        "submodules/UIKitRuntimeUtils",
        ["Source/UIKitRuntimeUtils/*.m"],
        ["Source/UIKitRuntimeUtils/*.h"],
        "Source",
        [],
        ["AsyncDisplayKit", "ObjCRuntimeUtils"],
    ),
    "AppBundle": (
        "objc",
        "submodules/AppBundle",
        ["Sources/**/*.m", "Sources/**/*.h"],
        ["PublicHeaders/**/*.h"],
        "PublicHeaders",
        [],
        [],
    ),
    "Markdown": ("swift", "submodules/Markdown", ["Source/**/*.swift"], [], None, [], []),
    "Display": (
        "swift",
        "submodules/Display",
        ["Source/**/*.swift"],
        [],
        None,
        [],
        ["ObjCRuntimeUtils", "UIKitRuntimeUtils", "AppBundle", "SwiftSignalKit", "Markdown", "AsyncDisplayKit"],
    ),
    "ComponentFlow": ("swift", "submodules/ComponentFlow", ["Source/**/*.swift"], [], None, [], ["Display", "UIKitRuntimeUtils"]),
    "MergeLists": ("swift", "submodules/MergeLists", ["Sources/**/*.swift"], [], None, [], []),
    "GradientBackground": (
        "swift",
        "submodules/GradientBackground",
        ["Sources/**/*.swift"],
        [],
        None,
        [],
        ["AsyncDisplayKit", "Display", "SwiftSignalKit"],
    ),
    "ActivityIndicator": ("swift", "submodules/ActivityIndicator", ["Sources/**/*.swift"], [], None, [], ["Display", "AsyncDisplayKit"]),
    "ComponentDisplayAdapters": (
        "swift",
        "submodules/Components/ComponentDisplayAdapters",
        ["Sources/**/*.swift"],
        [],
        None,
        [],
        ["Display", "ComponentFlow"],
    ),
    "MultilineTextComponent": (
        "swift",
        "submodules/Components/MultilineTextComponent",
        ["Sources/**/*.swift"],
        [],
        None,
        [],
        ["Display", "ComponentFlow", "Markdown"],
    ),
    "MeshTransformApi": (
        "objc",
        "submodules/TelegramUI/Components/MeshTransform/MeshTransformApi",
        ["Sources/*.m"],
        ["PublicHeaders/**/*.h"],
        "PublicHeaders",
        [],
        [],
    ),
    "MeshTransform": (
        "swift",
        "submodules/TelegramUI/Components/MeshTransform",
        ["Sources/**/*.swift"],
        [],
        None,
        [],
        ["MeshTransformApi"],
    ),
    "GlassBackgroundComponent": (
        "swift",
        "submodules/TelegramUI/Components/GlassBackgroundComponent",
        ["Sources/**/*.swift"],
        [],
        None,
        [],
        ["Display", "ComponentFlow", "ComponentDisplayAdapters", "UIKitRuntimeUtils", "AppBundle", "MeshTransform"],
    ),
    "EdgeEffect": (
        "swift",
        "submodules/TelegramUI/Components/EdgeEffect",
        ["Sources/**/*.swift"],
        [],
        None,
        [],
        ["Display", "ComponentFlow", "ComponentDisplayAdapters", "GlassBackgroundComponent"],
    ),
    "NavigationBarImpl": (
        "swift",
        "submodules/TelegramUI/Components/NavigationBarImpl",
        ["Sources/**/*.swift"],
        [],
        None,
        [],
        [
            "AsyncDisplayKit",
            "Display",
            "ComponentFlow",
            "GlassBackgroundComponent",
            "EdgeEffect",
            "ComponentDisplayAdapters",
            "MultilineTextComponent",
            "AppBundle",
        ],
    ),
    "HierarchyTrackingLayer": ("swift", "submodules/Components/HierarchyTrackingLayer", ["Sources/**/*.swift"], [], None, [], []),
    # Patched (see PATCHES): custom emoji pattern support removed.
    "MessageInlineBlockBackgroundView": (
        "swift",
        "submodules/TelegramUI/Components/Chat/MessageInlineBlockBackgroundView",
        ["Sources/**/*.swift"],
        [],
        None,
        [],
        ["Display", "HierarchyTrackingLayer", "SwiftSignalKit"],
    ),
    # Patched: custom emoji and spoiler dust removed. Only the text engine, not its TelegramCore-bound wrapper.
    "InteractiveTextComponent": (
        "swift",
        "submodules/TelegramUI/Components/InteractiveTextComponent",
        ["Sources/InteractiveTextComponent.swift"],
        [],
        None,
        [],
        ["AsyncDisplayKit", "Display", "ComponentFlow", "AppBundle", "MessageInlineBlockBackgroundView"],
    ),
    "LiquidLens": (
        "swift",
        "submodules/TelegramUI/Components/LiquidLens",
        ["Sources/**/*.swift"],
        [],
        None,
        [],
        ["Display", "ComponentFlow", "GlassBackgroundComponent"],
    ),
    "BundleIconComponent": (
        "swift",
        "submodules/Components/BundleIconComponent",
        ["Sources/**/*.swift"],
        [],
        None,
        [],
        ["ComponentFlow", "AppBundle", "Display"],
    ),
    "TextBadgeComponent": (
        "swift",
        "submodules/TelegramUI/Components/TextBadgeComponent",
        ["Sources/**/*.swift"],
        [],
        None,
        [],
        ["Display", "ComponentFlow"],
    ),
    "TabSelectionRecognizer": (
        "swift",
        "submodules/TelegramUI/Components/TabSelectionRecognizer",
        ["Sources/**/*.swift"],
        [],
        None,
        [],
        [],
    ),
    "LottieSettings": ("swift", "submodules/LottieSettings", ["Sources/**/*.swift"], [], None, [], []),
    # The iOS 26 floating tab bar. Its TelegramPresentationData, SearchBarNode and LottieComponent deps are shims.
    "TabBarComponent": (
        "swift",
        "submodules/TelegramUI/Components/TabBarComponent",
        ["Sources/**/*.swift"],
        [],
        None,
        [],
        [
            "Display",
            "LottieSettings",
            "TelegramPresentationData",
            "ComponentFlow",
            "ComponentDisplayAdapters",
            "MultilineTextComponent",
            "GlassBackgroundComponent",
            "LottieComponent",
            "BundleIconComponent",
            "TextBadgeComponent",
            "UIKitRuntimeUtils",
            "LiquidLens",
            "AppBundle",
            "SearchBarNode",
            "TabSelectionRecognizer",
        ],
    ),
    "StreamingTextReveal": (
        "swift",
        "submodules/TelegramUI/Components/StreamingTextReveal",
        ["Sources/**/*.swift"],
        [],
        None,
        [],
        [],
    ),
}


# tau's stand-ins for Telegram modules too heavy to copy (TelegramCore-bound or needing rlottie). Each has the
# module's name and only the API the copied modules use. They live in ios/ThirdParty/telegram-shims/<name> and are
# copied to tau-shims/<name>. name: deps
SHIMS = {
    "TelegramPresentationData": ["Display"],
    "SearchBarNode": ["Display", "AsyncDisplayKit", "TelegramPresentationData"],
    "LottieComponent": ["Display", "ComponentFlow", "LottieSettings"],
}
SHIMS_SOURCE = os.path.join(ROOT, "ios", "ThirdParty", "telegram-shims")

# Telegram images the modules load with UIImage(bundleImageName:), from submodules/TelegramUI/Images.xcassets.
IMAGES = [
    "Chat/Message/ReplyQuoteIcon",
    "Chat/Message/TextCodeIcon",
    "Item List/ExpandingItemVerticalRegularArrow",
    "Chat List/Tabs/IconChats",
    "Chat List/Tabs/IconSettings",
    "Chat List/Tabs/IconContacts",
    "Chat List/Tabs/IconCalls",
]

# Local changes, applied in order with `git apply` after copying. Paths in them are relative to ios/ThirdParty/Telegram.
PATCHES = os.path.join(ROOT, "ios", "ThirdParty", "telegram-patches")


def copy_images() -> None:
    catalog = os.path.join(SOURCE, "submodules", "TelegramUI", "Images.xcassets")
    target_catalog = os.path.join(DEST, "Images.xcassets")
    os.makedirs(target_catalog)
    with open(os.path.join(target_catalog, "Contents.json"), "w") as f:
        f.write('{\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n')
    for name in IMAGES:
        # Namespace folders carry a Contents.json that makes "Chat/Message/X" a valid image name.
        parts = name.split("/")
        for depth in range(1, len(parts)):
            folder = os.path.join(*parts[:depth])
            contents = os.path.join(catalog, folder, "Contents.json")
            os.makedirs(os.path.join(target_catalog, folder), exist_ok=True)
            if os.path.exists(contents):
                shutil.copy2(contents, os.path.join(target_catalog, folder, "Contents.json"))
        shutil.copytree(os.path.join(catalog, name + ".imageset"), os.path.join(target_catalog, name + ".imageset"))


def apply_patches() -> None:
    if not os.path.isdir(PATCHES):
        return
    for patch in sorted(os.listdir(PATCHES)):
        if patch.endswith(".patch"):
            subprocess.check_call(["git", "apply", "--directory=ios/ThirdParty/Telegram", os.path.join(PATCHES, patch)], cwd=ROOT)
            print(f"applied {patch}")


def files(base: str, patterns: list[str]) -> list[str]:
    found = set()
    for pattern in patterns:
        for path in glob.glob(os.path.join(base, pattern), recursive=True):
            if os.path.isfile(path):
                found.add(os.path.relpath(path, base))
    return sorted(found)


def main() -> None:
    revision = subprocess.check_output(["git", "-C", SOURCE, "rev-parse", "HEAD"], text=True).strip()
    if os.path.exists(DEST):
        shutil.rmtree(DEST)
    os.makedirs(DEST)
    with open(os.path.join(DEST, "NOTICE"), "w") as f:
        f.write(
            "These modules are copied from Telegram-iOS (https://github.com/TelegramMessenger/Telegram-iOS), "
            "licensed under GPLv2,\nat the revision in REVISION. Modules that carry their own LICENSE file "
            "(AsyncDisplayKit: Apache 2.0, from Texture) keep it.\n"
        )
    with open(os.path.join(DEST, "REVISION"), "w") as f:
        f.write(revision + "\n")

    targets = []
    for name, (kind, path, srcs, hdrs, include, defines, deps) in MODULES.items():
        base = os.path.join(SOURCE, path)
        sources = files(base, srcs)
        headers = files(base, hdrs)
        if not sources:
            sys.exit(f"{name}: no sources under {base}")
        for rel in sources + headers + [p for p in ("LICENSE",) if os.path.exists(os.path.join(base, p))]:
            target = os.path.join(DEST, path, rel)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            shutil.copy2(os.path.join(base, rel), target)
        compiled = [rel for rel in sources if not rel.endswith(".h")]
        lines = [
            f'        .target(',
            f'            name: "{name}",',
            f'            dependencies: [{", ".join(f"{dep!r}".replace(chr(39), chr(34)) for dep in deps)}],',
            f'            path: "{path}",',
        ]
        # A module nested in this one's directory (MeshTransform/MeshTransformApi) must not be part of it.
        nested = [other[1][len(path) + 1 :] for other in MODULES.values() if other[1].startswith(path + "/")]
        if nested:
            lines.append(f'            exclude: [{", ".join(chr(34) + n + chr(34) for n in nested)}],')
        lines += [
            f'            sources: [',
            *[f'                "{rel}",' for rel in compiled],
            f'            ],',
        ]
        if kind == "objc":
            public = [os.path.relpath(rel, include) for rel in headers]
            with open(os.path.join(DEST, path, include, "module.modulemap"), "w") as f:
                f.write(f"module {name} {{\n" + "".join(f'    header "{header}"\n' for header in public) + "}\n")
            lines.append(f'            publicHeadersPath: "{include}",')
            settings = ", ".join(f'.define("{define}")' for define in defines)
            lines.append(f"            cSettings: [{settings}],")
            lines.append(f"            cxxSettings: [{settings}]")
        else:
            lines.append("            swiftSettings: [.swiftLanguageMode(.v5)]")
        lines.append("        ),")
        targets.append("\n".join(lines))
        print(f"{name}: {len(compiled)} sources, {len(headers)} public headers")

    for name, deps in SHIMS.items():
        source = os.path.join(SHIMS_SOURCE, name)
        shutil.copytree(source, os.path.join(DEST, "tau-shims", name))
        compiled = sorted(f for f in os.listdir(source) if f.endswith(".swift"))
        targets.append("\n".join([
            "        .target(",
            f'            name: "{name}",',
            f'            dependencies: [{", ".join(chr(34) + d + chr(34) for d in deps)}],',
            f'            path: "tau-shims/{name}",',
            f"            sources: [{', '.join(chr(34) + f + chr(34) for f in compiled)}],",
            "            swiftSettings: [.swiftLanguageMode(.v5)]",
            "        ),",
        ]))
        print(f"{name}: shim, {len(compiled)} sources")

    products = "\n".join(f'        .library(name: "{name}", targets: ["{name}"]),' for name in [*MODULES, *SHIMS])
    package = f"""// swift-tools-version: 6.0
// Generated by ios/scripts/vendor_telegram.py from Telegram-iOS {revision}. Do not edit.
// The modules below are Telegram-iOS code, GPLv2 (see NOTICE).
import PackageDescription

let package = Package(
    name: "TelegramFoundation",
    platforms: [.iOS(.v15)],
    products: [
{products}
    ],
    targets: [
{chr(10).join(targets)}
    ],
    cxxLanguageStandard: .cxx17
)
"""
    with open(os.path.join(DEST, "Package.swift"), "w") as f:
        f.write(package)
    copy_images()
    apply_patches()
    print(f"Telegram-iOS {revision} -> {os.path.relpath(DEST, ROOT)}")


main()
