"""
Compliance rule configuration for the Branch EOD processor.

DEMO NOTE: This is the ONE line you change live in Act 4.
Python allows underscores in numbers, so Indian digit grouping works:
    10_00_000  -> Rs 10 lakh  (starting value)
     5_00_000  -> Rs 5 lakh   (the "compliance rule change")
    50_00_000  -> Rs 50 lakh  (the "bad change" - unit tests will block it)
"""

# Transactions at or above this amount (INR) are sent for compliance review.
THRESHOLD_INR = 10_00_000
