# Chat folders

Telegram's folders, for tau's chats: tabs over the chat list (All, then the user's folders) that each show the chats a
folder takes in. Telegram's folders take in chat types (contacts, groups, bots); tau's chats differ by where they run,
so a folder takes in:

- **servers**: every chat on one server, say the Mac's or a Linux box's;
- **chats** picked by hand;
- **two live types**: Working (an agent is busy in it, or one of its subagents) and Unread (an answer not seen).

It leaves out chats picked by hand, and optionally the read ones and the archived ones (on by default, as All leaves the
archive out). A chat is in a folder if anything takes it in and nothing leaves it out (`ChatFolder.contains`).

Folders live on the phone (`ChatFolderStore`, UserDefaults), not on a server: they span servers. The first time the list
has chats tau makes the obvious ones: a folder per server while there are several.

## What is copied

- The tabs are Telegram's `HorizontalTabsComponent` (the iOS 26 lens selection, badges, reordering with delete marks)
  inside `HeaderPanelContainerComponent`'s glass capsule, set as the navigation bar's secondary content under the search
  field, so they stay as the field collapses and leave when search opens.
- The lists follow `ChatListContainerNode`: one list per folder, the neighbours laid out beside it while a horizontal
  drag (`InteractiveTransitionGestureRecognizer`, rubber-banded at the ends) moves between them, the tab selection
  following the finger; a tap slides the new list in from its side.
- A tab's long press is `tabContextGesture`'s menu: Edit Folder, Add Chats, Read All, Remove; on All, Edit Folders;
  Reorder Tabs when there are two folders or more, which makes the tabs draggable with Done in the compose button's place.
- A chat's menu has Add to Folder (a submenu of the folders it is not in) and, inside a folder, Remove from Folder, with
  Undo.
- Settings > Chat Folders is `ChatListFilterPresetListController`: its animation, the folders with their chat counts,
  Create a New Folder, and recommended folders with Add (each server, Working, Unread). A folder's
  screen is `ChatListFilterPresetController`: the name, Included Chats with Add Chats, Excluded Chats with Remove Chats,
  Delete Folder; the name follows what is picked until the user types one. The picker lists the types, then servers, then
  the chats, with checks.
- An empty folder shows `ChatListEmptyNode`'s `.filter` state with Edit Folder.

Not copied: folder icons and colors, shared folder links, and Telegram's limits.
