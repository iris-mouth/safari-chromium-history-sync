#!/usr/bin/env python3
import sys
import json
import struct
import subprocess
import plistlib
import os
import shutil
import logging
import threading
import time
from datetime import datetime, timezone
from urllib.parse import urlparse, urlunparse, parse_qsl, urlencode

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
BASE_DIR = os.path.expanduser(os.environ.get("SAFARI_SYNC_STATE_DIR", SCRIPT_DIR))
BOOKMARKS_PATH = os.path.expanduser(
    os.environ.get("SAFARI_BOOKMARKS_PATH", "~/Library/Safari/Bookmarks.plist")
)
LOG_PATH = os.path.join(BASE_DIR, "sync.log")
STATE_PATH = os.path.join(BASE_DIR, "state.json")
POLL_INTERVAL = 1

os.makedirs(BASE_DIR, exist_ok=True)

logging.basicConfig(
    filename=LOG_PATH,
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)

SAFARI_BAR = "BookmarksBar"
SAFARI_MENU = "BookmarksMenu"
SAFARI_RL = "com.apple.ReadingList"
SYSTEM_ROOTS = {SAFARI_BAR, SAFARI_MENU, SAFARI_RL, "History"}
CANON_BAR = "BAR"
CANON_OTHER = "OTHER"

TRACKING_PARAMS = {
    "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
    "fbclid", "gclid", "msclkid", "mc_eid", "mc_cid", "igshid",
    "_ga", "_gl", "yclid", "dclid", "wbraid", "gbraid",
    "ref", "ref_src", "ref_url", "source", "via",
    "_hsenc", "_hsmi", "hsa_acc", "hsa_cam",
    "itm_source", "itm_medium", "itm_campaign",
    "itmmeta", "itmprp", "_skw",
    "_trkparms", "_trksid", "amdata", "__cf_chl_tk",
}


def normalize_url(url):
    if not url:
        return url
    try:
        p = urlparse(url.strip())
        scheme = (p.scheme or "https").lower()
        netloc = p.netloc.lower()
        if netloc.startswith("www."):
            netloc = netloc[4:]
        for dp in (":80", ":443"):
            if netloc.endswith(dp):
                netloc = netloc[: -len(dp)]
        path = p.path.rstrip("/") or "/"
        params = sorted(
            (k, v) for k, v in parse_qsl(p.query, keep_blank_values=True)
            if k.lower() not in TRACKING_PARAMS
        )
        return urlunparse((scheme, netloc, path, "", urlencode(params), ""))
    except Exception:
        return url.strip().lower()


stdout_lock = threading.Lock()
plist_lock = threading.Lock()
state_lock = threading.Lock()


def read_message():
    raw = sys.stdin.buffer.read(4)
    if len(raw) < 4:
        return None
    length = struct.unpack("I", raw)[0]
    return json.loads(sys.stdin.buffer.read(length).decode())


def send_message(msg):
    data = json.dumps(msg).encode()
    with stdout_lock:
        sys.stdout.buffer.write(struct.pack("I", len(data)))
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()


def load_state():
    try:
        with open(STATE_PATH) as f:
            return json.load(f)
    except Exception:
        return {}


_state = load_state()
sent_to_chrome = set(_state.get("sent_to_chrome", []))
folder_order_snapshot = _state.get("folder_order", {})  # path_key -> [norm_urls]
migration_done = _state.get("dissolve_bookmarksmenu_v2", False)


def persist_state():
    tmp = STATE_PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump({
            "sent_to_chrome": list(sent_to_chrome),
            "folder_order": folder_order_snapshot,
            "dissolve_bookmarksmenu_v2": migration_done,
        }, f)
    os.replace(tmp, STATE_PATH)


def migrate_dissolve_bookmarksmenu():
    """Move everything inside BookmarksMenu to plist root (leaves + subfolders),
    then remove the empty BookmarksMenu container entirely.

    Safari or earlier sync versions can recreate this container, so the presence
    of live children matters more than the historical migration flag.
    """
    global migration_done
    data = load_plist()
    root_children = data.setdefault("Children", [])

    menu = None
    for c in root_children:
        if isinstance(c, dict) and c.get("Title") == SAFARI_MENU:
            menu = c
            break
    if menu is None:
        if not migration_done:
            migration_done = True
            persist_state()
        return

    children_to_move = list(menu.get("Children", []) or [])
    if migration_done and not children_to_move:
        root_children.remove(menu)
        save_plist(data)
        logging.info("MIGRATE removed empty BookmarksMenu")
        return

    # Insertion point: just before ReadingList (preserves its position at the bottom)
    rl_idx = next((i for i, c in enumerate(root_children)
                   if isinstance(c, dict) and c.get("Title") == SAFARI_RL), len(root_children))

    moved_folders = 0
    moved_leaves = 0
    for item in children_to_move:
        root_children.insert(rl_idx, item)
        rl_idx += 1
        if isinstance(item, dict) and item.get("WebBookmarkType") == "WebBookmarkTypeList":
            moved_folders += 1
            logging.info("MIGRATE hoisted folder %r", item.get("Title"))
        else:
            moved_leaves += 1

    # Clear BookmarksMenu's children (it's been dissolved) then remove it from root
    menu["Children"] = []
    root_children.remove(menu)

    save_plist(data)
    logging.info(
        "MIGRATE dissolved BookmarksMenu: %d folders + %d leaves → plist root",
        moved_folders, moved_leaves,
    )
    migration_done = True
    persist_state()


def is_folder(node):
    return (
        isinstance(node, dict)
        and node.get("WebBookmarkType") == "WebBookmarkTypeList"
    )


def cleanup_bookmark_tree():
    """Normalize Safari's bookmark tree after older sync mappings.

    - Remove/dissolve BookmarksMenu.
    - Flatten literal "Other Bookmarks" folders; that is a Chromium root label,
      not a Safari folder we want to keep.
    - Merge duplicate sibling folders by title, preserving their children.
    """
    data = load_plist()
    changed = False

    def cleanup_children(node):
        nonlocal changed
        if not isinstance(node, dict) or "Children" not in node:
            return

        children = node.get("Children", []) or []
        rebuilt = []
        for child in children:
            if is_folder(child) and child.get("Title") in {SAFARI_MENU, "Other Bookmarks"}:
                rebuilt.extend(child.get("Children", []) or [])
                changed = True
            else:
                rebuilt.append(child)
        node["Children"] = rebuilt

        first_by_title = {}
        merged = []
        for child in node.get("Children", []) or []:
            if is_folder(child):
                title = child.get("Title")
                if title in first_by_title:
                    first_by_title[title].setdefault("Children", []).extend(child.get("Children", []) or [])
                    changed = True
                    continue
                first_by_title[title] = child
            merged.append(child)
        node["Children"] = merged

        for child in list(node.get("Children", []) or []):
            cleanup_children(child)

    cleanup_children(data)
    if changed:
        save_plist(data)
        logging.info("CLEANUP normalized Safari bookmark folders")


def record_sent(url):
    with state_lock:
        sent_to_chrome.add(url)


def path_key(path):
    return json.dumps(path)


def normalize_canonical_path(path):
    if not path:
        return path
    out = []
    for part in path:
        if part == "Other Bookmarks" and "Imported from Google Chrome" in out:
            continue
        out.append(part)
    if out == [CANON_OTHER, "Other Bookmarks"]:
        return [CANON_OTHER]
    return out


def load_plist():
    r = subprocess.run(
        ["plutil", "-convert", "xml1", "-o", "-", BOOKMARKS_PATH],
        capture_output=True, check=True,
    )
    return plistlib.loads(r.stdout)


def save_plist(data):
    with plist_lock:
        shutil.copy2(BOOKMARKS_PATH, BOOKMARKS_PATH + ".bak")
        tmp = BOOKMARKS_PATH + ".tmp"
        with open(tmp, "wb") as f:
            f.write(plistlib.dumps(data))
        subprocess.run(["plutil", "-convert", "binary1", tmp], check=True)
        os.replace(tmp, BOOKMARKS_PATH)


def new_uuid():
    return subprocess.run(["uuidgen"], capture_output=True, text=True).stdout.strip()


def find_root(data, title):
    for child in data.get("Children", []):
        if isinstance(child, dict) and child.get("Title") == title:
            return child
    return None


def new_folder(title):
    return {
        "Children": [],
        "Title": title,
        "WebBookmarkType": "WebBookmarkTypeList",
        "WebBookmarkUUID": new_uuid(),
        "dateAdded": datetime.now(timezone.utc),
    }


def ensure_folder_path(root_folder, parts):
    cur = root_folder
    for part in parts:
        children = cur.setdefault("Children", [])
        found = next(
            (c for c in children
             if isinstance(c, dict)
             and c.get("WebBookmarkType") == "WebBookmarkTypeList"
             and c.get("Title") == part),
            None,
        )
        if not found:
            found = new_folder(part)
            children.append(found)
        cur = found
    return cur


def find_or_create_toplevel(data, title):
    """Find a user-created top-level plist folder by title; create if missing."""
    for child in data.get("Children", []) or []:
        if (isinstance(child, dict)
            and child.get("WebBookmarkType") == "WebBookmarkTypeList"
            and child.get("Title") == title
            and title not in SYSTEM_ROOTS):
            return child
    new = new_folder(title)
    data.setdefault("Children", []).append(new)
    return new


def find_toplevel(data, title):
    for child in data.get("Children", []) or []:
        if (isinstance(child, dict)
            and child.get("WebBookmarkType") == "WebBookmarkTypeList"
            and child.get("Title") == title
            and title not in SYSTEM_ROOTS):
            return child
    return None


def descend_folder(root, parts, create=False):
    cur = root
    for part in parts:
        nxt = next(
            (c for c in cur.get("Children", []) or []
             if isinstance(c, dict)
             and c.get("WebBookmarkType") == "WebBookmarkTypeList"
             and c.get("Title") == part),
            None,
        )
        if nxt is None:
            if not create:
                return None
            nxt = new_folder(part)
            cur.setdefault("Children", []).append(nxt)
        cur = nxt
    return cur


def resolve_target_folder(data, path, create=True):
    """Map canonical path → plist folder container (the dict whose Children list holds the item).
    [BAR, ...]              → BookmarksBar / ...
    [OTHER]                 → plist root (loose leaves at top level)
    [OTHER, TopName, ...]   → top-level plist folder TopName / ...
    """
    path = normalize_canonical_path(path)
    if not path:
        return None
    if path[0] == CANON_BAR:
        root = find_root(data, SAFARI_BAR)
        sub_parts = path[1:]
    elif path[0] == CANON_OTHER:
        if len(path) == 1:
            return data  # plist root itself — its Children list holds loose leaves
        top_name = path[1]
        root = find_or_create_toplevel(data, top_name) if create else find_toplevel(data, top_name)
        sub_parts = path[2:]
    else:
        return None
    if root is None:
        return None
    return descend_folder(root, sub_parts, create=create)


# Back-compat alias — older callers used this name
def resolve_folder(data, path):
    return resolve_target_folder(data, path, create=False)


def url_exists(node, url):
    if isinstance(node, dict):
        if node.get("URLString") == url:
            return True
        for c in node.get("Children", []):
            if url_exists(c, url):
                return True
    return False


def url_exists_direct(folder, url):
    if not isinstance(folder, dict):
        return False
    return any(
        isinstance(c, dict) and c.get("URLString") == url
        for c in folder.get("Children", []) or []
    )


def pop_url_leaf(node, url):
    """Remove and return the first bookmark leaf with URLString == url."""
    if not isinstance(node, dict) or "Children" not in node:
        return None
    children = node.get("Children", []) or []
    for i, child in enumerate(children):
        if isinstance(child, dict) and child.get("URLString") == url:
            return children.pop(i)
    for child in children:
        found = pop_url_leaf(child, url)
        if found is not None:
            return found
    return None


def pop_url_leaf_direct(folder, url):
    if not isinstance(folder, dict):
        return None
    children = folder.get("Children", []) or []
    for i, child in enumerate(children):
        if isinstance(child, dict) and child.get("URLString") == url:
            return children.pop(i)
    return None


# --- Snapshot: walk plist, record leaves + ordered URL lists per folder ---

def snapshot_safari():
    """Returns (by_url, by_folder)."""
    data = load_plist()
    by_url = {}
    by_folder = {}

    def is_generated_sync_folder(path):
        return (
            len(path) >= 2
            and path[0] == CANON_OTHER
            and path[1] in {"Open Tabs", "Tab Groups"}
        )

    def walk_folder(node, path, is_rl):
        """Walk a real folder. path is the canonical path."""
        if not isinstance(node, dict):
            return
        if is_generated_sync_folder(path):
            return
        key = path_key(path)
        ordered = []

        for child in node.get("Children", []) or []:
            if not isinstance(child, dict):
                continue
            if child.get("WebBookmarkType") == "WebBookmarkTypeLeaf":
                url = child.get("URLString")
                if not url:
                    continue
                norm = normalize_url(url)
                if norm in by_url:
                    continue
                ctitle = child.get("URIDictionary", {}).get("title") or url
                by_url[norm] = {
                    "url": url,
                    "title": ctitle,
                    "path": path,
                    "kind": "reading_list" if is_rl else "bookmark",
                    "index": len(ordered),
                }
                ordered.append(norm)
            elif child.get("WebBookmarkType") == "WebBookmarkTypeList":
                walk_folder(child, path + [child.get("Title", "")], is_rl)

        if not is_rl and path:
            by_folder[key] = ordered

    # Top level of plist
    loose_ordered = []
    for child in data.get("Children", []) or []:
        if not isinstance(child, dict):
            continue
        title = child.get("Title", "")
        if title == SAFARI_BAR:
            walk_folder(child, [CANON_BAR], False)
        elif title == SAFARI_MENU:
            # Legacy — pre-migration. Walk as if its children were already at root.
            walk_folder(child, [CANON_OTHER], False)
        elif title == SAFARI_RL:
            walk_folder(child, [], True)
        elif title in SYSTEM_ROOTS:
            continue
        elif child.get("WebBookmarkType") == "WebBookmarkTypeList":
            # User top-level folder → canonical [OTHER, title, ...]
            walk_folder(child, [CANON_OTHER, title], False)
        elif child.get("WebBookmarkType") == "WebBookmarkTypeLeaf":
            # Loose leaf at plist root → path=[OTHER]
            url = child.get("URLString")
            if not url:
                continue
            norm = normalize_url(url)
            if norm in by_url:
                continue
            ctitle = child.get("URIDictionary", {}).get("title") or url
            by_url[norm] = {
                "url": url,
                "title": ctitle,
                "path": [CANON_OTHER],
                "kind": "bookmark",
                "index": len(loose_ordered),
            }
            loose_ordered.append(norm)

    if loose_ordered:
        by_folder[path_key([CANON_OTHER])] = loose_ordered

    return by_url, by_folder


# --- Add / remove / reorder ---

def add_at_path(url, title, path, is_reading_list, index=None, allow_duplicate=False):
    path = normalize_canonical_path(path or [CANON_OTHER])
    data = load_plist()
    now = datetime.now(timezone.utc)

    if is_reading_list:
        if url_exists(data, url):
            return {"status": "exists"}
        rl = find_root(data, SAFARI_RL)
        if rl is None:
            rl = {
                "Children": [],
                "Title": SAFARI_RL,
                "WebBookmarkType": "WebBookmarkTypeList",
                "WebBookmarkUUID": new_uuid(),
                "dateAdded": now,
            }
            data.setdefault("Children", []).append(rl)
        rl.setdefault("Children", []).append({
            "ReadingList": {"DateAdded": now},
            "ReadingListNonSync": {"neverFetchMetadata": False},
            "URIDictionary": {"title": title},
            "URLString": url,
            "WebBookmarkType": "WebBookmarkTypeLeaf",
            "WebBookmarkUUID": new_uuid(),
            "dateAdded": now,
        })
        save_plist(data)
        logging.info("RL+ %s", url)
        return {"status": "added"}

    target = resolve_target_folder(data, path, create=True)
    if target is None:
        return {"status": "error", "message": f"could not resolve path {path}"}

    if allow_duplicate and url_exists_direct(target, url):
        for child in target.get("Children", []) or []:
            if isinstance(child, dict) and child.get("URLString") == url:
                child["URIDictionary"] = child.get("URIDictionary") or {}
                child["URIDictionary"]["title"] = title
                save_plist(data)
                logging.info("BM~ %s @ %s[%s]", url, "/".join(path), index)
                return {"status": "updated"}
        return {"status": "exists"}

    leaf = None if allow_duplicate else pop_url_leaf(data, url)
    status = "moved" if leaf is not None else "added"
    if leaf is None:
        leaf = {
            "ReadingListNonSync": {"neverFetchMetadata": False},
            "URIDictionary": {"title": title},
            "URLString": url,
            "WebBookmarkType": "WebBookmarkTypeLeaf",
            "WebBookmarkUUID": new_uuid(),
            "dateAdded": now,
        }
    else:
        leaf["URIDictionary"] = leaf.get("URIDictionary") or {}
        leaf["URIDictionary"]["title"] = title
        leaf["URLString"] = url

    children = target.setdefault("Children", [])
    if index is None or index < 0 or index > len(children):
        children.append(leaf)
    else:
        children.insert(index, leaf)
    save_plist(data)
    logging.info("BM%s %s @ %s[%s]", "+" if status == "added" else ">", url, "/".join(path), index)
    return {"status": status}


def remove_url(url, path=None):
    path = normalize_canonical_path(path)
    data = load_plist()

    if path:
        folder = resolve_target_folder(data, path, create=False)
        leaf = pop_url_leaf_direct(folder, url)
        if leaf is not None:
            save_plist(data)
            logging.info("BM- %s @ %s", url, "/".join(path))
            return {"status": "removed"}

    def _rm(node):
        if not isinstance(node, dict) or "Children" not in node:
            return False
        before = len(node["Children"])
        node["Children"] = [
            c for c in node["Children"]
            if not (isinstance(c, dict) and c.get("URLString") == url)
        ]
        if len(node["Children"]) < before:
            return True
        return any(_rm(c) for c in node["Children"])

    if _rm(data):
        save_plist(data)
        logging.info("BM- %s", url)
        return {"status": "removed"}
    return {"status": "not_found"}


def reorder_folder(path, ordered_urls):
    """Reorder leaves within folder at `path` to match ordered_urls (by normalized URL)."""
    path = normalize_canonical_path(path)
    data = load_plist()
    folder = resolve_folder(data, path)
    if folder is None:
        return {"status": "folder_not_found"}

    children = list(folder.get("Children", []))

    if path == [CANON_OTHER]:
        # Plist root — reorder only loose leaves in place, keep folders/system roots where they are
        leaf_positions = [i for i, c in enumerate(children)
                          if isinstance(c, dict) and c.get("WebBookmarkType") == "WebBookmarkTypeLeaf"]
        leaves_by_norm = {}
        for i in leaf_positions:
            leaves_by_norm[normalize_url(children[i].get("URLString", ""))] = children[i]

        reordered = []
        seen = set()
        for norm in ordered_urls:
            leaf = leaves_by_norm.get(norm)
            if leaf is not None and norm not in seen:
                reordered.append(leaf)
                seen.add(norm)
        for norm, leaf in leaves_by_norm.items():
            if norm not in seen:
                reordered.append(leaf)

        new_children = list(children)
        for pos, leaf in zip(leaf_positions, reordered):
            new_children[pos] = leaf
        if new_children != children:
            folder["Children"] = new_children
            save_plist(data)
            logging.info("RO plist root (%d items)", len(ordered_urls))
            return {"status": "reordered"}
        return {"status": "unchanged"}

    # Regular folder
    leaves_by_norm = {}
    subfolders = []
    for c in children:
        if not isinstance(c, dict):
            continue
        if c.get("WebBookmarkType") == "WebBookmarkTypeLeaf":
            leaves_by_norm[normalize_url(c.get("URLString", ""))] = c
        else:
            subfolders.append(c)

    new_children = []
    seen = set()
    for norm in ordered_urls:
        leaf = leaves_by_norm.get(norm)
        if leaf is not None and norm not in seen:
            new_children.append(leaf)
            seen.add(norm)
    for norm, leaf in leaves_by_norm.items():
        if norm not in seen:
            new_children.append(leaf)
    new_children.extend(subfolders)

    if new_children != children:
        folder["Children"] = new_children
        save_plist(data)
        logging.info("RO %s (%d items)", "/".join(path), len(ordered_urls))
        return {"status": "reordered"}
    return {"status": "unchanged"}


# --- Watcher: push Safari deltas to Chrome ---

known_by_url = {}
known_by_folder = {}


def push_folder_order(path_str, ordered):
    """Send a reorder to Chrome for a folder whose order changed."""
    try:
        path = json.loads(path_str)
    except Exception:
        return
    send_message({
        "action": "reorder",
        "path": path,
        "urls": ordered,
    })


def watcher():
    global known_by_url, known_by_folder, folder_order_snapshot
    try:
        migrate_dissolve_bookmarksmenu()
        cleanup_bookmark_tree()
    except Exception as e:
        logging.error("startup cleanup failed: %s", e)
    try:
        known_by_url, known_by_folder = snapshot_safari()
    except Exception as e:
        logging.error("initial snapshot failed: %s", e)
        known_by_url, known_by_folder = {}, {}
    # Drop any stored folder-order keys that no longer exist under the new scheme
    for pk in list(folder_order_snapshot):
        if pk not in known_by_folder:
            folder_order_snapshot.pop(pk, None)

    with state_lock:
        to_push = {u: i for u, i in known_by_url.items() if u not in sent_to_chrome}
    logging.info("Initial: %d/%d new Safari items", len(to_push), len(known_by_url))
    # Send adds in path+index order so Chrome applies in the right sequence
    for url, info in sorted(
        to_push.items(),
        key=lambda kv: (kv[1]["path"], kv[1]["index"]),
    ):
        send_message({
            "action": "add",
            "kind": info["kind"],
            "url": info["url"],
            "title": info["title"],
            "path": info["path"],
            "index": info["index"],
        })
        record_sent(url)

    # Push initial folder order
    for pk, ordered in known_by_folder.items():
        prev = folder_order_snapshot.get(pk)
        if prev != ordered:
            push_folder_order(pk, ordered)
            folder_order_snapshot[pk] = ordered
    persist_state()

    last_mtime = 0.0
    try:
        last_mtime = os.path.getmtime(BOOKMARKS_PATH)
    except OSError:
        pass

    while True:
        time.sleep(POLL_INTERVAL)
        try:
            mtime = os.path.getmtime(BOOKMARKS_PATH)
            if mtime == last_mtime:
                continue
            last_mtime = mtime

            cur_url, cur_folder = snapshot_safari()
            added = {u: i for u, i in cur_url.items() if u not in known_by_url}
            removed = {u: i for u, i in known_by_url.items() if u not in cur_url}

            for url, info in sorted(
                added.items(),
                key=lambda kv: (kv[1]["path"], kv[1]["index"]),
            ):
                send_message({
                    "action": "add",
                    "kind": info["kind"],
                    "url": info["url"],
                    "title": info["title"],
                    "path": info["path"],
                    "index": info["index"],
                })
                record_sent(url)

            for url, info in removed.items():
                send_message({
                    "action": "remove",
                    "kind": info["kind"],
                    "url": info["url"],
                })
                with state_lock:
                    sent_to_chrome.discard(url)

            # Order changes per folder
            for pk, ordered in cur_folder.items():
                prev = folder_order_snapshot.get(pk)
                if prev != ordered:
                    push_folder_order(pk, ordered)
                    folder_order_snapshot[pk] = ordered

            # Folders gone entirely — drop from snapshot
            for pk in list(folder_order_snapshot):
                if pk not in cur_folder:
                    folder_order_snapshot.pop(pk, None)

            known_by_url = cur_url
            known_by_folder = cur_folder

            if added or removed:
                persist_state()
            else:
                # persist any reorder snapshot updates
                persist_state()
        except Exception as e:
            logging.error("watcher: %s", e)


threading.Thread(target=watcher, daemon=True).start()


# --- Main loop: process messages from Chrome ---

while True:
    msg = read_message()
    if msg is None:
        break
    try:
        action = msg.get("action")
        if action == "add":
            result = add_at_path(
                msg["url"],
                msg.get("title") or msg["url"],
                msg.get("path") or [CANON_OTHER],
                msg.get("kind") == "reading_list",
                msg.get("index"),
                msg.get("allowDuplicate", False),
            )
            if result.get("status") in ("added", "moved"):
                norm = normalize_url(msg["url"])
                known_by_url[norm] = {
                    "url": msg["url"],
                    "title": msg.get("title") or msg["url"],
                    "path": normalize_canonical_path(msg.get("path") or [CANON_OTHER]),
                    "kind": msg.get("kind", "bookmark"),
                    "index": msg.get("index", -1),
                }
                record_sent(norm)
        elif action == "remove":
            result = remove_url(msg["url"], msg.get("path"))
            if result.get("status") == "removed":
                norm = normalize_url(msg["url"])
                known_by_url.pop(norm, None)
                with state_lock:
                    sent_to_chrome.discard(norm)
        elif action == "reorder":
            result = reorder_folder(msg.get("path") or [], msg.get("urls") or [])
            # refresh our cached order for that folder so watcher doesn't echo
            if result.get("status") in ("reordered", "unchanged"):
                folder_order_snapshot[path_key(normalize_canonical_path(msg.get("path") or []))] = msg.get("urls") or []
        else:
            result = {"status": "unknown_action"}
    except Exception as e:
        logging.exception("error on %s", msg)
        result = {"status": "error", "message": str(e)}
    send_message(result)
