"""Pruebas unitarias del processor (sin AWS ni Redis reales)."""

from __future__ import annotations

import json
from types import SimpleNamespace

import pytest
from botocore.exceptions import ClientError

import app
from cache import Cache
from store import ResultStore


class FakeRedis:
    def __init__(self, fail: bool = False):
        self.data: dict[str, str] = {}
        self.ttls: dict[str, int] = {}
        self.fail = fail

    def get(self, key):
        if self.fail:
            raise ConnectionError("redis down")
        return self.data.get(key)

    def set(self, key, value, ex=None):
        if self.fail:
            raise ConnectionError("redis down")
        assert ex is not None, "toda key debe tener TTL"
        self.data[key] = value
        self.ttls[key] = ex
        return True


class FakeS3:
    def __init__(self):
        self.objects: dict[str, bytes] = {}

    def put_object(self, Bucket, Key, Body, ContentType):
        self.objects[Key] = Body


class FakeDynamo:
    def __init__(self):
        self.items: dict[str, dict] = {}

    def get_item(self, TableName, Key, ConsistentRead):
        item = self.items.get(Key["id"]["S"])
        return {"Item": item} if item else {}

    def put_item(self, TableName, Item, ConditionExpression):
        if Item["id"]["S"] in self.items:
            raise ClientError({"Error": {"Code": "ConditionalCheckFailedException"}}, "PutItem")
        self.items[Item["id"]["S"]] = Item


@pytest.fixture
def env():
    redis = FakeRedis()
    s3 = FakeS3()
    ddb = FakeDynamo()
    deps = {
        "cache": Cache(enabled=True, client=redis),
        "store": ResultStore(s3_client=s3, dynamodb_client=ddb, bucket="b", table="t"),
        "ttl": 60,
        "region": "us-east-1",
    }
    app._deps = deps
    yield SimpleNamespace(redis=redis, s3=s3, ddb=ddb, deps=deps)
    app._deps = None


CTX = SimpleNamespace(aws_request_id="req-123")


def _event(body, route="POST /process"):
    return {"routeKey": route, "body": body if isinstance(body, str) else json.dumps(body), "isBase64Encoded": False}


def test_miss_then_hit(env):
    first = app.handler(_event({"data": "hola mundo"}), CTX)
    second = app.handler(_event({"data": "hola mundo"}), CTX)

    assert first["statusCode"] == 200
    assert first["headers"]["X-Cache"] == "MISS"
    assert first["headers"]["X-Result-Source"] == "processed"
    assert second["headers"]["X-Cache"] == "HIT"
    assert json.loads(first["body"]) == json.loads(second["body"])


def test_result_written_to_s3_with_expected_prefix_and_ttl(env):
    response = app.handler(_event({"data": "abc"}), CTX)
    body = json.loads(response["body"])

    assert body["output"]["reversed"] == "cba"
    assert len(env.s3.objects) == 1
    key = next(iter(env.s3.objects))
    assert key.startswith("results/") and key.endswith(f"/{body['id']}.json")
    assert set(env.redis.ttls.values()) == {60}


def test_key_is_independent_of_json_key_order(env):
    app.handler(_event('{"data":"x","extra":1}'), CTX)
    second = app.handler(_event('{"extra":1,"data":"x"}'), CTX)
    assert second["headers"]["X-Cache"] == "HIT"


def test_cache_expired_is_served_from_dynamodb_without_reprocessing(env):
    app.handler(_event({"data": "persistente"}), CTX)
    env.redis.data.clear()  # simula expiracion del TTL

    response = app.handler(_event({"data": "persistente"}), CTX)
    assert response["headers"]["X-Cache"] == "MISS"
    assert response["headers"]["X-Result-Source"] == "dynamodb"
    assert len(env.s3.objects) == 1  # no se reescribio S3


def test_redis_down_degrades_gracefully(env):
    env.redis.fail = True
    response = app.handler(_event({"data": "sin cache"}), CTX)
    assert response["statusCode"] == 200
    assert response["headers"]["X-Cache"] == "MISS"


@pytest.mark.parametrize("body", ["", "no-json", "[1,2]", '{"data": ""}', '{"otro": "x"}'])
def test_invalid_input_returns_400(env, body):
    response = app.handler(_event(body), CTX)
    assert response["statusCode"] == 400
    assert response["headers"]["X-Cache"] == "MISS"
    assert json.loads(response["body"])["error"] == "BadRequest"


def test_unexpected_error_returns_500_with_descriptive_message(env):
    def boom(*_args, **_kwargs):
        raise RuntimeError("s3 caido")

    env.s3.put_object = boom
    response = app.handler(_event({"data": "falla"}), CTX)
    body = json.loads(response["body"])

    assert response["statusCode"] == 500
    assert body["error"] == "InternalServerError"
    assert "RuntimeError" in body["message"]
    assert body["requestId"] == "req-123"
    assert response["headers"]["X-Cache"] == "MISS"


def test_health_route(env):
    response = app.handler({"routeKey": "GET /health"}, CTX)
    assert response["statusCode"] == 200


def test_cache_rejects_keys_without_ttl():
    cache = Cache(enabled=True, client=FakeRedis())
    with pytest.raises(ValueError):
        cache.set("k", "v", ttl_seconds=0)
