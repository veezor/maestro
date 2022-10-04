FROM public.ecr.aws/amazonlinux/amazonlinux:2 AS core

ARG BUILDARCH

# Install git, SSH, and other utilities
RUN set -ex \
    && yum install -y openssh-clients \
    && mkdir ~/.ssh \
    && mkdir ~/.docker \
    && echo '{"credsStore":"ecr-login"}' > ~/.docker/config.json \
    && touch ~/.ssh/known_hosts \
    && ssh-keyscan -t rsa,dsa -H github.com >> ~/.ssh/known_hosts \
    && ssh-keyscan -t rsa,dsa -H bitbucket.org >> ~/.ssh/known_hosts \
    && chmod 600 ~/.ssh/known_hosts \
    && amazon-linux-extras enable docker \
    && yum groupinstall -y "Development tools" \
    && yum install -y gzip openssl openssl-devel libcurl-devel expat-devel tar vim wget which jq iptables \
       amazon-ecr-credential-helper

RUN useradd codebuild-user

#=======================End of layer: core  =================

FROM core AS tools

ARG BUILDARCH

# Install Git
RUN set -ex \
   && GIT_VERSION=2.27.0 \
   && GIT_TAR_FILE=git-$GIT_VERSION.tar.gz \
   && GIT_SRC=https://github.com/git/git/archive/v${GIT_VERSION}.tar.gz  \
   && curl -L -o $GIT_TAR_FILE $GIT_SRC \
   && tar zxvf $GIT_TAR_FILE \
   && cd git-$GIT_VERSION \
   && make -j4 prefix=/usr \
   && make install prefix=/usr \
   && cd .. ; rm -rf git-$GIT_VERSION \
   && rm -rf $GIT_TAR_FILE /tmp/*

# Install stunnel
RUN set -ex \
   && STUNNEL_VERSION=5.56 \
   && STUNNEL_TAR=stunnel-$STUNNEL_VERSION.tar.gz \
   && STUNNEL_SHA256="7384bfb356b9a89ddfee70b5ca494d187605bb516b4fff597e167f97e2236b22" \
   && curl -o $STUNNEL_TAR https://www.usenix.org.uk/mirrors/stunnel/archive/5.x/$STUNNEL_TAR \
   && echo "$STUNNEL_SHA256 $STUNNEL_TAR" | sha256sum -c - \
   && tar xvfz $STUNNEL_TAR \
   && cd stunnel-$STUNNEL_VERSION \
   && ./configure \
   && make -j4 \
   && make install \
   && openssl genrsa -out key.pem 2048 \
   && openssl req -new -x509 -key key.pem -out cert.pem -days 1095 -subj "/C=US/ST=Washington/L=Seattle/O=Amazon/OU=Codebuild/CN=codebuild.amazon.com" \
   && cat key.pem cert.pem >> /usr/local/etc/stunnel/stunnel.pem \
   && cd .. ; rm -rf stunnel-${STUNNEL_VERSION}*

# AWS Tools
# https://docs.aws.amazon.com/eks/latest/userguide/install-aws-iam-authenticator.html https://docs.aws.amazon.com/AmazonECS/latest/developerguide/ECS_CLI_installation.html https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
RUN curl -sS -o /usr/local/bin/aws-iam-authenticator "https://amazon-eks.s3.us-west-2.amazonaws.com/1.16.8/2020-04-16/bin/linux/${BUILDARCH}/aws-iam-authenticator" \
    && curl -sS -o /usr/local/bin/kubectl "https://amazon-eks.s3.us-west-2.amazonaws.com/1.16.8/2020-04-16/bin/linux/${BUILDARCH}/kubectl" \
    && curl -sS -o /usr/local/bin/ecs-cli "https://s3.amazonaws.com/amazon-ecs-cli/ecs-cli-linux-${BUILDARCH}-latest" \
    && if [ "$BUILDARCH" = "arm64" ]; then YUMBUILDARCH=aarch64; else YUMBUILDARCH=x86_64; fi \
    && curl -sS -o awscliv2.zip https://awscli.amazonaws.com/awscli-exe-linux-${YUMBUILDARCH}.zip \
    && curl -sS -L "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_Linux_${BUILDARCH}.tar.gz" | tar xz -C /usr/local/bin \
    && chmod +x /usr/local/bin/kubectl /usr/local/bin/aws-iam-authenticator /usr/local/bin/ecs-cli /usr/local/bin/eksctl

# Configure SSM & AWS CLI
RUN set -ex \
    && yum install -y "https://s3.amazonaws.com/amazon-ssm-us-east-1/2.3.1644.0/linux_${BUILDARCH}/amazon-ssm-agent.rpm" \
    && unzip awscliv2.zip \
    && ./aws/install \
    && aws --version

#=======================End of layer: tools  =================

FROM tools AS runtimes

ARG BUILDARCH

#Docker 19
ENV DOCKER_BUCKET="download.docker.com" \
    DOCKER_CHANNEL="stable" \
    DIND_COMMIT="3b5fac462d21ca164b3778647420016315289034" \
    DOCKER_COMPOSE_VERSION="2.7.0"

ENV DOCKER_SHA256_X86_64="caf74e54b58c0b38bb4d96c8f87665f29b684371c9a325562a3904b8c389995e"
ENV DOCKER_SHA256_AARCH64="0259f8b6572f02cf0dafd7388ca0e4adfdbbfaba81cfb1b7443e89fccbed22c7"
ENV DOCKER_VERSION="20.10.9"

VOLUME /var/lib/docker

RUN set -ex \
    && if [ "$BUILDARCH" = "arm64" ]; then YUMBUILDARCH=aarch64; else YUMBUILDARCH=x86_64; fi \
    && if [ "$BUILDARCH" = "arm64" ]; then DOCKER_SHA256=${DOCKER_SHA256_AARCH64}; else DOCKER_SHA256=${DOCKER_SHA256_X86_64}; fi \
    && curl -fSL "https://${DOCKER_BUCKET}/linux/static/${DOCKER_CHANNEL}/${YUMBUILDARCH}/docker-${DOCKER_VERSION}.tgz" -o docker.tgz \
    && echo "${DOCKER_SHA256} *docker.tgz" | sha256sum -c - \
    && tar --extract --file docker.tgz --strip-components 1  --directory /usr/local/bin/ \
    && rm docker.tgz \
    && docker -v \
    # set up subuid/subgid so that "--userns-remap=default" works out-of-the-box \
    && groupadd dockremap \
    && groupadd docker \
    && useradd -g dockremap dockremap \
    && echo 'dockremap:165536:65536' >> /etc/subuid \
    && echo 'dockremap:165536:65536' >> /etc/subgid \
    && wget -nv "https://raw.githubusercontent.com/docker/docker/${DIND_COMMIT}/hack/dind" -O /usr/local/bin/dind \
    && curl -L "https://github.com/docker/compose/releases/download/v${DOCKER_COMPOSE_VERSION}/docker-compose-linux-${YUMBUILDARCH}" > /usr/local/bin/docker-compose \
    && chmod +x /usr/local/bin/dind /usr/local/bin/docker-compose \
    && docker-compose version

# Install Cloud Native Buildpacks pack CLI
RUN set -ex \
   && PACK_VERSION=0.21.0 \
   && if [ "$BUILDARCH" = "arm64" ]; then PACK_BUILDARCH=-arm64; fi \
   && (curl -sSL "https://github.com/buildpacks/pack/releases/download/v${PACK_VERSION}/pack-v${PACK_VERSION}-linux${PACK_BUILDARCH}.tgz" | tar -C /usr/local/bin/ --no-same-owner -xzv pack)

#=======================End of layer: runtimes  =================
FROM runtimes AS maestro_v1

# Configure SSH
COPY ssh_config /root/.ssh/config
COPY runtimes.yml /codebuild/image/config/runtimes.yml
COPY *.sh /usr/local/bin/
COPY templates/* /templates/
COPY amazon-ssm-agent.json          /etc/amazon/ssm/

ENTRYPOINT ["dockerd-entrypoint.sh"]

#=======================End of layer: maestro_v1  =================
