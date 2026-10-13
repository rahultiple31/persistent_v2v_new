import os
import json


def lambda_handler(event, context):
    sn_instance = os.environ.get("SN_INSTANCE", "Not Set")
    sn_secret_name = os.environ.get("SN_SECRET_NAME", "Not Set")

    print("Lambda SNOW_Abbvie executed successfully!")
    print(f"ServiceNow Instance: {sn_instance}")
    print(f"Secret Name: {sn_secret_name}")

    return {
        "statusCode": 200,
        "body": json.dumps({
            "message": "Lambda executed successfully",
            "instance": sn_instance,
            "secret_name": sn_secret_name
        })
    }
