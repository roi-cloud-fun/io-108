"""Render the Lab 3 event fan-out diagram (lab_3/images/fanout.png).

Mirrors lab_environment/lab_env_student/fanout.tf:
  report workflow fails -> CloudWatch alarm (AWS/States ExecutionsFailed)
  -> EventBridge rule (alarm state change) -> fan-out state machine;
  EventBridge schedule (heartbeat) -> the same state machine.
  Parallel state -> one SQS queue per destination -> one forwarder Lambda
  -> that destination's S3 sink bucket.

Re-run after changing fanout.tf:  python lab_3/images/fanout_diagram.py
"""
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyArrowPatch, FancyBboxPatch

COLORS = {
    "cw": "#E7157B",      # CloudWatch / EventBridge / SQS (AWS pink)
    "sfn": "#C925D1",     # Step Functions
    "lambda": "#ED7100",  # Lambda
    "s3": "#3F8624",      # S3
}
TEXT = "#16191F"
MUTED = "#545B64"

fig, ax = plt.subplots(figsize=(16.5, 6.2), dpi=150)
ax.set_xlim(0, 16.5)
ax.set_ylim(0, 6.2)
ax.axis("off")
fig.patch.set_facecolor("white")


def box(x, y, w, h, title, sub, kind):
    c = COLORS[kind]
    ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0.02,rounding_size=0.12",
                                linewidth=1.6, edgecolor=c, facecolor="white"))
    ax.add_patch(FancyBboxPatch((x, y + h - 0.09), w, 0.09, boxstyle="square,pad=0",
                                linewidth=0, facecolor=c))
    ax.text(x + w / 2, y + h * 0.62, title, ha="center", va="center",
            fontsize=10.5, fontweight="bold", color=TEXT)
    ax.text(x + w / 2, y + h * 0.27, sub, ha="center", va="center",
            fontsize=8.5, color=MUTED, linespacing=1.25)
    return (x, y, w, h)


def right(b):
    x, y, w, h = b
    return (x + w, y + h / 2)


def left(b):
    x, y, w, h = b
    return (x, y + h / 2)


def arrow(p, q):
    ax.add_patch(FancyArrowPatch(p, q, arrowstyle="-|>", mutation_scale=14,
                                 linewidth=1.4, color=MUTED))


def note(x, y, t):
    ax.text(x, y, t, ha="center", va="center", fontsize=8, color=MUTED, style="italic",
            bbox=dict(boxstyle="round,pad=0.15", facecolor="white", edgecolor="none"))


W, H = 2.45, 1.05
report = box(0.2, 4.4, W, H, "Report workflow", "Step Functions\nexecution fails", "sfn")
alarm = box(0.2, 2.75, W, H, "CloudWatch alarm", "io108-<id>-fanout-trigger\nExecutionsFailed ≥ 1", "cw")
hb = box(0.2, 0.6, W, H, "EventBridge schedule", "heartbeat\nevery 2 minutes", "cw")
rule = box(3.3, 2.75, W, H, "EventBridge rule", "alarm state\nchanges to ALARM", "cw")
sfn = box(6.45, 1.6, 2.4, 2.3, "Fan-out\nstate machine", "Parallel state:\nsame input to\nevery branch", "sfn")
q_nr = box(9.75, 3.55, 2.1, H, "SQS queue", "newrelic branch", "cw")
q_sw = box(9.75, 1.05, 2.1, H, "SQS queue", "solarwinds branch", "cw")
fwd = box(12.35, 2.2, 1.95, 1.25, "Forwarder\nLambda", "writes each message to\nits destination's bucket", "lambda")
s3_nr = box(14.8, 3.55, 1.6, H, "S3 sink", "simulated\nNewRelic", "s3")
s3_sw = box(14.8, 1.05, 1.6, H, "S3 sink", "simulated\nSolarWinds", "s3")

arrow((report[0] + W / 2, report[1]), (alarm[0] + W / 2, alarm[1] + H))
arrow(right(alarm), left(rule))
arrow(right(rule), (sfn[0], sfn[1] + 1.55))
note(6.05, 3.55, "starts")
arrow(right(hb), (sfn[0], sfn[1] + 0.55))
note(4.4, 0.95, "starts (keeps the sinks fresh)")
arrow((sfn[0] + sfn[2], sfn[1] + 1.75), left(q_nr))
arrow((sfn[0] + sfn[2], sfn[1] + 0.55), left(q_sw))
arrow(right(q_nr), (fwd[0], fwd[1] + 0.90))
arrow(right(q_sw), (fwd[0], fwd[1] + 0.35))
arrow((fwd[0] + fwd[2], fwd[1] + 0.90), left(s3_nr))
arrow((fwd[0] + fwd[2], fwd[1] + 0.35), left(s3_sw))

ax.text(8.25, 5.95, "Lab 3: one incident event, many monitoring destinations", ha="center",
        va="center", fontsize=13, fontweight="bold", color=TEXT)
ax.text(8.25, 0.18, "Each SQS message carries its destination; the forwarder writes it to that "
        "destination's sink bucket. Both sinks get a copy because the Parallel state sends one "
        "message down each branch.", ha="center", va="center", fontsize=8.5, color=MUTED)

out = Path(__file__).with_name("fanout.png")
fig.savefig(out, bbox_inches="tight", facecolor="white")
print(out)
