# Requires Python 3 and AWS CLI v2. Creates and builds the DRAFT locale.
# The dtmf intent supplies sample utterances. Keypad routing is configured separately.

import json
import os
import subprocess
from functools import partial


def aws(region, service, *operation, **request):
    command = [
        "aws", service, *operation, "--region", region,
        "--output", "json", "--no-cli-pager", "--no-cli-auto-prompt",
    ]
    if request:
        command.extend(["--cli-input-json", json.dumps(request)])

    result = subprocess.run(
        command,
        capture_output=True,
        encoding="utf-8",
        env={**os.environ, "PYTHONIOENCODING": "utf-8"},
    )
    if result.returncode:
        raise RuntimeError(result.stderr.strip())
    return json.loads(result.stdout) if result.stdout.strip() else {}


def intent_ids(lex, scope):
    request = dict(scope)
    ids = {}
    while True:
        page = lex("list-intents", "--no-paginate", **request)
        ids.update({
            item["intentName"]: item["intentId"]
            for item in page.get("intentSummaries", [])
        })
        if not page.get("nextToken"):
            return ids
        request["nextToken"] = page["nextToken"]


def main():
    config = json.loads(os.environ["LEX_CONFIGURATION"])
    lex = partial(aws, config["region"], "lexv2-models")
    scope = {
        "botId": config["bot_id"],
        "botVersion": "DRAFT",
        "localeId": config["locale_id"],
    }

    identity = aws(config["region"], "sts", "get-caller-identity")
    if identity["Account"] != config["account_id"]:
        raise RuntimeError("Unexpected AWS account.")
    if lex("describe-bot", botId=config["bot_id"])["botName"] != config["bot_name"]:
        raise RuntimeError("Unexpected Lex bot.")

    try:
        locale = lex("describe-bot-locale", **scope)
    except RuntimeError as error:
        if "ResourceNotFoundException" not in str(error):
            raise
        locale = lex("create-bot-locale", **scope, nluIntentConfidenceThreshold=0.40)

    if locale["botLocaleStatus"] == "Creating":
        lex("wait", "bot-locale-created", **scope)
    elif locale["botLocaleStatus"] == "Building":
        lex("wait", "bot-locale-built", **scope)

    existing = intent_ids(lex, scope)
    writable = None
    changed = False

    for name, utterances in config["intents"].items():
        samples = [{"utterance": value} for value in utterances]
        if name not in existing:
            lex("create-intent", **scope, intentName=name, sampleUtterances=samples)
        else:
            intent = lex("describe-intent", **scope, intentId=existing[name])
            current = {item["utterance"] for item in intent.get("sampleUtterances", [])}
            if current == set(utterances):
                continue

            # Carry forward writable intent settings before replacing the samples.
            if writable is None:
                writable = lex("update-intent", "--generate-cli-skeleton", "input")
            settings = {
                key: value for key, value in intent.items()
                if key in writable and value is not None
            }
            settings.update(scope)
            settings.update(
                intentId=existing[name], intentName=name, sampleUtterances=samples
            )
            lex("update-intent", **settings)
        changed = True

    if changed or lex("describe-bot-locale", **scope)["botLocaleStatus"] != "Built":
        lex("build-bot-locale", **scope)
        lex("wait", "bot-locale-built", **scope)


if __name__ == "__main__":
    main()
