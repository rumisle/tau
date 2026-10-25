#!/usr/bin/env python3
"""Copy Telegram-iOS modules verbatim into ios/ThirdParty/Telegram and generate a SwiftPM package for them.

Usage: uv run ios/scripts/vendor_telegram.py [path to a Telegram-iOS checkout, default vendor/Telegram-iOS]

ROOTS lists the modules tau uses. Everything they depend on is copied too, read from Telegram's Bazel BUILD files
(sources, public headers, include roots, defines, deps), except modules in SHIMS: those are tau's stand-ins, with
the module's name and only the API the copied code uses, for modules bound to Telegram's account, network and
database layers. Modules keep their Telegram-iOS paths, so `diff -r` against a checkout shows every local change.
"""
import glob
import os
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from telegram_build import OBJC, SWIFT, Glob, Workspace, compile_flags, label_name, normalize_label  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SOURCE = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "vendor", "Telegram-iOS")
DEST = os.path.join(ROOT, "ios", "ThirdParty", "Telegram")

# What tau imports. Their dependencies are found from the BUILD files.
ROOTS = [
    "//submodules/Display",
    "//submodules/ComponentFlow",
    "//submodules/MergeLists",
    "//submodules/GradientBackground",
    "//submodules/ActivityIndicator",
    "//submodules/Components/MultilineTextComponent",
    "//submodules/TelegramUI/Components/GlassBackgroundComponent",
    "//submodules/TelegramUI/Components/EdgeEffect",
    "//submodules/TelegramUI/Components/NavigationBarImpl",
    "//submodules/TelegramUI/Components/LottieComponent",
    "//submodules/TelegramUI/Components/Chat/MessageInlineBlockBackgroundView",
    "//submodules/TelegramUI/Components/InteractiveTextComponent",
    "//submodules/TelegramUI/Components/TabBarComponent",
    "//submodules/TelegramUI/Components/StreamingTextReveal",
    "//submodules/AudioBlob",
    "//submodules/TelegramPresentationData",
    "//submodules/ContextUI",
    "//submodules/TelegramUI/Components/ContextControllerImpl",
    "//submodules/CheckNode",
    "//submodules/TelegramUI/Components/Chat/ChatMessageSelectionNode",
    "//submodules/LegacyComponents",
    "//submodules/Svg",
    "//submodules/TelegramUI/Components/AnimatedTextComponent",
    "//submodules/AnimatedCountLabelNode",
    "//submodules/AttachmentUI",
    "//submodules/MediaPickerUI",
    "//submodules/ImageBlur",
    "//submodules/Components/ViewControllerComponent",
    "//submodules/TelegramUI/Components/GlassBarButtonComponent",
    "//submodules/TelegramUI/Components/GlassControls",
    "//submodules/ItemListUI",
    "//submodules/GalleryUI",
    "//third-party/libprisma",
    "//submodules/TelegramUI/Components/ContextMenuScreen",
    "//submodules/TextSelectionNode",
    "//submodules/SearchBarNode",
    "//submodules/SearchUI",
    "//submodules/TelegramUI/Components/ChatListTitleView",
    "//submodules/UndoUI",
    "//submodules/TelegramUI/Components/AlertComponent",
    "//submodules/TelegramUI/Components/AlertComponent/AlertInputFieldComponent",
    "//submodules/TelegramUI/Components/HorizontalTabsComponent",
]

# tau's stand-ins, in ios/ThirdParty/telegram-shims/<name>, copied to tau-shims/<name>. name: deps (module names).
SHIMS = {
    "TelegramCore": ["Postbox", "SwiftSignalKit"],
    "Postbox": ["SwiftSignalKit"],
    "TelegramUIPreferences": ["TelegramCore", "Postbox", "Display"],
    "MediaResources": ["TelegramCore", "Postbox", "SwiftSignalKit"],
    "TinyThumbnail": [],
    "AccountContext": ["TelegramCore", "Postbox", "SwiftSignalKit", "Display", "AsyncDisplayKit", "TelegramPresentationData", "LottieSettings", "AnimationCache", "MultiAnimationRenderer", "TextFormat"],
    "AnimationCache": ["SwiftSignalKit"],
    "MultiAnimationRenderer": ["AnimationCache"],
    "EmojiTextAttachmentView": ["Display", "TelegramCore", "AccountContext", "AnimationCache", "MultiAnimationRenderer", "TextFormat"],
    "AnimatedStickerNode": ["Display", "AsyncDisplayKit", "SwiftSignalKit"],
    "EmojiStatusComponent": ["Display", "ComponentFlow", "TelegramCore", "AccountContext", "AnimationCache", "MultiAnimationRenderer"],
    "EntityKeyboard": ["Display", "ComponentFlow", "TelegramCore", "AccountContext", "AnimationCache", "MultiAnimationRenderer"],
    "ReactionSelectionNode": ["AsyncDisplayKit", "Display", "TelegramCore", "AccountContext", "AnimationCache", "MultiAnimationRenderer", "EntityKeyboard", "SwiftSignalKit", "TelegramPresentationData"],
    "TopMessageReactions": ["TelegramCore", "AccountContext", "ReactionSelectionNode"],
    "TextFormat": ["TelegramCore"],
    "AttachmentTextInputPanelNode": ["Display", "AsyncDisplayKit", "ComponentFlow", "TelegramCore", "TelegramPresentationData", "AccountContext", "ChatPresentationInterfaceState", "GlassBackgroundComponent", "AppBundle"],
    "ChatPresentationInterfaceState": ["Display", "TelegramCore", "TelegramPresentationData", "TelegramUIPreferences", "AccountContext"],
    "ChatSendMessageActionUI": ["Display", "ComponentFlow", "SwiftSignalKit"],
    "LegacyMessageInputPanel": ["Display", "AsyncDisplayKit", "SwiftSignalKit", "ComponentFlow", "TelegramCore", "Postbox", "TelegramPresentationData", "AccountContext", "LegacyComponents", "TextFormat", "TelegramUIPreferences"],
    "LegacyMessageInputPanelInputView": ["Display", "AsyncDisplayKit", "SwiftSignalKit", "ComponentFlow", "TelegramCore", "Postbox", "TelegramPresentationData", "AccountContext", "LegacyComponents", "TextFormat", "TelegramUIPreferences"],
    "TelegramBaseController": ["Display", "AsyncDisplayKit", "SwiftSignalKit", "ComponentFlow", "TelegramCore", "Postbox", "TelegramPresentationData", "AccountContext", "LegacyComponents", "TextFormat", "TelegramUIPreferences"],
    "MinimizedContainer": ["Display", "AsyncDisplayKit", "SwiftSignalKit", "ComponentFlow", "TelegramCore", "Postbox", "TelegramPresentationData", "AccountContext", "LegacyComponents", "TextFormat", "TelegramUIPreferences"],
    "UniversalMediaPlayer": ["Display", "AsyncDisplayKit", "SwiftSignalKit", "ComponentFlow", "TelegramCore", "Postbox", "TelegramPresentationData", "AccountContext", "LegacyComponents", "TextFormat", "TelegramUIPreferences"],
    "PhotoResources": ["Display", "AsyncDisplayKit", "SwiftSignalKit", "TelegramCore", "Postbox", "AccountContext"],
    "OverlayStatusController": ["Display", "AsyncDisplayKit", "SwiftSignalKit", "ComponentFlow", "TelegramCore", "Postbox", "TelegramPresentationData", "AccountContext", "LegacyComponents", "TextFormat", "TelegramUIPreferences"],
    "TelegramStringFormatting": ["TelegramPresentationData", "TelegramCore", "TelegramUIPreferences"],
    "AnimatedStickerComponent": ["Display", "ComponentFlow", "TelegramCore", "LottieComponent", "LottieSettings"],
    "MediaEditor": ["Display"],
    "Camera": ["SwiftSignalKit"],
    "CameraLegacy": ["Display", "AsyncDisplayKit", "SwiftSignalKit", "ComponentFlow", "TelegramCore", "Postbox", "TelegramPresentationData", "AccountContext", "LegacyComponents", "TextFormat", "TelegramUIPreferences"],
    "WallpaperBackgroundNode": ["Display", "AsyncDisplayKit", "AccountContext", "TelegramCore", "TelegramPresentationData"],
    "LegacyMediaPickerUI": [],
    "ImageObjectSeparation": ["SwiftSignalKit", "AccountContext"],
    "PresentationDataUtils": ["Display", "TelegramPresentationData", "SolidRoundedButtonNode", "SwiftSignalKit", "AccountContext"],
    "ChatMessageBackground": ["Display", "AsyncDisplayKit", "TelegramCore", "TelegramPresentationData", "WallpaperBackgroundNode"],
    "AvatarBackground": ["Display", "AsyncDisplayKit", "SwiftSignalKit", "ComponentFlow", "TelegramCore", "Postbox", "TelegramPresentationData", "AccountContext", "LegacyComponents", "TextFormat", "TelegramUIPreferences"],
    "TelegramAnimatedStickerNode": ["AnimatedStickerNode", "LottieSettings"],
    "LegacyUI": ["Display", "AsyncDisplayKit", "SwiftSignalKit", "ComponentFlow", "TelegramCore", "Postbox", "TelegramPresentationData", "AccountContext", "LegacyComponents", "TextFormat", "TelegramUIPreferences"],
    "DrawingUI": ["Display", "AsyncDisplayKit", "SwiftSignalKit", "ComponentFlow", "TelegramCore", "Postbox", "TelegramPresentationData", "AccountContext", "LegacyComponents", "TextFormat", "TelegramUIPreferences"],
    "AvatarNode": ["Display", "AsyncDisplayKit", "TelegramCore", "AccountContext", "TelegramPresentationData"],
    "TLottieBinding": [],
}
SHIMS_SOURCE = os.path.join(ROOT, "ios", "ThirdParty", "telegram-shims")

# Per-module changes to what the BUILD file says.
OVERRIDES = {
    # Only the text engine, not its TelegramCore-bound wrapper.
    "InteractiveTextComponent": {"srcs": ["Sources/InteractiveTextComponent.swift"]},
    # The list item base types and the rows' swipe actions (ItemListRevealOptionsItemNode), not the settings lists.
    # "deps" replaces the BUILD file's, which serve the whole module.
    "ItemListUI": {
        "srcs": [
            "Sources/ItemListItem.swift",
            "Sources/ListItemWithHeader.swift",
            "Sources/ItemListRevealOptionsNode.swift",
            "Sources/Items/ItemListEditableItem.swift",
        ],
        "deps": [
            "//submodules/Display",
            "//submodules/AsyncDisplayKit",
            "//submodules/SSignalKit/SwiftSignalKit",
            "//submodules/TelegramPresentationData",
            "//submodules/LottieSettings",
            "//submodules/ManagedAnimationNode",
        ],
    },
    # The avatar editor's preview, and the full-screen gallery (LegacyMediaPickerUI, TGMediaPickerGalleryModel).
    "MediaPickerUI": {"exclude": ["Sources/AvatarEditorPreviewView.swift", "Sources/LegacyMediaPickerGallery.swift"]},
    # The media viewer's frame (pager, zoomable page, swipe to dismiss, the open and close transitions), not the chat
    # media items, which are bound to messages.
    "GalleryUI": {
        "srcs": [
            "Sources/GalleryControllerNode.swift",
            "Sources/GalleryControllerPresentationState.swift",
            "Sources/GalleryFooterContentNode.swift",
            "Sources/GalleryFooterNode.swift",
            "Sources/GalleryItem.swift",
            "Sources/GalleryItemNode.swift",
            "Sources/GalleryItemTransitionNode.swift",
            "Sources/GalleryPagerNode.swift",
            "Sources/GalleryThumbnailContainerNode.swift",
            "Sources/GalleryTitleView.swift",
            "Sources/ZoomableContentGalleryItemNode.swift",
        ],
        "deps": [
            "//submodules/Display",
            "//submodules/AsyncDisplayKit",
            "//submodules/SSignalKit/SwiftSignalKit",
            "//submodules/SwipeToDismissGesture",
            "//submodules/AccountContext",
            "//submodules/UndoUI",
            "//submodules/TelegramCore",
            "//submodules/TelegramPresentationData",
            "//submodules/TelegramStringFormatting",
            "//submodules/ComponentFlow",
            "//submodules/Components/ComponentDisplayAdapters",
            "//submodules/Components/MultilineTextComponent",
            "//submodules/TelegramUI/Components/EdgeEffect",
            "//submodules/TelegramUI/Components/GlassBackgroundComponent",
        ],
    },
    # The toasts that need no account (patch 0010): no stickers, dice, peers or custom emoji.
    "UndoUI": {
        "deps": [
            "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
            "//submodules/LottieSettings:LottieSettings",
            "//submodules/AsyncDisplayKit:AsyncDisplayKit",
            "//submodules/Display:Display",
            "//submodules/TelegramCore:TelegramCore",
            "//submodules/TelegramPresentationData:TelegramPresentationData",
            "//submodules/TextFormat:TextFormat",
            "//submodules/Markdown:Markdown",
            "//submodules/RadialStatusNode:RadialStatusNode",
            "//submodules/AnimationUI:AnimationUI",
            "//submodules/AnimatedStickerNode:AnimatedStickerNode",
            "//submodules/AppBundle:AppBundle",
            "//submodules/TelegramAnimatedStickerNode:TelegramAnimatedStickerNode",
            "//submodules/AvatarNode:AvatarNode",
            "//submodules/AccountContext:AccountContext",
            "//submodules/ComponentFlow:ComponentFlow",
            "//submodules/TelegramUI/Components/EmojiStatusComponent",
            "//submodules/TelegramUI/Components/TextNodeWithEntities",
            "//submodules/Components/BundleIconComponent",
            "//submodules/TelegramUI/Components/AnimatedTextComponent",
            "//submodules/Components/ComponentDisplayAdapters",
        ],
    },
    # Loading and coding themes and wallpapers from Telegram's cloud. tau uses the built-in themes.
    "TelegramPresentationData": {
        "exclude": [
            "Sources/ChatControllerBackgroundNode.swift",
            "Sources/PresentationThemeCoder.swift",
            "Sources/PresentationThemeCodable.swift",
        ],
    },
}

# Generated at build time in Telegram: label -> function(module dir) that writes the sources.
def generate_presentation_strings(directory: str) -> None:
    os.makedirs(os.path.join(directory, "GeneratedPresentationStrings", "Sources"), exist_ok=True)
    os.makedirs(os.path.join(directory, "GeneratedPresentationStrings", "PublicHeaders", "PresentationStrings"), exist_ok=True)
    os.makedirs(os.path.join(directory, "GeneratedPresentationStrings", "Resources"), exist_ok=True)
    subprocess.check_call([
        sys.executable, os.path.join(SOURCE, "build-system", "GenerateStrings", "GenerateStrings.py"),
        "--source=" + os.path.join(SOURCE, "Telegram", "Telegram-iOS", "en.lproj", "Localizable.strings"),
        "--outImplementation=" + os.path.join(directory, "GeneratedPresentationStrings", "Sources", "PresentationStrings.m"),
        "--outHeader=" + os.path.join(directory, "GeneratedPresentationStrings", "PublicHeaders", "PresentationStrings", "PresentationStrings.h"),
        "--outData=" + os.path.join(directory, "GeneratedPresentationStrings", "Resources", "PresentationStrings.data"),
    ], stdout=subprocess.DEVNULL)


GENERATED = {"//Telegram:PresentationStrings": generate_presentation_strings}

# Telegram images the modules load with UIImage(bundleImageName:), from submodules/TelegramUI/Images.xcassets.
IMAGES = [
    "Chat/Message/ReplyQuoteIcon",
    "Chat/Message/TextCodeIcon",
    "Item List/ExpandingItemVerticalRegularArrow",
    "Chat List/Tabs/IconChats",
    "Chat List/Tabs/IconSettings",
    "Chat List/Tabs/IconContacts",
    "Chat List/Tabs/IconCalls",
    "Chat/Input/Text/IconAttachment",
    "Chat/Input/Text/IconMicrophone",
    "Chat/Input/Text/SendIcon",
    "Item List/Icons/Gradient",
    "Item List/Icons/Backdrop",
    "Item List/Icons/Appearance",
    "Item List/Icons/Proxy",
    "Item List/Icons/AITools",
    "Item List/Icons/Notifications",
    "Item List/Icons/Data",
    "Item List/Icons/Faq",
    "Item List/Icons/Privacy",
    "Item List/Icons/Folder",
    "Item List/Icons/Tips",
    "Item List/Icons/Pie",
    "Item List/Icons/Wifi",
    "Item List/Icons/Cellular",
    "Item List/Icons/Stats",
    "Item List/Icons/Bot",
    "Item List/Icons/Speed",
    "Chat/Attach Menu/Camera",
    "Chat/Context Menu/Copy",
    "Chat/Context Menu/Edit",
    "Chat/Context Menu/Select",
    "Chat/Context Menu/Delete",
    "Chat/Context Menu/HideArchive",
    "Chat/Context Menu/Forward",
    "Chat/Context Menu/Share",
    "Chat/Context Menu/Reply",
    "Chat/Context Menu/Read",
    "Chat/Context Menu/Unread",
    "Chat/Context Menu/Pin",
    "Chat/Context Menu/Unpin",
    "Chat/Context Menu/Archive",
    "Chat/Context Menu/Info",
    "Chat/Context Menu/Settings",
    "Chat/Context Menu/Clear",
    "Chat/Input/Accessory Panels/MessageSelectionAction",
    "Chat/Input/Accessory Panels/MessageSelectionForward",
    "Chat/Input/Accessory Panels/MessageSelectionTrash",
    "Chat/Input/Accessory Panels/EditIcon",
    "Chat/Input/Accessory Panels/CloseIcon",
    "Chat/Context Menu/Translate",
    "Chat/Context Menu/MarkAsRead",
    "Chat/Context Menu/MarkAsUnread",
    "Chat/Context Menu/Reload",
    "Chat/Context Menu/Pencil",
    "Chat/Context Menu/Quote",
    "Chat/Context Menu/SelectAll",
    "Chat/Context Menu/Resend",
    "Chat/Context Menu/Message",
    "Chat/Context Menu/Folder",
    "Chat/Context Menu/Pause",
    "Chat/Context Menu/More",
    "Chat/Context Menu/Back",
    "Chat/Context Menu/Check",
    "Chat/Context Menu/Timer",
    "Chat/Input/Search/DownButton",
    "Chat/Input/Search/UpButton",
    "Avatar/ArchiveAvatarIcon",
    "Chat/Context Menu/Unarchive",
    # The send button's menu: Send as Follow-up (ChatSendMessageContextScreen's Schedule Message icon).
    "Chat/Input/Menu/ScheduleIcon",
    # The title menu's Subagents.
    "Chat/Context Menu/Bots",
    "Chat/Context Menu/CellMergeV",
    # The media viewer's ⋯ (Save Image) and a link's menu (Open in Safari).
    "Chat/Context Menu/Download",
    "Chat/Context Menu/Browser",
    "Chat/Context Menu/Globe",
    "Chat/Context Menu/ReadingList",
    # Pinned chats: the list's pin badge and the menu's Pin / Unpin.
    "Chat List/PeerPinnedIcon",
    "Chat/Context Menu/Pin",
    "Chat/Context Menu/Unpin",
    # The title menu's Search.
    "Chat/Context Menu/Search",
    # Chat folders: a tab's menu, a chat's Add to Folder, the picker's categories (ChatListController.tabContextGesture,
    # ChatContextMenus.swift, ChatListFilterPresetController).
    "Chat/Context Menu/Add",
    "Chat/Context Menu/EditFolder",
    "Chat/Context Menu/ReorderItems",
    "Chat/Context Menu/ReadAll",
    "Chat/Context Menu/AddToFolder",
    "Chat/Context Menu/RemoveFromFolder",
    "Chat List/Filters/Archive",
    "Chat List/Filters/Read",
    "Chat List/Filters/Chats",
    "Chat List/Filters/NewChats",
    "Chat List/Filters/Bot",
]

# Lottie animations LottieComponent.AppBundleContent loads by name, from submodules/TelegramUI/Resources/Animations.
ANIMATIONS = [
    "TabChats.json",
    "TabSettings.json",
    "TabContacts.json",
    "TabCalls.json",
    "TabPhoto.tgs",
    "TabFile.tgs",
    "TabLocation.tgs",
    "anim_micToVideo.json",
    "anim_videoToMic.json",
    "anim_camera.json",
    # The chat list's swipe actions (ChatListItem.swift's reveal option icons).
    "anim_archive.json",
    "anim_unarchive.json",
    "anim_read.json",
    "anim_unread.json",
    "anim_delete.json",
    "anim_hide.json",
    "anim_pin.json",
    "anim_unpin.json",
    # Search with nothing found, Chat Folders' header, a new folder's, an empty folder (ChatListSearchListPaneNode,
    # ChatListFilterSettingsHeaderItem, ChatListEmptyNode).
    "ChatListNoResults.tgs",
    "ChatListFolders.tgs",
    "ChatListNewFolder.tgs",
    "ChatListFilterEmpty.tgs",
]

# Local changes, applied in order with `git apply` after copying. Paths in them are relative to ios/ThirdParty/Telegram.
PATCHES = os.path.join(ROOT, "ios", "ThirdParty", "telegram-patches")


def referenced_images() -> list[str]:
    """Every image name a copied Swift source loads with UIImage(bundleImageName:), plus IMAGES."""
    import re
    names = set(IMAGES)
    pattern = re.compile(r'bundleImageName:\s*"([^"]+)"')
    for root, _, filenames in os.walk(DEST):
        for filename in filenames:
            if filename.endswith(".swift"):
                names.update(pattern.findall(open(os.path.join(root, filename), errors="ignore").read()))
    return sorted(names)


def referenced_animations(directory: str) -> list[str]:
    """ANIMATIONS, plus every bundled Lottie file a copied source names in a string literal."""
    import re
    available = {os.path.splitext(f)[0]: f for f in os.listdir(directory) if f.endswith((".json", ".tgs"))}
    names = set(ANIMATIONS)
    literal = re.compile(r'"([A-Za-z0-9_]+)"')
    for root, _, filenames in os.walk(DEST):
        for filename in filenames:
            if filename.endswith((".swift", ".m")):
                for token in literal.findall(open(os.path.join(root, filename), errors="ignore").read()):
                    if token in available:
                        names.add(available[token])
    return sorted(names)


def copy_images() -> None:
    catalog = os.path.join(SOURCE, "submodules", "TelegramUI", "Images.xcassets")
    target_catalog = os.path.join(DEST, "Images.xcassets")
    os.makedirs(target_catalog)
    with open(os.path.join(target_catalog, "Contents.json"), "w") as f:
        f.write('{\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n')
    for name in referenced_images():
        if not os.path.isdir(os.path.join(catalog, name + ".imageset")):
            if name in IMAGES:
                print(f"warning: no image {name}")
            continue
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


def expand(base: str, spec) -> list[str]:
    if spec is None:
        return []
    include, exclude = (spec.include, spec.exclude) if isinstance(spec, Glob) else (list(spec), [])
    found = set()
    for pattern in include:
        if pattern.startswith(":") or pattern.startswith("//"):
            continue
        for path in glob.glob(os.path.join(base, pattern), recursive=True):
            if os.path.isfile(path):
                found.add(os.path.relpath(path, base))
    for pattern in exclude:
        for path in glob.glob(os.path.join(base, pattern), recursive=True):
            found.discard(os.path.relpath(path, base))
    return sorted(found)


def closure(ws: Workspace):
    """The rules to copy, in dependency-first order, and for each the module names it depends on."""
    order, deps_of, seen = [], {}, {}
    def visit(label, chain):
        label = normalize_label(label)
        name = label_name(label)
        if name in SHIMS:
            return name
        if label in seen:
            return seen[label]
        rule = ws.rule(label)
        if rule is None:
            sys.exit(f"no rule for {label} (via {' -> '.join(chain)})")
        if rule.kind not in SWIFT | OBJC:
            sys.exit(f"{label} is a {rule.kind} (via {' -> '.join(chain)})")
        seen[label] = rule.name
        names = []
        for dep in OVERRIDES.get(rule.name, {}).get("deps", rule.attrs.get("deps", [])) or []:
            if not isinstance(dep, str):
                continue
            if dep.startswith(":"):
                dep = f"//{rule.path}{dep}"
            names.append(visit(dep, chain + [rule.name]))
        deps_of[rule.name] = sorted(set(names))
        order.append(rule)
        return rule.name
    for root in ROOTS:
        visit(root, [])
    return order, deps_of


def relative_include(path: str, module_path: str) -> str:
    """A -I path from Telegram's copts (workspace-relative) as a path relative to the module directory."""
    if path == module_path:
        return "."
    if path.startswith(module_path + "/"):
        return path[len(module_path) + 1 :]
    return os.path.relpath(path, module_path)


def main() -> None:
    revision = subprocess.check_output(["git", "-C", SOURCE, "rev-parse", "HEAD"], text=True).strip()
    if os.path.exists(DEST):
        shutil.rmtree(DEST)
    os.makedirs(DEST)
    with open(os.path.join(DEST, "NOTICE"), "w") as f:
        f.write(
            "These modules are copied from Telegram-iOS (https://github.com/TelegramMessenger/Telegram-iOS), "
            "licensed under the GNU GPL\nv2 or later (telegram.org/apps), at the revision in REVISION; tau takes them "
            "under the GPL v3. Modules that carry their own LICENSE file (AsyncDisplayKit: Apache 2.0, from Texture) "
            "keep it.\n"
        )
    with open(os.path.join(DEST, "REVISION"), "w") as f:
        f.write(revision + "\n")

    ws = Workspace(SOURCE)
    rules, deps_of = closure(ws)
    # Bazel lets a module import its dependencies' dependencies; SwiftPM needs them declared. Add every copied module
    # or shim a Swift target's sources import.
    available = {rule.name for rule in rules} | set(SHIMS)
    for rule in rules:
        if rule.kind not in SWIFT:
            continue
        imported = set()
        for rel in expand(os.path.join(SOURCE, rule.path), OVERRIDES.get(rule.name, {}).get("srcs", rule.attrs.get("srcs"))):
            if rel.endswith(".swift"):
                for line in open(os.path.join(SOURCE, rule.path, rel), errors="ignore"):
                    if line.startswith("import "):
                        imported.add(line.split()[1])
        deps_of[rule.name] = sorted(set(deps_of[rule.name]) | ((imported & available) - {rule.name}))
    module_paths = {rule.path for rule in rules}
    targets = []
    total = 0
    for rule in rules:
        name, path, attrs = rule.name, rule.path, rule.attrs
        override = OVERRIDES.get(name, {})
        base = os.path.join(SOURCE, path)
        out = os.path.join(DEST, path)
        if rule.label in GENERATED:
            GENERATED[rule.label](out)
            base = out
        srcs = override.get("srcs", attrs.get("srcs"))
        if "exclude" in override:
            srcs = (srcs if isinstance(srcs, Glob) else Glob(list(srcs))) + Glob([], override["exclude"])
        sources = expand(base, srcs)
        headers = expand(base, attrs.get("hdrs"))
        if base != out:
            for rel in sources + headers + [p for p in ("LICENSE",) if os.path.exists(os.path.join(base, p))]:
                target = os.path.join(out, rel)
                os.makedirs(os.path.dirname(target), exist_ok=True)
                shutil.copy2(os.path.join(base, rel), target)
        compiled = [rel for rel in sources if not rel.endswith((".h", ".hpp", ".inc"))]
        defines, includes = compile_flags([c for c in attrs.get("copts", []) or [] if isinstance(c, str)])
        defines += [d for d in attrs.get("defines", []) or [] if isinstance(d, str)]
        if rule.kind in OBJC and not compiled:
            # A header-only library still needs one source file to be a target.
            with open(os.path.join(out, "tau-empty.c"), "w") as f:
                f.write("")
            compiled = ["tau-empty.c"]
        lines = [
            "        .target(",
            f'            name: "{name}",',
            f'            dependencies: [{", ".join(chr(34) + d + chr(34) for d in deps_of[name])}],',
            f'            path: "{path}",',
        ]
        # A module nested in this one's directory (MeshTransform/MeshTransformApi) must not be part of it.
        nested = sorted(other[len(path) + 1 :] for other in module_paths if other.startswith(path + "/"))
        if nested:
            lines.append(f'            exclude: [{", ".join(chr(34) + n + chr(34) for n in nested)}],')
        lines += ["            sources: [", *[f'                "{rel}",' for rel in compiled], "            ],"]
        if rule.kind in OBJC:
            roots = attrs.get("includes") or []
            include = roots[0] if roots else "tau-include"
            os.makedirs(os.path.join(out, include), exist_ok=True)
            public = [os.path.relpath(rel, include) for rel in headers if not os.path.relpath(rel, include).startswith("..")]
            # Swift imports the module through this map; C++-only headers stay out of it.
            listed = [h for h in public if h.endswith(".h")]
            with open(os.path.join(out, include, "module.modulemap"), "w") as f:
                f.write(f"module {name} {{\n" + "".join(f'    header "{h}"\n' for h in listed) + "    export *\n}\n")
            settings = []
            for value in defines:
                if "=" in value:
                    key, val = value.split("=", 1)
                    settings.append(f'.define("{key}", to: "{val}")')
                else:
                    settings.append(f'.define("{value}")')
            header_paths = [relative_include(i, path) for i in includes] + list(roots[1:])
            settings += [f'.headerSearchPath("{h}")' for h in dict.fromkeys(header_paths) if h != include]
            lines.append(f'            publicHeadersPath: "{include}",')
            lines.append(f"            cSettings: [{', '.join(settings)}],")
            lines.append(f"            cxxSettings: [{', '.join(settings)}],")
            links = [f'.linkedLibrary("{lib.removeprefix("lib")}")' for lib in attrs.get("sdk_dylibs", []) or []]
            links += [f'.linkedFramework("{fw}")' for fw in attrs.get("sdk_frameworks", []) or [] if fw.lower() != "uikit" or fw == "UIKit"]
            lines.append(f"            linkerSettings: [{', '.join(links)}]")
        else:
            settings = [".swiftLanguageMode(.v5)"] + [f'.define("{d}")' for d in defines]
            lines.append(f"            swiftSettings: [{', '.join(settings)}]")
        lines.append("        ),")
        targets.append("\n".join(lines))
        total += len(compiled)
        print(f"{name}: {len(compiled)} sources, {len(headers)} headers")

    for name, deps in SHIMS.items():
        source = os.path.join(SHIMS_SOURCE, name)
        if not os.path.isdir(source):
            sys.exit(f"missing shim {source}")
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

    products = "\n".join(f'        .library(name: "{name}", targets: ["{name}"]),' for name in [*(r.name for r in rules), *SHIMS])
    package = f"""// swift-tools-version: 6.0
// Generated by ios/scripts/vendor_telegram.py from Telegram-iOS {revision}. Do not edit.
// The modules below are Telegram-iOS code, GPL v2 or later (see NOTICE).
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
    os.makedirs(os.path.join(DEST, "Animations"))
    animations_dir = os.path.join(SOURCE, "submodules", "TelegramUI", "Resources", "Animations")
    for name in referenced_animations(animations_dir):
        shutil.copy2(os.path.join(animations_dir, name), os.path.join(DEST, "Animations", name))
    # Bundle resources the modules load at runtime: the strings table PresentationStrings reads.
    resources = os.path.join(DEST, "Resources")
    os.makedirs(os.path.join(resources, "en.lproj"))
    shutil.copy2(os.path.join(SOURCE, "Telegram", "Telegram-iOS", "en.lproj", "Localizable.strings"), os.path.join(resources, "en.lproj", "Localizable.strings"))
    shutil.move(os.path.join(DEST, "Telegram", "GeneratedPresentationStrings", "Resources", "PresentationStrings.data"), os.path.join(resources, "PresentationStrings.data"))
    # LegacyComponents loads its images from this bundle (TGComponentsImageNamed) and an asset catalog.
    legacy = os.path.join(SOURCE, "submodules", "LegacyComponents")
    shutil.copytree(os.path.join(legacy, "Resources", "LegacyComponentsResources.bundle"), os.path.join(resources, "LegacyComponentsResources.bundle"), ignore=shutil.ignore_patterns(".*"))
    shutil.copytree(os.path.join(legacy, "LegacyImages.xcassets"), os.path.join(DEST, "LegacyImages.xcassets"))
    # libprisma's Syntaxer reads its grammars from LibprismaBundle.bundle next to its class, here the app bundle.
    os.makedirs(os.path.join(resources, "LibprismaBundle.bundle"))
    shutil.copy2(os.path.join(SOURCE, "third-party", "libprisma", "Resources", "grammars.dat"), os.path.join(resources, "LibprismaBundle.bundle", "grammars.dat"))
    apply_patches()
    print(f"{len(rules)} modules, {total} sources, {len(SHIMS)} shims. Telegram-iOS {revision} -> {os.path.relpath(DEST, ROOT)}")


main()
