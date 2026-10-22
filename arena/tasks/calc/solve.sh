#!/bin/sh
cat > calc.py <<'EOF'
"""calc: a line calculator. See SPEC.md."""
import sys

FUNCS = {"min": (1, None), "max": (1, None), "abs": (1, 1), "gcd": (2, 2)}


class CalcError(Exception):
    def __init__(self, msg, col):
        super().__init__(msg)
        self.msg, self.col = msg, col


def tokens(line):
    out, i = [], 0
    while i < len(line):
        c = line[i]
        if c in " \t":
            i += 1
        elif c.isdigit():
            j = i
            while j < len(line) and (line[j].isdigit() or line[j] == "_"):
                j += 1
            text = line[i:j]
            if "__" in text or text.endswith("_"):
                raise CalcError("bad number", i + 1)
            out.append(("num", text, i + 1))
            i = j
        elif c == "_" or "a" <= c <= "z":
            j = i
            while j < len(line) and (line[j] == "_" or "a" <= line[j] <= "z" or line[j].isdigit()):
                j += 1
            out.append(("name", line[i:j], i + 1))
            i = j
        elif line.startswith("**", i):
            out.append(("op", "**", i + 1))
            i += 2
        elif c in "+-*/%(),=":
            out.append(("op", c, i + 1))
            i += 1
        else:
            raise CalcError(f"unknown character '{c}'", i + 1)
    return out


class Parser:
    def __init__(self, line, env):
        self.toks, self.i, self.env = tokens(line), 0, env
        self.end_col = len(line.rstrip()) + 1

    def peek(self):
        return self.toks[self.i] if self.i < len(self.toks) else None

    def take(self, text=None):
        t = self.peek()
        if t is None:
            raise CalcError("unexpected end of input", self.end_col)
        if text is not None and t[1] != text:
            raise CalcError(f"unexpected '{t[1]}'", t[2])
        self.i += 1
        return t

    def is_op(self, *ops):
        t = self.peek()
        return t is not None and t[0] == "op" and t[1] in ops

    def done(self):
        t = self.peek()
        if t is not None:
            raise CalcError(f"unexpected '{t[1]}'", t[2])

    def expr(self):
        v = self.term()
        while self.is_op("+", "-"):
            op = self.take()[1]
            r = self.term()
            v = v + r if op == "+" else v - r
        return v

    def term(self):
        v = self.unary()
        while self.is_op("*", "/", "%"):
            _, op, col = self.take()
            r = self.unary()
            if op == "*":
                v = v * r
            else:
                if r == 0:
                    raise CalcError("division by zero", col)
                q = abs(v) // abs(r)
                if (v < 0) != (r < 0):
                    q = -q
                v = q if op == "/" else v - q * r
        return v

    def unary(self):
        if self.is_op("-", "+"):
            op = self.take()[1]
            v = self.unary()
            return -v if op == "-" else v
        return self.power()

    def power(self):
        v = self.atom()
        if self.is_op("**"):
            col = self.take()[2]
            e = self.unary()
            if e < 0:
                raise CalcError("negative exponent", col)
            v = v ** e
        return v

    def atom(self):
        t = self.take()
        kind, text, col = t
        if kind == "num":
            return int(text.replace("_", ""))
        if kind == "name":
            if self.is_op("("):
                if text not in FUNCS:
                    raise CalcError(f"unknown name {text}", col)
                self.take("(")
                args = []
                if not self.is_op(")"):
                    args.append(self.expr())
                    while self.is_op(","):
                        self.take()
                        args.append(self.expr())
                self.take(")")
                lo, hi = FUNCS[text]
                if len(args) < lo or (hi is not None and len(args) > hi):
                    raise CalcError(f"wrong number of arguments to {text}", col)
                if text == "min":
                    return min(args)
                if text == "max":
                    return max(args)
                if text == "abs":
                    return abs(args[0])
                a, b = abs(args[0]), abs(args[1])
                while b:
                    a, b = b, a % b
                return a
            if text not in self.env:
                raise CalcError(f"unknown name {text}", col)
            return self.env[text]
        if text == "(":
            v = self.expr()
            self.take(")")
            return v
        raise CalcError(f"unexpected '{text}'", col)


def run_line(line, env):
    """Return the output line for one input line, or None for blank lines and comments."""
    if not line.strip() or line.lstrip().startswith("#"):
        return None
    try:
        p = Parser(line, env)
        t0 = p.peek()
        t1 = p.toks[1] if len(p.toks) > 1 else None
        if t0 and t0[0] == "name" and t0[1] == "let" and t1 and t1[0] == "name":
            p.i = 2
            name = t1[1]
            p.take("=")
            v = p.expr()
            p.done()
            env[name] = v
            return f"{name} = {v}"
        v = p.expr()
        p.done()
        return str(v)
    except CalcError as e:
        return f"error: {e.msg} at col {e.col}"


def main():
    env = {}
    for line in sys.stdin:
        out = run_line(line.rstrip("\n"), env)
        if out is not None:
            print(out)


if __name__ == "__main__":
    main()
EOF
cat >> tests/test_calc.py <<'EOF'


class SpecTest(unittest.TestCase):
    def test_division(self):
        self.assertEqual(run_line("-7 / 2", {}), "-3")
        self.assertEqual(run_line("-7 % 2", {}), "-1")

    def test_errors(self):
        self.assertEqual(run_line("1 / 0", {}), "error: division by zero at col 3")
EOF
