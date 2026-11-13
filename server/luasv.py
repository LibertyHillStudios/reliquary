"""Reads WoW SavedVariables files (Lua table literals) into Python values, and writes them.

Only the subset the game writes: assignments of tables, strings, numbers, booleans and
nil, with `-- [n]` comments. Tables whose keys are exactly 1..n become lists; any other
table becomes a dict (integer keys stay integers). dumps() writes the same subset back, so
loads(dumps(x)) == x.
"""
import re

_TOKEN = re.compile(
    r"""
    (?P<ws>\s+)
  | (?P<block>--\[(?P<eq>=*)\[.*?\](?P=eq)\])
  | (?P<comment>--[^\n]*)
  | (?P<str>"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')
  | (?P<num>-?(?:0[xX][0-9a-fA-F]+|(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)|-?inf|-?nan)
  | (?P<name>[A-Za-z_][A-Za-z0-9_]*)
  | (?P<sym>[{}\[\]=,;])
    """,
    re.VERBOSE | re.DOTALL,
)

_ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "a": "\a", "b": "\b", "f": "\f", "v": "\v", "\\": "\\", '"': '"', "'": "'", "\n": "\n"}


class ParseError(ValueError):
    pass


def _unescape(body):
    out, i, n = [], 0, len(body)
    raw = bytearray()

    def flush():
        if raw:
            out.append(raw.decode("utf-8", errors="replace"))
            raw.clear()

    while i < n:
        ch = body[i]
        if ch != "\\":
            flush()
            out.append(ch)
            i += 1
            continue
        i += 1
        if i >= n:
            break
        e = body[i]
        if e.isdigit():
            j = i
            while j < n and j - i < 3 and body[j].isdigit():
                j += 1
            raw.append(int(body[i:j]) & 0xFF)  # \ddd is a byte: UTF-8 may span several
            i = j
            continue
        flush()
        out.append(_ESCAPES.get(e, e))
        i += 1
    flush()
    return "".join(out)


def _tokens(text):
    pos, n = 0, len(text)
    while pos < n:
        m = _TOKEN.match(text, pos)
        if not m:
            raise ParseError(f"unexpected character {text[pos]!r} at {pos}")
        pos = m.end()
        kind = m.lastgroup
        if kind in ("ws", "block", "comment", "eq"):
            continue
        yield kind, m.group(kind), m.start()


def _number(s):
    low = s.lower()
    if low.endswith("inf"):
        return float("-inf") if low.startswith("-") else float("inf")
    if low.endswith("nan"):
        return None
    if "x" in low:
        return int(s, 16)
    if any(c in low for c in ".e"):
        return float(s)
    return int(s)


class _Parser:
    def __init__(self, text):
        self.toks = list(_tokens(text))
        self.i = 0

    def peek(self, k=0):
        j = self.i + k
        return self.toks[j] if j < len(self.toks) else (None, None, -1)

    def take(self, sym=None):
        tok = self.peek()
        if sym is not None and tok[1] != sym:
            raise ParseError(f"expected {sym!r}, found {tok[1]!r} at {tok[2]}")
        self.i += 1
        return tok

    def value(self):
        kind, val, at = self.take()
        if kind == "str":
            return _unescape(val[1:-1])
        if kind == "num":
            return _number(val)
        if kind == "name":
            if val == "true":
                return True
            if val == "false":
                return False
            if val == "nil":
                return None
            raise ParseError(f"unexpected name {val!r} at {at}")
        if val == "{":
            return self.table()
        raise ParseError(f"unexpected {val!r} at {at}")

    def table(self):
        d, nxt = {}, 1
        while True:
            kind, val, _ = self.peek()
            if val == "}":
                self.take()
                break
            if val == "[":
                self.take()
                key = self.value()
                self.take("]")
                self.take("=")
                v = self.value()
                if v is not None:
                    d[key] = v
            elif kind == "name" and self.peek(1)[1] == "=":
                self.take()
                self.take("=")
                v = self.value()
                if v is not None:
                    d[val] = v
            else:
                v = self.value()
                if v is not None:
                    d[nxt] = v
                nxt += 1
            if self.peek()[1] in (",", ";"):
                self.take()
        if d and all(type(k) is int for k in d) and sorted(d) == list(range(1, len(d) + 1)):
            return [d[k] for k in range(1, len(d) + 1)]
        return d

    def assignments(self):
        out = {}
        while self.peek()[0] is not None:
            kind, name, at = self.take()
            if kind != "name":
                raise ParseError(f"expected a variable name at {at}")
            self.take("=")
            out[name] = self.value()
        return out


def loads(text):
    """Returns {variable name: value} for one SavedVariables file."""
    return _Parser(text).assignments()


def load(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return loads(f.read())


def _quote(s):
    out = ['"']
    for ch in s:
        if ch in ('"', "\\"):
            out.append("\\" + ch)
        elif ch == "\n":
            out.append("\\n")
        elif ord(ch) < 32 or ord(ch) == 127:
            out.append("\\%03d" % ord(ch))
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def _value(v, indent):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        if v != v:
            raise ValueError("NaN can't be saved")
        return "inf" if v == float("inf") else "-inf" if v == float("-inf") else repr(v)
    if isinstance(v, str):
        return _quote(v)
    if isinstance(v, (list, tuple)):
        items = [f"{indent}\t{_value(x, indent + chr(9))}, -- [{i}]" for i, x in enumerate(v, 1) if x is not None]
        return "{\n" + "\n".join(items) + ("\n" if items else "") + indent + "}"
    if isinstance(v, dict):
        lines = []
        for k in sorted(v, key=lambda k: (not isinstance(k, (int, float)), str(k) if not isinstance(k, (int, float)) else k)):
            if v[k] is None:
                continue
            key = f"[{_quote(k)}]" if isinstance(k, str) else f"[{_value(k, indent)}]"
            lines.append(f"{indent}\t{key} = {_value(v[k], indent + chr(9))},")
        return "{\n" + "\n".join(lines) + ("\n" if lines else "") + indent + "}"
    raise TypeError(f"can't save a {type(v).__name__}")


def dumps(variables):
    """Writes {variable name: value} as a SavedVariables file."""
    return "\n".join(f"{name} = {_value(value, '')}" for name, value in variables.items() if value is not None) + "\n"
