#!/usr/bin/env python3
"""Fail-closed validation for GitHub workflow-run artifact provenance."""

from __future__ import annotations

import argparse
import re
import sys

from release_common import ReleaseError, fail, parse_json


MAX_RESPONSE_BYTES = 1024 * 1024
REPOSITORY_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
WORKFLOW_RE = re.compile(r"^\.github/workflows/[A-Za-z0-9_.-]+\.ya?ml$")
REVISION_RE = re.compile(r"^(?:[0-9a-f]{40}|[0-9a-f]{64})$")


def object_field(document: dict, name: str) -> dict:
    value = document.get(name)
    if not isinstance(value, dict):
        fail(f"workflow run: {name} must be an object")
    return value


def validate_run(
    document: dict,
    repository: str,
    revision: str,
    run_id: int,
    sources: dict[str, set[str]],
) -> str:
    if not isinstance(document, dict):
        fail("workflow run: API response must be an object")
    if type(document.get("id")) is not int or document["id"] != run_id:
        fail("workflow run: ID does not match requested run")
    if type(document.get("run_attempt")) is not int or document["run_attempt"] != 1:
        fail("workflow run: rerun attempts are not accepted")
    if document.get("status") != "completed":
        fail("workflow run: run is not completed")
    if document.get("conclusion") != "success":
        fail("workflow run: conclusion is not success")
    if document.get("head_sha") != revision:
        fail("workflow run: candidate revision does not match")
    source = object_field(document, "repository").get("full_name")
    head_source = object_field(document, "head_repository").get("full_name")
    if not isinstance(source, str) or source.casefold() != repository.casefold():
        fail("workflow run: repository does not match")
    if not isinstance(head_source, str) or head_source.casefold() != repository.casefold():
        fail("workflow run: head repository does not match")

    path = document.get("path")
    if not isinstance(path, str):
        fail("workflow run: path must be a string")
    workflow = path.split("@", 1)[0]
    if workflow not in sources:
        fail("workflow run: workflow path is not allowed")
    if document.get("event") not in sources[workflow]:
        fail("workflow run: workflow/event pair is not allowed")
    return workflow


def parse_sources(values: list[str]) -> dict[str, set[str]]:
    sources: dict[str, set[str]] = {}
    seen: set[tuple[str, str]] = set()
    for value in values:
        if value.count("=") != 1:
            fail("workflow run: source must be WORKFLOW=EVENT")
        workflow, event = value.split("=", 1)
        if not WORKFLOW_RE.fullmatch(workflow):
            fail("workflow run: invalid allowed workflow path")
        if not re.fullmatch(r"[a-z_]+", event):
            fail("workflow run: invalid allowed event")
        pair = (workflow, event)
        if pair in seen:
            fail("workflow run: duplicate allowed source")
        seen.add(pair)
        sources.setdefault(workflow, set()).add(event)
    return sources


def read_document() -> dict:
    data = sys.stdin.buffer.read(MAX_RESPONSE_BYTES + 1)
    if len(data) > MAX_RESPONSE_BYTES:
        fail("workflow run: API response exceeds 1 MiB")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        fail("workflow run: API response is not UTF-8")
    return parse_json(text, "workflow run API response")


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository", required=True)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--source", action="append", required=True)
    arguments = parser.parse_args()
    if not REPOSITORY_RE.fullmatch(arguments.repository):
        fail("workflow run: invalid repository name")
    if not REVISION_RE.fullmatch(arguments.revision):
        fail("workflow run: revision must be a full lowercase commit SHA")
    if not arguments.run_id.isdecimal() or len(arguments.run_id) > 19:
        fail("workflow run: run ID must be a positive decimal integer")
    arguments.run_id = int(arguments.run_id)
    if arguments.run_id == 0:
        fail("workflow run: run ID must be a positive decimal integer")
    arguments.sources = parse_sources(arguments.source)
    return arguments


def main() -> int:
    try:
        arguments = parse_arguments()
        workflow = validate_run(
            read_document(),
            arguments.repository,
            arguments.revision,
            arguments.run_id,
            arguments.sources,
        )
        print(workflow)
    except ReleaseError as error:
        print(f"workflow run verification failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
