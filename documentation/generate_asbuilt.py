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
                try:
                    if kind == "Queue":
                        x = c.describe_queue(InstanceId=iid, QueueId=rid)["Queue"]
                        add(rows, "Amazon Connect", "Queue configuration", name, rid, f"Status={x.get('Status')}; HoursId={x.get('HoursOfOperationId')}; MaxContacts={x.get('MaxContacts')}; OutboundCaller={value(x.get('OutboundCallerConfig'))}; Description={x.get('Description', '-')}", tag_text(x.get("Tags")))
                    elif kind == "Routing profile":
                        x = c.describe_routing_profile(InstanceId=iid, RoutingProfileId=rid)["RoutingProfile"]
                        add(rows, "Amazon Connect", "Routing profile configuration", name, rid, f"DefaultQueue={x.get('DefaultOutboundQueueId')}; MediaConcurrencies={value(x.get('MediaConcurrencies'))}; AgentAvailabilityTimer={x.get('AgentAvailabilityTimer')}", tag_text(x.get("Tags")))
                    elif kind == "Contact flow":
                        x = c.describe_contact_flow(InstanceId=iid, ContactFlowId=rid)["ContactFlow"]
                        add(rows, "Amazon Connect", "Contact flow configuration", name, rid, f"Type={x.get('Type')}; State={x.get('State')}; Status={x.get('Status')}; Description={x.get('Description', '-')}; ContentLength={len(x.get('Content', ''))}", tag_text(x.get("Tags")))
                    elif kind == "Flow module":
                        x = c.describe_contact_flow_module(InstanceId=iid, ContactFlowModuleId=rid)
                        add(rows, "Amazon Connect", "Flow module configuration", name, rid, f"State={x.get('State')}; Status={x.get('Status')}; Description={x.get('Description', '-')}; ContentLength={len(x.get('Content', ''))}", tag_text(x.get("Tags")))
                    elif kind == "Hours":
                        x = c.describe_hours_of_operation(InstanceId=iid, HoursOfOperationId=rid)["HoursOfOperation"]
                        add(rows, "Amazon Connect", "Hours configuration", name, rid, f"TimeZone={x.get('TimeZone')}; Config={value(x.get('Config'))}; Overrides={value(x.get('Overrides'))}", tag_text(x.get("Tags")))
                    elif kind == "Security profile":
                        x = c.describe_security_profile(InstanceId=iid, SecurityProfileId=rid)["SecurityProfile"]
                        add(rows, "Amazon Connect", "Security profile configuration", name, rid, f"Permissions={value(x.get('Permissions'))}; AllowedAccessControlTags={value(x.get('AllowedAccessControlTags'))}; TagRestrictedResources={value(x.get('TagRestrictedResources'))}", tag_text(x.get("Tags")))
                except ClientError as error:
                    add(rows, "Amazon Connect", f"{kind} configuration", name, rid, f"Not collected: {error.response.get('Error', {}).get('Code')}")


def lex(session, rows):
    c = session.client("lexv2-models")
    for bot in pages(c, "list_bots", "botSummaries"):
        bid, name = bot["botId"], bot.get("botName")
        add(rows, "Amazon Lex V2", "Bot", name, bid, f"Status={bot.get('botStatus')}; LatestVersion={bot.get('latestBotVersion')}")
        for x in pages(c, "list_bot_locales", "botLocaleSummaries", botId=bid, botVersion="DRAFT"):
            locale = x.get("localeId")
            add(rows, "Amazon Lex V2", "Locale", f"{name} / {locale}", locale, f"Status={x.get('botLocaleStatus')}; Intents={x.get('intentCount')}")
            for intent in pages(c, "list_intents", "intentSummaries", botId=bid, botVersion="DRAFT", localeId=locale):
                intent_id, intent_name = intent.get("intentId"), intent.get("intentName")
                add(rows, "Amazon Lex V2", "Intent", f"{name} / {intent_name}", intent_id, f"Description={intent.get('description', '-')}; ParentIntent={intent.get('parentIntentSignature', '-')}")
                for slot in pages(c, "list_slots", "slotSummaries", botId=bid, botVersion="DRAFT", localeId=locale, intentId=intent_id):
                    add(rows, "Amazon Lex V2", "Slot", f"{intent_name} / {slot.get('slotName')}", slot.get("slotId"), f"Type={slot.get('slotTypeId')}; Constraint={slot.get('valueElicitationPromptSpecification', '-')}")
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
                agent_id = agent.get("aiAgentId")
                detail = c.get_ai_agent(assistantId=aid, aiAgentId=agent_id).get("aiAgent", {})
                add(rows, "Amazon Connect AI", "AI agent configuration", agent.get("name"), agent_id, f"Origin={origin}; Type={agent.get('type')}; Status={agent.get('status')}; Configuration={value(detail.get('configuration'))}", tag_text(agent.get("tags")))
        for prompt in pages(c, "list_ai_prompts", "aiPromptSummaries", assistantId=aid, origin="CUSTOMER"):
            prompt_id = prompt.get("aiPromptId")
            detail = c.get_ai_prompt(assistantId=aid, aiPromptId=prompt_id).get("aiPrompt", {})
            add(rows, "Amazon Connect AI", "AI prompt configuration", prompt.get("name"), prompt_id, f"Type={prompt.get('type')}; Status={prompt.get('status')}; Model={detail.get('modelId')}; APIFormat={detail.get('apiFormat')}; TemplateType={detail.get('templateType')}", tag_text(prompt.get("tags")))


def iam(session, rows):
    c = session.client("iam")
    for role in pages(c, "list_roles", "Roles"):
        name = role["RoleName"]
        attached = [x["PolicyName"] for x in pages(c, "list_attached_role_policies", "AttachedPolicies", RoleName=name)]
        inline = list(pages(c, "list_role_policies", "PolicyNames", RoleName=name))
        add(rows, "AWS IAM", "Role", name, role.get("Arn"), f"Attached={value(attached)}; Inline={value(inline)}; MaxSession={role.get('MaxSessionDuration')}; TrustPolicy={value(role.get('AssumeRolePolicyDocument'))}", tag_text(role.get("Tags")))
        for policy_name in inline:
            document = c.get_role_policy(RoleName=name, PolicyName=policy_name).get("PolicyDocument")
            add(rows, "AWS IAM", "Inline role policy", f"{name} / {policy_name}", role.get("Arn"), f"Document={value(document)}")
    for policy in pages(c, "list_policies", "Policies", Scope="Local"):
        document = c.get_policy_version(PolicyArn=policy["Arn"], VersionId=policy["DefaultVersionId"]).get("PolicyVersion", {}).get("Document")
        add(rows, "AWS IAM", "Managed policy", policy.get("PolicyName"), policy.get("Arn"), f"DefaultVersion={policy.get('DefaultVersionId')}; Attachments={policy.get('AttachmentCount')}; Document={value(document)}")


def networking(session, rows):
    c = session.client("ec2")
    calls = [("describe_vpcs", "Vpcs", "VPC", "VpcId"), ("describe_subnets", "Subnets", "Subnet", "SubnetId"), ("describe_security_groups", "SecurityGroups", "Security group", "GroupId"), ("describe_route_tables", "RouteTables", "Route table", "RouteTableId"), ("describe_nat_gateways", "NatGateways", "NAT gateway", "NatGatewayId"), ("describe_vpc_endpoints", "VpcEndpoints", "VPC endpoint", "VpcEndpointId"), ("describe_internet_gateways", "InternetGateways", "Internet gateway", "InternetGatewayId")]
    for op, key, kind, id_key in calls:
        for item in getattr(c, op)().get(key, []):
            tags = {x["Key"]: x["Value"] for x in item.get("Tags", [])}
            detail = "; ".join(f"{k}={value(item[k])}" for k in ("VpcId", "State", "CidrBlock", "AvailabilityZone", "ServiceName", "IpPermissions", "IpPermissionsEgress", "Routes", "Associations", "RouteTableIds", "SubnetIds", "Groups") if item.get(k))
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
        try: detail.append(f"Lifecycle={value(c.get_bucket_lifecycle_configuration(Bucket=name).get('Rules'))}")
        except ClientError as e: detail.append(f"Lifecycle={e.response.get('Error', {}).get('Code', 'Not configured')}")
        try: detail.append(f"Logging={value(c.get_bucket_logging(Bucket=name).get('LoggingEnabled'))}")
        except ClientError as e: detail.append(f"Logging={e.response.get('Error', {}).get('Code', 'Error')}")
        add(rows, "Amazon S3", "Bucket", name, name, "; ".join(detail), tag_text(tags))


def monitoring(session, rows):
    logs = session.client("logs")
    for x in pages(logs, "describe_log_groups", "logGroups"):
        name = x.get("logGroupName")
        filters = list(pages(logs, "describe_metric_filters", "metricFilters", logGroupName=name))
        subscriptions = list(pages(logs, "describe_subscription_filters", "subscriptionFilters", logGroupName=name))
        add(rows, "Amazon CloudWatch", "Log group", name, x.get("arn"), f"Retention={x.get('retentionInDays', 'Never expire')}; StoredBytes={x.get('storedBytes', 0)}; KmsKey={x.get('kmsKeyId', '-')}; MetricFilters={value(filters)}; SubscriptionFilters={value(subscriptions)}")
    c = session.client("cloudwatch")
    for x in pages(c, "describe_alarms", "MetricAlarms"):
        add(rows, "Amazon CloudWatch", "Metric alarm", x.get("AlarmName"), x.get("AlarmArn"), f"State={x.get('StateValue')}; Metric={x.get('Namespace')}/{x.get('MetricName')}; Threshold={x.get('Threshold')}")


def api_gateway(session, rows):
    c = session.client("apigateway")
    for api in pages(c, "get_rest_apis", "items"):
        aid = api["id"]
        add(rows, "Amazon API Gateway", "REST API", api.get("name"), aid, f"EndpointTypes={value((api.get('endpointConfiguration') or {}).get('types'))}", tag_text(api.get("tags")))
        for stage in c.get_stages(restApiId=aid).get("item", []): add(rows, "Amazon API Gateway", "REST stage", f"{api.get('name')} / {stage.get('stageName')}", stage.get("deploymentId"), f"Tracing={stage.get('tracingEnabled', False)}")
        for resource in c.get_resources(restApiId=aid, embed=["methods"]).get("items", []):
            add(rows, "Amazon API Gateway", "REST resource", f"{api.get('name')} {resource.get('path')}", resource.get("id"), f"Methods={value(resource.get('resourceMethods'))}")
    c = session.client("apigatewayv2")
    for api in pages(c, "get_apis", "Items"):
        aid = api["ApiId"]
        add(rows, "Amazon API Gateway", "V2 API", api.get("Name"), aid, f"Protocol={api.get('ProtocolType')}; Endpoint={api.get('ApiEndpoint')}", tag_text(api.get("Tags")))
        for stage in pages(c, "get_stages", "Items", ApiId=aid): add(rows, "Amazon API Gateway", "V2 stage", f"{api.get('Name')} / {stage.get('StageName')}", stage.get("DeploymentId"), f"AutoDeploy={stage.get('AutoDeploy', False)}")
        for route in pages(c, "get_routes", "Items", ApiId=aid): add(rows, "Amazon API Gateway", "V2 route", f"{api.get('Name')} / {route.get('RouteKey')}", route.get("RouteId"), f"Target={route.get('Target')}; Authorization={route.get('AuthorizationType')}")
        for integration in pages(c, "get_integrations", "Items", ApiId=aid): add(rows, "Amazon API Gateway", "V2 integration", f"{api.get('Name')} / {integration.get('IntegrationType')}", integration.get("IntegrationId"), f"URI={integration.get('IntegrationUri')}; Method={integration.get('IntegrationMethod')}; Timeout={integration.get('TimeoutInMillis')}")


def security(session, rows):
    c = session.client("secretsmanager")
    for x in pages(c, "list_secrets", "SecretList"):
        detail = c.describe_secret(SecretId=x.get("ARN"))
        add(rows, "AWS Secrets Manager", "Secret metadata", x.get("Name"), x.get("ARN"), f"Rotation={detail.get('RotationEnabled', False)}; RotationLambda={detail.get('RotationLambdaARN', '-')}; RotationRules={value(detail.get('RotationRules'))}; KmsKey={detail.get('KmsKeyId', 'aws/secretsmanager')}; Description={detail.get('Description', '-')}; SecretValue=NOT COLLECTED", tag_text(detail.get("Tags")))
    c = session.client("kms")
    aliases = defaultdict(list)
    for x in pages(c, "list_aliases", "Aliases"):
        if x.get("TargetKeyId"): aliases[x["TargetKeyId"]].append(x.get("AliasName"))
    for x in pages(c, "list_keys", "Keys"):
        meta = c.describe_key(KeyId=x["KeyId"])["KeyMetadata"]
        try: rotation = c.get_key_rotation_status(KeyId=x["KeyId"]).get("KeyRotationEnabled")
        except ClientError: rotation = "Not available"
        add(rows, "AWS KMS", "Key", value(aliases.get(x["KeyId"]), x["KeyId"]), meta.get("Arn"), f"State={meta.get('KeyState')}; Manager={meta.get('KeyManager')}; Usage={meta.get('KeyUsage')}; MultiRegion={meta.get('MultiRegion')}; Rotation={rotation}; Description={meta.get('Description', '-')}")


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
        name = x.get("FunctionName")
        cfg = c.get_function_configuration(FunctionName=name)
        env_names = sorted((cfg.get("Environment") or {}).get("Variables", {}).keys())
        try: concurrency = c.get_function_concurrency(FunctionName=name).get("ReservedConcurrentExecutions", "Unreserved")
        except ClientError: concurrency = "Not available"
        aliases = list(pages(c, "list_aliases", "Aliases", FunctionName=name))
        versions = list(pages(c, "list_versions_by_function", "Versions", FunctionName=name))
        details = f"Runtime={cfg.get('Runtime')}; Architectures={value(cfg.get('Architectures'))}; Handler={cfg.get('Handler')}; Memory={cfg.get('MemorySize')}; Timeout={cfg.get('Timeout')}; EphemeralStorage={value(cfg.get('EphemeralStorage'))}; Role={cfg.get('Role')}; VpcConfig={value(cfg.get('VpcConfig'))}; Layers={value(cfg.get('Layers'))}; ReservedConcurrency={concurrency}; Tracing={value(cfg.get('TracingConfig'))}; Logging={value(cfg.get('LoggingConfig'))}; DeadLetter={value(cfg.get('DeadLetterConfig'))}; KmsKey={cfg.get('KMSKeyArn', '-')}; PackageType={cfg.get('PackageType')}; EnvironmentVariableNames={value(env_names)}; EnvironmentVariableValues=REDACTED; Aliases={value(aliases)}; Versions={len(versions)}"
        add(rows, "AWS Lambda", "Function configuration", name, cfg.get("FunctionArn"), details)
    c = session.client("dynamodb")
    for name in pages(c, "list_tables", "TableNames"):
        x = c.describe_table(TableName=name)["Table"]
        ttl = c.describe_time_to_live(TableName=name).get("TimeToLiveDescription", {})
        backups = c.describe_continuous_backups(TableName=name).get("ContinuousBackupsDescription", {})
        details = f"Status={x.get('TableStatus')}; Billing={((x.get('BillingModeSummary') or {}).get('BillingMode', 'PROVISIONED'))}; Keys={value(x.get('KeySchema'))}; Attributes={value(x.get('AttributeDefinitions'))}; GlobalIndexes={value(x.get('GlobalSecondaryIndexes'))}; LocalIndexes={value(x.get('LocalSecondaryIndexes'))}; Encryption={value(x.get('SSEDescription'))}; Stream={value(x.get('StreamSpecification'))}; TTL={value(ttl)}; Backups={value(backups)}; DeletionProtection={x.get('DeletionProtectionEnabled')}"
        add(rows, "Amazon DynamoDB", "Table configuration", name, x.get("TableArn"), details)


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
    table = Table([[Paragraph(escape(str(v)), styles["BodyText"]) for v in r] for r in data], colWidths=[1.7*inch, 1.1*inch, 7.4*inch], repeatRows=1, splitInRow=1); table.setStyle(style()); story.append(table)
    for service, items in grouped(rows).items():
        story.extend([PageBreak(), Paragraph(escape(service), styles["Heading1"])])
        data = [["Type", "Name", "Identifier", "Details", "Tags"]] + [[x[k] for k in ("type", "name", "identifier", "details", "tags")] for x in items]
        table = Table([[Paragraph(escape(str(v)), styles["BodyText"]) for v in r] for r in data], colWidths=[1.25*inch, 1.6*inch, 2.2*inch, 4*inch, 1.25*inch], repeatRows=1, splitInRow=1); table.setStyle(style()); story.append(table)
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
