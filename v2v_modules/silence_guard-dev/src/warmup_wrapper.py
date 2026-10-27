import os
import importlib

_orig = os.environ["ORIGINAL_HANDLER"]
_mod_name, _fn_name = _orig.rsplit(".", 1)
_original_handler = getattr(
    importlib.import_module(_mod_name.replace("/", ".")),
    _fn_name,
)


def handler(event, context):
    if isinstance(event, dict) and event.get("warmup") is True:
        print("Warm-up ping - skipped business logic")
        return {"Status": "Success", "Message": "warm"}

    return _original_handler(event, context)
