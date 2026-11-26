import os
import sqlite3
import struct
import sys
import unicodedata
import zlib

path = sys.argv[1]
for suffix in ("", "-wal", "-shm"):
    try:
        os.unlink(path + suffix)
    except FileNotFoundError:
        pass


def norm(s):
    kana = {c: c - 0x60 for c in range(0x30A1, 0x30F7)}
    kana.update({0x30FD: 0x309D, 0x30FE: 0x309E})
    kana.update({0x30F7: "わ\u3099", 0x30F8: "ゐ\u3099", 0x30F9: "ゑ\u3099", 0x30FA: "を\u3099"})
    return unicodedata.normalize("NFKC", s).casefold().translate(kana)


def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(b"\x00\x28\x7b\x55\xff")) + chunk(b"IEND", b"")
with sqlite3.connect(path) as conn:
    conn.executescript("""
    PRAGMA journal_mode=DELETE;
    CREATE TABLE sources(id TEXT PRIMARY KEY,browser TEXT NOT NULL,browser_type TEXT NOT NULL,profile_name TEXT NOT NULL,path TEXT NOT NULL,state TEXT NOT NULL,db_identity TEXT,generation TEXT,last_success REAL,error TEXT);
    CREATE TABLE visits(id INTEGER PRIMARY KEY AUTOINCREMENT,source_id TEXT NOT NULL,generation TEXT NOT NULL,native_id INTEGER NOT NULL,url TEXT NOT NULL,title TEXT,native_real REAL,native_int INTEGER,visit_seconds INTEGER NOT NULL,visit_fraction REAL NOT NULL,norm_title TEXT NOT NULL,norm_url TEXT NOT NULL,UNIQUE(source_id,native_id));
    CREATE INDEX visits_time ON visits(visit_seconds DESC,visit_fraction DESC,id DESC);
    CREATE TABLE icons(source_id TEXT NOT NULL,site TEXT NOT NULL,mime TEXT NOT NULL,image BLOB NOT NULL,PRIMARY KEY(source_id,site));
    CREATE INDEX icons_site ON icons(site);
    CREATE TABLE collection_settings(key TEXT PRIMARY KEY,value TEXT NOT NULL);
    INSERT INTO collection_settings VALUES('enabled','1');
    INSERT INTO sources VALUES('fixture','safari','Safari','Default','/synthetic','complete','fixture','fixture',1794268800,NULL);
    CREATE VIRTUAL TABLE visit_search USING fts5(norm_title,norm_url,content='visits',content_rowid='id',tokenize='trigram case_sensitive 1');
    CREATE TRIGGER visits_search_insert AFTER INSERT ON visits BEGIN INSERT INTO visit_search(rowid,norm_title,norm_url) VALUES(new.id,new.norm_title,new.norm_url); END;
    CREATE TRIGGER visits_search_delete AFTER DELETE ON visits BEGIN INSERT INTO visit_search(visit_search,rowid,norm_title,norm_url) VALUES('delete',old.id,old.norm_title,old.norm_url); END;
    CREATE TRIGGER visits_search_update AFTER UPDATE OF norm_title,norm_url ON visits BEGIN INSERT INTO visit_search(visit_search,rowid,norm_title,norm_url) VALUES('delete',old.id,old.norm_title,old.norm_url); INSERT INTO visit_search(rowid,norm_title,norm_url) VALUES(new.id,new.norm_title,new.norm_url); END;
    PRAGMA user_version=4;
    """)
    conn.execute("INSERT INTO icons VALUES(?,?,?,?)", ("fixture", "example.test", "image/png", png))
    rows = []
    for i in range(1200):
        title = "ＡＢＣ ｶﾞｯｺｳ ① ㎏" if i == 30 else f"調べ物 カタカナ {i + 1}"
        url = f"https://example.test/article/{i + 1}"
        if i == 139:
            title, url = "</script><script>window.pwned=1</script>", "javascript:alert(1)"
        stamp = 1794268800 - i * 60
        rows.append((i+1,"fixture","fixture",i+1,url,title,stamp,0,norm(title),norm(url)))
    conn.executemany("INSERT INTO visits(id,source_id,generation,native_id,url,title,visit_seconds,visit_fraction,norm_title,norm_url) VALUES(?,?,?,?,?,?,?,?,?,?)", rows)
