import argparse, json, os, re
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from xml.sax.saxutils import escape

import boto3
from botocore.exceptions import BotoCoreError, ClientError
from docx import Document
from docx.shared import Inches
from reportlab.lib import colors
from reportlab.lib.pagesizes import A4, landscape
from reportlab.lib.styles import getSampleStyleSheet
from reportlab.lib.units import inch
from reportlab.platypus import PageBreak, Paragraph, SimpleDocTemplate, Spacer, Table, TableStyle


def value(item, default="-"):
    if item in (None, "", [], {}): return default
    if isinstance(item, (list, tuple, set)): return ", ".join(map(str, item)) or default
    if isinstance(item, dict): return json.dumps(item, sort_keys=True, default=str)
    return str(item)


def add(rows, service, kind, name, identifier="-", details="-", tags="-"):
    rows.append({"service": service, "type": kind, "name": value(name), "identifier": value(identifier), "details": value(details), "tags": value(tags)})


def pages(client, operation, key, **kwargs):
    for page in client.get_paginator(operation).paginate(**kwargs):
        yield from page.get(key, [])


def tag_text(tags):
    if isinstance(tags, dict): data = tags
    else: data = {x.get("Key"): x.get("Value") for x in tags or [] if x.get("Key")}
    return ", ".join(f"{k}={v}" for k, v in sorted(data.items())) or "-"


def connect(session, rows):
    c = session.client("connect")
    for instance in pages(c, "list_instances", "InstanceSummaryList"):
        iid = instance["Id"]
        add(rows, "Amazon Connect", "Instance", instance.get("InstanceAlias"), iid, f"Status={instance.get('InstanceStatus')}")
        calls = [
            ("list_queues", "QueueSummaryList", "Queue", {"InstanceId": iid, "QueueTypes": ["STANDARD", "AGENT"]}),
            ("list_routing_profiles", "RoutingProfileSummaryList", "Routing profile", {"InstanceId": iid}),
            ("list_contact_flows", "ContactFlowSummaryList", "Contact flow", {"InstanceId": iid}),
            ("list_contact_flow_modules", "ContactFlowModulesSummaryList", "Flow module", {"InstanceId": iid}),
            ("list_hours_of_operations", "HoursOfOperationSummaryList", "Hours", {"InstanceId": iid}),
            ("list_prompts", "PromptSummaryList", "Prompt", {"InstanceId": iid}),
            ("list_security_profiles", "SecurityProfileSummaryList", "Security profile", {"InstanceId": iid}),
            ("list_integration_associations", "IntegrationAssociationSummaryList", "Integration", {"InstanceId": iid}),
        ]
        for op, key, kind, args in calls:
            for item in pages(c, op, key, **args):
                name = item.get("Name") or item.get("IntegrationType")
                rid = item.get("Id") or item.get("Arn") or item.get("IntegrationAssociationId")
                detail = "; ".join(f"{k}={v}" for k, v in item.items() if k not in {"Name", "Id", "Arn"} and v not in (None, "", [], {}))
                add(rows, "Amazon Connect", kind, name, rid, detail)


def lex(session, rows):
    c = session.client("lexv2-models")
    for bot in pages(c, "list_bots", "botSummaries"):
        bid, name = bot["botId"], bot.get("botName")
        add(rows, "Amazon Lex V2", "Bot", name, bid, f"Status={bot.get('botStatus')}; LatestVersion={bot.get('latestBotVersion')}")
        for x in pages(c, "list_bot_locales", "botLocaleSummaries", botId=bid, botVersion="DRAFT"):
            add(rows, "Amazon Lex V2", "Locale", f"{name} / {x.get('localeId')}", x.get("localeId"), f"Status={x.get('botLocaleStatus')}; Intents={x.get('intentCount')}")
        for x in pages(c, "list_bot_versions", "botVersionSummaries", botId=bid):
            add(rows, "Amazon Lex V2", "Version", f"{name} v{x.get('botVersion')}", x.get("botVersion"), f"Status={x.get('botStatus')}")
        for x in pages(c, "list_bot_aliases", "botAliasSummaries", botId=bid):
            add(rows, "Amazon Lex V2", "Alias", x.get("botAliasName"), x.get("botAliasId"), f"Version={x.get('botVersion')}; Status={x.get('botAliasStatus')}")


def qconnect(session, rows):
    c = session.client("qconnect")
    for assistant in pages(c, "list_assistants", "assistantSummaries"):
        aid, name = assistant["assistantId"], assistant.get("name")
        add(rows, "Amazon Connect AI", "Assistant", name, aid, f"Status={assistant.get('status')}; Type={assistant.get('type')}", tag_text(assistant.get("tags")))
        for origin in ("CUSTOMER", "SYSTEM"):
            for agent in pages(c, "list_ai_agents", "aiAgentSummaries", assistantId=aid, origin=origin):
                add(rows, "Amazon Connect AI", "AI agent", agent.get("name"), agent.get("aiAgentId"), f"Origin={origin}; Type={agent.get('type')}; Status={agent.get('status')}", tag_text(agent.get("tags")))
        for prompt in pages(c, "list_ai_prompts", "aiPromptSummaries", assistantId=aid, origin="CUSTOMER"):
            add(rows, "Amazon Connect AI", "AI prompt", prompt.get("name"), prompt.get("aiPromptId"), f"Type={prompt.get('type')}; Status={prompt.get('status')}", tag_text(prompt.get("tags")))


def iam(session, rows):
    c = session.client("iam")
    for role in pages(c, "list_roles", "Roles"):
        name = role["RoleName"]
        attached = [x["PolicyName"] for x in pages(c, "list_attached_role_policies", "AttachedPolicies", RoleName=name)]
        inline = list(pages(c, "list_role_policies", "PolicyNames", RoleName=name))
        add(rows, "AWS IAM", "Role", name, role.get("Arn"), f"Attached={value(attached)}; Inline={value(inline)}; MaxSession={role.get('MaxSessionDuration')}", tag_text(role.get("Tags")))
    for policy in pages(c, "list_policies", "Policies", Scope="Local"):
        add(rows, "AWS IAM", "Managed policy", policy.get("PolicyName"), policy.get("Arn"), f"DefaultVersion={policy.get('DefaultVersionId')}; Attachments={policy.get('AttachmentCount')}")


def networking(session, rows):
    c = session.client("ec2")
    calls = [("describe_vpcs", "Vpcs", "VPC", "VpcId"), ("describe_subnets", "Subnets", "Subnet", "SubnetId"), ("describe_security_groups", "SecurityGroups", "Security group", "GroupId"), ("describe_route_tables", "RouteTables", "Route table", "RouteTableId"), ("describe_nat_gateways", "NatGateways", "NAT gateway", "NatGatewayId"), ("describe_vpc_endpoints", "VpcEndpoints", "VPC endpoint", "VpcEndpointId"), ("describe_internet_gateways", "InternetGateways", "Internet gateway", "InternetGatewayId")]
    for op, key, kind, id_key in calls:
        for item in getattr(c, op)().get(key, []):
            tags = {x["Key"]: x["Value"] for x in item.get("Tags", [])}
            detail = "; ".join(f"{k}={item[k]}" for k in ("VpcId", "State", "CidrBlock", "AvailabilityZone", "ServiceName") if item.get(k))
            add(rows, "Amazon VPC", kind, tags.get("Name", item.get(id_key)), item.get(id_key), detail, tag_text(tags))


def s3(session, rows):
    c = session.client("s3")
    for bucket in c.list_buckets().get("Buckets", []):
        name, detail = bucket["Name"], []
        for label, fn, key in [("Versioning", c.get_bucket_versioning, "Status"), ("Encryption", c.get_bucket_encryption, "ServerSideEncryptionConfiguration"), ("PublicAccess", c.get_public_access_block, "PublicAccessBlockConfiguration")]:
            try: detail.append(f"{label}={value(fn(Bucket=name).get(key, 'Not configured'))}")
            except ClientError as e: detail.append(f"{label}={e.response.get('Error', {}).get('Code', 'Error')}")
        try: tags = c.get_bucket_tagging(Bucket=name).get("TagSet", [])
        except ClientError: tags = []
        add(rows, "Amazon S3", "Bucket", name, name, "; ".join(detail), tag_text(tags))


def monitoring(session, rows):
    logs = session.client("logs")
    for x in pages(logs, "describe_log_groups", "logGroups"):
        add(rows, "Amazon CloudWatch", "Log group", x.get("logGroupName"), x.get("arn"), f"Retention={x.get('retentionInDays', 'Never expire')}; StoredBytes={x.get('storedBytes', 0)}; KmsKey={x.get('kmsKeyId', '-')}")
    c = session.client("cloudwatch")
    for x in pages(c, "describe_alarms", "MetricAlarms"):
        add(rows, "Amazon CloudWatch", "Metric alarm", x.get("AlarmName"), x.get("AlarmArn"), f"State={x.get('StateValue')}; Metric={x.get('Namespace')}/{x.get('MetricName')}; Threshold={x.get('Threshold')}")


def api_gateway(session, rows):
    c = session.client("apigateway")
    for api in pages(c, "get_rest_apis", "items"):
        aid = api["id"]
        add(rows, "Amazon API Gateway", "REST API", api.get("name"), aid, f"EndpointTypes={value((api.get('endpointConfiguration') or {}).get('types'))}", tag_text(api.get("tags")))
        for stage in c.get_stages(restApiId=aid).get("item", []): add(rows, "Amazon API Gateway", "REST stage", f"{api.get('name')} / {stage.get('stageName')}", stage.get("deploymentId"), f"Tracing={stage.get('tracingEnabled', False)}")
    c = session.client("apigatewayv2")
    for api in pages(c, "get_apis", "Items"):
        aid = api["ApiId"]
        add(rows, "Amazon API Gateway", "V2 API", api.get("Name"), aid, f"Protocol={api.get('ProtocolType')}; Endpoint={api.get('ApiEndpoint')}", tag_text(api.get("Tags")))
        for stage in pages(c, "get_stages", "Items", ApiId=aid): add(rows, "Amazon API Gateway", "V2 stage", f"{api.get('Name')} / {stage.get('StageName')}", stage.get("DeploymentId"), f"AutoDeploy={stage.get('AutoDeploy', False)}")


def security(session, rows):
    c = session.client("secretsmanager")
    for x in pages(c, "list_secrets", "SecretList"):
        add(rows, "AWS Secrets Manager", "Secret metadata", x.get("Name"), x.get("ARN"), f"Rotation={x.get('RotationEnabled', False)}; KmsKey={x.get('KmsKeyId', 'aws/secretsmanager')}; Description={x.get('Description', '-')}", tag_text(x.get("Tags")))
    c = session.client("kms")
    aliases = defaultdict(list)
    for x in pages(c, "list_aliases", "Aliases"):
        if x.get("TargetKeyId"): aliases[x["TargetKeyId"]].append(x.get("AliasName"))
    for x in pages(c, "list_keys", "Keys"):
        meta = c.describe_key(KeyId=x["KeyId"])["KeyMetadata"]
        add(rows, "AWS KMS", "Key", value(aliases.get(x["KeyId"]), x["KeyId"]), meta.get("Arn"), f"State={meta.get('KeyState')}; Manager={meta.get('KeyManager')}; Usage={meta.get('KeyUsage')}; MultiRegion={meta.get('MultiRegion')}")


def messaging(session, rows):
    c = session.client("sns")
    for x in pages(c, "list_topics", "Topics"):
        arn = x["TopicArn"]; attrs = c.get_topic_attributes(TopicArn=arn).get("Attributes", {})
        add(rows, "Amazon SNS", "Topic", arn.rsplit(":", 1)[-1], arn, f"Subscriptions={attrs.get('SubscriptionsConfirmed')}; Fifo={attrs.get('FifoTopic', 'false')}; KmsKey={attrs.get('KmsMasterKeyId', '-')}")
    c = session.client("sqs")
    for url in c.list_queues().get("QueueUrls", []):
        attrs = c.get_queue_attributes(QueueUrl=url, AttributeNames=["All"]).get("Attributes", {})
        add(rows, "Amazon SQS", "Queue", url.rstrip("/").rsplit("/", 1)[-1], attrs.get("QueueArn", url), f"Fifo={attrs.get('FifoQueue', 'false')}; KmsKey={attrs.get('KmsMasterKeyId', '-')}; SSE={attrs.get('SqsManagedSseEnabled', '-')}")


def compute(session, rows):
    c = session.client("lambda")
    for x in pages(c, "list_functions", "Functions"):
        add(rows, "AWS Lambda", "Function", x.get("FunctionName"), x.get("FunctionArn"), f"Runtime={x.get('Runtime')}; Memory={x.get('MemorySize')}; Timeout={x.get('Timeout')}; VpcId={(x.get('VpcConfig') or {}).get('VpcId', '-')}")
    c = session.client("dynamodb")
    for name in pages(c, "list_tables", "TableNames"):
        x = c.describe_table(TableName=name)["Table"]
        add(rows, "Amazon DynamoDB", "Table", name, x.get("TableArn"), f"Status={x.get('TableStatus')}; Billing={((x.get('BillingModeSummary') or {}).get('BillingMode', 'PROVISIONED'))}; Encryption={((x.get('SSEDescription') or {}).get('Status', 'DEFAULT'))}")


COLLECTORS = [("Amazon Connect", connect), ("Amazon Connect AI", qconnect), ("Amazon Lex", lex), ("IAM", iam), ("VPC and networking", networking), ("S3", s3), ("CloudWatch", monitoring), ("API Gateway", api_gateway), ("Secrets Manager and KMS", security), ("SNS and SQS", messaging), ("Lambda and DynamoDB", compute)]


def collect_aws(region):
    session, rows, status = boto3.Session(region_name=region), [], []
    account = session.client("sts").get_caller_identity()["Account"]
    for name, fn in COLLECTORS:
        before = len(rows)
        try:
            fn(session, rows); status.append({"scope": name, "status": "Collected", "details": f"{len(rows)-before} records"})
        except (ClientError, BotoCoreError, KeyError, ValueError) as e:
            if isinstance(e, ClientError): detail = f"{e.response.get('Error', {}).get('Code')}: {e.response.get('Error', {}).get('Message')}"
            else: detail = str(e)
            status.append({"scope": name, "status": "Not collected", "details": detail})
    return account, rows, status


def collect_terraform(directory):
    rows, files = [], sorted(Path(directory).rglob("*.tf")) if Path(directory).is_dir() else []
    patterns = [("Resource", re.compile(r'^\s*resource\s+"([^"]+)"\s+"([^"]+)"', re.M)), ("Module", re.compile(r'^\s*module\s+"([^"]+)"', re.M)), ("Output", re.compile(r'^\s*output\s+"([^"]+)"', re.M)), ("Variable", re.compile(r'^\s*variable\s+"([^"]+)"', re.M))]
    for path in files:
        source = path.read_text(encoding="utf-8")
        for kind, pattern in patterns:
            for match in pattern.findall(source):
                name = ".".join(match) if isinstance(match, tuple) else match
                add(rows, "Terraform", f"{kind} declaration", name, path.as_posix(), "Sensitive values are not collected" if kind in {"Output", "Variable"} else "Declared in configuration")
    state = "Collected" if files else "Not collected"
    detail = f"{len(files)} .tf files; {len(rows)} declarations" if files else f"Directory not found or empty: {directory}"
    return rows, [{"scope": "Terraform configuration", "status": state, "details": detail}]


SENSITIVE_NAMES = re.compile(r"(password|secret|token|private.?key|access.?key|credential|authorization|environment)", re.I)


def flatten_configuration(item, prefix=""):
    flattened = []
    if isinstance(item, dict):
        for key, child in sorted(item.items()):
            path = f"{prefix}.{key}" if prefix else str(key)
            if SENSITIVE_NAMES.search(str(key)):
                flattened.append((path, "REDACTED"))
            else:
                flattened.extend(flatten_configuration(child, path))
    elif isinstance(item, list):
        for index, child in enumerate(item):
            flattened.extend(flatten_configuration(child, f"{prefix}[{index}]"))
    else:
        flattened.append((prefix or "value", value(item)))
    return flattened


def redact_sensitive(item, mask):
    if mask is True:
        return "REDACTED"
    if isinstance(item, dict):
        mask = mask if isinstance(mask, dict) else {}
        return {key: redact_sensitive(child, mask.get(key)) for key, child in item.items()}
    if isinstance(item, list):
        mask = mask if isinstance(mask, list) else []
        return [redact_sensitive(child, mask[index] if index < len(mask) else None) for index, child in enumerate(item)]
    return item


def state_resources(module):
    yield from module.get("resources", [])
    for child in module.get("child_modules", []):
        yield from state_resources(child)


def collect_terraform_json(plan_path=None, state_path=None):
    rows, status = [], []
    if plan_path and Path(plan_path).is_file():
        plan = json.loads(Path(plan_path).read_text(encoding="utf-8"))
        for change in plan.get("resource_changes", []):
            address = change.get("address", "unknown")
            actions = change.get("change", {}).get("actions", [])
            after = change.get("change", {}).get("after") or {}
            after = redact_sensitive(after, change.get("change", {}).get("after_sensitive"))
            for parameter, configured_value in flatten_configuration(after):
                add(rows, "Terraform Evaluated Plan", change.get("type", "Resource"), address, parameter, configured_value, f"Actions={value(actions)}")
        status.append({"scope": "Terraform evaluated plan", "status": "Collected", "details": f"{len(plan.get('resource_changes', []))} resource changes from {plan_path}"})
    else:
        status.append({"scope": "Terraform evaluated plan", "status": "Not collected", "details": "No terraform-plan.json supplied"})
    if state_path and Path(state_path).is_file():
        state = json.loads(Path(state_path).read_text(encoding="utf-8"))
        root = state.get("values", {}).get("root_module", {})
        state_items = list(state_resources(root))
        for resource in state_items:
            address = resource.get("address", "unknown")
            configured = redact_sensitive(resource.get("values", {}), resource.get("sensitive_values"))
            for parameter, configured_value in flatten_configuration(configured):
                add(rows, "Terraform State", resource.get("type", "Resource"), address, parameter, configured_value, f"Mode={resource.get('mode', '-')}; Provider={resource.get('provider_name', '-')}")
        status.append({"scope": "Terraform state", "status": "Collected", "details": f"{len(state_items)} state resources from {state_path}"})
    else:
        status.append({"scope": "Terraform state", "status": "Not collected", "details": "No terraform-state.json supplied"})
    return rows, status


def grouped(rows):
    data = defaultdict(list)
    for row in sorted(rows, key=lambda x: (x["service"], x["type"], x["name"])): data[row["service"]].append(row)
    return data


def word(path, title, metadata, rows, status):
    doc = Document(); section = doc.sections[0]; section.left_margin = section.right_margin = Inches(.5)
    doc.add_heading(title, 0)
    for k, v in metadata.items(): doc.add_paragraph(f"{k}: {v}")
    doc.add_heading("Collection Status", 1); table = doc.add_table(rows=1, cols=3); table.style = "Table Grid"
    for c, label in zip(table.rows[0].cells, ["Scope", "Status", "Details"]): c.text = label
    for x in status:
        cells = table.add_row().cells
        for i, key in enumerate(("scope", "status", "details")): cells[i].text = x[key]
    for service, items in grouped(rows).items():
        doc.add_heading(service, 1); table = doc.add_table(rows=1, cols=5); table.style = "Table Grid"
        for c, label in zip(table.rows[0].cells, ["Type", "Name", "Identifier", "Details", "Tags"]): c.text = label
        for x in items:
            cells = table.add_row().cells
            for i, key in enumerate(("type", "name", "identifier", "details", "tags")): cells[i].text = x[key]
    doc.save(path)


def style():
    return TableStyle([("BACKGROUND", (0,0), (-1,0), colors.HexColor("#17365D")), ("TEXTCOLOR", (0,0), (-1,0), colors.white), ("GRID", (0,0), (-1,-1), .35, colors.HexColor("#D9D9D9")), ("VALIGN", (0,0), (-1,-1), "TOP"), ("FONTSIZE", (0,0), (-1,-1), 7), ("ROWBACKGROUNDS", (0,1), (-1,-1), [colors.white, colors.HexColor("#F3F6FA")])])


def pdf(path, title, metadata, rows, status):
    styles = getSampleStyleSheet(); story = [Paragraph(escape(title), styles["Title"]), Spacer(1, 10)]
    for k, v in metadata.items(): story.append(Paragraph(f"<b>{escape(k)}:</b> {escape(str(v))}", styles["BodyText"]))
    story.extend([Spacer(1, 8), Paragraph("Collection Status", styles["Heading1"])])
    data = [["Scope", "Status", "Details"]] + [[x["scope"], x["status"], x["details"]] for x in status]
    table = Table([[Paragraph(escape(str(v)), styles["BodyText"]) for v in r] for r in data], colWidths=[1.7*inch, 1.1*inch, 7.4*inch], repeatRows=1); table.setStyle(style()); story.append(table)
    for service, items in grouped(rows).items():
        story.extend([PageBreak(), Paragraph(escape(service), styles["Heading1"])])
        data = [["Type", "Name", "Identifier", "Details", "Tags"]] + [[x[k] for k in ("type", "name", "identifier", "details", "tags")] for x in items]
        table = Table([[Paragraph(escape(str(v)), styles["BodyText"]) for v in r] for r in data], colWidths=[1.25*inch, 1.6*inch, 2.2*inch, 4*inch, 1.25*inch], repeatRows=1); table.setStyle(style()); story.append(table)
    SimpleDocTemplate(path, pagesize=landscape(A4), leftMargin=24, rightMargin=24, topMargin=28, bottomMargin=28).build(story)


def markdown(path, title, metadata, rows, status):
    lines = [f"# {title}", ""] + [f"**{k}:** {v}  " for k, v in metadata.items()] + ["", "## Collection Status", "", "| Scope | Status | Details |", "|---|---|---|"]
    clean = lambda x: str(x).replace("|", "\\|").replace("\n", " ")
    for x in status: lines.append("| " + " | ".join(clean(x[k]) for k in ("scope", "status", "details")) + " |")
    for service, items in grouped(rows).items():
        lines += ["", f"## {service}", "", "| Type | Name | Identifier | Details | Tags |", "|---|---|---|---|---|"]
        for x in items: lines.append("| " + " | ".join(clean(x[k]) for k in ("type", "name", "identifier", "details", "tags")) + " |")
    Path(path).write_text("\n".join(lines) + "\n", encoding="utf-8")


def main():
    p = argparse.ArgumentParser(); p.add_argument("--environment", required=True); p.add_argument("--region", default="us-east-1"); p.add_argument("--output", default="documentation/output"); p.add_argument("--terraform-directory", default="environments/v2v-dev"); p.add_argument("--terraform-plan-json"); p.add_argument("--terraform-state-json"); args = p.parse_args(); os.makedirs(args.output, exist_ok=True)
    account, aws_rows, aws_status = collect_aws(args.region); tf_rows, tf_status = collect_terraform(args.terraform_directory); evaluated_rows, evaluated_status = collect_terraform_json(args.terraform_plan_json, args.terraform_state_json); rows, status = aws_rows + tf_rows + evaluated_rows, aws_status + tf_status + evaluated_status
    metadata = {"Environment": args.environment, "AWS Account": account, "AWS Region": args.region, "Terraform Directory": args.terraform_directory, "Generated At": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC"), "Total Inventory Records": len(rows), "Security": "Read-only; secret values and sensitive Terraform values are excluded"}
    prefix, title = f"BTSGSD-{args.environment}-AsBuilt", "BTSGSD AWS Infrastructure As-Built"
    word(os.path.join(args.output, prefix + ".docx"), title, metadata, rows, status); pdf(os.path.join(args.output, prefix + ".pdf"), title, metadata, rows, status); markdown(os.path.join(args.output, prefix + ".md"), title, metadata, rows, status)
    print(f"As-Built documentation generated successfully with {len(rows)} inventory records")


if __name__ == "__main__": main()
