FROM debian:trixie

# Add FAI repository and install all dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        wget gnupg ca-certificates && \
    wget -qO /etc/apt/trusted.gpg.d/fai-project.gpg \
        https://fai-project.org/download/2BF8D9FE074BCDE4.gpg && \
    echo "deb https://fai-project.org/download trixie koeln" \
        > /etc/apt/sources.list.d/fai.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        fai-quickstart fai-doc git curl openssl jq python3-yaml \
        dosfstools mtools && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
COPY . /workspace/

# fai-setup must run at container runtime (needs --privileged)
# so we do NOT run it during docker build
ENTRYPOINT ["/workspace/build.sh", "--no-docker"]
