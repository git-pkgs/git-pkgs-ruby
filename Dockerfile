FROM ruby:3.4-alpine

RUN apk add --no-cache \
    build-base \
    git \
    libgit2-dev \
    cmake

RUN gem install git-pkgs

ENTRYPOINT ["git", "pkgs"]
