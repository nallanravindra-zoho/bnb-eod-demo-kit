# Presenter Script — "Branch EOD Processing at Bharat National Bank" (30 min)

**SAY** = what to say · **DO** = what to click/type · **SHOW** = what the audience should notice

## Tabs to open before you start (Presenter profile)
1. Architecture slide (`docs/architecture.png`)
2. Portal URL (ALB DNS)
3. EC2 → Target Groups → `bnb-portal-tg` → Targets
4. EC2 → Auto Scaling Groups → `bnb-portal-asg` → Activity
5. S3 console (bucket list)
6. CloudWatch → Log groups (the Lambda log group appears after Act 1)
7. CodePipeline → `bnb-eod-compliance-release`
8. GitHub → `lambda/config.py` (edit view), or VS Code with the repo open
9. CloudTrail → Event history
10. GuardDuty → Findings
11. Terminal in `terraform/platform`

Separate **Auditor** browser profile, already signed in, on the S3 console.

---

## 0:00 – 2:00 · The problem
**SHOW** the architecture slide.

**SAY:** "Let me start with a problem every bank has. Bharat National Bank — a fictional bank — has 200 branches. Every evening, each branch uploads its end-of-day transaction file. The bank needs four things:
one, the upload portal must never go down;
two, files must be processed automatically, and high-value transactions flagged for compliance;
three, customer data must be encrypted, and only authorised people can see it;
four, every action must be auditable — who did what, and when.
And because this is regulated financial data, everything runs in the **Mumbai region** so the data stays in India. In the next 30 minutes we'll build and run this live, and every piece maps to a day of the training."

---

## 2:00 – 7:00 · Act 1 — Build the platform with code (IaC)
**SAY:** "First — nobody in a bank should be clicking around the console to build production. The network and portal were built yesterday with CloudFormation. Let me show you."

**DO:** CloudFormation → `bnb-branch-portal` → **Resources** tab (scroll quickly), then **Outputs**.
**SHOW:** VPC, 4 subnets across 2 AZs, NAT, ALB, ASG — all from one template.

**SAY:** "Now I'll build the processing platform live, with Terraform."

**DO (terminal):**
```bash
terraform plan
```
**SHOW:** "Plan: 18 to add" — point at `aws_kms_key`, `aws_s3_bucket`, `aws_lambda_function`.

```bash
terraform apply -auto-approve
```
**SAY while it runs (~1 min):** "Terraform is creating an encryption key, two encrypted buckets, a secret, a Lambda function with a least-privilege role, and the trigger connecting them. The same code builds dev, UAT and production identically — which is exactly what your change-control and audit teams want."

**SHOW:** "Apply complete! Resources: 18 added." Then open the S3 tab and refresh: the two new `bnb-eod-…` buckets are there.

> Day 2 (VPC), Day 3 (CloudFormation, Terraform)

---

## 7:00 – 10:00 · Act 2 — "A portal server just crashed"
**DO:** Open the **Portal URL** tab and refresh 3–4 times.
**SHOW:** the instance ID and Availability Zone change → the ALB spreads traffic across 2 AZs.

**SAY:** "It's 7 PM, branches are uploading, and a server fails. Let's make that happen."

**DO:** EC2 → Instances → select one `bnb-portal-web` → **Instance state → Terminate**.
**DO:** Refresh the portal a few times.
**SHOW:** The portal still works, now served only by the surviving instance.

**DO:** Switch to the Target Group tab → the terminated target shows **draining/unhealthy**.
**SAY:** "Auto Scaling has noticed and is already launching a replacement. We'll come back to it at the end."

> Day 1 (EC2, ALB, Auto Scaling)

---

## 10:00 – 14:00 · Act 3 — Zero-touch EOD processing
**SAY:** "Branch 0457 has just uploaded its EOD file. Twenty transactions."

**DO:** S3 → `bnb-eod-incoming-…` → create folder `eod` → **Upload** `sample-data/branch_0457_eod.csv`.
(Or in the terminal: run the `upload_command` from `terraform output`.)

**DO:** CloudWatch → Log groups → `/aws/lambda/bnb-eod-processor` → latest stream.
**SHOW:**
- `Rule in force: review transactions >= Rs 10,00,000`
- `FLAGGED BR0457-T0003 … Rs 12,50,000` and `FLAGGED BR0457-T0011 … Rs 18,00,000`
- `Fetched compliance API key from Secrets Manager (ending ****A8D4)`

**SAY:** "No one touched this file. The upload triggered a Lambda, which validated it, totalled it, and flagged the 2 high-value transactions. Notice the API key: it came from Secrets Manager. There are no passwords in the code."

**DO:** S3 → `bnb-eod-processed-…` → open `compliance-review/branch_0457_eod_review.csv`.

**SAY:** "Now a branch sends a bad file — someone exported the amounts with commas."
**DO:** Upload `branch_0457_eod_CORRUPT.csv` → open `rejected/branch_0457_eod_CORRUPT_error.json`.
**SHOW:** `"Line 4: amount '12,50,000' is not a valid number"` — the whole batch is rejected, not half-loaded.

> Day 2 (S3), Day 4 (Lambda), Day 5 (Secrets Manager)

---

## 14:00 – 16:00 · Act 4 — The compliance rule changes (CI/CD)
**SAY:** "A message from the compliance head: *'From today, review every transaction of ₹5 lakh and above.'* In many banks, this is a two-week process. Watch."

**DO:** Open `lambda/config.py` → change
```python
THRESHOLD_INR = 10_00_000
```
to
```python
THRESHOLD_INR = 5_00_000
```
Commit with the message `Lower review threshold to Rs 5 lakh per compliance` → push to `main`.

**DO:** Switch to the CodePipeline tab → a new execution starts at **Source**.
**SAY:** "The push started the pipeline. First, CodeBuild runs our unit tests — including a policy test that the threshold can never exceed ₹10 lakh. Let's do something else while it runs."

> Day 4 (CodePipeline, CodeBuild)

---

## 16:00 – 22:00 · Act 5 — Security in action
**① Encryption (KMS)**
**DO:** S3 → processed bucket → any object → **Properties → Server-side encryption**.
**SHOW:** `SSE-KMS` with the `bnb-eod-data` key. "Every file is encrypted with the bank's own key, and that key is rotated automatically."

**② Least privilege (IAM)**
**SAY:** "Now I'm the branch auditor. I should be able to read the reports, and nothing else."
**DO (Auditor profile):** S3 → `bnb-eod-processed-…` → open a summary file → ✅ it works.
**DO:** S3 → `bnb-eod-incoming-…` → ❌ **AccessDenied**. Try deleting a processed file → ❌ denied.
**SAY:** "The auditor can see the reports but not the raw customer data, and can't delete anything. That's least privilege, enforced by IAM, not by trust."

**③ Maker-checker (back in the pipeline)**
**DO:** CodePipeline tab → the **Change-Approval** stage is now waiting. Open the **Unit-Tests** details first → show all tests **OK**.
**SAY:** "Tests passed, but nothing goes to production without approval. I'm the checker." → **Review → Approve** with the comment `Approved – CR-2026-1029`.

**④ Audit trail (CloudTrail)**
**DO:** CloudTrail → Event history → filter **Event name = TerminateInstances**.
**SHOW:** Who terminated the server in Act 2, from which IP, at what time.
**SAY:** "When the RBI auditor asks 'who touched production?', this is the answer — and nobody can edit it."

**⑤ Threat detection (GuardDuty)**
**DO:** GuardDuty → **Settings → Generate sample findings** → Findings → open a high-severity one (an S3 or IAM finding works best).
**SAY:** "GuardDuty continuously analyses account activity. Here it's flagging credentials being used from a suspicious IP — the kind of alert the bank's SOC would act on."

> Day 1 (IAM), Day 5 (KMS, CloudTrail, GuardDuty)

---

## 22:00 – 25:00 · Back to the pipeline — the new rule is live
**DO:** CodePipeline → all 4 stages are **green**.
**DO:** Re-upload the **same** `branch_0457_eod.csv` → open the newest CloudWatch log stream.
**SHOW:** `Rule in force: review transactions >= Rs 5,00,000` → **5 FLAGGED** (previously 2).

**SAY:** "Same file, new rule. From the compliance request to production took about 5 minutes — tested, approved, and recorded."

**Optional (if ahead of time, or play the backup video):** change to `50_00_000` → push → **Unit-Tests fails** with `POLICY VIOLATION: review threshold Rs 50,00,000 must be between Rs 1 and Rs 10,00,000` → "A bad change can never reach production." *(Revert it afterwards.)*

---

## 25:00 – 27:00 · Back to the crashed server
**DO:** ASG → **Activity** tab → "Launching a new EC2 instance … in response to an unhealthy/terminated instance".
**DO:** Target group → **2 healthy** targets. Refresh the portal → a **new instance ID** appears.
**SAY:** "The server we killed 15 minutes ago was replaced automatically, and the branches never saw an outage."

**Optional:** CloudTrail → filter `PutApprovalResult` or `UpdateFunctionCode` → "and here's who approved and deployed the rule change." *(Events can take a few minutes to appear.)*

---

## 27:00 – 30:00 · Recap & Q&A
**SAY / SHOW (recap slide):**

| What you saw | Training day |
|---|---|
| IAM users, roles, least privilege, auditor AccessDenied | Day 1 |
| EC2, ALB, Auto Scaling — self-healing portal | Day 1 |
| S3, custom VPC across 2 AZs, DR to Hyderabad (CRR) | Day 2 |
| CloudFormation + Terraform — the whole platform as code | Day 3 |
| CodePipeline, CodeBuild, Lambda — tested, approved releases | Day 4 |
| KMS, Secrets Manager, CloudTrail, GuardDuty | Day 5 |

**SAY:** "Everything you saw today, your team will build hands-on during the 5 days — and they'll leave with code they can reuse in their own projects."

---

## If something goes wrong
| Problem | Recovery |
|---|---|
| `terraform apply` is slow or fails | Say "this is why we rehearse," and switch to the pre-recorded clip, or apply again (it's idempotent) |
| No log stream after the upload | Check the file name ends in `.csv` and that it went to the **incoming** bucket; wait 10 s and refresh |
| Pipeline didn't start on push | CodePipeline → **Release change** |
| Approval stage not reached yet in Act 5 | Do CloudTrail/GuardDuty first, then approve |
| ASG replacement still launching at 25:00 | Show the Activity tab "in progress" and come back after Q&A |
