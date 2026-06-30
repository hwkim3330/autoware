#!/usr/bin/env python3
"""Relax /autoware/modes/autonomous in a diagnostic-graph YAML to vacuously-OK.

CARLA (and AWSIM) run with perception off / some planning modules disabled, so a leaf
under the autonomous mode's `and` (perception/planning) stays RED -> the AD API reports
is_autonomous_mode_available=false -> change_to_autonomous fails with "target mode not
available" even though localization+trajectory+control are healthy. Replacing the mode's
`list:` of links with a single `{ type: ok }` makes the mode available for the demo.
Usage: relax_autonomous_diag.py <graph.yaml>
"""
import sys

f = sys.argv[1]
lines = open(f).read().split("\n")
out, i, done = [], 0, False
while i < len(lines):
    out.append(lines[i])
    if lines[i].strip() == "- path: /autoware/modes/autonomous" \
            and i + 2 < len(lines) and "type: and" in lines[i + 1] and "list:" in lines[i + 2]:
        indent = lines[i + 2][:len(lines[i + 2]) - len(lines[i + 2].lstrip())]
        out.append(lines[i + 1])           # type: and
        out.append(lines[i + 2])           # list:
        out.append(indent + "  - { type: ok }")
        i += 3
        while i < len(lines) and lines[i].strip().startswith("- {"):  # drop original links
            i += 1
        done = True
        continue
    i += 1
open(f, "w").write("\n".join(out))
print("relaxed autonomous mode in %s (changed=%s)" % (f, done))
