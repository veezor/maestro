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

#### **Environment Variables**

1. MAESTRO_BRANCH_OVERRIDE
    * Temporary overriding of the working branch
    * Examples:
        * staging
        * staging-yourcompany
2. ECS_SERVICE_SUBNETS
    * Subnets linked to the ECS Service
    * Multiples can be assigned at the same time
    * Examples:
        * subnet-qwer1234567890
        * subnet-asdf0987654321
        * subnet-nth
3. ECS_SERVICE_SECURITY_GROUPS
    * Security Groups linked to the ECS Service
    * Multiples can be assigned at the same time
    * Examples:
        * sg-asdf
        * sg-krekre
        * sg-nth
4. ECS_TASK_ROLE_ARN
    * IAM Role ARN linked to ECS Task
    * Example:
        * arn:aws:iam::0123456789:role/< role-name>
5. ECS_EXECUTION_ROLE_ARN
    * IAM Role ARN linked to ECS Execution
    * Example:
        * arn:aws:iam::0123456789:role/< role-name>
6. ECS_SERVICE_TASK_PROCESSES
    * Processes intended to have a service to be created
    * Examples:
        * web
        * worker
7. WORKLOAD_RESOURCE_TAGS
    * Tags related to the workload that will be used to all resources provisioned
    * Examples of tags and values (tag name is case-insensitive):
        * workload=myapp
        * environment=staging
        * owner=me
8. ALB_SUBNETS
    * Subnets linked to ALB
    * Multiples can be assigned at the same time
    * Examples:
        * subnet-qwer1234567890
        * subnet-asdf0987654321
        * subnet-nth
9. ALB_SCHEME
    * Scheme of the ALB
    * Possible Values (only one):
        * internet-facing
        * internal
10. ALB_SECURITY_GROUPS
    * Security Groups linked to ALB
    * Multiples can be assigned at the same time
    * Examples:
        * sg-asdf
        * sg-krekre
        * sg-nth
11. WORKLOAD_VPC_ID
    * VPC id of the workload
    * Examples:
        * vpc-ad1234df
        * vpc-qw56er78
        * vpc-zxcvghjk

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
