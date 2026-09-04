#!/usr/bin/env bash
# Reset between rehearsals: purge the dead-letter queue so the alarm returns to
# OK and PagerDuty resolves the incident on its own.
#
# SQS allows one purge per queue per 60 seconds. If you are re-running quickly,
# wait it out rather than retrying in a loop.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"

DLQ_URL=$(pulumi stack output dlqUrl)
QUEUE_URL=$(pulumi stack output paymentQueueUrl)

aws sqs purge-queue --queue-url "$DLQ_URL" --no-cli-pager
aws sqs purge-queue --queue-url "$QUEUE_URL" --no-cli-pager || true

echo "Queues purged. The alarm returns to OK on its next evaluation (up to 60s)."

# Resolve any open incident now rather than waiting for the alarm to flip:
# a stale open incident makes the next rehearsal ambiguous, and PagerDuty
# refuses to delete the schedule (so `pulumi destroy` fails) while one is open.
TOKEN=$(pulumi config get --secret pagerduty:token 2>/dev/null || pulumi config get pagerduty:token 2>/dev/null || true)
if [[ -n "$TOKEN" ]]; then
    PD="https://api.pagerduty.com"
    H1="Authorization: Token token=$TOKEN"; H2="Accept: application/vnd.pagerduty+json;version=2"
    FROM=$(curl -s -H "$H1" -H "$H2" "$PD/users?limit=1" | python3 -c 'import sys,json; print(json.load(sys.stdin)["users"][0]["email"])' 2>/dev/null || true)
    IDS=$(curl -s -H "$H1" -H "$H2" "$PD/incidents?statuses[]=triggered&statuses[]=acknowledged&limit=50" \
        | python3 -c 'import sys,json; print(" ".join(i["id"] for i in json.load(sys.stdin).get("incidents",[])))' 2>/dev/null || true)
    for id in $IDS; do
        curl -s -o /dev/null -X PUT -H "$H1" -H "$H2" -H "Content-Type: application/json" -H "From: $FROM" \
            "$PD/incidents/$id" -d '{"incident":{"type":"incident_reference","status":"resolved"}}'
        echo "Resolved PagerDuty incident $id."
    done
    [[ -z "$IDS" ]] && echo "No open PagerDuty incidents."
else
    echo "No pagerduty:token in stack config; resolve any open incident in the PagerDuty UI."
fi

# Remove the extra security group so the next run starts from the same place.
# Re-arm with ./add-db-sg.sh.
"$SCRIPT_DIR/remove-db-sg.sh"
