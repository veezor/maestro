# AWS CodeBuild Cloud Native Buildpack pack CLI Docker image

This repository holds a Dockerfile based on [AWS CodeBuild Docker Images](https://github.com/aws/aws-codebuild-docker-images) with focus on building [Cloud Native Buildpacks](https://buildpacks.io/) using [`pack CLI`](https://buildpacks.io/docs/tools/pack/#pack-cli).

![Build Status](https://codebuild.us-east-1.amazonaws.com/badges?uuid=eyJlbmNyeXB0ZWREYXRhIjoiZnk2Z2dqdVIzdXpTVXYyWmJ1VGxDVWtLMGZ0OVMybjJQb1M2dmI4c3F4RkpEcWduZ2hxODVkUzdqTlhoVFJUdkg5aFpqL0k3SnFXSVZ0ajYvS0hYK1lNPSIsIml2UGFyYW1ldGVyU3BlYyI6Im96Mjc3amNmMDJmVWp4S2giLCJtYXRlcmlhbFNldFNlcmlhbCI6MX0%3D&branch=main)

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
  install:
    commands:
      - dockerd-entrypoint.sh
  build:
    commands:
      - |
        pack build $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/<image>:<version> \
        --cache-image $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/<image>:cache \
        --buildpack heroku/php,heroku/nodejs --builder heroku/buildpacks:20 --pull-policy if-not-present --publish
```

### How to build Docker image

Steps to build image

```bash
$ git clone https://github.com/aws/aws-codebuild-cnb-pack.git
$ docker build -t aws/codebuild/pack:1.0 .
$ docker run -it --entrypoint sh aws/codebuild/pack:1.0 -c bash
```

To let the Docker daemon start up in the container, build it and run:
`docker run -it --privileged aws/codebuild/pack:1.0 bash`

### Contributing

Feel free to suggest improvements via pull requests!