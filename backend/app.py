
import os, json, boto3
from decimal import Decimal

TABLE_NAME = os.environ.get("TABLE_NAME", "resume-visitor-counter")
ddb = boto3.client("dynamodb")

def handler(event, context):
    resp = ddb.update_item(
        TableName=TABLE_NAME,
        Key={"pk": {"S": "counter"}},
        UpdateExpression="SET #c = if_not_exists(#c, :zero) + :one",
        ExpressionAttributeNames={"#c": "count"},
        ExpressionAttributeValues={":zero": {"N": "0"}, ":one": {"N": "1"}},
        ReturnValues="UPDATED_NEW",
    )
    count = int(Decimal(resp["Attributes"]["count"]["N"]))
    return {"statusCode": 200, "headers": {"Content-Type": "application/json"}, "body": json.dumps({"count": count})}
