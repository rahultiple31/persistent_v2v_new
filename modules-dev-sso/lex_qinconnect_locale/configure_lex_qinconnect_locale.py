# Requires Python 3 and AWS CLI v2. Updates and builds the DRAFT locale.
# Assumes the assistant has self-service prompts for the requested language.
import json
import os
import subprocess


def aws(service, *operation, **request):
    command = [
        "aws", service, *operation, "--region", os.environ["LEX_AWS_REGION"],
        "--output", "json", "--no-cli-pager", "--no-cli-auto-prompt",
    ]
    if request:
        command.extend(["--cli-input-json", json.dumps(request)])

    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(result.stderr.strip())
    return json.loads(result.stdout) if result.stdout.strip() else {}


def lex(*operation, **request):
    return aws("lexv2-models", *operation, **request)


def list_items(operation, key, **request):
    while True:
        page = lex(operation, "--no-paginate", **request)
        yield from page.get(key, [])
        if not page.get("nextToken"):
            return
        request["nextToken"] = page["nextToken"]


def main():
    bot_id = os.environ["LEX_BOT_ID"]
    bot_name = os.environ["LEX_BOT_NAME"]
    locale_id = os.environ["LEX_LOCALE_ID"]
    assistant_arn = os.environ["LEX_ASSISTANT_ARN"]
    scope = {"botId": bot_id, "botVersion": "DRAFT", "localeId": locale_id}

    if aws("sts", "get-caller-identity")["Account"] != assistant_arn.split(":")[4]:
        raise RuntimeError("Unexpected AWS account.")
    if lex("describe-bot", botId=bot_id)["botName"] != bot_name:
        raise RuntimeError("Unexpected Lex bot.")

    built_in_intents = list_items(
        "list-built-in-intents", "builtInIntentSummaries", localeId=locale_id
    )
    signature = next(
        (
            item["intentSignature"]
            for item in built_in_intents
            if item["intentSignature"].casefold() == "amazon.qinconnectintent"
        ),
        None,
    )
    if signature is None:
        raise RuntimeError(f"Amazon Q in Connect intent is unavailable for {locale_id}.")

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

    desired = {
        "intentName": "AmazonQinConnect",
        "parentIntentSignature": signature,
        "qInConnectIntentConfiguration": {
            "qInConnectAssistantConfiguration": {"assistantArn": assistant_arn}
        },
    }
    existing = next(
        (
            item for item in list_items("list-intents", "intentSummaries", **scope)
            if item["intentName"] == desired["intentName"]
        ),
        None,
    )

    changed = existing is None
    if existing is None:
        lex("create-intent", **scope, **desired)
    else:
        intent = lex("describe-intent", **scope, intentId=existing["intentId"])
        changed = any(intent.get(key) != value for key, value in desired.items())
        if changed:
            # Preserve the existing intent's writable settings.
            writable = lex("update-intent", "--generate-cli-skeleton", "input")
            settings = {
                key: value for key, value in intent.items()
                if key in writable and value is not None
            }
            settings.update(scope)
            settings.update(desired)
            settings["intentId"] = existing["intentId"]
            lex("update-intent", **settings)

    if changed or lex("describe-bot-locale", **scope)["botLocaleStatus"] != "Built":
        lex("build-bot-locale", **scope)
        lex("wait", "bot-locale-built", **scope)


if __name__ == "__main__":
    main()
