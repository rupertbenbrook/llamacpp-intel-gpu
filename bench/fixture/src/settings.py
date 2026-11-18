import json


def load_settings(path):
    with open(path) as f:
        return json.load(f)


def merge(a, b):
    out = dict(a)
    out.update(b)
    return out
