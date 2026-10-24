# =====================================================
# DevOps / AWS / Kubernetes Workstation
# Base: Ubuntu 24.04
# =====================================================

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# =====================================================
# Versions (fixed for stability)
# =====================================================

ARG KUBECTL_VERSION=v1.33.1
ARG HELM_VERSION=v3.18.2
ARG TERRAFORM_VERSION=1.12.1

# =====================================================
# Base packages
# =====================================================

RUN apt-get update && \
    apt-get install -y \
      curl \
      wget \
      git \
      unzip \
      zip \
      jq \
      yq \
      less \
      groff \
      dos2unix \
      ca-certificates \
      procps \
      iputils-ping \
      dnsutils \
      net-tools \
      telnet \
      traceroute \
      vim \
      nano \
      tree \
      make \
      bash-completion \
      software-properties-common \
      gnupg \
      lsb-release \
      python3 \
      python3-pip \
      mysql-client \
      postgresql-client && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# =====================================================
# AWS CLI v2
# =====================================================

RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" \
      -o "/tmp/awscliv2.zip" && \
    unzip /tmp/awscliv2.zip -d /tmp && \
    /tmp/aws/install && \
    rm -rf /tmp/aws /tmp/awscliv2.zip

# =====================================================
# kubectl
# =====================================================

RUN curl -LO \
    "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" && \
    install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl && \
    rm kubectl

# =====================================================
# Helm
# =====================================================

RUN curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# =====================================================
# GitHub CLI (gh)
# =====================================================

RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | \
    dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg && \
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update && \
    apt-get install -y gh && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# =====================================================
# eksctl
# =====================================================

RUN ARCH=amd64 && \
    PLATFORM=$(uname -s)_$ARCH && \
    curl -sLO \
    "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_${PLATFORM}.tar.gz" && \
    tar -xzf eksctl_${PLATFORM}.tar.gz -C /tmp && \
    mv /tmp/eksctl /usr/local/bin && \
    rm eksctl_${PLATFORM}.tar.gz

# =====================================================
# Terraform
# =====================================================

RUN wget https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip && \
    unzip terraform_${TERRAFORM_VERSION}_linux_amd64.zip && \
    mv terraform /usr/local/bin/ && \
    rm terraform_${TERRAFORM_VERSION}_linux_amd64.zip

# =====================================================
# AWS Session Manager Plugin
# =====================================================

RUN curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" \
      -o "/tmp/session-manager-plugin.deb" && \
    dpkg -i /tmp/session-manager-plugin.deb && \
    rm /tmp/session-manager-plugin.deb

# =====================================================
# k9s
# =====================================================

RUN curl -sS https://webinstall.dev/k9s | bash

ENV PATH="/root/.local/bin:${PATH}"

# =====================================================
# kubectx + kubens
# =====================================================

RUN git clone https://github.com/ahmetb/kubectx /opt/kubectx && \
    ln -s /opt/kubectx/kubectx /usr/local/bin/kubectx && \
    ln -s /opt/kubectx/kubens /usr/local/bin/kubens

# =====================================================
# stern (multi pod logs)
# =====================================================

RUN STERN_VERSION=$(curl -s https://api.github.com/repos/stern/stern/releases/latest | jq -r .tag_name) && \
    curl -L -o stern.tar.gz \
    "https://github.com/stern/stern/releases/download/${STERN_VERSION}/stern_${STERN_VERSION#v}_linux_amd64.tar.gz" && \
    tar -xzf stern.tar.gz && \
    mv stern /usr/local/bin/stern && \
    chmod +x /usr/local/bin/stern && \
    rm stern.tar.gz

# =====================================================
# Docker CLI
# (cliente solamente para usar docker host)
# =====================================================

RUN curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker.gpg && \
    echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list && \
    apt-get update && \
    apt-get install -y docker-ce-cli && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# =====================================================
# Script: fix CRLF line endings (Windows → Unix)
# =====================================================

RUN printf '#!/bin/bash\n\
# fix-crlf — convierte archivos Windows CRLF a Unix LF\n\
# Uso: fix-crlf [directorio, default /root/work]\n\
TARGET="${1:-/root/work}"\n\
echo "==> Corrigiendo CRLF → LF en: $TARGET"\n\
find "$TARGET" -type f \\( -name "*.sh" -o -name "*.yaml" -o -name "*.yml" -o -name "*.py" -o -name "*.env" -o -name "*.conf" \\) \\\n\
    -exec sh -c '"'"'file="$1"; if grep -q $'"'"'\\r'"'"'$ "$file" 2>/dev/null; then dos2unix -q "$file" && echo "  OK: $file"; fi'"'"' _ {} \\;\n\
echo "==> Listo."\n' > /usr/local/bin/fix-crlf && chmod +x /usr/local/bin/fix-crlf

# =====================================================
# Bash enhancements
# =====================================================

RUN echo 'alias k=kubectl' >> /root/.bashrc && \
    echo 'alias ks=kubens' >> /root/.bashrc && \
    echo 'alias kx=kubectx' >> /root/.bashrc && \
    echo 'alias fixwin=fix-crlf' >> /root/.bashrc && \
    echo 'source <(kubectl completion bash)' >> /root/.bashrc && \
    echo 'complete -F __start_kubectl k' >> /root/.bashrc

# =========================================================
# Configuración Git
# =========================================================

RUN git config --global init.defaultBranch main && \
    git config --global color.ui auto && \
    git config --global user.email "you@example.com" && \
    git config --global user.name "Your Name"


# =====================================================
# Workspace
# =====================================================

WORKDIR /root/work

# =====================================================
# Health / Validation
# =====================================================

RUN aws --version && \
    kubectl version --client && \
    helm version && \
    terraform version && \
    eksctl version && \
    gh --version

RUN rm -rf /root/.ssh/github*

# =====================================================
# Arranque: corregir CRLF automaticamente y luego bash
# =====================================================

CMD ["/bin/bash", "-c", "fix-crlf /root/work 2>/dev/null; exec /bin/bash"]