FROM ruby:4.0-alpine

RUN apk add --no-cache \
    build-base \
    git \
    libgit2-dev \
    cmake

RUN gem install git-pkgs

# The git repository (the mounted directory) has different ownership that the root user of the container.
# Due to an update in git, a different user cannot perform git operations on the mounted directory.
# This command allows the any user to perform git operations on the mounted directory.
RUN git config --system --add safe.directory /mnt

WORKDIR /mnt

ENTRYPOINT ["git", "pkgs"]
