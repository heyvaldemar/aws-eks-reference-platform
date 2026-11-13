#!/usr/bin/env python3
"""aws-bill-days.py [days]

The account's bill for each of the last DAYS days (default 30), before
credits, as Cost Explorer holds it now. The sweeper's "Yesterday's bill" is
read the next day, and Cost Explorer can still add to a day after that: a
day read again a week later is the settled number. Then what "EC2 - Other"
was made of on each day it passed $0.05, by usage type (NAT gateway hours
and bytes, data transfer, volumes), since a run's own estimate counts some
of it and not the rest. Every repository that runs in the account is in it.
Written as Markdown to stdout.

Never fails the job: a lookup that fails is named instead.
"""
import datetime as dt
import json
import subprocess
import sys

NOT_CREDITS = {"Not": {"Dimensions": {"Key": "RECORD_TYPE", "Values": ["Credit", "Refund"]}}}
EC2_OTHER = "EC2 - Other"
COLUMNS = [
    (EC2_OTHER, "EC2 - Other"),
    ("Amazon Elastic Compute Cloud - Compute", "EC2"),
    ("Amazon Elastic Container Service for Kubernetes", "EKS"),
    ("Amazon Virtual Private Cloud", "VPC"),
    ("Amazon Elastic Load Balancing", "ELB"),
]


def ce(start, end, group, flt):
    """(day, key, dollars) for every group of every day, across pages."""
    rows, token = [], None
    while True:
        cmd = ["aws", "ce", "get-cost-and-usage", "--time-period", f"Start={start},End={end}",
               "--granularity", "DAILY", "--metrics", "UnblendedCost",
               "--group-by", f"Type=DIMENSION,Key={group}", "--filter", json.dumps(flt), "--output", "json"]
        if token:
            cmd += ["--next-page-token", token]
        out = subprocess.run(cmd, capture_output=True, text=True)
        if out.returncode != 0:
            raise RuntimeError(out.stderr.strip()[:200])
        doc = json.loads(out.stdout or "{}")
        for period in doc.get("ResultsByTime", []):
            day = period["TimePeriod"]["Start"]
            for g in period.get("Groups", []):
                rows.append((day, g["Keys"][0], float(g["Metrics"]["UnblendedCost"]["Amount"])))
        token = doc.get("NextPageToken")
        if not token:
            return rows


def main():
    days = int(sys.argv[1]) if len(sys.argv) > 1 else 30
    end = dt.datetime.now(dt.timezone.utc).date()
    start = end - dt.timedelta(days=days)
    print(f"### The last {days} days, as the bill stands now, before credits", "", sep="\n")
    try:
        rows = ce(start, end, "SERVICE", NOT_CREDITS)
    except (RuntimeError, ValueError, KeyError) as err:
        print(f"The Cost Explorer lookup failed: {err}")
        return
    by_day = {}
    for day, service, dollars in rows:
        by_day.setdefault(day, {}).setdefault(service, 0.0)
        by_day[day][service] += dollars
    print("| Day | " + " | ".join(label for _, label in COLUMNS) + " | Other | Total |")
    print("|---|" + "---:|" * (len(COLUMNS) + 2))
    for day in sorted(by_day):
        services = by_day[day]
        total = sum(services.values())
        listed = [services.get(name, 0.0) for name, _ in COLUMNS]
        cells = [f"${v:.2f}" for v in listed] + [f"${total - sum(listed):.2f}", f"**${total:.2f}**"]
        print(f"| {day} | " + " | ".join(cells) + " |")

    busy = sorted(d for d, s in by_day.items() if s.get(EC2_OTHER, 0.0) > 0.05)
    if not busy:
        return
    print("", f"#### {EC2_OTHER} by usage type, on the days it passed $0.05", "", sep="\n")
    try:
        usage = ce(start, end, "USAGE_TYPE",
                   {"And": [NOT_CREDITS, {"Dimensions": {"Key": "SERVICE", "Values": [EC2_OTHER]}}]})
    except (RuntimeError, ValueError, KeyError) as err:
        print(f"The Cost Explorer lookup failed: {err}")
        return
    print("| Day | Usage type | Cost |", "|---|---|---:|", sep="\n")
    for day, kind, dollars in sorted(usage):
        if day in busy and dollars > 0.005:
            print(f"| {day} | {kind} | ${dollars:.2f} |")


if __name__ == "__main__":
    main()
