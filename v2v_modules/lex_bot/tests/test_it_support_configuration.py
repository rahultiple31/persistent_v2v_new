import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "configure_it_support.py"
SPEC = importlib.util.spec_from_file_location("configure_it_support", SCRIPT)
CONFIGURE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CONFIGURE)

BOT_ID = "RCKELE93XH"
ALIAS_ID = "W64U0WXHCF"
CONFIG = {
    "bot_name": "BTSGSD-V2V-US-IT-Support_Agent",
    "assistant_arn": "arn:aws:wisdom:us-east-1:518902362956:assistant/bc274e3f-380d-45e7-968f-2d19f92acd74",
    "alias_name": "btsgsd-alias-dev-sso",
    "connect_instance_arn": "arn:aws:connect:us-east-1:518902362956:instance/c227a737-3e4f-4c64-8397-2d37e318801d",
    "locales": ["en_US", "hi_IN", "pt_BR", "es_419"],
}


class FakeAws:
    def __init__(self, existing=False, account="518902362956", child_directed=True,
                 bot_name=CONFIG["bot_name"], fail_operation=None):
        self.existing = existing
        self.account = account
        self.child_directed = child_directed
        self.bot_name = bot_name
        self.fail_operation = fail_operation
        self.calls = []

    def __call__(self, service, *operation, **payload):
        self.calls.append((service, operation, payload))
        op = operation[0]
        if op == self.fail_operation:
            raise RuntimeError("AccessDeniedException: test failure")
        if service == "sts":
            return {"Account": self.account}
        if op == "wait":
            return {}
        if op == "describe-bot":
            return {
                "botName": self.bot_name,
                "dataPrivacy": {"childDirected": self.child_directed},
            }
        if op == "list-intents":
            values = [{"intentName": "FallbackIntent", "intentId": "FALLBCKINT"}]
            if self.existing:
                values.append({"intentName": "AmazonQinConnect", "intentId": "EXISTINGQ1"})
                if payload["localeId"] == "pt_BR":
                    values.append({"intentName": "TransferToAgent", "intentId": "EXISTINGT1"})
            return {"intentSummaries": values}
        if op == "create-bot-version":
            return {"botVersion": "2"}
        if op == "list-bot-aliases":
            return {"botAliasSummaries": [
                {"botAliasName": CONFIG["alias_name"], "botAliasId": ALIAS_ID}
            ] if self.existing else []}
        if op == "create-bot-alias":
            return {"botAliasId": ALIAS_ID}
        if op == "describe-resource-policy":
            if not self.existing:
                raise RuntimeError("ResourceNotFoundException")
            return {
                "revisionId": "revision-1",
                "policy": json.dumps({
                    "Version": "2012-10-17",
                    "Statement": [{"Sid": "ExistingOtherGrant", "Effect": "Allow"}],
                }),
            }
        return {}

    def payloads(self, operation):
        return [payload for _, ops, payload in self.calls if ops[0] == operation]


class ItSupportConfigurationTests(unittest.TestCase):
    def run_configuration(self, fake):
        with mock.patch.dict(os.environ, {
            "LEX_BOT_ID": BOT_ID,
            "LEX_CONFIGURATION": json.dumps(CONFIG),
        }), mock.patch.object(CONFIGURE, "aws", fake), contextlib.redirect_stdout(io.StringIO()):
            CONFIGURE.main()

    def test_creates_requested_intents_and_builds_before_publishing(self):
        fake = FakeAws()
        self.run_configuration(fake)
        created = fake.payloads("create-intent")
        q_intents = [p for p in created if p["intentName"] == "AmazonQinConnect"]
        self.assertEqual({p["localeId"] for p in q_intents}, set(CONFIG["locales"]))
        for intent in q_intents:
            self.assertEqual(intent["parentIntentSignature"], "AMAZON.QinConnectIntent")
            self.assertEqual(intent["qInConnectIntentConfiguration"]["qInConnectAssistantConfiguration"]["assistantArn"], CONFIG["assistant_arn"])
            self.assertEqual(intent["fulfillmentCodeHook"], {"active": True, "enabled": False})
        transfers = [p for p in created if p["intentName"] == "TransferToAgent"]
        self.assertEqual(len(transfers), 1)
        self.assertEqual(transfers[0]["localeId"], "pt_BR")
        self.assertEqual(transfers[0]["sampleUtterances"], [{"utterance": "transfer my call to agent"}])
        fallbacks = fake.payloads("update-intent")
        self.assertEqual(len(fallbacks), 4)
        self.assertTrue(all(p["intentId"] == "FALLBCKINT" for p in fallbacks))
        version_position = next(i for i, (_, op, _) in enumerate(fake.calls) if op[0] == "create-bot-version")
        built = [p["localeId"] for _, op, p in fake.calls[:version_position] if op == ("wait", "bot-locale-built")]
        self.assertEqual(set(built), set(CONFIG["locales"]))
        self.assertEqual(set(fake.payloads("create-bot-version")[0]["botVersionLocaleSpecification"]), set(CONFIG["locales"]))
        alias = fake.payloads("create-bot-alias")[0]
        self.assertEqual(alias["sentimentAnalysisSettings"], {"detectSentiment": False})
        self.assertEqual(alias["tags"], {"AmazonConnectEnabled": "True"})
        self.assertEqual(set(alias["botAliasLocaleSettings"]), set(CONFIG["locales"]))
        self.assertNotIn("conversationLogSettings", alias)

    def test_updates_existing_intents_alias_and_preserves_other_policy_grants(self):
        fake = FakeAws(existing=True)
        self.run_configuration(fake)
        self.assertEqual(fake.payloads("create-intent"), [])
        self.assertEqual(len(fake.payloads("update-intent")), 9)
        self.assertEqual(fake.payloads("create-bot-alias"), [])
        self.assertEqual(fake.payloads("update-bot-alias")[0]["botAliasId"], ALIAS_ID)
        update = fake.payloads("update-resource-policy")[0]
        self.assertEqual(update["expectedRevisionId"], "revision-1")
        statements = json.loads(update["policy"])["Statement"]
        self.assertEqual(statements[0]["Sid"], "ExistingOtherGrant")
        grant = statements[1]
        self.assertEqual(grant["Resource"], f"arn:aws:lex:us-east-1:518902362956:bot-alias/{BOT_ID}/{ALIAS_ID}")
        self.assertEqual(grant["Condition"]["ArnEquals"]["AWS:SourceArn"], CONFIG["connect_instance_arn"])
        self.assertEqual(grant["Action"], ["lex:RecognizeText", "lex:StartConversation", "lex:RecognizeMessageAsync"])

    def test_rejects_incorrect_account_bot_or_coppa_before_updating_intents(self):
        for fake in [FakeAws(account="000000000000"), FakeAws(bot_name="AnotherBot"), FakeAws(child_directed=False)]:
            with self.subTest(account=fake.account, bot=fake.bot_name, coppa=fake.child_directed):
                with self.assertRaises(RuntimeError):
                    self.run_configuration(fake)
                self.assertEqual(fake.payloads("create-intent"), [])
                self.assertEqual(fake.payloads("update-intent"), [])

    def test_failed_build_does_not_publish_version_or_update_alias(self):
        fake = FakeAws(fail_operation="build-bot-locale")
        with self.assertRaisesRegex(RuntimeError, "AccessDeniedException"):
            self.run_configuration(fake)
        self.assertEqual(fake.payloads("create-bot-version"), [])
        self.assertEqual(fake.payloads("update-bot-alias"), [])

    def test_policy_access_denied_is_not_treated_as_missing_policy(self):
        fake = FakeAws(existing=True, fail_operation="describe-resource-policy")
        with self.assertRaisesRegex(RuntimeError, "AccessDeniedException"):
            self.run_configuration(fake)
        self.assertEqual(fake.payloads("create-resource-policy"), [])


if __name__ == "__main__":
    unittest.main()
