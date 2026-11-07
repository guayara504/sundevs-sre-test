"""Persistencia: S3 (documento completo) + DynamoDB (registro durable / indice).

S3 guarda el resultado bajo results/<fecha>/<id>.json (requerimiento).
DynamoDB es la fuente de verdad consultable por id: si la cache expiro
(TTL 60s), el resultado se recupera de aqui sin reprocesar ni reescribir S3.
"""

from __future__ import annotations

import json
from typing import Any

from botocore.exceptions import ClientError


class ResultStore:
    def __init__(self, *, s3_client, dynamodb_client, bucket: str, table: str) -> None:
        self._s3 = s3_client
        self._ddb = dynamodb_client
        self._bucket = bucket
        self._table = table

    def get(self, result_id: str) -> dict[str, Any] | None:
        response = self._ddb.get_item(
            TableName=self._table,
            Key={"id": {"S": result_id}},
            ConsistentRead=True,
        )
        item = response.get("Item")
        if not item:
            return None
        return json.loads(item["result"]["S"])

    def put(self, result: dict[str, Any], s3_key: str) -> dict[str, Any]:
        """Escribe S3 y luego DynamoDB (idempotente por id).

        Si dos requests identicos llegan a la vez, solo uno gana la escritura
        condicional y el otro devuelve el resultado ya registrado.
        """
        body = json.dumps(result, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self._s3.put_object(
            Bucket=self._bucket,
            Key=s3_key,
            Body=body,
            ContentType="application/json",
        )
        try:
            self._ddb.put_item(
                TableName=self._table,
                Item={
                    "id": {"S": result["id"]},
                    "s3_key": {"S": s3_key},
                    "created_at": {"S": result["processed_at"]},
                    "result": {"S": body.decode("utf-8")},
                },
                ConditionExpression="attribute_not_exists(id)",
            )
        except ClientError as exc:
            if exc.response.get("Error", {}).get("Code") != "ConditionalCheckFailedException":
                raise
            existing = self.get(result["id"])
            if existing is not None:
                return existing
        return result
