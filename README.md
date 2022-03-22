# AWS CodeBuild Cloud Native Buildpack pack CLI Docker image

This repository holds a Dockerfile based on [AWS CodeBuild Docker Images](https://github.com/aws/aws-codebuild-docker-images) with focus on building [Cloud Native Buildpacks](https://buildpacks.io/) using [`pack CLI`](https://buildpacks.io/docs/tools/pack/#pack-cli).

[![Build Status](https://codebuild.us-east-1.amazonaws.com/badges?uuid=eyJlbmNyeXB0ZWREYXRhIjoiZnk2Z2dqdVIzdXpTVXYyWmJ1VGxDVWtLMGZ0OVMybjJQb1M2dmI4c3F4RkpEcWduZ2hxODVkUzdqTlhoVFJUdkg5aFpqL0k3SnFXSVZ0ajYvS0hYK1lNPSIsIml2UGFyYW1ldGVyU3BlYyI6Im96Mjc3amNmMDJmVWp4S2giLCJtYXRlcmlhbFNldFNlcmlhbCI6MX0%3D&branch=main)](https://us-east-1.codebuild.aws.amazon.com/project/eyJlbmNyeXB0ZWREYXRhIjoiSnh1TjBMZzB1NGRTODZmWVhNcWpCelY3Sk9wcno0SmJsQkE3eWlTMjR1bGV4eUVON2lQT3RBa1VhRFBwOTRvUkd5cU5TWGRrdXlKQ240aFJ4ZXg0a3pUVzhVRDRBa0hqSHlZd2JtYzVPMXR6bUc0R0JqZUhlbzZvQjNhQW9LZllPYWlmIiwiaXZQYXJhbWV0ZXJTcGVjIjoiVTY5NmRZY0ZNandMeC93UyIsIm1hdGVyaWFsU2V0U2VyaWFsIjoxfQ%3D%3D)

### Advantages

- Does not require to install `pack` and other dependencies at runtime
- Will provide `docker login` implicitly as CodeBuild service role allows

### How to use this image on AWS Codebuild

Create or edit your CodeBuild project's evironment sections and override as described below:

![CodeBuild Environment](codebuild-snapshot.png)

Create a `buildspec.yml` like this:

```yaml
version: 0.2
phases:
  build:
    on-failure: ABORT
    commands:
      - dockerd-entrypoint.sh main.sh
```

### **Environment Variables**


Variable | Description | Examples
-------- | -------- | -------- 
`MAESTRO_BRANCH_OVERRIDE` | Temporary overriding of the working branch | `staging` <br> `production`
`ECS_SERVICE_SUBNETS` | Subnets linked to the ECS Service <br> *Multiple values can be assigned using comma as separator* | `subnet-qwer1234567890` <br> `subnet-asdf0987654321,subnet-nth`
ECS_SERVICE_SECURITY_GROUPS | Security Groups linked to the ECS Service <br> Multiples can be assigned at the same time | sg-qwerty <br> sg-asdfgh <br> sg-nth
ECS_TASK_ROLE_ARN | IAM Role ARN linked to ECS Task | arn:aws:iam::0123456789:role/&lt;role-name&gt;
ECS_EXECUTION_ROLE_ARN | IAM Role ARN linked to ECS Execution | `arn:aws:iam::0123456789:role/<role-name>`
ECS_SERVICE_TASK_PROCESSES | Processes intended to have a service to be created | `web` <br> `web,worker` <br> `web:2,worker:1` <br> `web:2{0.5;512},worker:1{1,2048}`
WORKLOAD_RESOURCE_TAGS | Tags related to the workload that will be used to all resources provisioned <br><br> Examples include tag name and value <br> &nbsp; &nbsp; Tag name is case-insensitive  | workload=myapp <br> environment=staging <br> owner=me
ALB_SUBNETS | Subnets linked to ALB <br> Multiples can be assigned at the same time | subnet-qwer1234567890 <br> subnet-asdf0987654321 <br> subnet-nth
ALB_SCHEME | Scheme of the ALB <br> The example values are the two possible ones <br> &nbsp; &nbsp; Only one of them can be chosen | internet-facing <br> internal
ALB_SECURITY_GROUPS | Security Groups linked to ALB <br> Multiples can be assigned at the same time | sg-qwerty <br> sg-asdfgh <br> sg-nth
WORKLOAD_VPC_ID | VPC ID of the workload | vpc-ad1234df <br> vpc-qw56er78 <br> vpc-zxcvghjk

### How to build Docker image

Steps to build image

```bash
$ git clone https://github.com/aws/aws-codebuild-cnb-pack.git
$ docker build -t aws/codebuild/pack:1.0 .
$ docker run -it --entrypoint sh aws/codebuild/pack:1.0 -c bash
```

To let the Docker daemon start up in the container, build it and run:
`docker run -it --privileged aws/codebuild/pack:1.0 bash`

### Current process steps:

1. Test (TBD)
2. Build
3. Release/Render
4. Provision
5. Deploy

### Contributing

Feel free to suggest improvements via pull requests!
