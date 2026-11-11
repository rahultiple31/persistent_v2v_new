
import argparse
import os
from datetime import datetime, timezone
from xml.sax.saxutils import escape

import boto3
from docx import Document
from docx.shared import Inches
from reportlab.lib import colors
from reportlab.lib.styles import getSampleStyleSheet
from reportlab.lib.enums import TA_CENTER
from reportlab.platypus import (
    SimpleDocTemplate, Paragraph, Spacer, Table,
    TableStyle
)


def collect_aws_resources(region):
    session = boto3.Session(region_name=region)

    sts = session.client("sts")
    account = sts.get_caller_identity()["Account"]

    # Read Lambda functions
    lambdas = []
    lambda_client = session.client("lambda")

    for page in lambda_client.get_paginator(
        "list_functions"
    ).paginate():
        for function in page["Functions"]:
            lambdas.append({
                "name": function["FunctionName"],
                "type": "Lambda",
                "details": function.get("Runtime", "N/A")
            })

    # Read DynamoDB tables
    dynamodb = session.client("dynamodb")
    tables = []

    for page in dynamodb.get_paginator(
        "list_tables"
    ).paginate():
        for name in page.get("TableNames", []):
            tables.append({
                "name": name,
                "type": "DynamoDB",
                "details": "Table"
            })

    return account, lambdas + tables


def create_word(path, title, metadata, resources):
    document = Document()

    document.add_heading(title, 0)

    for key, value in metadata.items():
        document.add_paragraph(
            f"{key}: {value}"
        )

    document.add_heading("AWS Resource Inventory", 1)

    table = document.add_table(
        rows=1, cols=3
    )
    table.style = "Table Grid"

    for cell, label in zip(
        table.rows[0].cells,
        ["Resource Name", "Type", "Details"]
    ):
        cell.text = label

    for resource in resources:
        row = table.add_row().cells
        row[0].text = resource["name"]
        row[1].text = resource["type"]
        row[2].text = resource["details"]

    document.save(path)


def create_pdf(path, title, metadata, resources):
    pdf = SimpleDocTemplate(
        path,
        pagesize=(595, 842),
        rightMargin=35,
        leftMargin=35,
        topMargin=40,
        bottomMargin=40
    )

    styles = getSampleStyleSheet()
    story = [
        Paragraph(escape(title), styles["Title"]),
        Spacer(1, 20)
    ]

    for key, value in metadata.items():
        story.append(Paragraph(
            f"<b>{escape(key)}:</b> "
            f"{escape(str(value))}",
            styles["Normal"]
        ))
        story.append(Spacer(1, 6))

    story.append(Spacer(1, 15))
    story.append(Paragraph(
        "AWS Resource Inventory",
        styles["Heading2"]
    ))

    data = [[
        Paragraph("Resource Name", styles["Normal"]),
        Paragraph("Type", styles["Normal"]),
        Paragraph("Details", styles["Normal"])
    ]]

    for resource in resources:
        data.append([
            Paragraph(
                escape(str(resource[key])),
                styles["Normal"]
            )
            for key in ["name", "type", "details"]
        ])

    table = Table(
        data,
        colWidths=[265, 90, 170],
        repeatRows=1,
        hAlign="LEFT"
    )

    table.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, 0), colors.lightgrey),
        ("GRID", (0, 0), (-1, -1), 0.4, colors.grey),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 8),
        ("TOPPADDING", (0, 0), (-1, -1), 8)
    ]))

    story.append(table)
    pdf.build(story)


def create_markdown(path, title, metadata, resources):
    lines = [f"# {title}", ""]

    for key, value in metadata.items():
        lines.append(f"**{key}:** {value}  ")

    lines.extend([
        "",
        "## AWS Resource Inventory",
        "",
        "| Resource Name | Type | Details |",
        "|---|---|---|"
    ])

    for resource in resources:
        values = [
            str(resource[key]).replace("|", "\\|")
            for key in ["name", "type", "details"]
        ]
        lines.append("| " + " | ".join(values) + " |")

    with open(path, "w", encoding="utf-8") as file:
        file.write("\n".join(lines) + "\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--environment", required=True)
    parser.add_argument("--region", default="us-east-1")
    parser.add_argument("--output", default="documentation/output")
    args = parser.parse_args()

    os.makedirs(args.output, exist_ok=True)

    account, resources = collect_aws_resources(args.region)

    title = "BTSGSD AWS Infrastructure As-Built"
    metadata = {
        "Environment": args.environment,
        "AWS Account": account,
        "AWS Region": args.region,
        "Generated At": datetime.now(
            timezone.utc
        ).strftime("%Y-%m-%d %H:%M UTC"),
        "Total Resources": len(resources),
        "Inventory Scope": "Lambda and DynamoDB"
    }

    prefix = f"BTSGSD-{args.environment}-AsBuilt"

    create_word(
        os.path.join(args.output, prefix + ".docx"),
        title, metadata, resources
    )

    create_pdf(
        os.path.join(args.output, prefix + ".pdf"),
        title, metadata, resources
    )

    create_markdown(
        os.path.join(args.output, prefix + ".md"),
        title, metadata, resources
    )

    print("As-Built documentation generated successfully")


if __name__ == "__main__":
    main()
