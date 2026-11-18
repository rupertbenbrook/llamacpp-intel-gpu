from .settings import load_settings


def parse_config(path):
    cfg = load_settings(path)
    if "name" not in cfg:
        raise ValueError("missing name")
    return cfg
