/**
 * The read-only role behind the workshop's `aws` CLI integration.
 *
 * Why this exists: the org's existing `shared/cloud-creds` environment is the
 * right shape but its role carries AdministratorAccess. Pointing the integration
 * at that would make the credential beat's central claim — "scoped to exactly the
 * permissions you choose" — false on stage, in the beat that is about scoping.
 *
 * It would also make the credential-precedence test undecidable: an admin ESC role
 * can do everything the laptop profile can, so there is no observable difference
 * between the two resolving. See ../../docs/credentials.md.
 */
import * as aws from "@pulumi/aws";
import * as pulumi from "@pulumi/pulumi";

const cfg = new pulumi.Config();
const org = cfg.get("pulumiOrg") ?? "ediri";

// Pulumi Cloud's OIDC issuer. In a shared account the provider already exists and
// carries many orgs' audiences, so look it up: creating or importing it here would
// let this stack overwrite that audience list.
const accountId = aws.getCallerIdentityOutput().accountId;
const provider = aws.iam.getOpenIdConnectProviderOutput({
    arn: pulumi.interpolate`arn:aws:iam::${accountId}:oidc-provider/api.pulumi.com/oidc`,
});

const role = new aws.iam.Role("neo-workshop-readonly", {
    name: "pulumi-neo-workshop-readonly",
    description: "Read-only role assumed by Pulumi ESC for Neo's aws CLI integration (Sep 8 workshop).",
    maxSessionDuration: 3600,
    assumeRolePolicy: pulumi.all([provider.arn, provider.url]).apply(([arn, url]) =>
        JSON.stringify({
            Version: "2012-10-17",
            Statement: [{
                Effect: "Allow",
                Principal: { Federated: arn },
                Action: "sts:AssumeRoleWithWebIdentity",
                Condition: {
                    StringEquals: {
                        // ESC's aws-login presents `aws:<org>` as the audience.
                        [`${url.replace("https://", "")}:aud`]: [org, `aws:${org}`],
                    },
                },
            }],
        })
    ),
});

// ReadOnlyAccess, deliberately. Neo's remediation is a pull request, so it never
// needs to mutate anything to do the whole incident walkthrough.
new aws.iam.RolePolicyAttachment("neo-workshop-readonly-attach", {
    role: role.name,
    policyArn: "arn:aws:iam::aws:policy/ReadOnlyAccess",
});

export const roleArn = role.arn;

/**
 * Paste into a NEW ESC environment — suggested ref:
 *   <org>/neo-workshop/aws-readonly
 *
 *   values:
 *     aws:
 *       login:
 *         fn::open::aws-login:
 *           oidc:
 *             duration: 1h
 *             roleArn: <roleArn from this stack>
 *             sessionName: pulumi-esc
 *     environmentVariables:
 *       AWS_ACCESS_KEY_ID: ${aws.login.accessKeyId}
 *       AWS_SECRET_ACCESS_KEY: ${aws.login.secretAccessKey}
 *       AWS_SESSION_TOKEN: ${aws.login.sessionToken}
 *       AWS_REGION: eu-central-1
 *
 * Then verify it is genuinely narrower than the laptop, which is the point:
 *   pulumi env run <ref> -- aws sts get-caller-identity
 *   pulumi env run <ref> -- aws sqs purge-queue --queue-url <any>   # must be DENIED
 */
export const escEnvironmentHint = pulumi.interpolate`roleArn: ${role.arn}`;
