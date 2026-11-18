"""
BTSGSD AWS Infrastructure As-Built Documentation Generator
Generates professional Word (DOCX), PDF, and Markdown as-built documents
from live AWS API data and Terraform configuration.

Cover page · Table of Contents · Executive Summary · Readable IAM policies
Proper column widths · 9pt PDF font · Branding · Page numbers
"""

import argparse, json, os, re
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from xml.sax.saxutils import escape

import boto3
from botocore.exceptions import BotoCoreError, ClientError
from docx import Document
from docx.enum.section import WD_ORIENT
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Inches, Pt, RGBColor
from reportlab.lib import colors
from reportlab.lib.pagesizes import A4, landscape
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import inch
from reportlab.platypus import (
    BaseDocTemplate, Frame, HRFlowable, NextPageTemplate,
    PageBreak, PageTemplate, Paragraph, Spacer, Table, TableStyle,
)

# ── Branding ──────────────────────────────────────────────────────────────────
BRAND_DARK    = "#17365D"
BRAND_MID     = "#2E74B5"
BRAND_LIGHT   = "#D6E4F3"
BRAND_ACCENT  = "#70AD47"
BRAND_ROW_ALT = "#F3F6FA"

# ── Truncation limits ──────────────────────────────────────────────────────────
MAX_DETAIL = 320
MAX_TAG    = 140
MAX_NAME   = 85
MAX_ID     = 100

ENVIRONMENT_DISPLAY = {
    "dev":     "Development (Dev)",
    "v2v-dev": "V2V Development (V2V-Dev)",
    "prod":    "Production (Prod)",
}

SERVICE_DESCRIPTIONS = {
    "Amazon Connect": (
        "Amazon Connect is the cloud-based contact centre. Resources include instances, "
        "queues, routing profiles, contact flows, hours of operation, security profiles, "
        "and integration associations."
    ),
    "Amazon Connect AI": (
        "Amazon Q in Connect provides AI-powered agent assistance. Resources include "
        "assistants, AI agents, and AI prompts with their model and configuration details."
    ),
    "Amazon Lex V2": (
        "Amazon Lex V2 provides conversational AI. Resources include bots, locales, "
        "intents, slots, bot versions, and aliases."
    ),
    "AWS IAM": (
        "IAM controls access to AWS services. Policy statements are shown as human-readable "
        "Allow/Deny lines. Trust relationships list which principals can assume each role."
    ),
    "Amazon VPC": (
        "VPC provides network isolation. Resources include VPCs, subnets, security groups, "
        "route tables, NAT gateways, VPC endpoints, and internet gateways."
    ),
    "Amazon S3": (
        "S3 provides object storage. Resources include buckets with versioning, encryption, "
        "public-access block, lifecycle, and logging settings."
    ),
    "Amazon CloudWatch": (
        "CloudWatch provides monitoring. Resources include log groups (with retention and "
        "metric filters) and metric alarms."
    ),
    "Amazon API Gateway": (
        "API Gateway provides managed API hosting. Resources include REST and V2 APIs, "
        "stages, routes, and backend integrations."
    ),
    "AWS Secrets Manager": (
        "Secrets Manager stores credentials. Secret values are never collected — only "
        "metadata such as rotation config and KMS key."
    ),
    "AWS KMS": (
        "KMS manages encryption keys. Resources include customer-managed keys with state, "
        "usage, rotation status, and aliases."
    ),
    "Amazon SNS": (
        "SNS provides pub/sub messaging. Resources include topics with subscription counts "
        "and encryption settings."
    ),
    "Amazon SQS": (
        "SQS provides managed queuing. Resources include queues with FIFO and encryption "
        "configuration."
    ),
    "AWS Lambda": (
        "Lambda provides serverless compute. Resources include functions with runtime, "
        "memory, timeout, concurrency, and env variable names (values always redacted)."
    ),
    "Amazon DynamoDB": (
        "DynamoDB provides managed NoSQL storage. Resources include tables with key schema, "
        "indexes, encryption, TTL, and backup configuration."
    ),
    "Terraform": (
        "Terraform IaC declarations from the selected environment directory. "
        "Sensitive values are not collected."
    ),
    "Terraform Evaluated Plan": (
        "Evaluated Terraform plan showing resource configuration values that will be applied. "
        "Sensitive values are automatically redacted."
    ),
    "Terraform State": (
        "Terraform state showing current deployed resource values. "
        "Sensitive values are automatically redacted."
    ),
}

# ── Utilities ──────────────────────────────────────────────────────────────────

def truncate(text, max_len, suffix="…"):
    t = str(text) if text is not None else "-"
    return t if len(t) <= max_len else t[: max_len - len(suffix)] + suffix


def format_iam_policy(policy):
    """Return a human-readable summary of an IAM policy dict or JSON string."""
    if isinstance(policy, str):
        try:
            policy = json.loads(policy)
        except Exception:
            return truncate(policy, 220)
    if not isinstance(policy, dict):
        return truncate(str(policy), 220)
    stmts = policy.get("Statement", [])
    if not stmts:
        return "Empty policy"
    lines = []
    for s in stmts:
        effect    = s.get("Effect", "?")
        actions   = s.get("Action",   [])
        resources = s.get("Resource", [])
        principal = s.get("Principal")
        if isinstance(actions, str):   actions   = [actions]
        if isinstance(resources, str): resources = [resources]
        act = ", ".join(actions[:4]) + (f" (+{len(actions)-4} more)" if len(actions) > 4 else "")
        res = ", ".join(str(r)[-55:] for r in resources[:3])
        if len(resources) > 3:
            res += f" (+{len(resources)-3} more)"
        line = f"[{effect}] {act}"
        if principal:
            if isinstance(principal, dict):
                svc = principal.get("Service") or principal.get("AWS") or str(principal)
                if isinstance(svc, list):
                    svc = ", ".join(svc)
            else:
                svc = str(principal)
            line += f" | Principal: {truncate(str(svc), 55)}"
        line += f" | Resource: {res}"
        cond = s.get("Condition")
        if cond:
            line += f" | Condition: {truncate(json.dumps(cond, separators=(',', ':')), 60)}"
        lines.append(line)
    return " || ".join(lines)


def format_json(obj):
    """Format a JSON object as a compact, readable string."""
    if isinstance(obj, str):
        try:
            obj = json.loads(obj)
        except Exception:
            return truncate(obj, 200)
    if isinstance(obj, dict):
        if "Statement" in obj:
            return format_iam_policy(obj)
        if not obj:
            return "(empty)"
        parts = [f"{k}: {truncate(str(v), 45)}" for k, v in list(obj.items())[:6]]
        return ", ".join(parts) + (f" +{len(obj)-6} more" if len(obj) > 6 else "")
    if isinstance(obj, list):
        if not obj:
            return "(empty)"
        return ", ".join(truncate(str(x), 40) for x in obj[:5]) + (
            f" +{len(obj)-5} more" if len(obj) > 5 else ""
        )
    return truncate(str(obj), 200)


def format_detail(raw):
    """
    Convert a raw detail string (key=val; key=val) into clean, readable text.
    JSON sub-values are formatted; IAM policies become Allow/Deny lines.
    """
    if not raw or raw in ("-", ""):
        return "-"
    raw = str(raw).strip()
    if raw.startswith(("{", "[")):
        try:
            return truncate(format_json(json.loads(raw)), MAX_DETAIL)
        except Exception:
            pass
    parts = []
    for seg in raw.split("; "):
        seg = seg.strip()
        if not seg:
            continue
        if "=" not in seg:
            parts.append(truncate(seg, 110))
            continue
        key, _, val = seg.partition("=")
        key = key.strip()
        val = val.strip()
        if val in ("None", "none", "null", "[]", "{}", "-", ""):
            continue
        if val.startswith(("{", "[")):
            try:
                val = format_json(json.loads(val))
            except Exception:
                val = truncate(val, 110)
        elif len(val) > 110:
            val = truncate(val, 110)
        parts.append(f"{key}: {val}")
    result = " | ".join(parts)
    return truncate(result, MAX_DETAIL) if result else "-"


def tag_text(tags):
    if isinstance(tags, dict):
        data = tags
    else:
        data = {x.get("Key"): x.get("Value") for x in (tags or []) if x.get("Key")}
    text = " | ".join(f"{k}={v}" for k, v in sorted(data.items()))
    return truncate(text, MAX_TAG) if text else "-"


def value(item, default="-"):
    if item in (None, "", [], {}):
        return default
    if isinstance(item, (list, tuple, set)):
        return ", ".join(map(str, item)) or default
    if isinstance(item, dict):
        return format_json(item)
    return str(item)


def add(rows, service, kind, name, identifier="-", details="-", tags="-"):
    rows.append({
        "service":    service,
        "type":       kind,
        "name":       truncate(value(name),       MAX_NAME),
        "identifier": truncate(value(identifier), MAX_ID),
        "details":    format_detail(value(details)),
        "tags":       truncate(value(tags),        MAX_TAG),
    })


def pages(client, operation, key, **kwargs):
    """
    Paginate through all results for an AWS API operation.
    Uses the boto3 built-in paginator when available; falls back to manual
    nextToken iteration for operations that support nextToken pagination but
    are not registered as paginators (e.g. Amazon Lex V2 list_bots).
    """
    from botocore.exceptions import OperationNotPageableError
    try:
        for page in client.get_paginator(operation).paginate(**kwargs):
            yield from page.get(key, [])
    except OperationNotPageableError:
        # Manual nextToken fallback
        fn = getattr(client, operation)
        while True:
            resp  = fn(**kwargs)
            yield from resp.get(key, [])
            token = resp.get("nextToken")
            if not token:
                break
            kwargs = {**kwargs, "nextToken": token}


# ── Tag-based resource filtering (Application tag) ───────────────────────────
# Uses the AWS Resource Groups Tagging API to fetch every resource ARN tagged
# with the configured Application tag value.  Each collector checks membership
# in that pre-loaded set so ONLY tagged resources appear in the document.

# Default Application tag value derived automatically from --environment.
ENV_DEFAULT_FILTER = {
    "dev":     "BTSGSD-DEV",
    "v2v-dev": "BTSGSD-V2V-US",
    "prod":    "BTSGSD-PROD",
}

# Name hints used as a last-resort pre-filter for S3 (list_buckets has no tags).
_ENV_NAME_HINTS = {
    "dev":     ("btsgsd-dev", "btsgsd_dev"),
    "v2v-dev": ("btsgsd-v2v", "btsgsd_v2v", "v2v"),
    "prod":    ("btsgsd-prod", "btsgsd_prod"),
}


def _td(raw):
    """Normalise raw tags to a plain {key: value} dict."""
    if isinstance(raw, dict):
        return raw
    return {t.get("Key", ""): t.get("Value", "") for t in (raw or []) if t.get("Key")}


def _load_tagged_arns(session, tag_key, tag_value):
    """
    Call the AWS Resource Groups Tagging API and return a frozenset of every
    resource ARN in the account that has tag_key=tag_value.
    Returns None when the API call fails (falls back to per-resource checks).
    """
    try:
        client = session.client("resourcegroupstaggingapi")
        arns = set()
        for page in client.get_paginator("get_resources").paginate(
            TagFilters=[{"Key": tag_key, "Values": [tag_value]}]
        ):
            for r in page.get("ResourceTagMappingList", []):
                arns.add(r["ResourceARN"])
        print(f"  Tagging API: '{tag_key}={tag_value}' matched {len(arns)} resource ARNs.")
        return frozenset(arns)
    except (ClientError, BotoCoreError) as exc:
        print(f"  Warning: Tagging API unavailable ({exc}). "
              "Falling back to per-resource tag inspection.")
        return None


class FilterCtx:
    """
    Filtering context passed to every AWS collector.

    Decision order inside ok():
      1. Direct tag check  — fastest; used when the tag is in the list response.
      2. ARN set lookup    — from the pre-loaded Tagging API result.
      3. Conservative include — when neither tag nor ARN is determinable.

    A resource is INCLUDED only when it carries the configured Application tag
    with the correct value.  Resources confirmed to lack this tag are excluded.
    """

    def __init__(self, env, region, account, tagged_arns, tag_key, tag_value):
        self.env         = env
        self.region      = region
        self.account     = account
        self.tagged_arns = tagged_arns        # frozenset[str] | None
        self.tag_key     = tag_key
        self.tag_value_l = tag_value.lower()  # e.g. "btsgsd-v2v-us"

    def ok(self, arn=None, raw_tags=None):
        """
        Return True  → include this resource.
        Return False → exclude this resource.
        """
        # 1. Direct tag check (cheapest — tags already in the list response)
        if raw_tags is not None:
            td = _td(raw_tags)
            app_val = td.get(self.tag_key)
            if app_val is not None:
                return app_val.lower() == self.tag_value_l
            # Tag key absent in this resource's tags — fall through to ARN check

        # 2. ARN membership in the Tagging API pre-loaded set
        if self.tagged_arns is not None:
            if arn:
                return arn in self.tagged_arns
            # No ARN and direct tag did not confirm inclusion → exclude
            return False

        # 3. Conservative include (Tagging API unavailable, no direct tag)
        return True

    def name_ok(self, name):
        """Cheap name-based pre-filter used for S3 (list_buckets has no tags)."""
        if not name:
            return True
        nl = name.lower()
        our_hints = _ENV_NAME_HINTS.get(self.env, (self.env,))
        if any(h in nl for h in our_hints):
            return True
        for other, hints in _ENV_NAME_HINTS.items():
            if other != self.env and any(h in nl for h in hints):
                return False
        return True


# ── AWS Collectors ─────────────────────────────────────────────────────────────

def connect(session, rows, ctx):
    c = session.client("connect")
    for instance in pages(c, "list_instances", "InstanceSummaryList"):
        iid   = instance["Id"]
        alias = instance.get("InstanceAlias", "")

        # Amazon Connect instances are environment-level resources: one instance
        # per environment.  The Tagging API does not reliably index Connect
        # instances, and the instance itself may not carry the Application tag
        # (tags are often applied to queues / contact-flows instead).
        #
        # Strategy:
        #   1. Try a direct Application tag check on the instance.
        #   2. If that is inconclusive, fall back to the instance alias which
        #      always contains the environment identifier (e.g. btsgsd-v2v-…).
        #   3. Never use the Tagging API ARN set alone for Connect instances
        #      because they are frequently absent from that index.
        instance_arn = f"arn:aws:connect:{ctx.region}:{ctx.account}:instance/{iid}"
        try:
            tag_resp  = c.list_tags_for_resource(resourceArn=instance_arn)
            # Connect returns lowercase 'tags' as a plain dict
            inst_tags = tag_resp.get("tags") or tag_resp.get("Tags") or None
        except ClientError:
            inst_tags = None

        if inst_tags:
            # Tags available — do a strict Application tag match
            td      = _td(inst_tags)
            app_val = td.get(ctx.tag_key)
            if app_val is not None:
                if app_val.lower() != ctx.tag_value_l:
                    continue          # tagged, wrong value → exclude
                # else: tagged correctly → include, fall through
            # else: Application tag absent on instance → fall to alias check

        # Alias-based fallback: include only if the alias contains the
        # environment's name hints.  If no hints match either direction,
        # include conservatively (single-instance accounts).
        if not ctx.name_ok(alias):
            continue
        add(rows, "Amazon Connect", "Instance",
            instance.get("InstanceAlias"), iid,
            f"Status={instance.get('InstanceStatus')}; ServiceRole={instance.get('ServiceRole', '-')}")
        calls = [
            ("list_queues",                  "QueueSummaryList",
             "Queue",            {"InstanceId": iid, "QueueTypes": ["STANDARD", "AGENT"]}),
            ("list_routing_profiles",         "RoutingProfileSummaryList",
             "Routing profile",  {"InstanceId": iid}),
            ("list_contact_flows",            "ContactFlowSummaryList",
             "Contact flow",     {"InstanceId": iid}),
            ("list_contact_flow_modules",     "ContactFlowModulesSummaryList",
             "Flow module",      {"InstanceId": iid}),
            ("list_hours_of_operations",      "HoursOfOperationSummaryList",
             "Hours",            {"InstanceId": iid}),
            ("list_prompts",                  "PromptSummaryList",
             "Prompt",           {"InstanceId": iid}),
            ("list_security_profiles",        "SecurityProfileSummaryList",
             "Security profile", {"InstanceId": iid}),
            ("list_integration_associations", "IntegrationAssociationSummaryList",
             "Integration",      {"InstanceId": iid}),
        ]
        # Sub-resource name-prefix filter.
        # Only resources whose Name starts with the Application tag value
        # (case-insensitive) are included, e.g. "BTSGSD-V2V-US-..."
        # Integrations have no meaningful Name, so they are always included.
        connect_prefix = ctx.tag_value_l  # e.g. "btsgsd-v2v-us"

        for op, key, kind, args in calls:
            for item in pages(c, op, key, **args):
                name = item.get("Name") or item.get("IntegrationType")
                rid  = (item.get("Id") or item.get("Arn")
                        or item.get("IntegrationAssociationId"))

                # Apply name-prefix filter for named sub-resources.
                # Integrations use IntegrationType (not a customer-defined name)
                # so skip the prefix check for them.
                if kind != "Integration" and name:
                    if not str(name).lower().startswith(connect_prefix):
                        continue

                detail = "; ".join(
                    f"{k}={v}" for k, v in item.items()
                    if k not in {"Name", "Id", "Arn"} and v not in (None, "", [], {})
                )
                add(rows, "Amazon Connect", kind, name, rid, detail)
                try:
                    if kind == "Queue":
                        x = c.describe_queue(InstanceId=iid, QueueId=rid)["Queue"]
                        add(rows, "Amazon Connect", "Queue configuration", name, rid,
                            f"Status={x.get('Status')}; HoursId={x.get('HoursOfOperationId')}; "
                            f"MaxContacts={x.get('MaxContacts')}; Description={x.get('Description','-')}",
                            tag_text(x.get("Tags")))
                    elif kind == "Routing profile":
                        x = c.describe_routing_profile(InstanceId=iid, RoutingProfileId=rid)["RoutingProfile"]
                        add(rows, "Amazon Connect", "Routing profile configuration", name, rid,
                            f"DefaultQueue={x.get('DefaultOutboundQueueId')}; "
                            f"MediaConcurrencies={value(x.get('MediaConcurrencies'))}; "
                            f"AgentAvailabilityTimer={x.get('AgentAvailabilityTimer')}",
                            tag_text(x.get("Tags")))
                    elif kind == "Contact flow":
                        x = c.describe_contact_flow(InstanceId=iid, ContactFlowId=rid)["ContactFlow"]
                        add(rows, "Amazon Connect", "Contact flow configuration", name, rid,
                            f"Type={x.get('Type')}; State={x.get('State')}; "
                            f"Status={x.get('Status')}; Description={x.get('Description','-')}",
                            tag_text(x.get("Tags")))
                    elif kind == "Hours":
                        x = c.describe_hours_of_operation(InstanceId=iid, HoursOfOperationId=rid)["HoursOfOperation"]
                        add(rows, "Amazon Connect", "Hours configuration", name, rid,
                            f"TimeZone={x.get('TimeZone')}; Config={value(x.get('Config'))}",
                            tag_text(x.get("Tags")))
                    elif kind == "Security profile":
                        x = c.describe_security_profile(InstanceId=iid, SecurityProfileId=rid)["SecurityProfile"]
                        add(rows, "Amazon Connect", "Security profile configuration", name, rid,
                            f"AllowedAccessControlTags={value(x.get('AllowedAccessControlTags'))}",
                            tag_text(x.get("Tags")))
                except ClientError as e:
                    add(rows, "Amazon Connect", f"{kind} configuration", name, rid,
                        f"Not collected: {e.response.get('Error', {}).get('Code')}")


def lex(session, rows, ctx):
    c = session.client("lexv2-models")
    for bot in pages(c, "list_bots", "botSummaries"):
        bid = bot["botId"]
        # describe_bot returns the canonical botArn and botTags — both are
        # absent from list_bots, so we need this call to filter correctly.
        try:
            bot_detail = c.describe_bot(botId=bid)
            bot_arn    = (
                bot_detail.get("botArn")
                or f"arn:aws:lex:{ctx.region}:{ctx.account}:bot/{bid}"
            )
            bot_tags   = bot_detail.get("botTags", {})
        except ClientError:
            bot_arn  = f"arn:aws:lex:{ctx.region}:{ctx.account}:bot/{bid}"
            bot_tags = None
        if not ctx.ok(arn=bot_arn, raw_tags=bot_tags):
            continue
        bname = bot.get("botName")
        add(rows, "Amazon Lex V2", "Bot", bname, bid,
            f"Status={bot.get('botStatus')}; LatestVersion={bot.get('latestBotVersion')}")
        for x in pages(c, "list_bot_locales", "botLocaleSummaries",
                        botId=bid, botVersion="DRAFT"):
            locale = x.get("localeId")
            add(rows, "Amazon Lex V2", "Locale", f"{bname}/{locale}", locale,
                f"Status={x.get('botLocaleStatus')}; Intents={x.get('intentCount')}")
            for intent in pages(c, "list_intents", "intentSummaries",
                                 botId=bid, botVersion="DRAFT", localeId=locale):
                iid2, iname = intent.get("intentId"), intent.get("intentName")
                add(rows, "Amazon Lex V2", "Intent", f"{bname}/{iname}", iid2,
                    f"Description={intent.get('description', '-')}")
                for slot in pages(c, "list_slots", "slotSummaries",
                                   botId=bid, botVersion="DRAFT",
                                   localeId=locale, intentId=iid2):
                    add(rows, "Amazon Lex V2", "Slot",
                        f"{iname}/{slot.get('slotName')}", slot.get("slotId"),
                        f"Type={slot.get('slotTypeId')}")
        for x in pages(c, "list_bot_versions", "botVersionSummaries", botId=bid):
            add(rows, "Amazon Lex V2", "Version",
                f"{bname} v{x.get('botVersion')}", x.get("botVersion"),
                f"Status={x.get('botStatus')}")
        for x in pages(c, "list_bot_aliases", "botAliasSummaries", botId=bid):
            add(rows, "Amazon Lex V2", "Alias",
                x.get("botAliasName"), x.get("botAliasId"),
                f"Version={x.get('botVersion')}; Status={x.get('botAliasStatus')}")


def qconnect(session, rows, ctx):
    c = session.client("qconnect")
    for assistant in pages(c, "list_assistants", "assistantSummaries"):
        if not ctx.ok(arn=assistant.get("assistantArn"),
                      raw_tags=assistant.get("tags")):
            continue
        aid, name = assistant["assistantId"], assistant.get("name")
        add(rows, "Amazon Connect AI", "Assistant", name, aid,
            f"Status={assistant.get('status')}; Type={assistant.get('type')}",
            tag_text(assistant.get("tags")))
        for origin in ("CUSTOMER", "SYSTEM"):
            for agent in pages(c, "list_ai_agents", "aiAgentSummaries",
                                assistantId=aid, origin=origin):
                agent_id = agent.get("aiAgentId")
                # get_ai_agent can raise ResourceNotFoundException if the
                # agent was deleted after being listed — skip it gracefully.
                try:
                    detail = c.get_ai_agent(
                        assistantId=aid, aiAgentId=agent_id
                    ).get("aiAgent", {})
                except ClientError:
                    detail = {}
                add(rows, "Amazon Connect AI", "AI agent", agent.get("name"), agent_id,
                    f"Origin={origin}; Type={agent.get('type')}; Status={agent.get('status')}; "
                    f"Config={value(detail.get('configuration'))}",
                    tag_text(agent.get("tags")))
        for prompt in pages(c, "list_ai_prompts", "aiPromptSummaries",
                             assistantId=aid, origin="CUSTOMER"):
            pid = prompt.get("aiPromptId")
            # Same defensive pattern for get_ai_prompt.
            try:
                detail = c.get_ai_prompt(
                    assistantId=aid, aiPromptId=pid
                ).get("aiPrompt", {})
            except ClientError:
                detail = {}
            add(rows, "Amazon Connect AI", "AI prompt", prompt.get("name"), pid,
                f"Type={prompt.get('type')}; Status={prompt.get('status')}; "
                f"Model={detail.get('modelId')}; TemplateType={detail.get('templateType')}",
                tag_text(prompt.get("tags")))


def iam(session, rows, ctx):
    c = session.client("iam")
    for role in pages(c, "list_roles", "Roles"):
        # IAM Roles carry Tags in the list response
        if not ctx.ok(arn=role.get("Arn"), raw_tags=role.get("Tags", [])):
            continue
        name     = role["RoleName"]
        attached = [x["PolicyName"] for x in
                    pages(c, "list_attached_role_policies", "AttachedPolicies", RoleName=name)]
        inline   = list(pages(c, "list_role_policies", "PolicyNames", RoleName=name))
        trust    = format_iam_policy(role.get("AssumeRolePolicyDocument", {}))
        add(rows, "AWS IAM", "Role", name, role.get("Arn"),
            f"TrustPolicy: {trust} | AttachedPolicies: {value(attached)} | "
            f"InlinePolicies: {value(inline)} | MaxSession: {role.get('MaxSessionDuration')}s",
            tag_text(role.get("Tags")))
        for pname in inline:
            doc_obj = c.get_role_policy(RoleName=name, PolicyName=pname).get("PolicyDocument", {})
            add(rows, "AWS IAM", "Inline policy", f"{name} / {pname}", role.get("Arn"),
                format_iam_policy(doc_obj))
    for policy in pages(c, "list_policies", "Policies", Scope="Local"):
        doc_obj = (c.get_policy_version(PolicyArn=policy["Arn"],
                                         VersionId=policy["DefaultVersionId"])
                    .get("PolicyVersion", {}).get("Document", {}))
        add(rows, "AWS IAM", "Managed policy", policy.get("PolicyName"), policy.get("Arn"),
            f"Attachments: {policy.get('AttachmentCount')} | {format_iam_policy(doc_obj)}")


def networking(session, rows, ctx):
    c = session.client("ec2")
    # Maps the response list key to its EC2 resource-type name and ID field
    EC2_RES = {
        "Vpcs":             ("vpc",              "VpcId"),
        "Subnets":          ("subnet",           "SubnetId"),
        "SecurityGroups":   ("security-group",   "GroupId"),
        "RouteTables":      ("route-table",      "RouteTableId"),
        "NatGateways":      ("natgateway",       "NatGatewayId"),
        "VpcEndpoints":     ("vpc-endpoint",     "VpcEndpointId"),
        "InternetGateways": ("internet-gateway", "InternetGatewayId"),
    }
    calls = [
        ("describe_vpcs",              "Vpcs",             "VPC",              "VpcId"),
        ("describe_subnets",           "Subnets",          "Subnet",           "SubnetId"),
        ("describe_security_groups",   "SecurityGroups",   "Security group",   "GroupId"),
        ("describe_route_tables",      "RouteTables",      "Route table",      "RouteTableId"),
        ("describe_nat_gateways",      "NatGateways",      "NAT gateway",      "NatGatewayId"),
        ("describe_vpc_endpoints",     "VpcEndpoints",     "VPC endpoint",     "VpcEndpointId"),
        ("describe_internet_gateways", "InternetGateways", "Internet gateway", "InternetGatewayId"),
    ]
    for op, key, kind, id_key in calls:
        ec2_res, ec2_id_key = EC2_RES[key]
        for item in getattr(c, op)().get(key, []):
            tags = {x["Key"]: x["Value"] for x in item.get("Tags", [])}
            arn  = (f"arn:aws:ec2:{ctx.region}:{ctx.account}"
                    f":{ec2_res}/{item[id_key]}")
            # EC2 tags are always in the response; also supply ARN for Tagging API
            if not ctx.ok(arn=arn, raw_tags=tags):
                continue
            detail = "; ".join(
                f"{k}={value(item[k])}" for k in
                ("VpcId", "State", "CidrBlock", "AvailabilityZone", "ServiceName")
                if item.get(k)
            )
            add(rows, "Amazon VPC", kind,
                tags.get("Name", item.get(id_key)), item.get(id_key), detail, tag_text(tags))


def s3(session, rows, ctx):
    c = session.client("s3")
    for bucket in c.list_buckets().get("Buckets", []):
        name   = bucket["Name"]
        detail = []
        s3_arn = f"arn:aws:s3:::{name}"
        # list_buckets has no tags.  When Tagging API is available use ARN;
        # when it is not, use the cheap name pre-filter to avoid fetching
        # tags for obviously wrong buckets.
        if ctx.tagged_arns is not None:
            if not ctx.ok(arn=s3_arn):
                continue
        elif not ctx.name_ok(name):
            continue
        for label, fn, key in [
            ("Versioning",   c.get_bucket_versioning,   "Status"),
            ("Encryption",   c.get_bucket_encryption,   "ServerSideEncryptionConfiguration"),
            ("PublicAccess", c.get_public_access_block, "PublicAccessBlockConfiguration"),
        ]:
            try:
                detail.append(f"{label}={value(fn(Bucket=name).get(key, 'Not configured'))}")
            except ClientError as e:
                detail.append(f"{label}={e.response.get('Error', {}).get('Code', 'Error')}")
        try:
            tags = c.get_bucket_tagging(Bucket=name).get("TagSet", [])
        except ClientError:
            tags = []
        # Secondary confirm via own tags (catches buckets not yet indexed
        # by Tagging API or when Tagging API was unavailable)
        if ctx.tagged_arns is None and not ctx.ok(arn=s3_arn, raw_tags=tags):
            continue
        try:
            detail.append(
                f"Lifecycle={value(c.get_bucket_lifecycle_configuration(Bucket=name).get('Rules'))}")
        except ClientError as e:
            detail.append(f"Lifecycle={e.response.get('Error', {}).get('Code', 'Not configured')}")
        try:
            detail.append(f"Logging={value(c.get_bucket_logging(Bucket=name).get('LoggingEnabled'))}")
        except ClientError:
            detail.append("Logging=Not configured")
        add(rows, "Amazon S3", "Bucket", name, name, "; ".join(detail), tag_text(tags))


def monitoring(session, rows, ctx):
    logs = session.client("logs")
    for x in pages(logs, "describe_log_groups", "logGroups"):
        name = x.get("logGroupName")
        # describe_log_groups returns the ARN — use it for Tagging API lookup
        if not ctx.ok(arn=x.get("arn")):
            continue
        filters = len(list(pages(logs, "describe_metric_filters",
                                  "metricFilters", logGroupName=name)))
        subs    = len(list(pages(logs, "describe_subscription_filters",
                                  "subscriptionFilters", logGroupName=name)))
        stored  = round(x.get("storedBytes", 0) / 1_048_576, 1)
        add(rows, "Amazon CloudWatch", "Log group", name, x.get("arn"),
            f"Retention={x.get('retentionInDays', 'Never expire')} days; "
            f"StoredMB={stored}; MetricFilters={filters}; Subscriptions={subs}; "
            f"KmsKey={x.get('kmsKeyId', '-')}")
    cw = session.client("cloudwatch")
    for x in pages(cw, "describe_alarms", "MetricAlarms"):
        # describe_alarms returns AlarmArn — use it to scope alarms to
        # the selected environment via the Tagging API ARN set.
        if not ctx.ok(arn=x.get("AlarmArn")):
            continue
        add(rows, "Amazon CloudWatch", "Metric alarm",
            x.get("AlarmName"), x.get("AlarmArn"),
            f"State={x.get('StateValue')}; "
            f"Metric={x.get('Namespace')}/{x.get('MetricName')}; "
            f"Comparison={x.get('ComparisonOperator')} {x.get('Threshold')}")


def api_gateway(session, rows, ctx):
    c = session.client("apigateway")
    for api in pages(c, "get_rest_apis", "items"):
        aid = api["id"]
        arn = f"arn:aws:apigateway:{ctx.region}::/restapis/{aid}"
        if not ctx.ok(arn=arn, raw_tags=api.get("tags", {})):
            continue
        add(rows, "Amazon API Gateway", "REST API", api.get("name"), aid,
            f"EndpointTypes={value((api.get('endpointConfiguration') or {}).get('types'))}",
            tag_text(api.get("tags")))
        for stage in c.get_stages(restApiId=aid).get("item", []):
            add(rows, "Amazon API Gateway", "REST stage",
                f"{api.get('name')}/{stage.get('stageName')}", stage.get("deploymentId"),
                f"Tracing={stage.get('tracingEnabled', False)}")
        for resource in c.get_resources(restApiId=aid, embed=["methods"]).get("items", []):
            methods = list((resource.get("resourceMethods") or {}).keys())
            add(rows, "Amazon API Gateway", "REST resource",
                f"{api.get('name')} {resource.get('path')}", resource.get("id"),
                f"Methods={value(methods)}")
    c2 = session.client("apigatewayv2")
    for api in pages(c2, "get_apis", "Items"):
        aid = api["ApiId"]
        arn = f"arn:aws:apigateway:{ctx.region}::/apis/{aid}"
        if not ctx.ok(arn=arn, raw_tags=api.get("Tags", {})):
            continue
        add(rows, "Amazon API Gateway", "V2 API", api.get("Name"), aid,
            f"Protocol={api.get('ProtocolType')}; "
            f"Endpoint={truncate(api.get('ApiEndpoint', ''), 70)}",
            tag_text(api.get("Tags")))
        for stage in pages(c2, "get_stages", "Items", ApiId=aid):
            add(rows, "Amazon API Gateway", "V2 stage",
                f"{api.get('Name')}/{stage.get('StageName')}", stage.get("DeploymentId"),
                f"AutoDeploy={stage.get('AutoDeploy', False)}")
        for route in pages(c2, "get_routes", "Items", ApiId=aid):
            add(rows, "Amazon API Gateway", "V2 route",
                f"{api.get('Name')}/{route.get('RouteKey')}", route.get("RouteId"),
                f"Target={route.get('Target')}; AuthType={route.get('AuthorizationType')}")
        for integ in pages(c2, "get_integrations", "Items", ApiId=aid):
            add(rows, "Amazon API Gateway", "V2 integration",
                f"{api.get('Name')}/{integ.get('IntegrationType')}", integ.get("IntegrationId"),
                f"URI={truncate(integ.get('IntegrationUri', ''), 70)}; "
                f"Method={integ.get('IntegrationMethod')}; "
                f"Timeout={integ.get('TimeoutInMillis')}ms")


def security(session, rows, ctx):
    sm = session.client("secretsmanager")
    for x in pages(sm, "list_secrets", "SecretList"):
        # list_secrets returns both ARN and Tags in each item
        if not ctx.ok(arn=x.get("ARN"), raw_tags=x.get("Tags", [])):
            continue
        d = sm.describe_secret(SecretId=x.get("ARN"))
        add(rows, "AWS Secrets Manager", "Secret metadata", x.get("Name"), x.get("ARN"),
            f"Rotation={d.get('RotationEnabled', False)}; "
            f"RotationLambda={d.get('RotationLambdaARN', '-')}; "
            f"KmsKey={d.get('KmsKeyId', 'aws/secretsmanager')}; "
            f"Description={truncate(d.get('Description', '-'), 80)}; "
            f"SecretValue=NOT COLLECTED",
            tag_text(d.get("Tags")))
    kms     = session.client("kms")
    aliases = defaultdict(list)
    for x in pages(kms, "list_aliases", "Aliases"):
        if x.get("TargetKeyId"):
            aliases[x["TargetKeyId"]].append(x.get("AliasName"))
    for x in pages(kms, "list_keys", "Keys"):
        # Construct the KMS key ARN to avoid expensive describe_key for excluded keys
        key_arn = f"arn:aws:kms:{ctx.region}:{ctx.account}:key/{x['KeyId']}"
        if not ctx.ok(arn=key_arn):
            continue
        meta = kms.describe_key(KeyId=x["KeyId"])["KeyMetadata"]
        try:
            rotation = kms.get_key_rotation_status(KeyId=x["KeyId"]).get("KeyRotationEnabled")
        except ClientError:
            rotation = "Not available"
        add(rows, "AWS KMS", "Key",
            value(aliases.get(x["KeyId"]), x["KeyId"]), meta.get("Arn"),
            f"State={meta.get('KeyState')}; Manager={meta.get('KeyManager')}; "
            f"Usage={meta.get('KeyUsage')}; MultiRegion={meta.get('MultiRegion')}; "
            f"Rotation={rotation}; "
            f"Description={truncate(meta.get('Description', '-'), 80)}")


def messaging(session, rows, ctx):
    sns = session.client("sns")
    for x in pages(sns, "list_topics", "Topics"):
        arn        = x["TopicArn"]
        topic_name = arn.rsplit(":", 1)[-1]
        # Fetch SNS tags (list_topics does not include them)
        try:
            sns_tags = sns.list_tags_for_resource(ResourceArn=arn).get("Tags", [])
        except ClientError:
            sns_tags = None
        if not ctx.ok(arn=arn, raw_tags=sns_tags):
            continue
        attrs = sns.get_topic_attributes(TopicArn=arn).get("Attributes", {})
        add(rows, "Amazon SNS", "Topic", topic_name, arn,
            f"SubscriptionsConfirmed={attrs.get('SubscriptionsConfirmed')}; "
            f"Fifo={attrs.get('FifoTopic', 'false')}; "
            f"KmsKey={attrs.get('KmsMasterKeyId', '-')}")
    sqs = session.client("sqs")
    for url in sqs.list_queues().get("QueueUrls", []):
        qname = url.rstrip("/").rsplit("/", 1)[-1]
        # Filter SQS queues by tags, fall back to name
        try:
            sqs_tags = sqs.list_queue_tags(QueueUrl=url).get("Tags", {})
        except ClientError:
            sqs_tags = {}
        attrs = sqs.get_queue_attributes(
            QueueUrl=url, AttributeNames=["All"]).get("Attributes", {})
        if not ctx.ok(arn=attrs.get("QueueArn"), raw_tags=sqs_tags):
            continue
        add(rows, "Amazon SQS", "Queue",
            qname, attrs.get("QueueArn", url),
            f"Fifo={attrs.get('FifoQueue', 'false')}; "
            f"KmsKey={attrs.get('KmsMasterKeyId', '-')}; "
            f"SSE={attrs.get('SqsManagedSseEnabled', '-')}")


def compute(session, rows, ctx):
    lmb = session.client("lambda")
    for x in pages(lmb, "list_functions", "Functions"):
        # list_functions returns both FunctionArn and Tags in each object
        if not ctx.ok(arn=x.get("FunctionArn"), raw_tags=x.get("Tags", {})):
            continue
        name = x.get("FunctionName")
        cfg  = lmb.get_function_configuration(FunctionName=name)
        env_names = sorted((cfg.get("Environment") or {}).get("Variables", {}).keys())
        try:
            concurrency = lmb.get_function_concurrency(FunctionName=name).get(
                "ReservedConcurrentExecutions", "Unreserved")
        except ClientError:
            concurrency = "Not available"
        aliases  = [a.get("Name") for a in pages(lmb, "list_aliases", "Aliases", FunctionName=name)]
        versions = list(pages(lmb, "list_versions_by_function", "Versions", FunctionName=name))
        add(rows, "AWS Lambda", "Function", name, cfg.get("FunctionArn"),
            f"Runtime={cfg.get('Runtime')}; Arch={value(cfg.get('Architectures'))}; "
            f"Handler={cfg.get('Handler')}; Memory={cfg.get('MemorySize')}MB; "
            f"Timeout={cfg.get('Timeout')}s; ReservedConcurrency={concurrency}; "
            f"Tracing={value(cfg.get('TracingConfig'))}; "
            f"EnvVars={value(env_names)} (values REDACTED); "
            f"Aliases={value(aliases)}; Versions={len(versions)}",
            tag_text(x.get("Tags", {})))
    ddb = session.client("dynamodb")
    for name in pages(ddb, "list_tables", "TableNames"):
        # Construct the DynamoDB ARN to check before the expensive describe call
        table_arn = f"arn:aws:dynamodb:{ctx.region}:{ctx.account}:table/{name}"
        if not ctx.ok(arn=table_arn):
            continue
        x         = ddb.describe_table(TableName=name)["Table"]
        ttl     = ddb.describe_time_to_live(TableName=name).get("TimeToLiveDescription", {})
        backups = ddb.describe_continuous_backups(TableName=name).get(
            "ContinuousBackupsDescription", {})
        billing = (x.get("BillingModeSummary") or {}).get("BillingMode", "PROVISIONED")
        keys    = " | ".join(
            f"{k.get('AttributeName')} ({k.get('KeyType')})" for k in x.get("KeySchema", []))
        pitr = (backups.get("PointInTimeRecoveryDescription") or {}).get(
            "PointInTimeRecoveryStatus", "-")
        add(rows, "Amazon DynamoDB", "Table", name, x.get("TableArn"),
            f"Status={x.get('TableStatus')}; Billing={billing}; Keys={keys}; "
            f"GSI={len(x.get('GlobalSecondaryIndexes', []))}; "
            f"LSI={len(x.get('LocalSecondaryIndexes', []))}; "
            f"Encryption={value(x.get('SSEDescription'))}; "
            f"TTL={value(ttl)}; PITR={pitr}; "
            f"DeletionProtection={x.get('DeletionProtectionEnabled', False)}",
            tag_text(x.get("Tags", [])))


COLLECTORS = [
    ("Amazon Connect",        connect),
    ("Amazon Connect AI",     qconnect),
    ("Amazon Lex",            lex),
    ("IAM",                   iam),
    ("VPC and networking",    networking),
    ("S3",                    s3),
    ("CloudWatch",            monitoring),
    ("API Gateway",           api_gateway),
    ("Secrets Manager / KMS", security),
    ("SNS / SQS",             messaging),
    ("Lambda / DynamoDB",     compute),
]


def collect_aws(region, environment, filter_tag_key, filter_tag_value):
    session = boto3.Session(region_name=region)
    account = session.client("sts").get_caller_identity()["Account"]

    # Pre-load every resource ARN that carries the Application tag.
    tagged_arns = _load_tagged_arns(session, filter_tag_key, filter_tag_value)

    ctx = FilterCtx(
        env=environment,
        region=region,
        account=account,
        tagged_arns=tagged_arns,
        tag_key=filter_tag_key,
        tag_value=filter_tag_value,
    )

    rows, status = [], []
    for name, fn in COLLECTORS:
        before = len(rows)
        try:
            fn(session, rows, ctx)
            status.append({"scope": name, "status": "Collected",
                            "details": f"{len(rows)-before} records"})
        except (ClientError, BotoCoreError, KeyError, ValueError) as e:
            detail = (
                f"{e.response.get('Error',{}).get('Code')}: "
                f"{e.response.get('Error',{}).get('Message')}"
                if isinstance(e, ClientError) else str(e)
            )
            status.append({"scope": name, "status": "Not collected", "details": detail})
    return account, rows, status


# ── Terraform Collectors ───────────────────────────────────────────────────────

SENSITIVE_NAMES = re.compile(
    r"(password|secret|token|private.?key|access.?key|credential|authorization|environment)", re.I)


def flatten_configuration(item, prefix=""):
    flat = []
    if isinstance(item, dict):
        for k, v in sorted(item.items()):
            path = f"{prefix}.{k}" if prefix else k
            if SENSITIVE_NAMES.search(str(k)):
                flat.append((path, "REDACTED"))
            else:
                flat.extend(flatten_configuration(v, path))
    elif isinstance(item, list):
        for i, v in enumerate(item):
            flat.extend(flatten_configuration(v, f"{prefix}[{i}]"))
    else:
        flat.append((prefix or "value", value(item)))
    return flat


def redact_sensitive(item, mask):
    if mask is True:
        return "REDACTED"
    if isinstance(item, dict):
        mask = mask if isinstance(mask, dict) else {}
        return {k: redact_sensitive(v, mask.get(k)) for k, v in item.items()}
    if isinstance(item, list):
        mask = mask if isinstance(mask, list) else []
        return [redact_sensitive(v, mask[i] if i < len(mask) else None)
                for i, v in enumerate(item)]
    return item


def state_resources(module):
    yield from module.get("resources", [])
    for child in module.get("child_modules", []):
        yield from state_resources(child)


def collect_terraform(directory):
    rows = []
    files = sorted(Path(directory).rglob("*.tf")) if Path(directory).is_dir() else []
    patterns = [
        ("Resource", re.compile(r'^\s*resource\s+"([^"]+)"\s+"([^"]+)"', re.M)),
        ("Module",   re.compile(r'^\s*module\s+"([^"]+)"', re.M)),
        ("Output",   re.compile(r'^\s*output\s+"([^"]+)"', re.M)),
        ("Variable", re.compile(r'^\s*variable\s+"([^"]+)"', re.M)),
    ]
    for path in files:
        source = path.read_text(encoding="utf-8")
        for kind, pattern in patterns:
            for match in pattern.findall(source):
                name = ".".join(match) if isinstance(match, tuple) else match
                add(rows, "Terraform", f"{kind} declaration", name, path.as_posix(),
                    "Sensitive values not collected"
                    if kind in {"Output", "Variable"} else "Declared in IaC configuration")
    state  = "Collected" if files else "Not collected"
    detail = (f"{len(files)} .tf files; {len(rows)} declarations" if files
              else f"Directory not found or empty: {directory}")
    return rows, [{"scope": "Terraform configuration", "status": state, "details": detail}]


def collect_terraform_json(plan_path=None, state_path=None):
    rows, status = [], []
    if plan_path and Path(plan_path).is_file():
        plan = json.loads(Path(plan_path).read_text(encoding="utf-8"))
        for change in plan.get("resource_changes", []):
            address = change.get("address", "unknown")
            actions = change.get("change", {}).get("actions", [])
            after   = redact_sensitive(
                change.get("change", {}).get("after") or {},
                change.get("change", {}).get("after_sensitive"))
            for param, val in flatten_configuration(after):
                add(rows, "Terraform Evaluated Plan",
                    change.get("type", "Resource"), address, param, str(val),
                    f"Actions={value(actions)}")
        status.append({"scope": "Terraform evaluated plan", "status": "Collected",
                        "details": f"{len(plan.get('resource_changes',[]))} resource changes"})
    else:
        status.append({"scope": "Terraform evaluated plan", "status": "Not collected",
                        "details": "No terraform-plan.json supplied"})
    if state_path and Path(state_path).is_file():
        state_doc   = json.loads(Path(state_path).read_text(encoding="utf-8"))
        root        = state_doc.get("values", {}).get("root_module", {})
        state_items = list(state_resources(root))
        for resource in state_items:
            address    = resource.get("address", "unknown")
            configured = redact_sensitive(
                resource.get("values", {}), resource.get("sensitive_values"))
            for param, val in flatten_configuration(configured):
                add(rows, "Terraform State", resource.get("type", "Resource"), address, param,
                    str(val),
                    f"Mode={resource.get('mode','-')}; Provider={resource.get('provider_name','-')}")
        status.append({"scope": "Terraform state", "status": "Collected",
                        "details": f"{len(state_items)} state resources"})
    else:
        status.append({"scope": "Terraform state", "status": "Not collected",
                        "details": "No terraform-state.json supplied"})
    return rows, status


# ── Data Organisation ──────────────────────────────────────────────────────────

def grouped(rows):
    data = defaultdict(list)
    for row in sorted(rows, key=lambda x: (x["service"], x["type"], x["name"])):
        data[row["service"]].append(row)
    return data


def build_summary(rows, status):
    counts = defaultdict(int)
    for row in rows:
        counts[row["service"]] += 1
    collected     = sum(1 for s in status if s["status"] == "Collected")
    not_collected = sum(1 for s in status if s["status"] == "Not collected")
    return counts, collected, not_collected


# ── Word Generator ─────────────────────────────────────────────────────────────

def _w_bg(cell, hex_color):
    """Set a Word table cell background colour."""
    tc   = cell._tc
    tcPr = tc.get_or_add_tcPr()
    shd  = OxmlElement("w:shd")
    shd.set(qn("w:val"),   "clear")
    shd.set(qn("w:color"), "auto")
    shd.set(qn("w:fill"),  hex_color.lstrip("#"))
    tcPr.append(shd)


def _w_text(cell, text, bold=False, pt=9, color=None, align=WD_ALIGN_PARAGRAPH.LEFT):
    """Set a Word table cell text with font styling."""
    cell.text = ""
    para = cell.paragraphs[0]
    para.alignment = align
    run = para.add_run(str(text))
    run.bold       = bold
    run.font.size  = Pt(pt)
    if color:
        run.font.color.rgb = color
    return run


def _w_field(para, field_name):
    """Append a PAGE or NUMPAGES field to a paragraph."""
    run  = para.add_run()
    fc1  = OxmlElement("w:fldChar"); fc1.set(qn("w:fldCharType"), "begin")
    ins  = OxmlElement("w:instrText"); ins.set(qn("xml:space"), "preserve"); ins.text = field_name
    fc2  = OxmlElement("w:fldChar"); fc2.set(qn("w:fldCharType"), "end")
    run._r.append(fc1); run._r.append(ins); run._r.append(fc2)


def _w_toc(doc):
    """Insert a Word TOC field that updates when opened in Word."""
    doc.add_heading("Table of Contents", level=1)
    para = doc.add_paragraph()
    run  = para.add_run()
    fc_b = OxmlElement("w:fldChar"); fc_b.set(qn("w:fldCharType"), "begin")
    ins  = OxmlElement("w:instrText"); ins.set(qn("xml:space"), "preserve")
    ins.text = 'TOC \\o "1-2" \\h \\z \\u'
    fc_s = OxmlElement("w:fldChar"); fc_s.set(qn("w:fldCharType"), "separate")
    ph   = OxmlElement("w:r"); pt_elem = OxmlElement("w:t")
    pt_elem.text = ("Right-click this area in Word and choose "
                    "'Update Field' to build the table of contents.")
    ph.append(pt_elem)
    fc_e = OxmlElement("w:fldChar"); fc_e.set(qn("w:fldCharType"), "end")
    run._r.append(fc_b); run._r.append(ins); run._r.append(fc_s)
    run._r.append(ph);   run._r.append(fc_e)


def _w_cover(doc, title, metadata, environment):
    """Add a branded cover page."""
    env_label = ENVIRONMENT_DISPLAY.get(environment, environment)

    # Dark-blue title banner (2-row table)
    banner = doc.add_table(rows=2, cols=1)
    banner.style = "Table Grid"

    top = banner.cell(0, 0)
    _w_bg(top, BRAND_DARK)
    p1 = top.paragraphs[0]; p1.alignment = WD_ALIGN_PARAGRAPH.CENTER
    r1 = p1.add_run(title)
    r1.font.size = Pt(26); r1.font.bold = True
    r1.font.color.rgb = RGBColor(0xFF, 0xFF, 0xFF)

    sub = banner.cell(1, 0)
    _w_bg(sub, BRAND_MID)
    p2 = sub.paragraphs[0]; p2.alignment = WD_ALIGN_PARAGRAPH.CENTER
    r2 = p2.add_run(env_label)
    r2.font.size = Pt(15); r2.font.color.rgb = RGBColor(0xE9, 0xF3, 0xFF)

    for _ in range(2):
        doc.add_paragraph()

    # Metadata table
    meta_tbl = doc.add_table(rows=0, cols=2)
    meta_tbl.style = "Table Grid"
    for k, v in metadata.items():
        row = meta_tbl.add_row()
        kc, vc = row.cells[0], row.cells[1]
        kc.width = Inches(2.8); vc.width = Inches(5.5)
        _w_bg(kc, BRAND_LIGHT.lstrip("#"))
        _w_text(kc, k, bold=True, pt=10)
        _w_text(vc, str(v), pt=10)

    for _ in range(2):
        doc.add_paragraph()

    notice = doc.add_paragraph("CONFIDENTIAL – INTERNAL USE ONLY")
    notice.alignment = WD_ALIGN_PARAGRAPH.CENTER
    for run in notice.runs:
        run.bold = True; run.font.size = Pt(10)
        run.font.color.rgb = RGBColor(0xC0, 0x00, 0x00)
    desc = doc.add_paragraph(
        "This document contains sensitive infrastructure configuration details. "
        "Do not share outside the authorised team.")
    desc.alignment = WD_ALIGN_PARAGRAPH.CENTER
    for run in desc.runs:
        run.font.size = Pt(9)
        run.font.color.rgb = RGBColor(0x7F, 0x7F, 0x7F)
    doc.add_page_break()


def _w_exec_summary(doc, metadata, rows, status):
    """Render the executive summary section."""
    doc.add_heading("Executive Summary", level=1)
    counts, collected, not_collected = build_summary(rows, status)
    env     = metadata.get("Environment", "Unknown")
    account = metadata.get("AWS Account", "Unknown")
    region  = metadata.get("AWS Region",  "Unknown")
    total   = metadata.get("Total Inventory Records", len(rows))

    p = doc.add_paragraph(
        f"This As-Built document describes the AWS infrastructure deployed in the "
        f"{ENVIRONMENT_DISPLAY.get(env.split()[0], env)} environment. "
        f"Generated automatically on {metadata.get('Generated At','Unknown')} "
        f"from account {account} in region {region}. "
        f"{total} inventory records were collected across {len(counts)} service areas. "
        f"{collected} scope(s) succeeded and {not_collected} could not be collected."
    )
    for run in p.runs:
        run.font.size = Pt(10)
    doc.add_paragraph()

    # Collection status table
    doc.add_heading("Collection Status", level=2)
    tbl = doc.add_table(rows=1, cols=3)
    tbl.style = "Table Grid"
    for i, (hdr, w) in enumerate(
        zip(["Scope", "Status", "Details"],
            [Inches(2.3), Inches(1.2), Inches(7.0)])
    ):
        c = tbl.rows[0].cells[i]; c.width = w
        _w_bg(c, BRAND_DARK)
        _w_text(c, hdr, bold=True, pt=9, color=RGBColor(0xFF, 0xFF, 0xFF))
    for idx, s in enumerate(status):
        row = tbl.add_row()
        bg  = BRAND_ROW_ALT if idx % 2 else "FFFFFF"
        for i, key in enumerate(("scope", "status", "details")):
            c = row.cells[i]; _w_bg(c, bg)
            clr = None
            if key == "status":
                clr = (RGBColor(0x20, 0x80, 0x20) if s[key] == "Collected"
                       else RGBColor(0xC0, 0x00, 0x00))
            _w_text(c, s[key], pt=9, color=clr)
    doc.add_paragraph()

    # Records by service table
    doc.add_heading("Records by Service Area", level=2)
    tbl2 = doc.add_table(rows=1, cols=2)
    tbl2.style = "Table Grid"
    for i, (hdr, w) in enumerate(
        zip(["Service Area", "Records"], [Inches(5.5), Inches(2.0)])
    ):
        c = tbl2.rows[0].cells[i]; c.width = w
        _w_bg(c, BRAND_DARK)
        _w_text(c, hdr, bold=True, pt=9, color=RGBColor(0xFF, 0xFF, 0xFF))
    for idx, (svc, cnt) in enumerate(sorted(counts.items())):
        row = tbl2.add_row()
        bg  = BRAND_ROW_ALT if idx % 2 else "FFFFFF"
        _w_bg(row.cells[0], bg); _w_bg(row.cells[1], bg)
        _w_text(row.cells[0], svc, pt=9)
        _w_text(row.cells[1], str(cnt), pt=9)
    doc.add_page_break()


def _w_resource_table(doc, items):
    """Render a styled 5-column resource table with proper column widths."""
    headers = ["Type", "Name", "Identifier", "Details", "Tags"]
    widths  = [Inches(1.5), Inches(2.0), Inches(2.0), Inches(3.9), Inches(1.3)]
    keys    = ["type", "name", "identifier", "details", "tags"]
    tbl = doc.add_table(rows=1, cols=5)
    tbl.style = "Table Grid"
    for i, (hdr, w) in enumerate(zip(headers, widths)):
        c = tbl.rows[0].cells[i]; c.width = w
        _w_bg(c, BRAND_DARK)
        _w_text(c, hdr, bold=True, pt=9, color=RGBColor(0xFF, 0xFF, 0xFF))
    for idx, item in enumerate(items):
        row = tbl.add_row()
        bg  = BRAND_ROW_ALT if idx % 2 else "FFFFFF"
        for i, (key, w) in enumerate(zip(keys, widths)):
            c = row.cells[i]; c.width = w; _w_bg(c, bg)
            _w_text(c, item.get(key, "-"), pt=9)


def word(path, title, metadata, rows, status, environment):
    """Generate the Word (DOCX) as-built document."""
    doc = Document()

    # Landscape A4
    section = doc.sections[0]
    section.orientation  = WD_ORIENT.LANDSCAPE
    new_w = section.page_height; new_h = section.page_width
    section.page_width   = new_w;  section.page_height  = new_h
    section.left_margin  = section.right_margin  = Inches(0.5)
    section.top_margin   = section.bottom_margin = Inches(0.5)

    # Header
    hdr = section.header; hp = hdr.paragraphs[0]; hp.alignment = WD_ALIGN_PARAGRAPH.RIGHT
    r = hp.add_run(f"{title}  |  {ENVIRONMENT_DISPLAY.get(environment, environment)}")
    r.font.size = Pt(8); r.font.color.rgb = RGBColor(0x17, 0x36, 0x5D)

    # Footer with page numbers
    ftr = section.footer; fp = ftr.paragraphs[0]; fp.alignment = WD_ALIGN_PARAGRAPH.RIGHT
    fp.add_run("Page ").font.size = Pt(8)
    _w_field(fp, "PAGE")
    fp.add_run(" of ").font.size = Pt(8)
    _w_field(fp, "NUMPAGES")

    _w_cover(doc, title, metadata, environment)
    _w_toc(doc)
    doc.add_page_break()
    _w_exec_summary(doc, metadata, rows, status)

    for service, items in grouped(rows).items():
        doc.add_heading(service, level=1)
        desc = SERVICE_DESCRIPTIONS.get(service)
        if desc:
            p = doc.add_paragraph(desc)
            for run in p.runs:
                run.font.size = Pt(9)
                run.font.color.rgb = RGBColor(0x40, 0x40, 0x40)
        doc.add_paragraph()
        _w_resource_table(doc, items)
        doc.add_page_break()

    doc.save(path)
    print(f"  Word → {path}")


# ── PDF Generator ──────────────────────────────────────────────────────────────

PAGE_W, PAGE_H = landscape(A4)   # 841.89 x 595.27 pts
MARGIN_H  = 0.33 * inch
HEADER_H  = 0.33 * inch
FOOTER_H  = 0.27 * inch
MARGIN_TOP = HEADER_H + 0.18 * inch
MARGIN_BOT = FOOTER_H + 0.18 * inch
USABLE_W  = PAGE_W - 2 * MARGIN_H
USABLE_H  = PAGE_H - MARGIN_TOP - MARGIN_BOT


def _pdf_styles():
    base = getSampleStyleSheet()

    def ps(name, **kw):
        return ParagraphStyle(name, parent=base["Normal"], **kw)

    return {
        "cover_title": ps("CoverTitle", fontSize=26, textColor=colors.white,
                           alignment=1, fontName="Helvetica-Bold", spaceAfter=8),
        "cover_sub":   ps("CoverSub",   fontSize=14,
                           textColor=colors.HexColor("#BDD5EE"),
                           alignment=1, fontName="Helvetica", spaceAfter=6),
        "cover_key":   ps("CoverKey",   fontSize=10,
                           textColor=colors.HexColor(BRAND_DARK),
                           fontName="Helvetica-Bold"),
        "cover_val":   ps("CoverVal",   fontSize=10, fontName="Helvetica"),
        "notice":      ps("Notice",     fontSize=9,
                           textColor=colors.HexColor("#C00000"),
                           alignment=1, fontName="Helvetica-Bold"),
        "h1":          ps("H1",         fontSize=12,
                           textColor=colors.HexColor(BRAND_DARK),
                           fontName="Helvetica-Bold", spaceBefore=10, spaceAfter=4),
        "h2":          ps("H2",         fontSize=10,
                           textColor=colors.HexColor(BRAND_MID),
                           fontName="Helvetica-Bold", spaceBefore=6,  spaceAfter=3),
        "body":        ps("Body",       fontSize=9, leading=12, spaceAfter=4,
                           fontName="Helvetica"),
        "desc":        ps("Desc",       fontSize=9, leading=12, spaceAfter=6,
                           textColor=colors.HexColor("#404040"),
                           fontName="Helvetica-Oblique"),
        "cell":        ps("Cell",       fontSize=9, leading=11, fontName="Helvetica"),
        "cell_hdr":    ps("CellHdr",    fontSize=9, leading=11,
                           fontName="Helvetica-Bold", textColor=colors.white),
    }


def _pdf_tbl_style():
    return TableStyle([
        ("BACKGROUND",     (0, 0), (-1,  0), colors.HexColor(BRAND_DARK)),
        ("TEXTCOLOR",      (0, 0), (-1,  0), colors.white),
        ("FONTNAME",       (0, 0), (-1,  0), "Helvetica-Bold"),
        ("FONTSIZE",       (0, 0), (-1, -1), 9),
        ("LEADING",        (0, 0), (-1, -1), 11),
        ("GRID",           (0, 0), (-1, -1), 0.3, colors.HexColor("#D9D9D9")),
        ("VALIGN",         (0, 0), (-1, -1), "TOP"),
        ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, colors.HexColor(BRAND_ROW_ALT)]),
        ("LEFTPADDING",    (0, 0), (-1, -1), 4),
        ("RIGHTPADDING",   (0, 0), (-1, -1), 4),
        ("TOPPADDING",     (0, 0), (-1, -1), 3),
        ("BOTTOMPADDING",  (0, 0), (-1, -1), 3),
    ])


def _para(text, style):
    return Paragraph(escape(str(text)), style)


def pdf(path, title, metadata, rows, status, environment):
    """Generate the PDF as-built document with cover page, branding, and page numbers."""
    env_label = ENVIRONMENT_DISPLAY.get(environment, environment)
    stl       = _pdf_styles()

    # Page template callbacks (closures capture title / env_label)
    def on_cover(canvas, doc):
        canvas.saveState()
        canvas.setFillColor(colors.HexColor(BRAND_DARK))
        canvas.rect(0, PAGE_H * 0.42, PAGE_W, PAGE_H * 0.58, fill=1, stroke=0)
        canvas.setFillColor(colors.HexColor(BRAND_ACCENT))
        canvas.rect(0, PAGE_H * 0.40, PAGE_W, PAGE_H * 0.025, fill=1, stroke=0)
        canvas.setFillColor(colors.HexColor(BRAND_MID))
        canvas.rect(0, 0, PAGE_W, FOOTER_H, fill=1, stroke=0)
        canvas.setFillColor(colors.white); canvas.setFont("Helvetica", 7)
        canvas.drawString(MARGIN_H, 7, "BTSGSD AWS Infrastructure As-Built  |  CONFIDENTIAL")
        canvas.restoreState()

    def on_content(canvas, doc):
        canvas.saveState()
        # Header bar
        canvas.setFillColor(colors.HexColor(BRAND_DARK))
        canvas.rect(0, PAGE_H - HEADER_H, PAGE_W, HEADER_H, fill=1, stroke=0)
        canvas.setFillColor(colors.white)
        canvas.setFont("Helvetica-Bold", 9)
        canvas.drawString(MARGIN_H, PAGE_H - HEADER_H + 8, title[:80])
        canvas.setFont("Helvetica", 8)
        canvas.drawRightString(PAGE_W - MARGIN_H, PAGE_H - HEADER_H + 8, env_label)
        # Footer bar
        canvas.setFillColor(colors.HexColor(BRAND_MID))
        canvas.rect(0, 0, PAGE_W, FOOTER_H, fill=1, stroke=0)
        canvas.setFillColor(colors.white); canvas.setFont("Helvetica", 7)
        canvas.drawString(MARGIN_H, 7,
                          "BTSGSD AWS Infrastructure As-Built  |  CONFIDENTIAL – INTERNAL USE ONLY")
        canvas.drawRightString(PAGE_W - MARGIN_H, 7, f"Page {doc.page}")
        canvas.restoreState()

    cover_frame   = Frame(MARGIN_H, MARGIN_BOT, USABLE_W, PAGE_H * 0.38,
                          leftPadding=4, rightPadding=4, topPadding=4, bottomPadding=4)
    content_frame = Frame(MARGIN_H, MARGIN_BOT, USABLE_W, USABLE_H,
                          leftPadding=0, rightPadding=0, topPadding=0, bottomPadding=0)
    cover_tpl   = PageTemplate("cover",   frames=[cover_frame],   onPage=on_cover)
    content_tpl = PageTemplate("content", frames=[content_frame], onPage=on_content)
    doc = BaseDocTemplate(path, pagesize=landscape(A4),
                          leftMargin=MARGIN_H, rightMargin=MARGIN_H,
                          topMargin=MARGIN_TOP, bottomMargin=MARGIN_BOT)
    doc.addPageTemplates([cover_tpl, content_tpl])

    story = []

    # ── Cover page ──
    story.append(Spacer(1, PAGE_H * 0.10))
    story.append(_para(title,     stl["cover_title"]))
    story.append(Spacer(1, 6))
    story.append(_para(env_label, stl["cover_sub"]))
    story.append(Spacer(1, 18))
    cover_meta = [[_para(k, stl["cover_key"]), _para(str(v), stl["cover_val"])]
                  for k, v in metadata.items()]
    if cover_meta:
        ct = Table(cover_meta, colWidths=[2.2 * inch, USABLE_W - 2.4 * inch])
        ct.setStyle(TableStyle([
            ("BACKGROUND",   (0, 0), (0, -1), colors.HexColor(BRAND_LIGHT)),
            ("GRID",         (0, 0), (-1,-1), 0.3, colors.HexColor("#D9D9D9")),
            ("LEFTPADDING",  (0, 0), (-1,-1), 6),
            ("TOPPADDING",   (0, 0), (-1,-1), 4),
            ("BOTTOMPADDING",(0, 0), (-1,-1), 4),
        ]))
        story.append(ct)
    story.append(Spacer(1, 10))
    story.append(_para("CONFIDENTIAL – INTERNAL USE ONLY", stl["notice"]))
    story.append(NextPageTemplate("content"))
    story.append(PageBreak())

    # ── Executive Summary ──
    counts, collected, not_collected = build_summary(rows, status)
    env     = metadata.get("Environment", "Unknown")
    account = metadata.get("AWS Account", "Unknown")
    region  = metadata.get("AWS Region",  "Unknown")
    total   = metadata.get("Total Inventory Records", len(rows))

    story.append(_para("Executive Summary", stl["h1"]))
    story.append(HRFlowable(width=USABLE_W, thickness=1, color=colors.HexColor(BRAND_DARK)))
    story.append(Spacer(1, 6))
    story.append(_para(
        f"This As-Built document describes the AWS infrastructure in the "
        f"<b>{env_label}</b> environment. Generated on "
        f"{metadata.get('Generated At','Unknown')} from account <b>{account}</b> in "
        f"region <b>{region}</b>. <b>{total}</b> inventory records collected across "
        f"<b>{len(counts)}</b> service areas. <b>{collected}</b> scope(s) succeeded, "
        f"<b>{not_collected}</b> could not be collected.",
        stl["body"],
    ))
    story.append(Spacer(1, 8))

    # Collection status table
    story.append(_para("Collection Status", stl["h2"]))
    cw_s = [2.3 * inch, 1.2 * inch, USABLE_W - 3.5 * inch]
    tbl_s = Table(
        [[_para(h, stl["cell_hdr"]) for h in ["Scope", "Status", "Details"]]]
        + [[_para(s["scope"],   stl["cell"]),
            _para(s["status"],  stl["cell"]),
            _para(s["details"], stl["cell"])] for s in status],
        colWidths=cw_s, repeatRows=1, splitInRow=1,
    )
    tbl_s.setStyle(_pdf_tbl_style())
    story.append(tbl_s); story.append(Spacer(1, 10))

    # Records by service
    story.append(_para("Records by Service Area", stl["h2"]))
    cw_v = [USABLE_W * 0.76, USABLE_W * 0.24]
    tbl_v = Table(
        [[_para(h, stl["cell_hdr"]) for h in ["Service Area", "Records"]]]
        + [[_para(svc, stl["cell"]), _para(str(cnt), stl["cell"])]
           for svc, cnt in sorted(counts.items())],
        colWidths=cw_v, repeatRows=1,
    )
    tbl_v.setStyle(_pdf_tbl_style())
    story.append(tbl_v); story.append(PageBreak())

    # ── Per-service sections (9pt, properly truncated) ──
    col_w = [1.3 * inch, 1.8 * inch, 2.1 * inch, USABLE_W - 7.0 * inch, 1.8 * inch]
    for service, items in grouped(rows).items():
        story.append(_para(service, stl["h1"]))
        story.append(HRFlowable(width=USABLE_W, thickness=0.5,
                                color=colors.HexColor(BRAND_DARK)))
        desc = SERVICE_DESCRIPTIONS.get(service)
        if desc:
            story.append(_para(desc, stl["desc"]))
        story.append(Spacer(1, 4))
        hdr_row = [_para(h, stl["cell_hdr"])
                   for h in ["Type", "Name", "Identifier", "Details", "Tags"]]
        data = [hdr_row] + [
            [_para(item.get(k, "-"), stl["cell"])
             for k in ("type", "name", "identifier", "details", "tags")]
            for item in items
        ]
        tbl = Table(data, colWidths=col_w, repeatRows=1, splitInRow=1)
        tbl.setStyle(_pdf_tbl_style())
        story.append(tbl); story.append(PageBreak())

    doc.build(story)
    print(f"  PDF  → {path}")


# ── Markdown Generator ─────────────────────────────────────────────────────────

def markdown(path, title, metadata, rows, status):
    clean = lambda x: str(x).replace("|", "\\|").replace("\n", " ")
    env   = metadata.get("Environment", "")
    lines = [f"# {title}", "",
             f"> **Environment:** {ENVIRONMENT_DISPLAY.get(env.split()[0], env)}  "]
    lines += [f"> **{k}:** {v}  " for k, v in metadata.items()]
    lines += ["", "---", "", "## Collection Status", "",
              "| Scope | Status | Details |", "|---|---|---|"]
    for x in status:
        lines.append(
            "| " + " | ".join(clean(x[k]) for k in ("scope", "status", "details")) + " |")
    lines += ["", "---"]
    for service, items in grouped(rows).items():
        desc = SERVICE_DESCRIPTIONS.get(service, "")
        lines += ["", f"## {service}", ""]
        if desc:
            lines += [f"_{desc}_", ""]
        lines += ["| Type | Name | Identifier | Details | Tags |", "|---|---|---|---|---|"]
        for x in items:
            lines.append(
                "| " + " | ".join(
                    clean(x[k]) for k in ("type", "name", "identifier", "details", "tags")
                ) + " |")
    Path(path).write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"  MD   → {path}")


# ── Main ───────────────────────────────────────────────────────────────────────

def main():
    p = argparse.ArgumentParser(
        description="Generate BTSGSD AWS As-Built documentation.")
    p.add_argument("--environment",          required=True,
                   help="Environment name: dev, v2v-dev, or prod")
    p.add_argument("--region",               default="us-east-1")
    p.add_argument("--output",               default="documentation/generated")
    p.add_argument("--terraform-directory",  default="environments/v2v-dev")
    p.add_argument("--terraform-plan-json",  default=None)
    p.add_argument("--terraform-state-json", default=None)
    p.add_argument("--filter-tag-key",       default="Application",
                   help="AWS tag key used to scope resource collection (default: Application)")
    p.add_argument("--filter-tag-value",     default="",
                   help="AWS tag value to filter resources. "
                        "If omitted, derived automatically from --environment "
                        "(e.g. v2v-dev \u2192 BTSGSD-V2V-US).")
    args = p.parse_args()
    os.makedirs(args.output, exist_ok=True)

    # Resolve tag filter value: explicit arg wins; otherwise derive from env.
    filter_tag_value = (
        args.filter_tag_value
        or ENV_DEFAULT_FILTER.get(args.environment, "")
    )
    if not filter_tag_value:
        raise SystemExit(
            f"Cannot derive --filter-tag-value for environment '{args.environment}'. "
            "Please supply it explicitly: --filter-tag-value <VALUE>"
        )

    print(f"[1/4] Collecting AWS data ({args.region}) "
          f"\u2014 filter: {args.filter_tag_key}={filter_tag_value} …")
    account, aws_rows, aws_status = collect_aws(
        args.region, args.environment,
        args.filter_tag_key, filter_tag_value
    )

    print(f"[2/4] Collecting Terraform declarations ({args.terraform_directory}) …")
    tf_rows, tf_status = collect_terraform(args.terraform_directory)

    print("[3/4] Collecting Terraform plan/state …")
    eval_rows, eval_status = collect_terraform_json(
        args.terraform_plan_json, args.terraform_state_json)

    rows   = aws_rows   + tf_rows   + eval_rows
    status = aws_status + tf_status + eval_status

    env_label = ENVIRONMENT_DISPLAY.get(args.environment, args.environment)
    metadata  = {
        "Environment":             f"{args.environment}  ({env_label})",
        "AWS Account":             account,
        "AWS Region":              args.region,
        "Terraform Directory":     args.terraform_directory,
        "Generated At":            datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC"),
        "Total Inventory Records": len(rows),
        "Security":
            "Read-only collection. Secret values and sensitive Terraform values excluded.",
    }

    prefix = f"BTSGSD-{args.environment}-AsBuilt"
    title  = "BTSGSD AWS Infrastructure As-Built Documentation"

    print("[4/4] Writing documents …")
    word(os.path.join(args.output, prefix + ".docx"),
         title, metadata, rows, status, args.environment)
    pdf(os.path.join(args.output, prefix + ".pdf"),
        title, metadata, rows, status, args.environment)
    markdown(os.path.join(args.output, prefix + ".md"),
             title, metadata, rows, status)

    print(f"\nDone. {len(rows)} records | "
          f"{len(set(r['service'] for r in rows))} services | "
          f"output: {args.output}")


if __name__ == "__main__":
    main()
