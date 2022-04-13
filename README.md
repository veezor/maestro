# AWS CodeBuild Cloud Native Buildpack pack CLI Docker image

This repository holds a Dockerfile based on [AWS CodeBuild Docker Images](https://github.com/aws/aws-codebuild-docker-images) with focus on building [Cloud Native Buildpacks](https://buildpacks.io/) using [`pack CLI`](https://buildpacks.io/docs/tools/pack/#pack-cli).

[![Build Status](https://codebuild.us-east-1.amazonaws.com/badges?uuid=eyJlbmNyeXB0ZWREYXRhIjoiZnk2Z2dqdVIzdXpTVXYyWmJ1VGxDVWtLMGZ0OVMybjJQb1M2dmI4c3F4RkpEcWduZ2hxODVkUzdqTlhoVFJUdkg5aFpqL0k3SnFXSVZ0ajYvS0hYK1lNPSIsIml2UGFyYW1ldGVyU3BlYyI6Im96Mjc3amNmMDJmVWp4S2giLCJtYXRlcmlhbFNldFNlcmlhbCI6MX0%3D&branch=main)](https://us-east-1.codebuild.aws.amazon.com/project/eyJlbmNyeXB0ZWREYXRhIjoiSnh1TjBMZzB1NGRTODZmWVhNcWpCelY3Sk9wcno0SmJsQkE3eWlTMjR1bGV4eUVON2lQT3RBa1VhRFBwOTRvUkd5cU5TWGRrdXlKQ240aFJ4ZXg0a3pUVzhVRDRBa0hqSHlZd2JtYzVPMXR6bUc0R0JqZUhlbzZvQjNhQW9LZllPYWlmIiwiaXZQYXJhbWV0ZXJTcGVjIjoiVTY5NmRZY0ZNandMeC93UyIsIm1hdGVyaWFsU2V0U2VyaWFsIjoxfQ%3D%3D)

### Advantages

- Does not require to install `pack` and other dependencies at runtime
- Will provide `docker login` implicitly as CodeBuild service role allows
- Build step is automatically skipped if commit is the same

### Current process steps:

1. Test (TBD)
2. Build
3. Release/Render
4. Provision
5. Deploy

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

Variable | Description | Examples/Values/Default 
---|---|---
 `ALB_SCHEME` | Scheme of the ALB <br><br> **Choose only one of the example values** | `internet-facing` <br> `internal` <br><br><br> *Default =* `internet-facing`
 `ALB_SECURITY_GROUPS` | Security Groups linked to ALB <br><br> *Multiple values can be assigned using comma as separator* | `sg-qwerty` <br> `sg-asdfgh,sg-nth` 
 `ALB_SUBNETS` | Subnets linked to ALB <br><br> *Multiple values can be assigned using comma as separator* | `subnet-qwer1234567890` <br> `subnet-asdf0987654321,subnet-nth` 
 `ECS_EFS_VOLUMES` | Add EFS volumes for ECS tasks <br><br> *Multiple values can be assigned using comma as separator* | `<volume-name>:<filesystem-id>{<efs-root>@<path-to-task-build>;<to-encrypt-in-transit>}` <br> `storage-efs:fs-013a693f90df46413{/@public/storage;encrypted},images-efs:fs-0bd8f82bba0a89448{/@public/images;encrypted}` 
 `ECS_EXECUTION_ROLE_ARN` | IAM Role ARN linked to ECS Execution | `arn:aws:iam::0123456789:role/<role-name>` 
 `ECS_SERVICE_SECURITY_GROUPS` | Security Groups linked to the ECS Service <br><br> *Multiple values can be assigned using comma as separator* | `sg-qwerty` <br> `sg-asdfgh,sg-nth` 
 `ECS_SERVICE_SUBNETS` | Subnets linked to the ECS Service <br><br> *Multiple values can be assigned using comma as separator* | `subnet-qwer1234567890` <br> `subnet-asdf0987654321,subnet-nth` 
 `ECS_SERVICE_TASK_PROCESSES` | Processes intended to have a service to be created according to Procfile <br><br> Possible values and specifics: <br> 1. Name of the process <br> 2. Values for CPU Cores (multiplied by 1024) and Allocated RAM <br> 3. Amount of tasks per process <br> 4. Amount of tasks and triggers in percentage for auto scaling <br><br> *Multiple services can be assigned using comma as separator* <br> <br> *For CPU and RAM assignment use semicolon as separator and curly brackets as container* <br> *For number of tasks assignment use colon as separator and a dash between numbers to define max task auto scaling value* <br> *For CPU and RAM auto scaling usage percentage triggers assignment  use semicolon as separator and square brackets as container* | `web` <br> `web,worker` <br> `web{1024,2048}:2-5[mem=55;cpu=60]` <br> `web{512;1024}:2,worker{1024;2048}:1-3` <br><br> `process{v-cpus;mem}:min-max[mem=percent;cpu=percent]` <br><br><br> **Default Values:** <br> `Tasks per Process` = `1` <br> `Number of CPU Cores` = `512` (0.5) <br> `Allocated RAM` = `512` <br> `CPU usage percentage auto scaling trigger` = `55` <br><br> Example using all default values except `Tasks per Process`: <br> `test:2-5` <br> Full manual example would be: <br> `test{512,512}:2-5[cpu=55]`
 `ECS_TASK_ROLE_ARN` | IAM Role ARN linked to ECS Task | `arn:aws:iam::0123456789:role/<role-name>` 
 `MAESTRO_BRANCH_OVERRIDE` | Temporary overriding of the working branch | `staging` <br> `production` 
 `MAESTRO_CLEAR_CACHE` | If all the known cache layers should be cleared <br><br> **Choose only one of the example values** | `true` <br> `false` 
 `MAESTRO_DEBUG` | Amplify verbosity of the build <br><br> **Choose only one of the example values** | `true` <br> `false` 
 `MAESTRO_NO_CACHE` | If the cache layer shouldn't be used in the pack build <br><br> **Choose only one of the example values** | `true` <br> `false` 
 `MAESTRO_ONLY_BUILD` | Stops after build if `true`, leave empty otherwise | `true` 
 `MAESTRO_SKIP_BUILD` | Skips build and process following steps if true, leave empty otherwise | `true` 
 `WORKLOAD_RESOURCE_TAGS` | Tags related to the workload that will be used to all resources provisioned <br><br> *Examples include tag name (case-insensitive) and value* | `workload=myapp` <br> `environment=staging` <br> `owner=me` 
 `WORKLOAD_VPC_ID` | VPC ID of the workload | `vpc-ad1234df` <br> `vpc-qw56er78` <br> `vpc-zxcvghjk` 

### How to build Docker image

Steps to build image

``` bash
$ git clone https://github.com/aws/aws-codebuild-cnb-pack.git
$ docker build -t aws/codebuild/pack:1.0 .
$ docker run -it --entrypoint sh aws/codebuild/pack:1.0 -c bash
```

To let the Docker daemon start up in the container, build it and run: <br>
`docker run -it --privileged aws/codebuild/pack:1.0 bash`

>### Contributing
>Feel free to suggest improvements via pull requests!
