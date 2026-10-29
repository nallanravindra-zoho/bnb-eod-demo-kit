"""
Unit tests run by CodeBuild before any deployment.
If any test fails, the pipeline stops and production is untouched.
Run locally:  PYTHONPATH=lambda python3 -m unittest discover -s tests -v
"""
import os
import unittest

from config import THRESHOLD_INR
from processor import FileRejected, evaluate_eod_file, format_inr

HEADER = "txn_id,branch_code,account_no,customer_name,txn_type,channel,amount_inr,txn_timestamp\n"
POLICY_CEILING_INR = 10_00_000  # internal policy: review threshold can never exceed Rs 10 lakh


def row(txn_id, amount, txn_type="CREDIT"):
    return f"{txn_id},BR0457,XXXXXX1234,Test Customer,{txn_type},BRANCH,{amount},2026-10-28T11:00:00\n"


class TestCompliancePolicy(unittest.TestCase):
    def test_threshold_within_policy(self):
        self.assertTrue(
            0 < THRESHOLD_INR <= POLICY_CEILING_INR,
            f"POLICY VIOLATION: review threshold {format_inr(THRESHOLD_INR)} "
            f"must be between Rs 1 and {format_inr(POLICY_CEILING_INR)}",
        )


class TestHighValueRule(unittest.TestCase):
    def test_txn_at_threshold_is_flagged(self):
        _, flagged = evaluate_eod_file(HEADER + row("T1", THRESHOLD_INR), THRESHOLD_INR)
        self.assertEqual(len(flagged), 1)

    def test_txn_below_threshold_is_not_flagged(self):
        _, flagged = evaluate_eod_file(HEADER + row("T1", THRESHOLD_INR - 1), THRESHOLD_INR)
        self.assertEqual(len(flagged), 0)

    def test_totals_are_correct(self):
        text = HEADER + row("T1", 1000) + row("T2", 2500) + row("T3", 700, "DEBIT")
        summary, _ = evaluate_eod_file(text, THRESHOLD_INR)
        self.assertEqual(summary["txn_count"], 3)
        self.assertEqual(summary["total_credit_inr"], "3500")
        self.assertEqual(summary["total_debit_inr"], "700")


class TestFileValidation(unittest.TestCase):
    def test_bad_header_rejected(self):
        with self.assertRaises(FileRejected):
            evaluate_eod_file("id,amount\n1,100\n", THRESHOLD_INR)

    def test_non_numeric_amount_rejected(self):
        text = HEADER + 'T1,BR0457,XXXXXX1234,Test,CREDIT,BRANCH,"12,50,000",2026-10-28T11:00:00\n'
        with self.assertRaises(FileRejected):
            evaluate_eod_file(text, THRESHOLD_INR)

    def test_empty_file_rejected(self):
        with self.assertRaises(FileRejected):
            evaluate_eod_file(HEADER, THRESHOLD_INR)

    def test_sample_files(self):
        here = os.path.join(os.path.dirname(__file__), "..", "sample-data")
        with open(os.path.join(here, "branch_0457_eod.csv")) as f:
            summary, _ = evaluate_eod_file(f.read(), THRESHOLD_INR)
        self.assertEqual(summary["txn_count"], 20)
        with open(os.path.join(here, "branch_0457_eod_CORRUPT.csv")) as f:
            with self.assertRaises(FileRejected):
                evaluate_eod_file(f.read(), THRESHOLD_INR)


class TestFormatting(unittest.TestCase):
    def test_indian_grouping(self):
        self.assertEqual(format_inr(1250000), "Rs 12,50,000")
        self.assertEqual(format_inr(500), "Rs 500")
        self.assertEqual(format_inr(123456789), "Rs 12,34,56,789")


if __name__ == "__main__":
    unittest.main()
