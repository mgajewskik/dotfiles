FROM archlinux:latest

RUN pacman -Syu --noconfirm --needed git gnupg sudo zsh && yes | pacman -Scc

RUN useradd --create-home --uid 1000 --shell /bin/zsh dev \
    && echo 'dev ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/dev \
    && chmod 440 /etc/sudoers.d/dev
