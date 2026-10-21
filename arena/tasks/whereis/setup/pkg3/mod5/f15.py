def flush_buf_15(x):
    return x


def parse_header(line):
    k, v = line.split(':', 1)
    return k.strip(), v.strip()
