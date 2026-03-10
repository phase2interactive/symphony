FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

# Avoid prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install system dependencies for Erlang/Elixir compilation and native deps
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    autoconf \
    libncurses5-dev \
    libssl-dev \
    unixodbc-dev \
    libwxgtk3.2-dev \
    libwxgtk-webview3.2-dev \
    libsctp-dev \
    libgmp-dev \
    curl \
    git \
    inotify-tools \
    && rm -rf /var/lib/apt/lists/*

# Install mise (runtime version manager)
RUN curl https://mise.run | sh \
    && echo 'eval "$(~/.local/bin/mise activate bash)"' >> /etc/bash.bashrc

# Switch to vscode user for mise installs
USER vscode

# Install mise for the vscode user
RUN curl https://mise.run | sh \
    && echo 'eval "$(~/.local/bin/mise activate bash)"' >> ~/.bashrc \
    && echo 'eval "$(~/.local/bin/mise activate zsh)"' >> ~/.zshrc

# Pre-install Erlang/Elixir via mise (uses the project's mise.toml)
# This speeds up first container start significantly
COPY --chown=vscode:vscode elixir/mise.toml /tmp/mise.toml
RUN cd /tmp && ~/.local/bin/mise trust /tmp/mise.toml && ~/.local/bin/mise install

# Install Node.js for Playwright E2E tests
RUN ~/.local/bin/mise use --global node@lts

# Install just command runner
RUN ~/.local/bin/mise use --global just

USER root
