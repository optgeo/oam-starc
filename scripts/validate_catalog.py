#!/usr/bin/env python3
"""Validate STAC items embedded in the OAM-STARC catalog.

Uses stac-validator (https://github.com/stac-utils/stac-validator) to check
each STAC Item in docs/catalog.json against the STAC 1.0.0 specification and
any declared extensions.

Usage:
    python scripts/validate_catalog.py [path/to/catalog.json]

Exit codes:
    0 — all items passed validation
    1 — one or more items failed validation
    2 — the catalog file could not be read or parsed
"""

import json
import os
import sys
import tempfile

MAX_ERROR_MESSAGE_LENGTH = 200


def load_catalog(catalog_path: str) -> dict:
    try:
        with open(catalog_path, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        print(f"ERROR: Catalog file not found: {catalog_path}", file=sys.stderr)
        sys.exit(2)
    except json.JSONDecodeError as e:
        print(f"ERROR: Failed to parse catalog JSON: {e}", file=sys.stderr)
        sys.exit(2)


def validate_item_with_stac_validator(item_dict: dict) -> list[dict]:
    """Validate a single STAC Item dict using stac-validator.

    Returns the list of stac-validator message dicts.
    """
    try:
        from stac_validator import stac_validator  # type: ignore
    except ImportError:
        print(
            "ERROR: stac-validator is not installed. Run: pip install stac-validator",
            file=sys.stderr,
        )
        sys.exit(2)

    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".json", delete=False, encoding="utf-8"
    ) as tmp:
        json.dump(item_dict, tmp)
        tmp_path = tmp.name

    try:
        sv = stac_validator.StacValidate(tmp_path)
        sv.run()
        return sv.message
    finally:
        os.unlink(tmp_path)


def format_error(item_id: str, message: dict) -> str:
    lines = [f"  Item '{item_id}':"]
    lines.append(f"    valid_stac : {message.get('valid_stac')}")
    lines.append(f"    schema     : {message.get('schema', [])}")
    error_type = message.get("error_type", "")
    error_msg = message.get("error_message", "")
    if error_type:
        lines.append(f"    error_type : {error_type}")
    if error_msg:
        if len(error_msg) > MAX_ERROR_MESSAGE_LENGTH:
            error_msg = error_msg[:MAX_ERROR_MESSAGE_LENGTH] + "..."
        lines.append(f"    error      : {error_msg}")
    return "\n".join(lines)


def main() -> None:
    catalog_path = sys.argv[1] if len(sys.argv) > 1 else "docs/catalog.json"
    catalog = load_catalog(catalog_path)

    items = catalog.get("items", [])
    if not items:
        print("WARNING: No items found in catalog.")
        return

    print(f"Validating {len(items)} STAC items from {catalog_path} ...")

    errors: list[str] = []
    connection_errors = 0

    for i, item_dict in enumerate(items):
        item_id = item_dict.get("id", f"item[{i}]")
        messages = validate_item_with_stac_validator(item_dict)

        for msg in messages:
            if msg.get("valid_stac"):
                continue
            error_type = msg.get("error_type", "")
            # Network errors are reported separately; they do not mean the item
            # is structurally invalid.
            if error_type == "ConnectionError":
                connection_errors += 1
                continue
            errors.append(format_error(item_id, msg))

    print()
    if connection_errors:
        print(
            f"NOTE: {connection_errors} item(s) could not be schema-validated due to "
            "network connectivity issues (schema URLs unreachable). "
            "Run in an environment with internet access for full schema validation."
        )

    if errors:
        print(f"FAILED: {len(errors)} item(s) did not pass STAC validation:\n")
        for err in errors:
            print(err)
        sys.exit(1)
    elif connection_errors and not errors:
        print(
            f"PARTIAL: {len(items)} items parsed successfully; "
            f"{connection_errors} could not be schema-validated (network unavailable)."
        )
    else:
        print(f"OK: All {len(items)} items passed STAC validation.")


if __name__ == "__main__":
    main()
