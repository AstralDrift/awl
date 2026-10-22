"""calc: a line calculator. See SPEC.md."""
import sys


def run_line(line, env):
    """Return the output line for one input line, or None for blank lines and comments."""
    raise NotImplementedError


def main():
    env = {}
    for line in sys.stdin:
        out = run_line(line.rstrip("\n"), env)
        if out is not None:
            print(out)


if __name__ == "__main__":
    main()
