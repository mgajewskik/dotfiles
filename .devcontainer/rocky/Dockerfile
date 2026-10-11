FROM rockylinux/rockylinux:10

RUN dnf install -y file git gnupg2 gzip shadow-utils sudo tar zsh && dnf clean all

RUN useradd --create-home --uid 1000 --shell /bin/zsh dev \
    && echo 'dev ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/dev \
    && chmod 440 /etc/sudoers.d/dev
