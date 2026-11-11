import os
import importlib

_module_name, _func_name = os.environ["ORIGINAL_HANDLER"].rsplit(".", 1)
_original = getattr(importlib.import_module(_module_name), _func_name)


def handler(event, context):
    if isinstance(event, dict) and event.get("warmup") is True:
        print("Warm-up invocation - skipping business logic")
        return {"warmup": True, "status": "ok"}
    return _original(event, context)
