# v2v_modules/lex_bot/configure_it_support.py
# Requires Python 3 and AWS CLI v2 with qInConnectIntentConfiguration support.
import json
import os
import subprocess

def aws(service, *operation, **payload):
    command = [
        "aws", service, *operation,
        "--region", "us-east-1", "--output", "json", "--no-cli-pager",
        "--cli-input-json", json.dumps(payload),
    ]
    result = subprocess.run(command, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stderr.strip())
    return json.loads(result.stdout) if result.stdout.strip() else {}

def main():
    bot_id = os.environ["LEX_BOT_ID"]
    config = json.loads(os.environ["LEX_CONFIGURATION"])
    account = aws("sts", "get-caller-identity")["Account"]
    if account != "518902362956":
        raise RuntimeError("Unexpected AWS account")

    aws("lexv2-models", "wait", "bot-available", botId=bot_id)
    bot = aws("lexv2-models", "describe-bot", botId=bot_id)
    if bot["botName"] != config["bot_name"]:
        raise RuntimeError("Unexpected Lex bot")
    if not bot["dataPrivacy"]["childDirected"]:
        raise RuntimeError("Set child_directed=true in module.lex_bot first")

    for locale in config["locales"]:
        scope = {"botId": bot_id, "botVersion": "DRAFT", "localeId": locale}
        summaries = aws("lexv2-models", "list-intents", **scope)["intentSummaries"]
        intents = {item["intentName"]: item["intentId"] for item in summaries}

        desired = [
            {
                "intentName": "AmazonQinConnect",
                "parentIntentSignature": "AMAZON.QinConnectIntent",
                "qInConnectIntentConfiguration": {
                    "qInConnectAssistantConfiguration": {
                        "assistantArn": config["assistant_arn"]
                    }
                },
            },
            {
                "intentName": "FallbackIntent",
                "intentId": "FALLBCKINT",
                "parentIntentSignature": "AMAZON.FallbackIntent",
                "description": "Default intent when no other intent matches",
            },
        ]
        if locale == "pt_BR":
            desired.append({
                "intentName": "TransferToAgent",
                "sampleUtterances": [{"utterance": "transfer my call to agent"}],
            })

        for intent in desired:
            intent_id = intent.pop("intentId", intents.get(intent["intentName"]))
            payload = {
                **scope,
                **intent,
                "dialogCodeHook": {"enabled": False},
                "fulfillmentCodeHook": {"active": True, "enabled": False},
            }
            if intent_id:
                aws("lexv2-models", "update-intent", intentId=intent_id, **payload)
            else:
                aws("lexv2-models", "create-intent", **payload)

        aws("lexv2-models", "build-bot-locale", **scope)
        aws("lexv2-models", "wait", "bot-locale-built", **scope)

    version = aws(
        "lexv2-models", "create-bot-version",
        botId=bot_id,
        description="IT Support: Q in Connect, four locales, COPPA enabled",
        botVersionLocaleSpecification={
            locale: {"sourceBotVersion": "DRAFT"}
            for locale in config["locales"]
        },
    )["botVersion"]
    aws(
        "lexv2-models", "wait", "bot-version-available",
        botId=bot_id, botVersion=version,
    )

    aliases = aws("lexv2-models", "list-bot-aliases", botId=bot_id)
    alias_id = next((
        item["botAliasId"]
        for item in aliases["botAliasSummaries"]
        if item["botAliasName"] == config["alias_name"]
    ), None)
    alias_payload = {
        "botId": bot_id,
        "botAliasName": config["alias_name"],
        "botVersion": version,
        "botAliasLocaleSettings": {
            locale: {"enabled": True} for locale in config["locales"]
        },
        "sentimentAnalysisSettings": {"detectSentiment": False},
    }
    if alias_id:
        aws(
            "lexv2-models", "update-bot-alias",
            botAliasId=alias_id, **alias_payload,
        )
    else:
        alias_id = aws(
            "lexv2-models", "create-bot-alias",
            tags={"AmazonConnectEnabled": "True"}, **alias_payload,
        )["botAliasId"]

    aws(
        "lexv2-models", "wait", "bot-alias-available",
        botId=bot_id, botAliasId=alias_id,
    )
    alias_arn = f"arn:aws:lex:us-east-1:{account}:bot-alias/{bot_id}/{alias_id}"
    aws(
        "lexv2-models", "tag-resource",
        resourceARN=alias_arn, tags={"AmazonConnectEnabled": "True"},
    )

    instance_id = config["connect_instance_arn"].rsplit("/", 1)[1]
    statement = {
        "Sid": f"connect-us-east-1-{instance_id}",
        "Effect": "Allow",
        "Principal": {"Service": "connect.amazonaws.com"},
        "Action": [
            "lex:RecognizeText",
            "lex:StartConversation",
            "lex:RecognizeMessageAsync",
        ],
        "Resource": alias_arn,
        "Condition": {
            "StringEquals": {"AWS:SourceAccount": account},
            "ArnEquals": {"AWS:SourceArn": config["connect_instance_arn"]},
        },
    }

    try:
        existing = aws(
            "lexv2-models", "describe-resource-policy",
            resourceArn=alias_arn,
        )
    except RuntimeError as error:
        if "ResourceNotFoundException" not in str(error):
            raise
        existing = {}

    policy = json.loads(existing["policy"]) if existing.get("policy") else {
        "Version": "2012-10-17", "Statement": []
    }
    statements = policy.get("Statement", [])
    if isinstance(statements, dict):
        statements = [statements]
    policy["Statement"] = [
        item for item in statements if item.get("Sid") != statement["Sid"]
    ] + [statement]

    if existing.get("revisionId"):
        aws(
            "lexv2-models", "update-resource-policy",
            resourceArn=alias_arn, policy=json.dumps(policy),
            expectedRevisionId=existing["revisionId"],
        )
    else:
        aws(
            "lexv2-models", "create-resource-policy",
            resourceArn=alias_arn, policy=json.dumps(policy),
        )

    print(json.dumps({
        "botId": bot_id,
        "botVersion": version,
        "botAliasId": alias_id,
        "botAliasArn": alias_arn,
    }, indent=2))

if __name__ == "__main__":
    main()
