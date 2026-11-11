import boto3, time, os, json
from botocore.config import Config

connect = boto3.client("connect", config=Config(retries={"max_attempts": 1}))
INSTANCE_ID = os.environ["CONNECT_INSTANCE_ID"]
POLL_SLEEP = float(os.environ.get("POLL_SLEEP", "4"))

def lambda_handler(event, context):
    params = event.get("Details", {}).get("Parameters", {})
    contact_id = params.get("contactId") or event["Details"]["ContactData"]["ContactId"]
    state = "connecting"
    try:
        c = connect.describe_contact(InstanceId=INSTANCE_ID, ContactId=contact_id)["Contact"]
        if c.get("DisconnectTimestamp"):
            state = "ended"
        elif c.get("AgentInfo", {}).get("ConnectedToAgentTimestamp"):
            state = "connected"
    except Exception as e:
        print(json.dumps({"contactId": contact_id, "error": str(e)}))
    print(json.dumps({"contactId": contact_id, "state": state}))
    if state == "connecting":
        time.sleep(POLL_SLEEP)
    return {"state": state}
