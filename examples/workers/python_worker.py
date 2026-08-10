#!/usr/bin/env python3
"""Minimal Tarantool Jobs Queue worker using only the Python standard library."""

from __future__ import annotations

import json
import os
import random
import signal
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any


class PermanentJobError(Exception):
    """A handler error that should not be retried."""


class QueueResponseError(Exception):
    """An HTTP error returned by the queue."""

    def __init__(self, status: int, code: str, message: str) -> None:
        super().__init__(f"queue returned {status} {code}: {message}")
        self.status = status
        self.code = code


def env_number(name: str, default: float, minimum: float, maximum: float) -> float:
    raw_value = os.getenv(name)
    try:
        value = default if raw_value is None else float(raw_value)
    except ValueError as error:
        raise SystemExit(f"{name} must be a number") from error
    if not minimum <= value <= maximum:
        raise SystemExit(f"{name} must be between {minimum} and {maximum}")
    return value


BASE_URL = os.getenv("QUEUE_URL", "http://127.0.0.1:3000").rstrip("/")
TOKEN = os.getenv("QUEUE_TOKEN")
LEASE_SECONDS = env_number("WORKER_LEASE_SECONDS", 60, 0.1, 3600)
HTTP_TIMEOUT = env_number("WORKER_HTTP_TIMEOUT", 10, 0.1, 300)
POLL_MIN = env_number("WORKER_POLL_MIN_SECONDS", 0.25, 0.01, 60)
POLL_MAX = env_number("WORKER_POLL_MAX_SECONDS", 5, POLL_MIN, 300)
stopping = False


def request(
    method: str,
    path: str,
    *,
    body: dict[str, Any] | None = None,
    lease_token: str | None = None,
) -> tuple[int, dict[str, Any] | None]:
    headers = {"Accept": "application/json"}
    if TOKEN:
        headers["Authorization"] = f"Bearer {TOKEN}"
    if lease_token:
        headers["Lease-Token"] = lease_token

    encoded_body = None
    if body is not None:
        headers["Content-Type"] = "application/json"
        encoded_body = json.dumps(body).encode("utf-8")

    queue_request = urllib.request.Request(
        f"{BASE_URL}{path}",
        data=encoded_body,
        headers=headers,
        method=method,
    )
    try:
        with urllib.request.urlopen(queue_request, timeout=HTTP_TIMEOUT) as response:
            if response.status == 204:
                return response.status, None
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        try:
            response_body = json.load(error)
            details = response_body.get("error", {})
            code = str(details.get("code", "http_error"))
            message = str(details.get("message", error.reason))
        except (ValueError, AttributeError):
            code = "http_error"
            message = str(error.reason)
        raise QueueResponseError(error.code, code, message) from error


def handle_job(payload: dict[str, Any]) -> None:
    """Replace this demonstration dispatcher with application-specific work."""
    if payload.get("kind") != "echo":
        raise PermanentJobError("unsupported job kind")
    print(f"echo: {json.dumps(payload, sort_keys=True)}", flush=True)


def transition(job: dict[str, Any], action: str, body: dict[str, Any] | None = None) -> None:
    job_id = urllib.parse.quote(str(job["job_id"]), safe="")
    request(
        "POST",
        f"/jobs/{job_id}/{action}",
        body=body,
        lease_token=str(job["lease_token"]),
    )


def run_transition(
    job: dict[str, Any],
    action: str,
    body: dict[str, Any] | None = None,
) -> bool:
    try:
        transition(job, action, body)
        return True
    except QueueResponseError as error:
        if error.status != 409:
            raise
        print(
            f"lost lease for job {job.get('job_id', '<unknown>')}: {error}",
            file=sys.stderr,
            flush=True,
        )
        return False


def process(job: dict[str, Any]) -> None:
    job_id = job.get("job_id", "<unknown>")
    try:
        payload = job.get("payload")
        if not isinstance(payload, dict):
            raise PermanentJobError("payload must be an object")
        handle_job(payload)
    except PermanentJobError as error:
        message = str(error).strip() or error.__class__.__name__
        if run_transition(
            job,
            "fail",
            {"error": message[:1000], "retry": False, "retry_delay": 0},
        ):
            print(f"permanently failed job {job_id}: {error}", file=sys.stderr, flush=True)
        return
    except Exception as error:
        message = str(error).strip() or error.__class__.__name__
        retry_delay = min(300, 2 ** min(int(job.get("attempts", 1)), 8))
        if run_transition(
            job,
            "fail",
            {"error": message[:1000], "retry": True, "retry_delay": retry_delay},
        ):
            print(f"scheduled retry for job {job_id}: {error}", file=sys.stderr, flush=True)
        return

    if run_transition(job, "ack"):
        print(f"acknowledged job {job_id}", flush=True)


def stop(_signum: int, _frame: Any) -> None:
    global stopping
    stopping = True


def main() -> int:
    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    poll_delay = POLL_MIN
    connection_delay = POLL_MIN

    print(f"worker polling {BASE_URL} with a {LEASE_SECONDS:g}s lease", flush=True)
    while not stopping:
        try:
            lease = urllib.parse.urlencode({"lease": LEASE_SECONDS})
            status, job = request("POST", f"/jobs/claim?{lease}")
            connection_delay = POLL_MIN
            if status == 204 or job is None:
                time.sleep(random.uniform(POLL_MIN, poll_delay))
                poll_delay = min(POLL_MAX, poll_delay * 2)
                continue

            poll_delay = POLL_MIN
            process(job)
        except (urllib.error.URLError, TimeoutError, QueueResponseError) as error:
            print(f"queue request failed: {error}", file=sys.stderr, flush=True)
            if stopping:
                break
            time.sleep(random.uniform(POLL_MIN, connection_delay))
            connection_delay = min(POLL_MAX, connection_delay * 2)

    print("worker stopped", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
