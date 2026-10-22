"""Logging for svc.

Deprecated: log(level, msg) prints "[level] msg" and does not say which module
spoke. Use a named logger instead: at the top of a module,

    from svc.logging import get_logger
    logger = get_logger(__name__)

then logger.info(msg), logger.warn(msg), logger.error(msg), or logger.log(level, msg)
when the level is a variable. Output: "[level] module.name: msg".
"""


def log(level, msg):
    print(f"[{level}] {msg}")


class Logger:
    def __init__(self, name):
        self.name = name

    def log(self, level, msg):
        print(f"[{level}] {self.name}: {msg}")

    def info(self, msg):
        self.log("info", msg)

    def warn(self, msg):
        self.log("warn", msg)

    def error(self, msg):
        self.log("error", msg)


def get_logger(name):
    return Logger(name)
