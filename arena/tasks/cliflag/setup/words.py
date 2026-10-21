import sys


def main(argv):
    words = sys.stdin.read().split()
    for w in sorted(set(words)):
        print(w)


if __name__ == "__main__":
    main(sys.argv[1:])
