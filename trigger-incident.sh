#!/usr/bin/env bash
# Cause a real PagerDuty page, on demand.
#
# Sends a payment message with no "amount", then plays the failing consumer:
# there is no worker in the stack, so this script receives the message without
# deleting it until SQS gives up. Past maxReceiveCount the message moves to the
# dead-letter queue, the alarm goes red, SNS notifies PagerDuty, and an
# incident opens.
#
# Timing, MEASURED (2026-09-02): send → DLQ in 13s, but send → incident open
# took 2m53s — SQS publishes its CloudWatch metrics at ~1-minute granularity,
# so the 60s alarm period doesn't help. Budget a full 3 minutes from running
# this to the page. (Engin's original at maxReceiveCount 3 took 3m45s.)
#
# ⇒ RUN THIS DURING THE PREVIOUS BEAT, not at the top of the incident beat.
set -euo pipefail
cd "$(dirname "$0")"

QUEUE_URL=$(pulumi stack output paymentQueueUrl)

aws sqs send-message \
    --queue-url "$QUEUE_URL" \
    --message-body '{"orderId":"4712","currency":"EUR"}' \
    --no-cli-pager >/dev/null

echo "Poison payment sent to the payment queue."

# Play the consumer that keeps failing: receive without delete. The message
# becomes invisible for visibilityTimeoutSeconds (5s) after each receive; once
# its receive count exceeds maxReceiveCount (1), SQS moves it to the DLQ
# instead of delivering it again.
DLQ_URL=$(pulumi stack output dlqUrl)
for i in 1 2 3 4 5 6; do
    aws sqs receive-message --queue-url "$QUEUE_URL" \
        --wait-time-seconds 2 --no-cli-pager >/dev/null 2>&1 || true
    N=$(aws sqs get-queue-attributes --queue-url "$DLQ_URL" \
        --attribute-names ApproximateNumberOfMessages \
        --query 'Attributes.ApproximateNumberOfMessages' --output text)
    if [ "$N" != "0" ]; then
        echo "Message dead-lettered after $i receive attempt(s)."
        break
    fi
    sleep 6   # let the visibility timeout (5s) expire before the next receive
done
if [ "${N:-0}" = "0" ]; then
    echo "⚠️  Message has not reached the DLQ yet — check receive count by hand."
fi
echo "Watch the alarm flip:"
echo "  aws cloudwatch describe-alarms --alarm-names \"$(pulumi stack output alarmName)\" \\"
echo "    --query 'MetricAlarms[0].StateValue' --output text"
echo
echo "Incident will open on: $(pulumi stack output pagerdutyServiceUrl)"
