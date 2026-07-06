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
import sqlite3
import math
from datetime import datetime, timezone
from urllib.parse import urlparse, urlunparse, parse_qsl, urlencode

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_BASE_DIR = os.path.expanduser("~/Library/Application Support/Safari Sync")
BASE_DIR = os.path.expanduser(os.environ.get("SAFARI_SYNC_STATE_DIR", DEFAULT_BASE_DIR))
BOOKMARKS_PATH = os.path.expanduser(
    os.environ.get("SAFARI_BOOKMARKS_PATH", "~/Library/Safari/Bookmarks.plist")
)
HISTORY_PATH = os.path.expanduser(
    os.environ.get("SAFARI_HISTORY_PATH", "~/Library/Safari/History.db")
)
LOG_PATH = os.path.join(BASE_DIR, "sync.log")
STATE_PATH = os.path.join(BASE_DIR, "state.json")
BACKUP_DIR = os.path.join(BASE_DIR, "backups")
POLL_INTERVAL = 1
HISTORY_POLL_INTERVAL = 2
HISTORY_PUSH_LIMIT = 200
HISTORY_RECENT_KEYS_LIMIT = 5000
HISTORY_DEDUPE_SECONDS = 0.0005
MAC_EPOCH_OFFSET = 978307200

def migrate_legacy_runtime_files():
    if os.environ.get("SAFARI_SYNC_STATE_DIR"):
        return
    for name in ("state.json", "sync.log"):
        src = os.path.join(SCRIPT_DIR, name)
        dst = os.path.join(BASE_DIR, name)
        if os.path.exists(src) and not os.path.exists(dst):
            try:
                shutil.move(src, dst)
            except Exception:
                shutil.copy2(src, dst)


os.makedirs(BASE_DIR, exist_ok=True)
os.makedirs(BACKUP_DIR, exist_ok=True)
migrate_legacy_runtime_files()

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
state_lock = threading.RLock()


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
safari_history_cursor = _state.get("safari_history_cursor")
history_recent_from_chrome = set(_state.get("history_recent_from_chrome", []))

DEFAULT_CONFIG = {
    "paused": False,
    "direction": "bidirectional",
    "syncHistory": True,
    "syncReadingList": True,
    "syncOpenTabs": True,
    "syncTabGroups": True,
    "openTabsFolderName": "Open Tabs",
    "tabGroupsFolderName": "Tab Groups",
}
VALID_DIRECTIONS = {"bidirectional", "chrome_to_safari", "safari_to_chrome"}

sync_config = dict(DEFAULT_CONFIG)
config_lock = threading.Lock()
watcher_started = False
watcher_start_lock = threading.Lock()


def clean_folder_name(value, fallback):
    text = str(value or "").strip()
    return text or fallback


def apply_config(settings):
    global sync_config
    settings = settings or {}
    next_config = dict(DEFAULT_CONFIG)
    with config_lock:
        next_config.update(sync_config)
        next_config["paused"] = bool(settings.get("paused", next_config["paused"]))
        direction = settings.get("direction", next_config["direction"])
        next_config["direction"] = (
            direction if direction in VALID_DIRECTIONS else DEFAULT_CONFIG["direction"]
        )
        for key in ("syncHistory", "syncReadingList", "syncOpenTabs", "syncTabGroups"):
            if key in settings:
                next_config[key] = bool(settings[key])
        next_config["openTabsFolderName"] = clean_folder_name(
            settings.get("openTabsFolderName", next_config["openTabsFolderName"]),
            DEFAULT_CONFIG["openTabsFolderName"],
        )
        next_config["tabGroupsFolderName"] = clean_folder_name(
            settings.get("tabGroupsFolderName", next_config["tabGroupsFolderName"]),
            DEFAULT_CONFIG["tabGroupsFolderName"],
        )
        sync_config = next_config
        return dict(sync_config)


def current_config():
    with config_lock:
        return dict(sync_config)


def can_push_safari_to_chrome():
    cfg = current_config()
    return not cfg["paused"] and cfg["direction"] != "chrome_to_safari"


def can_apply_chrome_to_safari():
    cfg = current_config()
    return not cfg["paused"] and cfg["direction"] != "safari_to_chrome"


def can_push_safari_history_to_chrome():
    cfg = current_config()
    return (
        not cfg["paused"]
        and cfg["syncHistory"]
        and cfg["direction"] != "chrome_to_safari"
    )


def can_apply_chrome_history_to_safari():
    cfg = current_config()
    return (
        not cfg["paused"]
        and cfg["syncHistory"]
        and cfg["direction"] != "safari_to_chrome"
    )


def generated_sync_folder_names():
    cfg = current_config()
    names = {
        DEFAULT_CONFIG["openTabsFolderName"],
        DEFAULT_CONFIG["tabGroupsFolderName"],
        cfg["openTabsFolderName"],
        cfg["tabGroupsFolderName"],
    }
    return {name for name in names if name}


def persist_state():
    tmp = f"{STATE_PATH}.{os.getpid()}.{threading.get_ident()}.tmp"
    with state_lock:
        data = {
            "sent_to_chrome": list(sent_to_chrome),
            "folder_order": folder_order_snapshot,
            "dissolve_bookmarksmenu_v2": migration_done,
            "safari_history_cursor": safari_history_cursor,
            "history_recent_from_chrome": list(history_recent_from_chrome)[
                -HISTORY_RECENT_KEYS_LIMIT:
            ],
        }
        with open(tmp, "w") as f:
            json.dump(data, f)
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
        "MIGRATE dissolved BookmarksMenu: %d folders + %d leaves -> plist root",
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
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        backup_name = f"Bookmarks-{stamp}-{os.getpid()}-{time.time_ns()}.plist"
        shutil.copy2(BOOKMARKS_PATH, os.path.join(BACKUP_DIR, backup_name))
        tmp = BOOKMARKS_PATH + ".tmp"
        with open(tmp, "wb") as f:
            f.write(plistlib.dumps(data))
        subprocess.run(["plutil", "-convert", "binary1", tmp], check=True)
        os.replace(tmp, BOOKMARKS_PATH)


def is_history_url(url):
    try:
        parsed = urlparse(url or "")
        return parsed.scheme in {"http", "https"} and bool(parsed.netloc)
    except Exception:
        return False


def chrome_ms_to_safari_time(value):
    try:
        millis = float(value)
    except Exception:
        millis = time.time() * 1000
    if not math.isfinite(millis) or millis <= 0:
        millis = time.time() * 1000
    return (millis / 1000.0) - MAC_EPOCH_OFFSET


def safari_time_to_chrome_ms(value):
    return int((float(value) + MAC_EPOCH_OFFSET) * 1000)


def history_key(url, visit_time):
    return f"{normalize_url(url)}|{round(float(visit_time), 3)}"


def remember_history_from_chrome(url, visit_time):
    key = history_key(url, visit_time)
    with state_lock:
        history_recent_from_chrome.add(key)
        if len(history_recent_from_chrome) > HISTORY_RECENT_KEYS_LIMIT:
            keep = list(history_recent_from_chrome)[-HISTORY_RECENT_KEYS_LIMIT:]
            history_recent_from_chrome.clear()
            history_recent_from_chrome.update(keep)
    return key


def open_history_db():
    conn = sqlite3.connect(HISTORY_PATH, timeout=10)
    conn.execute("PRAGMA busy_timeout=5000")
    conn.execute("PRAGMA foreign_keys=ON")
    return conn


def next_history_generation(conn):
    row = conn.execute(
        "SELECT value FROM metadata WHERE key = 'current_generation'"
    ).fetchone()
    try:
        current = int(row[0]) if row and row[0] is not None else 0
    except Exception:
        current = 0
    generation = current + 1
    conn.execute(
        """
        INSERT INTO metadata (key, value)
        VALUES ('current_generation', ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """,
        (generation,),
    )
    return generation


def add_history_visit(url, title=None, visit_time_ms=None):
    if not is_history_url(url):
        return {"status": "skipped_url"}
    visit_time = chrome_ms_to_safari_time(visit_time_ms)
    title = title or url

    with open_history_db() as conn:
        conn.execute(
            """
            INSERT OR IGNORE INTO history_items (
                url,
                domain_expansion,
                visit_count,
                daily_visit_counts,
                weekly_visit_counts,
                autocomplete_triggers,
                should_recompute_derived_visit_counts,
                visit_count_score,
                status_code
            ) VALUES (?, NULL, 0, ?, NULL, NULL, 1, 0, 0)
            """,
            (url, b""),
        )
        row = conn.execute(
            "SELECT id FROM history_items WHERE url = ?",
            (url,),
        ).fetchone()
        if row is None:
            return {"status": "error", "message": "history item insert failed"}

        item_id = row[0]
        existing = conn.execute(
            """
            SELECT id FROM history_visits
            WHERE history_item = ? AND ABS(visit_time - ?) < ?
            LIMIT 1
            """,
            (item_id, visit_time, HISTORY_DEDUPE_SECONDS),
        ).fetchone()
        if existing is not None:
            remember_history_from_chrome(url, visit_time)
            return {"status": "exists"}

        generation = next_history_generation(conn)
        conn.execute(
            """
            INSERT INTO history_visits (
                history_item,
                visit_time,
                title,
                load_successful,
                http_non_get,
                synthesized,
                origin,
                generation,
                attributes,
                score
            ) VALUES (?, ?, ?, 1, 0, 0, 1, ?, 0, 0)
            """,
            (item_id, visit_time, title, generation),
        )
        conn.execute(
            """
            UPDATE history_items
            SET visit_count = visit_count + 1,
                should_recompute_derived_visit_counts = 1
            WHERE id = ?
            """,
            (item_id,),
        )

    remember_history_from_chrome(url, visit_time)
    logging.info("H+ %s", url)
    return {"status": "added", "visit_time": visit_time}


def current_safari_history_max_time():
    if not os.path.exists(HISTORY_PATH):
        return None
    with open_history_db() as conn:
        row = conn.execute("SELECT MAX(visit_time) FROM history_visits").fetchone()
    return row[0] if row and row[0] is not None else None


def safari_history_since(since_time):
    if not os.path.exists(HISTORY_PATH):
        return []
    with open_history_db() as conn:
        return conn.execute(
            """
            SELECT hv.id, hi.url, hv.title, hv.visit_time
            FROM history_visits hv
            JOIN history_items hi ON hi.id = hv.history_item
            WHERE hv.visit_time > ?
              AND hv.load_successful = 1
              AND hi.url LIKE 'http%'
            ORDER BY hv.visit_time ASC, hv.id ASC
            LIMIT ?
            """,
            (float(since_time), HISTORY_PUSH_LIMIT),
        ).fetchall()


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
    """Map canonical path -> plist folder container (the dict whose Children list holds the item).
    [BAR, ...]              -> BookmarksBar / ...
    [OTHER]                 -> plist root (loose leaves at top level)
    [OTHER, TopName, ...]   -> top-level plist folder TopName / ...
    """
    path = normalize_canonical_path(path)
    if not path:
        return None
    if path[0] == CANON_BAR:
        root = find_root(data, SAFARI_BAR)
        sub_parts = path[1:]
    elif path[0] == CANON_OTHER:
        if len(path) == 1:
            return data
        top_name = path[1]
        root = find_or_create_toplevel(data, top_name) if create else find_toplevel(data, top_name)
        sub_parts = path[2:]
    else:
        return None
    if root is None:
        return None
    return descend_folder(root, sub_parts, create=create)


# Back-compat alias for older callers.
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
    cfg = current_config()
    generated_names = generated_sync_folder_names()
    by_url = {}
    by_folder = {}

    def is_generated_sync_folder(path):
        return (
            len(path) >= 2
            and path[0] == CANON_OTHER
            and path[1] in generated_names
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
            # Legacy pre-migration. Walk as if its children were already at root.
            walk_folder(child, [CANON_OTHER], False)
        elif title == SAFARI_RL:
            if cfg["syncReadingList"]:
                walk_folder(child, [], True)
        elif title in SYSTEM_ROOTS:
            continue
        elif child.get("WebBookmarkType") == "WebBookmarkTypeList":
            # User top-level folder maps to canonical [OTHER, title, ...]
            walk_folder(child, [CANON_OTHER, title], False)
        elif child.get("WebBookmarkType") == "WebBookmarkTypeLeaf":
            # Loose leaf at plist root maps to path=[OTHER]
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
        # Plist root: reorder only loose leaves in place, keep folders/system roots where they are.
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

    push_allowed = can_push_safari_to_chrome()
    with state_lock:
        to_push = (
            {u: i for u, i in known_by_url.items() if u not in sent_to_chrome}
            if push_allowed else {}
        )
    logging.info("Initial: %d/%d new Safari items", len(to_push), len(known_by_url))
    # Send adds in path+index order so Chrome applies in the right sequence
    if push_allowed:
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
            if push_allowed:
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
            push_allowed = can_push_safari_to_chrome()
            pushed_adds = 0
            pushed_removes = 0
            pushed_reorders = 0

            if push_allowed:
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
                    pushed_adds += 1

                for url, info in removed.items():
                    send_message({
                        "action": "remove",
                        "kind": info["kind"],
                        "url": info["url"],
                    })
                    with state_lock:
                        sent_to_chrome.discard(url)
                    pushed_removes += 1

            # Order changes per folder
            for pk, ordered in cur_folder.items():
                prev = folder_order_snapshot.get(pk)
                if prev != ordered:
                    if push_allowed:
                        push_folder_order(pk, ordered)
                        pushed_reorders += 1
                    folder_order_snapshot[pk] = ordered

            # Folders gone entirely: drop from snapshot.
            for pk in list(folder_order_snapshot):
                if pk not in cur_folder:
                    folder_order_snapshot.pop(pk, None)

            known_by_url = cur_url
            known_by_folder = cur_folder

            if pushed_adds or pushed_removes or pushed_reorders:
                logging.info(
                    "S> +%d -%d ~%d",
                    pushed_adds,
                    pushed_removes,
                    pushed_reorders,
                )

            if added or removed:
                persist_state()
            else:
                # persist any reorder snapshot updates
                persist_state()
        except Exception as e:
            logging.error("watcher: %s", e)


def history_watcher():
    global safari_history_cursor
    try:
        if safari_history_cursor is None:
            safari_history_cursor = current_safari_history_max_time()
            persist_state()
    except Exception as e:
        logging.error("initial history cursor failed: %s", e)

    while True:
        time.sleep(HISTORY_POLL_INTERVAL)
        try:
            if not can_push_safari_history_to_chrome():
                continue

            cursor = safari_history_cursor
            if cursor is None:
                cursor = current_safari_history_max_time()
                safari_history_cursor = cursor
                persist_state()
                continue

            rows = safari_history_since(float(cursor))
            max_seen = float(cursor)
            pushed = 0

            for _visit_id, url, title, visit_time in rows:
                max_seen = max(max_seen, float(visit_time))
                key = history_key(url, visit_time)
                with state_lock:
                    if key in history_recent_from_chrome:
                        continue
                send_message({
                    "action": "history_add",
                    "url": url,
                    "title": title or url,
                    "visitTime": safari_time_to_chrome_ms(visit_time),
                })
                pushed += 1

            if max_seen > float(cursor):
                safari_history_cursor = max_seen
                persist_state()
            if pushed:
                logging.info("H> %d Safari history visits", pushed)
        except Exception as e:
            logging.error("history watcher: %s", e)


def ensure_watcher_started():
    global watcher_started
    with watcher_start_lock:
        if watcher_started:
            return
        threading.Thread(target=watcher, daemon=True).start()
        threading.Thread(target=history_watcher, daemon=True).start()
        watcher_started = True


# --- Main loop: process messages from Chrome ---

while True:
    msg = read_message()
    if msg is None:
        break
    try:
        action = msg.get("action")
        if action == "config":
            result = {
                "status": "config_applied",
                "settings": apply_config(msg.get("settings") or {}),
            }
            ensure_watcher_started()
        elif action == "ping":
            result = {
                "status": "ok",
                "config": current_config(),
                "watcher_started": watcher_started,
            }
        else:
            ensure_watcher_started()
            if action == "history_add" and not can_apply_chrome_history_to_safari():
                result = {"status": "skipped_direction"}
            elif action in {"add", "remove", "reorder"} and not can_apply_chrome_to_safari():
                result = {"status": "skipped_direction"}
            elif msg.get("kind") == "reading_list" and not current_config()["syncReadingList"]:
                result = {"status": "skipped_disabled"}
            elif action == "history_add":
                result = add_history_visit(
                    msg["url"],
                    msg.get("title") or msg["url"],
                    msg.get("visitTime"),
                )
            elif action == "add":
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
