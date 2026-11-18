"""Resolve a Lex V2 bot alias ARN by bot and alias name for a Terraform external data source.

Used for aliases created outside Terraform state (the IT Support alias is
created by v2v_modules/lex_bot/configure_it_support.py). Read-only.
"""

import json
import re
import subprocess
import sys


def aws(runner, region, operation, payload):
    result = runner([
        "aws", "lexv2-models", operation,
        "--region", region,
        "--cli-input-json", json.dumps(payload),
        "--output", "json",
        "--no-cli-pager",
    ], text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(f"lexv2-models {operation} failed: " + result.stderr.strip())
    return json.loads(result.stdout or "{}")


def paged(runner, region, operation, payload, key):
    request = dict(payload)
    while True:
        response = aws(runner, region, operation, request)
        yield from response.get(key, [])
        if not response.get("nextToken"):
            return
        request["nextToken"] = response["nextToken"]


def resolve_alias(query, runner=None):
    bot_name = query["bot_name"]
    alias_name = query["alias_name"]
    account_id = query["account_id"]
    region = query["region"]

    if not re.fullmatch(r"[0-9a-zA-Z][_.\-0-9a-zA-Z]{0,99}", bot_name):
        raise ValueError("bot_name must be a Lex V2 bot name")
    if not re.fullmatch(r"[0-9a-zA-Z][_\-0-9a-zA-Z]{0,99}", alias_name):
        raise ValueError("alias_name must be a Lex V2 alias name")
    if not re.fullmatch(r"[0-9]{12}", account_id):
        raise ValueError("account_id must be a 12-digit AWS account ID")
    if not re.fullmatch(r"[a-z]{2}(?:-[a-z]+)+-[0-9]+", region):
        raise ValueError("region must be a valid AWS region name")

    runner = runner or subprocess.run
    bots = [
        bot for bot in paged(runner, region, "list-bots", {
            "filters": [{"name": "BotName", "values": [bot_name], "operator": "EQ"}],
        }, "botSummaries")
        if bot.get("botName") == bot_name
    ]
    if len(bots) != 1:
        raise ValueError(f"Expected one Lex bot named {bot_name}; found {len(bots)}. Deploy the lex_bot choice first.")
    bot_id = bots[0]["botId"]

    aliases = [
        alias for alias in paged(runner, region, "list-bot-aliases", {"botId": bot_id}, "botAliasSummaries")
        if alias.get("botAliasName") == alias_name
    ]
    if len(aliases) != 1:
        raise ValueError(
            f"Expected one alias named {alias_name} on Lex bot {bot_name}; found {len(aliases)}. "
            "Deploy the lex_bot choice first."
        )
    alias_id = aliases[0]["botAliasId"]
    if not re.fullmatch(r"[0-9A-Z]{10}", bot_id) or not re.fullmatch(r"[0-9A-Z]{10}", alias_id):
        raise ValueError("AWS returned an invalid bot or alias ID")

    return {
        "bot_id": bot_id,
        "alias_id": alias_id,
        "alias_arn": f"arn:aws:lex:{region}:{account_id}:bot-alias/{bot_id}/{alias_id}",
    }


def main():
    try:
        result = resolve_alias(json.load(sys.stdin))
    except (ValueError, KeyError, RuntimeError, OSError) as error:
        print(str(error), file=sys.stderr)
        return 1
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
