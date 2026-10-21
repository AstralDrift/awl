"""Output formats for `todo list`. Each formatter takes a list of Task and returns a str."""
from todo.formatters import csv_fmt, text

FORMATTERS = {
    "text": text.render,
    "csv": csv_fmt.render,
}
