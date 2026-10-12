# nginx-git-static
#
# A small nginx image that keeps a shallow (depth=1, single branch) view of a
# git repository and publishes it as static content on port 8080 with zero
# downtime: each new commit lands in an immutable release directory that is
# swapped in atomically, so nginx never needs a reload and never serves a
# partially written tree.
#
# Build:
#   docker build -t nginx-git-static .
# Pin a different base when you need to:
#   docker build --build-arg NGINX_IMAGE=nginx:1.27-alpine -t nginx-git-static .

ARG NGINX_IMAGE=nginx:stable-alpine
FROM ${NGINX_IMAGE}

LABEL org.opencontainers.image.title="nginx-git-static" \
      org.opencontainers.image.description="nginx serving a static site continuously deployed from a git branch"

# git + ssh for the pull loop, coreutils for an atomic `mv -T` symlink swap,
# ca-certificates for https remotes.
RUN apk add --no-cache git openssh-client ca-certificates coreutils \
 && rm -rf /var/cache/apk/*

# Serve on 8080 from the atomically swapped "current" symlink. The `location /`
# fallback is not static -- it depends on SPA -- so it is included from a snippet
# the entrypoint rewrites at startup. The copy here is the SPA=0 default: it
# keeps the image's own config valid when nginx is run without the entrypoint.
RUN rm -f /etc/nginx/conf.d/default.conf
COPY nginx/default.conf /etc/nginx/conf.d/default.conf
COPY nginx/routing.conf /etc/nginx/webhost/routing.conf

# Page shown until the very first release is published.
COPY bootstrap/ /usr/share/webhost/bootstrap/

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

# Set modes explicitly so the image does not depend on the build host's umask.
RUN chmod 0644 /etc/nginx/conf.d/default.conf /etc/nginx/webhost/routing.conf /usr/share/webhost/bootstrap/* \
 && chmod 0755 /usr/local/bin/docker-entrypoint.sh

ENV PULL_INTERVAL=30s \
    BRANCH=main \
    WORK_DIR=/var/www/repo \
    RELEASES_DIR=/var/www/releases \
    CURRENT_LINK=/var/www/current \
    BOOTSTRAP_DIR=/var/www/bootstrap \
    SPA=0

EXPOSE 8080

# The pull loop stays alive even if the remote is temporarily unreachable, so
# health only reflects whether nginx can answer requests.
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1:8080/healthz || exit 1

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
