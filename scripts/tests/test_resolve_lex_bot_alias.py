import importlib.util
import json
from pathlib import Path
import subprocess
import unittest
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / "resolve-lex-bot-alias.py"
SPEC = importlib.util.spec_from_file_location("resolve_lex_bot_alias", SCRIPT)
RESOLVER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RESOLVER)

QUERY = {
    "bot_name": "BTSGSD-V2V-US-IT-Support_Agent",
    "alias_name": "btsgsd-alias-dev-sso",
    "account_id": "518902362956",
    "region": "us-east-1",
}


def ok(body):
    return subprocess.CompletedProcess([], 0, stdout=json.dumps(body), stderr="")


def payload(call):
    command = call.args[0]
    return command[2], json.loads(command[command.index("--cli-input-json") + 1])


class ResolveLexBotAliasTests(unittest.TestCase):
    def test_returns_alias_arn_for_exact_names(self):
        runner = mock.Mock(side_effect=[
            ok({"botSummaries": [
                {"botName": "BTSGSD-V2V-US-IT-Support_Agent-old", "botId": "AAAAAAAAAA"},
                {"botName": QUERY["bot_name"], "botId": "BOTID12345"},
            ]}),
            ok({"botAliasSummaries": [
                {"botAliasName": "TestBotAlias", "botAliasId": "TSTALIASID"},
                {"botAliasName": QUERY["alias_name"], "botAliasId": "ALIAS12345"},
            ]}),
        ])
        self.assertEqual(RESOLVER.resolve_alias(QUERY, runner=runner), {
            "bot_id": "BOTID12345",
            "alias_id": "ALIAS12345",
            "alias_arn": "arn:aws:lex:us-east-1:518902362956:bot-alias/BOTID12345/ALIAS12345",
        })
        operation, request = payload(runner.call_args_list[0])
        self.assertEqual(operation, "list-bots")
        self.assertEqual(request["filters"][0]["values"], [QUERY["bot_name"]])
        operation, request = payload(runner.call_args_list[1])
        self.assertEqual((operation, request), ("list-bot-aliases", {"botId": "BOTID12345"}))

    def test_follows_alias_pages(self):
        runner = mock.Mock(side_effect=[
            ok({"botSummaries": [{"botName": QUERY["bot_name"], "botId": "BOTID12345"}]}),
            ok({"botAliasSummaries": [{"botAliasName": "TestBotAlias", "botAliasId": "TSTALIASID"}], "nextToken": "t1"}),
            ok({"botAliasSummaries": [{"botAliasName": QUERY["alias_name"], "botAliasId": "ALIAS12345"}]}),
        ])
        self.assertEqual(RESOLVER.resolve_alias(QUERY, runner=runner)["alias_id"], "ALIAS12345")
        self.assertEqual(payload(runner.call_args_list[2])[1]["nextToken"], "t1")

    def test_missing_bot_or_alias_fails(self):
        runner = mock.Mock(return_value=ok({"botSummaries": []}))
        with self.assertRaisesRegex(ValueError, "found 0"):
            RESOLVER.resolve_alias(QUERY, runner=runner)
        runner = mock.Mock(side_effect=[
            ok({"botSummaries": [{"botName": QUERY["bot_name"], "botId": "BOTID12345"}]}),
            ok({"botAliasSummaries": [{"botAliasName": "TestBotAlias", "botAliasId": "TSTALIASID"}]}),
        ])
        with self.assertRaisesRegex(ValueError, "alias named btsgsd-alias-dev-sso"):
            RESOLVER.resolve_alias(QUERY, runner=runner)

    def test_rejects_bad_input_before_calling_aws(self):
        runner = mock.Mock()
        for key, value in (("bot_name", "bad name;"), ("account_id", "123"), ("region", "nowhere")):
            with self.subTest(key=key), self.assertRaises(ValueError):
                RESOLVER.resolve_alias(dict(QUERY, **{key: value}), runner=runner)
        runner.assert_not_called()

    def test_cli_error_is_reported(self):
        runner = mock.Mock(return_value=subprocess.CompletedProcess([], 255, stdout="", stderr="AccessDenied"))
        with self.assertRaisesRegex(RuntimeError, "AccessDenied"):
            RESOLVER.resolve_alias(QUERY, runner=runner)


if __name__ == "__main__":
    unittest.main()
