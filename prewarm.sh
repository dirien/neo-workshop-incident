#!/usr/bin/env bash
# Pre-flight for the live demo. Read-only: checks, never changes anything.
# Run it the morning of, not five minutes before.
set -uo pipefail
cd "$(dirname "$0")"

pass=0; fail=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

echo "Pulumi"
pulumi whoami >/dev/null 2>&1 && ok "logged in as $(pulumi whoami 2>/dev/null)" || bad "pulumi login"
pulumi stack --show-name >/dev/null 2>&1 && ok "stack selected: $(pulumi stack --show-name 2>/dev/null)" || bad "no stack selected"

echo "Stack outputs"
for o in paymentQueueUrl dlqUrl alarmName pagerdutyServiceUrl; do
  v=$(pulumi stack output "$o" 2>/dev/null) && [ -n "$v" ] && ok "$o" || bad "$o missing — has the stack been deployed?"
done

echo "AWS"
aws sts get-caller-identity >/dev/null 2>&1 \
  && ok "credentials resolve: $(aws sts get-caller-identity --query Arn --output text 2>/dev/null)" \
  || bad "aws credentials"

echo "Alarm state"
AL=$(pulumi stack output alarmName 2>/dev/null || true)
if [ -n "$AL" ]; then
  ST=$(aws cloudwatch describe-alarms --alarm-names "$AL" --query 'MetricAlarms[0].StateValue' --output text 2>/dev/null)
  case "$ST" in
    OK) ok "alarm is OK — clean starting state" ;;
    ALARM) bad "alarm is already in ALARM — run cleanup.sh before you present" ;;
    *) bad "alarm state is '$ST'" ;;
  esac
fi

echo "Queues drained"
Q=$(pulumi stack output dlqUrl 2>/dev/null || true)
if [ -n "$Q" ]; then
  N=$(aws sqs get-queue-attributes --queue-url "$Q" \
       --attribute-names ApproximateNumberOfMessages \
       --query 'Attributes.ApproximateNumberOfMessages' --output text 2>/dev/null)
  [ "$N" = "0" ] && ok "dead-letter queue empty" || bad "dead-letter queue holds $N message(s) — run cleanup.sh"
fi

echo
echo "  $pass ok, $fail failed"
echo
echo "Not checked here, because only you can see them:"
echo "  - PagerDuty trial not expired (14-day term)"
echo "  - PagerDuty, Linear and aws integrations connected in the Neo org"
echo "  - the aws integration points at the READ-ONLY ESC environment"
echo "  - GitHub connected, so Neo can open the PR"
[ "$fail" -eq 0 ]
