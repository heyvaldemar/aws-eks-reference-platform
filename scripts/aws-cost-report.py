#!/usr/bin/env python3
"""aws-cost-report.py <cluster-name> <run-start-epoch> <run-end-epoch>

What a validation run (ADR 10) cost, estimated at the end of the run from
resource-hours and list prices: the instances the cluster ran (Spot at the
price history's rate for the zone and hour, on-demand at the price list's),
the control plane, NAT gateways, the load balancer and volumes. Written as a
Markdown table to stdout (and to $GITHUB_STEP_SUMMARY when set). The bill
itself arrives a day later; the sweeper reconciles it.

Never fails the job: a lookup that fails is named in the table instead.
"""
import datetime as dt
import json
import os
import subprocess
import sys

REGION = os.environ.get("AWS_REGION", "us-east-1")
LOCATION = {"us-east-1": "US East (N. Virginia)"}.get(REGION, REGION)
# List prices, us-east-1, per hour (the README's table). EBS gp3 per GB-month.
EKS_HOUR, NAT_HOUR, NLB_HOUR, GP3_GB_MONTH = 0.10, 0.045, 0.0225, 0.08


def aws(*args):
    out = subprocess.run(["aws", *args, "--output", "json"], capture_output=True, text=True)
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip()[:200])
    return json.loads(out.stdout or "null")


def parse(t):
    return dt.datetime.fromisoformat(t.replace("Z", "+00:00")).timestamp()


def on_demand_price(itype):
    filters = [f"Type=TERM_MATCH,Field={k},Value={v}" for k, v in [
        ("instanceType", itype), ("location", LOCATION), ("operatingSystem", "Linux"),
        ("tenancy", "Shared"), ("preInstalledSw", "NA"), ("capacitystatus", "Used")]]
    res = aws("pricing", "get-products", "--region", "us-east-1", "--service-code", "AmazonEC2", "--filters", *filters)
    for item in res.get("PriceList", []):
        doc = json.loads(item)
        for term in doc["terms"]["OnDemand"].values():
            for dim in term["priceDimensions"].values():
                return float(dim["pricePerUnit"]["USD"])
    raise RuntimeError(f"no on-demand price for {itype}")


def spot_price(itype, az, when):
    t = dt.datetime.fromtimestamp(when, dt.timezone.utc).isoformat()
    res = aws("ec2", "describe-spot-price-history", "--instance-types", itype, "--availability-zone", az,
              "--product-descriptions", "Linux/UNIX", "--start-time", t, "--end-time", t, "--max-items", "1")
    prices = res.get("SpotPriceHistory", [])
    if not prices:
        raise RuntimeError(f"no spot price for {itype} in {az}")
    return float(prices[0]["SpotPrice"])


def main():
    cluster, start, end = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
    hours = max(end - start, 0) / 3600
    rows, total = [], 0.0

    def add(item, qty_hours, rate, note=""):
        nonlocal total
        cost = qty_hours * rate
        total += cost
        rows.append((item, f"{qty_hours:.2f} h", f"${rate:.4f}/h", f"${cost:.2f}", note))

    add("EKS control plane", hours, EKS_HOUR)

    try:
        res = aws("ec2", "describe-instances", "--filters", f"Name=tag:kubernetes.io/cluster/{cluster},Values=owned")
        for r in res["Reservations"]:
            for i in r["Instances"]:
                launched = parse(i["LaunchTime"])
                stopped = end
                reason = i.get("StateTransitionReason", "")
                if "(" in reason and "GMT" in reason:
                    try:
                        stopped = dt.datetime.strptime(reason[reason.index("(") + 1:reason.index(")")], "%Y-%m-%d %H:%M:%S %Z").replace(tzinfo=dt.timezone.utc).timestamp()
                    except ValueError:
                        pass
                h = max(min(stopped, end) - max(launched, start), 0) / 3600
                itype, az = i["InstanceType"], i["Placement"]["AvailabilityZone"]
                spot = i.get("InstanceLifecycle") == "spot"
                try:
                    rate = spot_price(itype, az, launched) if spot else on_demand_price(itype)
                    add(f"{itype} {'Spot' if spot else 'on-demand'} ({i['InstanceId']})", h, rate)
                except RuntimeError as e:
                    rows.append((f"{itype} ({i['InstanceId']})", f"{h:.2f} h", "?", "?", str(e)))
    except RuntimeError as e:
        rows.append(("instances", "?", "?", "?", str(e)))

    try:
        res = aws("ec2", "describe-nat-gateways", "--filter", f"Name=tag:Name,Values={cluster}*")
        for n in res["NatGateways"]:
            created = parse(n["CreateTime"])
            deleted = parse(n["DeleteTime"]) if n.get("DeleteTime") else end
            add(f"NAT gateway ({n['NatGatewayId']})", max(min(deleted, end) - max(created, start), 0) / 3600, NAT_HOUR,
                "before data processing")
    except RuntimeError as e:
        rows.append(("NAT gateways", "?", "?", "?", str(e)))

    add("Network Load Balancer", hours, NLB_HOUR, "upper bound: the run's length; before capacity units")

    try:
        res = aws("ec2", "describe-volumes", "--filters", f"Name=tag:kubernetes.io/cluster/{cluster},Values=owned")
        gb = sum(v["Size"] for v in res["Volumes"])
        if gb:
            add(f"EBS gp3, {gb} GB still present at the end", hours, gb * GP3_GB_MONTH / 730)
    except RuntimeError as e:
        rows.append(("volumes", "?", "?", "?", str(e)))

    out = ["### What this run cost (estimate)", "",
           f"Run length {hours:.2f} h. Resource-hours times list prices for {REGION}; the bill arrives a day later and the sweeper reconciles it.", "",
           "| Item | Time | Rate | Cost | Note |", "|---|---|---|---|---|"]
    out += [f"| {a} | {b} | {c} | {d} | {e} |" for a, b, c, d, e in rows]
    out += ["", f"**Total, before data transfer, logs and capacity units: about ${total:.2f}**"]
    text = "\n".join(out) + "\n"
    print(text)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as f:
            f.write(text)


if __name__ == "__main__":
    main()
