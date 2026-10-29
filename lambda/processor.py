"""
Pure business logic for Branch End-of-Day (EOD) transaction files.
No AWS calls here, so it can be unit-tested in CodeBuild in seconds.
"""
import csv
import io
from decimal import Decimal, InvalidOperation

EXPECTED_COLUMNS = [
    "txn_id",
    "branch_code",
    "account_no",
    "customer_name",
    "txn_type",
    "channel",
    "amount_inr",
    "txn_timestamp",
]
VALID_TXN_TYPES = {"CREDIT", "DEBIT"}


class FileRejected(Exception):
    """Raised when an EOD file fails validation. The whole file is rejected."""


def format_inr(amount):
    """Format a number with Indian digit grouping, e.g. 1250000 -> 'Rs 12,50,000'."""
    n = int(Decimal(amount))
    sign = "-" if n < 0 else ""
    s = str(abs(n))
    if len(s) > 3:
        head, tail = s[:-3], s[-3:]
        groups = []
        while len(head) > 2:
            groups.insert(0, head[-2:])
            head = head[:-2]
        if head:
            groups.insert(0, head)
        s = ",".join(groups) + "," + tail
    return f"{sign}Rs {s}"


def evaluate_eod_file(csv_text, threshold_inr):
    """
    Validate an EOD file and apply the high-value review rule.

    Returns (summary: dict, flagged: list[dict]).
    Raises FileRejected if the file is malformed (all-or-nothing, like a bank batch).
    """
    threshold = Decimal(threshold_inr)
    reader = csv.DictReader(io.StringIO(csv_text.lstrip("﻿")))

    header = [h.strip() for h in (reader.fieldnames or [])]
    if header != EXPECTED_COLUMNS:
        raise FileRejected(
            f"Header mismatch. Expected {EXPECTED_COLUMNS}, got {header}"
        )

    txn_count = 0
    total_credit = Decimal(0)
    total_debit = Decimal(0)
    flagged = []
    branches = set()

    for line_no, row in enumerate(reader, start=2):
        if None in row or any(v is None for v in row.values()):
            raise FileRejected(f"Line {line_no}: wrong number of columns")

        raw_amount = row["amount_inr"].strip()
        try:
            amount = Decimal(raw_amount)
        except InvalidOperation:
            raise FileRejected(
                f"Line {line_no}: amount '{raw_amount}' is not a valid number"
            )
        if amount <= 0:
            raise FileRejected(f"Line {line_no}: amount must be positive")

        txn_type = row["txn_type"].strip().upper()
        if txn_type not in VALID_TXN_TYPES:
            raise FileRejected(f"Line {line_no}: unknown txn_type '{txn_type}'")

        txn_count += 1
        branches.add(row["branch_code"].strip())
        if txn_type == "CREDIT":
            total_credit += amount
        else:
            total_debit += amount

        if amount >= threshold:
            flagged.append(
                {
                    "txn_id": row["txn_id"].strip(),
                    "account_no": row["account_no"].strip(),
                    "customer_name": row["customer_name"].strip(),
                    "txn_type": txn_type,
                    "channel": row["channel"].strip(),
                    "amount_inr": str(amount),
                    "txn_timestamp": row["txn_timestamp"].strip(),
                }
            )

    if txn_count == 0:
        raise FileRejected("File contains no transactions")
    if len(branches) != 1:
        raise FileRejected(f"File mixes branches: {sorted(branches)}")

    summary = {
        "branch_code": branches.pop(),
        "txn_count": txn_count,
        "total_credit_inr": str(total_credit),
        "total_debit_inr": str(total_debit),
        "review_threshold_inr": str(threshold),
        "review_threshold_display": format_inr(threshold),
        "high_value_count": len(flagged),
        "high_value_total_inr": str(sum((Decimal(f["amount_inr"]) for f in flagged), Decimal(0))),
    }
    return summary, flagged
