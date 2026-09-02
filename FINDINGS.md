# What Neo is supposed to find

The demo program carries three deliberate configuration faults, plus a fourth
thing that isn't in the program at all. Each is real —
these are bugs you would want caught — and each is **visible in a single look at
current state**.

That constraint is the whole design. A fresh PagerDuty trial and a fresh AWS
account have no history, so nothing here can depend on a trend. The launch blog's
marquee example (*"storage grew 5 GB/day for 30 days"*) and the *Ten More Things*
item 2 framing (*"the last 7 days of metrics"*) are both undemonstrable on a
two-week-old account. These are the same incidents, made visible without history.

| # | Fault | Where | Why it's real |
|---|-------|-------|---------------|
| 1 | `maxReceiveCount: 1` | `payment-queue` redrive policy | One transient failure and the message is dead-lettered. There is no retry at all. |
| 2 | Alarm with no actions | `payment-queue-age-alarm` | It evaluates, it goes red, nobody is told. The "but we had monitoring" postmortem. |
| 3 | `maxAllocatedStorage == allocatedStorage` | `payments-db` | Storage autoscaling is configured and inert — it can never grow the volume. |
| 4 | A security group open to `0.0.0.0/0` on 5432 | **nowhere — it's not in the program** | Attached to `payments-db`, created out-of-band. No Pulumi state describes it. |

## Fault 4 is the one that needs the CLI

Faults 1–3 are in the program. Neo could find all three by reading the code, and
someone in the room will notice that. Fault 4 is the answer.

`./create-unmanaged.sh` creates a security group with the raw AWS CLI — standing
in for "somebody opened the console at 2am and never came back" — opens tcp/5432
to `0.0.0.0/0`, tags it `CreatedBy=console`, and attaches it to `payments-db`.

Nothing in `index.ts` mentions it. It is in the account and not in
state, so **reading the program cannot find it**. Only running `aws` against the
live account can. That is the entire argument for CLI integrations, demonstrated
rather than asserted.

Confirm before the session:

```bash
pulumi stack --show-urns | grep -i security   # expect nothing
```

**The honest nuance, and it improves the demo.** `payments-db` has
`publiclyAccessible: false`, so the open security group is not actually
reachable from the internet. It is a genuine audit finding — defense-in-depth,
and one flag flip from being exploitable — but it is not a live breach. If Neo
reports both the finding *and* the mitigating factor, that is a better moment
than a false alarm would be. Don't oversell it on stage; the restraint is the
credibility.

**The fix is an adoption, not a deletion.** The PR should bring the resource
under management and narrow it, rather than just deleting something a colleague
created for a reason:

```ts
// Adopt the security group that was created in the console, then scope it.
const dbAccess = new aws.ec2.SecurityGroup("payments-db-emergency-access", {
    vpcId: vpcId,
    description: "Postgres access for payments-db",
    ingress: [{
        protocol: "tcp",
        fromPort: 5432,
        toPort: 5432,
        cidrBlocks: [vpcCidr],   // was 0.0.0.0/0
    }],
}, { import: "sg-0abc123..." });   // the id the CLI reported
```

Neo will need the security group id and the VPC CIDR — both of which it gets
from `aws`, which is the point.

## Fault 1 is doing two jobs

`maxReceiveCount: 1` is both the bug Neo diagnoses **and** what makes the beat
presentable. Engin's measured run, at `maxReceiveCount: 3`, took **3m45s** from
poison message to alarm and 3m49s to page. That is four minutes of dead air —
longer than the entire Linear beat.

At 1, with a 5-second visibility timeout, the message reaches the dead-letter
queue almost immediately and the remaining delay is just the alarm's 60-second
evaluation period.

⚠️ Fixing it is therefore a **PR, never applied live** — merging it during the
session would make the next rehearsal slow again.

## Suggested prompt

> There's an active PagerDuty incident. What's going on, and what would you change?

If it stays inside the program and never reaches for the CLI, nudge once —
still without naming the finding:

> Is there anything running in the account that this program doesn't describe?

Do not name the faults. The demo is worth more if Neo finds them, and the whole
claim is that it can look for itself.

## If Neo finds something we didn't plan

Good — say so out loud and follow it. An agent finding a fourth real problem in
a program the presenter wrote is a better moment than the script.

## Resetting

`./cleanup.sh` purges the queues. It also calls `./remove-unmanaged.sh`, which
detaches and deletes the security group, so a rehearsal always starts from the
same place. Re-arm with `./create-unmanaged.sh`.

## What it must not do

Neo needs **no write access** to any of this. The remediation is a pull request
against the program, and the read-only ESC environment is what proves it — see
`../docs/credentials.md`.
