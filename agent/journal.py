"""Read Lunar Journal's saved files and hand the untold parts to the story agent.

    python -I journal.py list
    python -I journal.py untold Lunamal-Sunshadow        # JSON: what has happened since the last story
    python -I journal.py mark Lunamal-Sunshadow 1763400000   # sessions up to this id are now told

The game writes the journal to
    <WoW>\\_forever_\\WTF\\Account\\<account>\\<realm>\\<Character-Surname>\\SavedVariables\\LunarJournal.lua
when you log out or /reload. This script only reads it. Which sessions are already in a
story is kept in told.json next to this script.
"""

import json
import os
import re
import sys
from datetime import datetime

WTF = os.environ.get("LUNARJOURNAL_WTF", r"D:\Blizzard\World of Warcraft\_forever_\WTF\Account")
HERE = os.path.dirname(os.path.abspath(__file__))
TOLD = os.path.join(HERE, "told.json")


# ------------------------------------------------------------------ Lua reader
TOKEN = re.compile(r"""
    \s+ | --[^\n]* |
    (?P<str>"(?:\\.|[^"\\])*") |
    (?P<num>-?(?:\d+\.?\d*(?:[eE][-+]?\d+)?|\.\d+|inf|nan)) |
    (?P<name>[A-Za-z_][A-Za-z0-9_]*) |
    (?P<sym>[{}\[\]=,;])
""", re.X)

ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "\\": "\\", '"': '"', "'": "'", "\n": "\n"}


def unquote(s):
    out, i, s = [], 0, s[1:-1]
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s):
            n = s[i + 1]
            if n.isdigit():
                m = re.match(r"\d{1,3}", s[i + 1:]).group()
                out.append(chr(int(m)))
                i += 1 + len(m)
                continue
            out.append(ESCAPES.get(n, n))
            i += 2
            continue
        out.append(c)
        i += 1
    # WoW writes UTF-8 bytes; the \ddd escapes above give them as single chars
    text = "".join(out)
    try:
        return text.encode("latin-1").decode("utf-8")
    except (UnicodeEncodeError, UnicodeDecodeError):
        return text


def tokens(text):
    pos = 0
    while pos < len(text):
        m = TOKEN.match(text, pos)
        if not m:
            raise ValueError(f"can't read the saved file at character {pos}: {text[pos:pos + 40]!r}")
        pos = m.end()
        for kind in ("str", "num", "name", "sym"):
            if m.group(kind) is not None:
                yield kind, m.group(kind)
                break


class Reader:
    def __init__(self, text):
        self.toks = list(tokens(text))
        self.i = 0

    def peek(self):
        return self.toks[self.i] if self.i < len(self.toks) else (None, None)

    def take(self):
        t = self.peek()
        self.i += 1
        return t

    def value(self):
        kind, v = self.take()
        if kind == "str":
            return unquote(v)
        if kind == "num":
            if v in ("inf", "nan"):
                return None
            f = float(v)
            return int(f) if f.is_integer() and "." not in v and "e" not in v.lower() else f
        if kind == "name":
            return {"true": True, "false": False, "nil": None}.get(v, v)
        if v == "{":
            return self.table()
        raise ValueError(f"unexpected {v!r}")

    def table(self):
        items, n = {}, 0
        while True:
            kind, v = self.peek()
            if v == "}":
                self.take()
                break
            if v == "[":
                self.take()
                key = self.value()
                self.take()  # ]
                self.take()  # =
                items[key] = self.value()
            elif kind == "name" and self.toks[self.i + 1][1] == "=":
                self.take()
                self.take()
                items[v] = self.value()
            else:
                n += 1
                items[n] = self.value()
            if self.peek()[1] in (",", ";"):
                self.take()
        if items and all(isinstance(k, int) for k in items) and sorted(items) == list(range(1, len(items) + 1)):
            return [items[k] for k in range(1, len(items) + 1)]
        return {str(k): v for k, v in items.items()}

    def file(self):
        out = {}
        while self.peek()[0] is not None:
            _, name = self.take()
            self.take()  # =
            out[name] = self.value()
        return out


# ------------------------------------------------------------------ journal files
def journal_files():
    found = {}
    if not os.path.isdir(WTF):
        return found
    for account in os.listdir(WTF):
        acc = os.path.join(WTF, account)
        if not os.path.isdir(acc) or account == "SavedVariables":
            continue
        for realm in os.listdir(acc):
            for char in os.listdir(os.path.join(acc, realm)) if os.path.isdir(os.path.join(acc, realm)) else []:
                f = os.path.join(acc, realm, char, "SavedVariables", "LunarJournal.lua")
                if os.path.isfile(f):
                    found[char] = f
    return found


def load(char):
    files = journal_files()
    match = next((k for k in files if k.lower() == char.lower()), None)
    if not match:
        sys.exit(f"No journal for {char}. Found: {', '.join(files) or 'none'}")
    with open(files[match], encoding="latin-1") as fh:
        data = Reader(fh.read()).file()
    return match, data.get("LunarJournalDB") or {}, files[match]


def told():
    if os.path.isfile(TOLD):
        with open(TOLD, encoding="utf-8") as fh:
            return json.load(fh)
    return {}


def when(t):
    return datetime.fromtimestamp(t).strftime("%Y-%m-%d %H:%M") if isinstance(t, (int, float)) else None


def tidy_session(s, quests):
    """One session, with times in minutes and the quests it touched filled in."""
    ids = {e.get("id") for e in s.get("events", []) if str(e.get("k", "")).startswith("quest_") and e.get("id")}
    events = []
    for e in s.get("events", []):
        e = dict(e)
        e["when"] = when(e.pop("t", None))
        if "t2" in e:
            e["until"] = when(e.pop("t2"))
        events.append(e)
    minutes = lambda m: {k: round(v / 60, 1) for k, v in (m or {}).items() if isinstance(v, (int, float)) and v >= 30}
    return {
        "id": s.get("id"),
        "start": when(s.get("start")),
        "stop": when(s.get("stop")),
        "realMinutes": round((s.get("stop", 0) - s.get("start", 0)) / 60),
        "gameTimeAtStart": s.get("startGameTime"),
        "level": [s.get("levelStart"), s.get("level")],
        "minutes": minutes(s.get("time")),
        "yards": {k: round(v) for k, v in (s.get("dist") or {}).items()},
        "minutesPerZone": minutes(s.get("zones")),
        "kills": s.get("kills"),
        "fishCaught": s.get("fish"),
        "crafted": s.get("crafted"),
        "gathered": s.get("gathered"),
        "npcsTalkedTo": s.get("npcs"),
        "playersMet": s.get("players"),
        "moneyGainedCopper": s.get("moneyGained"),
        "moneySpentCopper": s.get("moneySpent"),
        "questDetails": {str(i): quests.get(str(i)) for i in ids if quests.get(str(i))},
        "events": events,
        "eventsCut": bool(s.get("truncated")),
    }


def main(argv):
    if len(argv) < 2 or argv[1] not in ("list", "untold", "mark"):
        print(__doc__)
        return 1
    cmd = argv[1]
    state = told()

    if cmd == "list":
        out = []
        for char in journal_files():
            _, db, path = load(char)
            sessions = db.get("sessions") or []
            last = state.get(char.lower(), 0)
            out.append({
                "character": char,
                "slug": char.lower(),
                "info": db.get("character"),
                "sessions": len(sessions),
                "untold": sum(1 for s in sessions if s.get("id", 0) > last),
                "file": path,
                "savedAt": when(os.path.getmtime(path)),
            })
        print(json.dumps(out, ensure_ascii=False, indent=1))
        return 0

    if len(argv) < 3:
        print(__doc__)
        return 1
    char, db, path = load(argv[2])

    if cmd == "untold":
        last = state.get(char.lower(), 0)
        quests = db.get("quests") or {}
        sessions = [tidy_session(s, quests) for s in db.get("sessions") or [] if s.get("id", 0) > last]
        print(json.dumps({
            "character": char,
            "slug": char.lower(),
            "info": db.get("character"),
            "savedAt": when(os.path.getmtime(path)),
            "alreadyToldUpTo": when(last) if last else None,
            "sessions": sessions,
        }, ensure_ascii=False, indent=1))
        return 0

    if cmd == "mark":
        upto = int(argv[3]) if len(argv) > 3 else max((s.get("id", 0) for s in db.get("sessions") or []), default=0)
        state[char.lower()] = upto
        with open(TOLD, "w", encoding="utf-8") as fh:
            json.dump(state, fh, indent=1)
        print(f"{char}: sessions up to {when(upto)} are told.")
        return 0


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    sys.exit(main(sys.argv))
