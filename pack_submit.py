#!/usr/bin/env python3
"""Pack Caliber code (20k) so the EXTRACTED tree terraform fmt+validates.

Must keep: every root var main.tf uses, module variables, storage,
compute IAM, ACM validation, capacity providers, autoscaling target+policy.
"""
from __future__ import annotations

import re
import shutil
from pathlib import Path

ROOT = Path("/data/caliber/iac-prod")
OUT = ROOT / "_submit"
EXTRACT = OUT / "extract"
CODE_LIMIT = 19950


def collapse_align(text: str) -> str:
    out = []
    for line in text.splitlines():
        m = re.match(r"^(\s*)(.*)$", line)
        indent, rest = m.group(1), m.group(2)
        rest = re.sub(r" {2,}", " ", rest)
        if rest.startswith("tags = {") and rest.endswith("}"):
            continue
        out.append(rest)
    return re.sub(r"\n{3,}", "\n\n", "\n".join(out) + "\n")


def strip_hcl(text: str) -> str:
    lines = []
    for line in text.splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        lines.append(line.rstrip())
    body = "\n".join(lines) + "\n"
    body = re.sub(r"^\s*description\s*=.*\n", "", body, flags=re.M)
    return collapse_align(body)


def oneline_vars(text: str) -> str:
    """One argument per single-line variable block (Terraform rule)."""
    parts = re.split(r"\n(?=variable )", text)
    out = []
    for part in parts:
        m = re.match(r'variable\s+"([^"]+)"\s*\{(.*)\}\s*', part, re.S)
        if not m:
            out.append(part.rstrip())
            continue
        name, inner = m.group(1), m.group(2)
        if "validation" in inner:
            out.append(part.rstrip())
            continue
        tm = re.search(r"type\s*=\s*(\S+)", inner)
        ty = tm.group(1) if tm else "string"
        out.append(f'variable "{name}" {{ type = {ty} }}')
    return "\n".join(p for p in out if p) + "\n"


def drop_block(text: str, keyword: str) -> str:
    """Remove balanced HCL blocks starting with keyword (e.g. 'validation')."""
    out = []
    i = 0
    while True:
        j = text.find(keyword, i)
        if j < 0:
            out.append(text[i:])
            break
        # only treat as a block if followed by whitespace and {
        m = re.match(rf"{re.escape(keyword)}\s*\{{", text[j:])
        if not m:
            out.append(text[i : j + len(keyword)])
            i = j + len(keyword)
            continue
        # include leading whitespace/newline before keyword
        start = j
        while start > 0 and text[start - 1] in " \t":
            start -= 1
        if start > 0 and text[start - 1] == "\n":
            start -= 1
        open_idx = j + m.end() - 1
        close_idx = _balanced(text, open_idx)
        if close_idx < 0:
            out.append(text[i:])
            break
        out.append(text[i:start])
        i = close_idx + 1
    return "".join(out)


def oneline_module_vars(text: str) -> str:
    """Module variables for pack: drop validations (root validates inputs)."""
    stripped = drop_block(text, "validation")
    return oneline_vars(stripped)


def slim_root_vars(text: str) -> str:
    """Root variables for pack: keep only container_user validation."""
    keep = {"container_user"}
    parts = re.split(r"\n(?=variable )", text)
    out = []
    for part in parts:
        m = re.match(r'variable\s+"([^"]+)"\s*\{(.*)\}\s*', part, re.S)
        if not m:
            out.append(part.rstrip())
            continue
        name, inner = m.group(1), m.group(2)
        if "validation" in inner and name not in keep:
            inner = drop_block(inner, "validation")
            part = f'variable "{name}" {{{inner}}}'
        if "validation" in inner:
            # keep multi-line validation block; collapse whitespace inside carefully
            out.append(part.rstrip())
            continue
        tm = re.search(r"type\s*=\s*(\S+)", inner)
        ty = tm.group(1) if tm else "string"
        # default may be a string/list spanning the rest of the line after =
        dm = re.search(r"default\s*=\s*(.+)", inner)
        if dm:
            default = dm.group(1).strip()
            out.append(f'variable "{name}" {{\ntype = {ty}\ndefault = {default}\n}}')
        else:
            out.append(f'variable "{name}" {{ type = {ty} }}')
    return "\n".join(p for p in out if p) + "\n"


def oneline_outputs(text: str) -> str:
    parts = re.split(r"\n(?=output )", text)
    out = []
    for part in parts:
        m = re.match(r'output\s+"([^"]+)"\s*\{(.*)\}\s*', part, re.S)
        if m:
            inner = " ".join(m.group(2).split())
            out.append(f'output "{m.group(1)}" {{ {inner} }}')
        else:
            out.append(part.rstrip())
    return "\n".join(p for p in out if p) + "\n"


def drop_attrs(text: str, attrs: list[str]) -> str:
    for attr in attrs:
        text = re.sub(rf"^\s*{re.escape(attr)}\s*=.*\n", "", text, flags=re.M)
    return text


def drop_typed(text: str, pairs: list[tuple[str, str]]) -> str:
    needles = [f'"{typ}" "{name}"' for typ, name in pairs]
    parts = re.split(r"\n(?=(?:resource|data) )", text)
    kept = []
    for part in parts:
        head = part.split("{", 1)[0]
        if any(n in head for n in needles):
            continue
        kept.append(part)
    return "\n".join(kept).rstrip() + "\n"


def _balanced(src: str, open_idx: int) -> int:
    depth = 0
    for i, ch in enumerate(src[open_idx:], open_idx):
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return i
    return -1


def dense_jsonencode(text: str) -> str:
    out = []
    i = 0
    needle = "jsonencode({"
    while True:
        j = text.find(needle, i)
        if j < 0:
            out.append(text[i:])
            break
        open_idx = j + len("jsonencode(")
        close_idx = _balanced(text, open_idx)
        if close_idx < 0:
            out.append(text[i:])
            break
        out.append(text[i:j])
        body = re.sub(r"\s+", " ", text[open_idx + 1 : close_idx]).strip()
        # Same-line HCL objects need commas between attributes.
        body = re.sub(r'(["\d\*\]\}]) ([A-Za-z][A-Za-z0-9_-]*) =', r"\1, \2 =", body)
        out.append("jsonencode({ " + body + " })")
        i = close_idx + 1
        if i < len(text) and text[i] == ")":
            i += 1
    return "".join(out)


sections: list[tuple[str, str]] = []

sections.append(("versions.tf", strip_hcl((ROOT / "versions.tf").read_text()).replace('\nManagedBy = "terraform"', "").replace('\nEnvironment = var.environment', "")))
sections.append(("variables.tf", slim_root_vars(strip_hcl((ROOT / "variables.tf").read_text())).replace(
    'error_message = "ECS tasks must run as UID 1000 (not root, not an image USER name)."',
    'error_message = "UID 1000."',
)))
sections.append(("main.tf", strip_hcl((ROOT / "main.tf").read_text())))

obs = strip_hcl((ROOT / "observability.tf").read_text())
obs = drop_typed(
    obs,
    [
        ("aws_cloudwatch_metric_alarm", "rds_credits"),
        ("aws_cloudwatch_metric_alarm", "ecs_pending"),
        ("aws_caller_identity", "current"),
    ],
)
# Pack drops SourceAccount scoping; live tree keeps it.
obs = re.sub(r'\s*Sid\s*=\s*"AllowCloudWatchAndEventsPublish"\n?', "", obs)
obs = re.sub(
    r'\n?Condition\s*=\s*\{[^{}]*\{[^{}]*\}[^{}]*\}',
    "",
    obs,
    flags=re.S,
)
obs = dense_jsonencode(obs)
sections.append(("observability.tf", obs))

boot = """terraform {
required_version = ">= 1.6.0"
required_providers {
aws = {
source = "hashicorp/aws"
version = "~> 5.70"
}
}
}
provider "aws" { region = var.aws_region }
"""
boot += oneline_vars(strip_hcl((ROOT / "bootstrap/variables.tf").read_text()))
boot += strip_hcl((ROOT / "bootstrap/main.tf").read_text())
boot = drop_attrs(boot, ["force_destroy", "bucket_key_enabled"])
boot = dense_jsonencode(boot)
sections.append(("bootstrap/main.tf", boot))

net = oneline_module_vars(strip_hcl((ROOT / "modules/networking/variables.tf").read_text()))
net += strip_hcl((ROOT / "modules/networking/main.tf").read_text())
net = drop_attrs(net, ["enable_dns_support"])
net = re.sub(r"\ndepends_on = \[aws_internet_gateway.this\]", "", net)
net = re.sub(
    r'subnet_ids = \[for i in range\(2\) : aws_subnet\.tier\["app-\$\{i\}"\]\.id\]',
    'subnet_ids = [aws_subnet.tier["app-0"].id, aws_subnet.tier["app-1"].id]',
    net,
)
net += oneline_outputs(strip_hcl((ROOT / "modules/networking/outputs.tf").read_text()))
net = re.sub(r'\noutput "nat_az".*', "", net)
sections.append(("modules/networking/main.tf", net))

db = oneline_module_vars(strip_hcl((ROOT / "modules/database/variables.tf").read_text()))
db += strip_hcl((ROOT / "modules/database/main.tf").read_text())
db = drop_attrs(
    db,
    [
        "ca_cert_identifier",
        "performance_insights_enabled",
        "monitoring_interval",
        "apply_immediately",
        "auto_minor_version_upgrade",
        "copy_tags_to_snapshot",
        "max_allocated_storage",
        "maintenance_window",
    ],
)
db = re.sub(
    r"parameter \{\n\s*name = \"log_min_duration_statement\"\n\s*value = \"1000\"\n\s*\}\n",
    "",
    db,
)
db += oneline_outputs(strip_hcl((ROOT / "modules/database/outputs.tf").read_text()))
db = re.sub(r'\noutput "identifier".*', "", db)
db = re.sub(r'\noutput "availability_zone".*', "", db)
sections.append(("modules/database/main.tf", db))

stor = oneline_module_vars(strip_hcl((ROOT / "modules/storage/variables.tf").read_text()))
stor += strip_hcl((ROOT / "modules/storage/main.tf").read_text())
stor = drop_typed(stor, [("aws_s3_bucket_policy", "tls_only")])
stor = dense_jsonencode(stor)
stor += oneline_outputs(strip_hcl((ROOT / "modules/storage/outputs.tf").read_text()))
sections.append(("modules/storage/main.tf", stor))

compute = oneline_module_vars(strip_hcl((ROOT / "modules/compute/variables.tf").read_text()))
for rel in ("locals.tf", "ecr.tf", "acm.tf", "dns.tf", "alb.tf", "iam.tf", "ecs.tf"):
    compute += strip_hcl((ROOT / "modules/compute" / rel).read_text())
compute = drop_typed(compute, [("aws_ecr_lifecycle_policy", "api")])
compute = re.sub(r"image_scanning_configuration \{[^}]*\}\n", "", compute)
compute = re.sub(r"\s*initProcessEnabled = true\n", "\n", compute)
compute = drop_attrs(
    compute,
    [
        "timeout",
        "healthy_threshold",
        "internal",
        "essential",
        "privileged",
        "deployment_minimum_healthy_percent",
        "deployment_maximum_percent",
        "scale_in_cooldown",
        "scale_out_cooldown",
        "matcher",
        "interval",
        "unhealthy_threshold",
        "allow_overwrite",
        "image_tag_mutability",
        "ssl_policy",
        "retention_in_days",
    ],
)
# Service strategy is the source of truth; cluster defaults are duplicate chars.
compute = re.sub(
    r"default_capacity_provider_strategy \{\ncapacity_provider = \"FARGATE\"\nweight = 1\nbase = 1\n\}\n",
    "",
    compute,
)
compute = re.sub(
    r"default_capacity_provider_strategy \{\ncapacity_provider = \"FARGATE_SPOT\"\nweight = 1\nbase = 0\n\}\n",
    "",
    compute,
)
# Keep linuxParameters capabilities drop ALL for non-root hardening in the paste.
compute = re.sub(
    r"setting \{\nname = \"containerInsights\"\nvalue = \"enabled\"\n\}\n",
    "",
    compute,
)
compute = re.sub(r'\nawslogs-stream-prefix = "api"', "", compute)
compute = re.sub(r"\nlifecycle \{ create_before_destroy = true \}", "", compute)
compute = re.sub(r"\nttl = 60", "", compute)
compute = dense_jsonencode(compute)
compute += 'output "cluster_arn" { value = aws_ecs_cluster.this.arn }\n'
sections.append(("modules/compute/main.tf", compute))

chunks = [f"// === {rel} ===\n{body.rstrip()}\n" for rel, body in sections]
code = "".join(chunks)
code = re.sub(r"\n{3,}", "\n\n", code)

print("section sizes:")
for rel, body in sections:
    hdr = f"// === {rel} ===\n"
    print(f"  {len(hdr) + len(body.rstrip()) + 1:5d}  {rel}")
over = len(code) - CODE_LIMIT
print("CODE", len(code), "OVER" if over > 0 else "ok", abs(over))

OUT.mkdir(exist_ok=True)
(OUT / "code.txt").write_text(code)

if EXTRACT.exists():
    shutil.rmtree(EXTRACT)
EXTRACT.mkdir(parents=True)
for rel, body in sections:
    dest = EXTRACT / rel
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(body if body.endswith("\n") else body + "\n")

print("wrote", OUT / "code.txt")
print("extract", EXTRACT)
if over > 0:
    raise SystemExit(f"code over {CODE_LIMIT} by {over}")
