# calc: a line calculator

`python3 calc.py` reads lines from stdin and prints one line of output per statement.
Blank lines and lines starting with `#` print nothing.

## Values

Integers only, any size. Digits may be grouped with `_` (`1_000_000`); a number may not
start or end with `_` or contain `__` (that is a bad number).

## Statements

- An expression prints its value: `1 + 2` prints `3`.
- `let NAME = EXPR` stores the value and prints `NAME = VALUE`. Names are a lower-case
  letter or `_`, then lower-case letters, digits or `_`. A name can be set again.
  `let` is a keyword, never a name: a line that starts with `let` is a `let` statement,
  and when it does not go on as `NAME = EXPR`, the error is at the first token that does not fit.

## Expressions, loosest binding first

| | |
|---|---|
| `+` `-` | left to right |
| `*` `/` `%` | left to right. `/` divides and truncates toward zero (`-7 / 2` is `-3`). `%` is the matching remainder, with the sign of the left side (`-7 % 2` is `-1`), so `(a / b) * b + a % b == a`. |
| unary `-` `+` | `--3` is `3` |
| `**` | power, right to left (`2 ** 3 ** 2` is `512`), and binds tighter than unary minus on its left: `-2 ** 2` is `-4`, `2 ** -1` is an error (negative exponent) |
| atoms | numbers, names, `( EXPR )`, calls |

Calls: `min(a, ...)` and `max(a, ...)` take one or more arguments, `abs(x)` one, `gcd(a, b)` two
(`gcd` of negatives is positive; `gcd(0, 0)` is `0`). Spaces anywhere between tokens are fine.

## Errors

A statement that fails prints `error: MESSAGE at col N` and changes nothing; the session goes
on. N is the 1-based column where the offending token starts (for end of input: one past the
last non-space character). Messages:

| message | when | column of |
|---|---|---|
| `unknown name NAME` | reading a name never set, or calling an unknown function | the name |
| `division by zero` | `/` or `%` by 0 | the operator |
| `negative exponent` | `**` with a negative right side | the `**` |
| `wrong number of arguments to NAME` | | the function name |
| `bad number` | `1__0`, `_1` is a name not a number, `1_` | the number |
| `unexpected end of input` | the line stops early | see above |
| `unexpected TOKEN` | anything else that does not fit; TOKEN is the text in quotes, e.g. `unexpected ')'` | the token |
| `unknown character C` | a character that starts no token, e.g. `unknown character '$'` | the character |
