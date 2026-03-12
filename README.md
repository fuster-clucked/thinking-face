# Thinking Face

Thinking Face is a reusable GitHub workflow for AWS deployment of ML development environments.

## Configuration

### AWS IAM Identity Provider and Role

See [OIDC Quick Start](https://github.com/aws-actions/configure-aws-credentials#quick-start-oidc-recommended)

Make sure to select "Web identity" for the role's trusted entity type.

Add the following inline policy to the role:
<!-- TODO narrow down exactly which resources are allowed for the given actions -->

```yaml
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "iam:CreateRole",
                "iam:UpdateAssumeRolePolicy",
                "iam:TagRole",
                "iam:PutRolePolicy",
                "iam:PassRole",
                "iam:DeleteRolePolicy",
                "iam:DeleteRole"
            ],
            "Resource": "arn:aws:iam::$ACCOUNT:role/thinkingface-*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "iam:CreateInstanceProfile",
                "iam:TagInstanceProfile",
                "iam:GetInstanceProfile",
                "iam:AddRoleToInstanceProfile",
                "iam:RemoveRoleFromInstanceProfile",
                "iam:DeleteInstanceProfile"
            ],
            "Resource": "arn:aws:iam::$ACCOUNT:instance-profile/thinkingface-*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "ec2:DeleteSecurityGroup",
                "ec2:CreateSecurityGroup",
                "ec2:CreateTags",
                "ec2:AuthorizeSecurityGroupIngress",
                "ec2:DescribeImages",
                "ec2:CancelSpotInstanceRequests",
                "ec2:RunInstances",
                "ec2:StartInstances",
                "ec2:StopInstances",
                "ec2:TerminateInstances",
                "ec2:DescribeInstances",
                "ec2:DescribeSpotInstanceRequests",
                "ec2:DescribeSpotPriceHistory",
                "ssm:DescribeInstanceInformation",
                "ssm:PutParameter",
                "ssm:SendCommand",
                "ssm:GetCommandInvocation",
                "ssm:DeleteParameter"
            ],
            "Resource": "*"
        }
    ]
}
```

### AWS System Manager Parameter Store

- `/wireguard/SERVER_KEY`: the WireGuard server private key
- `/wireguard/CLIENT_PUB`: the WireGuard client public key
- `/caddy/CA_CRT`: the Caddy proxy CA certificate
- `/caddy/CA_KEY`: the Caddy proxy CA private key
- `/thinkingface/CS_PASSWORD`: the Code Server password
- `/thinkingface/DCV_PASSWORD`: the AWS DCV password

### GitHub Repository Action Variables

- `AWS_THINKINGFACE_ROLE_ARN`: the AWS IAM identity provider role ARN

### GitHub Repository Devcontainer

The devcontainer must have a usable `curl` command

### Local Hostnames (`/etc/hosts`)

```
...
10.0.0.1 thinkingface.lan
```

### WireGuard Client

```
[Interface]
PrivateKey = <SERVER_KEY>
Address = 10.10.0.2/32
DNS = 1.1.1.1

[Peer]
PublicKey = <CLIENT_PUB>
AllowedIPs = 0.0.0.0/0
Endpoint = <INSTANCE_IP>:51820
```

## Usage

> ⚠️ **WARNING**
> Terminating an instance will lose its file system changes and its instance tags!

Include the following workflow definitions in your project's `.github/workflows` folder:

`launch.yml`:
```yaml
name: Launch AWS Workspace

on:
  workflow_dispatch:
    inputs:
      region:
        type: string
        default: <AWS_REGION>

permissions:
  id-token: write
  contents: read

jobs:
  launch:
    uses: fuster-clucked/thinking-face/.github/workflows/launch.yml@main
    with:
      region: ${{ inputs.region }}
```

`terminate.yml`:
```yaml
name: Terminate AWS Workspace

on:
  workflow_dispatch:
    inputs:
      region:
        type: string
        default: <AWS_REGION>

permissions:
  id-token: write

jobs:
  terminate:
    uses: fuster-clucked/thinking-face/.github/workflows/terminate.yml@main
    with:
      region: ${{ inputs.region }}
```

`destroy.yml`:
```yaml
name: Destroy AWS Workspace

on:
  workflow_dispatch:
    inputs:
      region:
        type: string
        default: <AWS_REGION>

permissions:
  id-token: write

jobs:
  destroy:
    uses: fuster-clucked/thinking-face/.github/workflows/destroy.yml@main
    with:
      region: ${{ inputs.region }}
```
