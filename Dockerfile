FROM debian:trixie

# Add FAI repository
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        wget gnupg ca-certificates && \
    wget -qO /etc/apt/trusted.gpg.d/fai-project.gpg \
        https://fai-project.org/download/2BF8D9FE074BCDE4.gpg && \
    echo "deb https://fai-project.org/download trixie koeln" \
        > /etc/apt/sources.list.d/fai.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        fai-quickstart fai-doc git curl openssl && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Install yq (Go-based YAML parser)
RUN ARCH=$(dpkg --print-architecture) && \
    wget -qO /usr/local/bin/yq \
        "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${ARCH}" && \
    chmod +x /usr/local/bin/yq

WORKDIR /workspace
COPY . /workspace/

# fai-setup must run at container runtime (needs --privileged)
# so we do NOT run it during docker build
ENTRYPOINT ["/workspace/build.sh", "--no-docker"]
