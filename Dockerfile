# Dockerfile -- builds the Angular "conduit" frontend into a static nginx image.
#
# Two stages: (1) a Bun-capable image compiles the Angular app with `bun run build`;
# (2) an unprivileged nginx image serves the resulting static bundle. Only the final
# stage ships -- the Bun toolchain and node_modules never reach the runtime image.
#
# Closes F7 (the repo's Netlify-only `_redirects` file is inert here; nginx.conf
# provides the real SPA fallback) and F20 (no Dockerfile existed upstream).

# ---- Stage 1: build ----
# oven/bun:1 is the official Bun runtime image (Debian-slim based), pinned to the
# major version so the build tracks Bun 1.x patch/security releases without pinning
# to an exact patch that could drift from what `bun.lock` was generated against.
# It ships `bun` preinstalled, which this repo's package.json/bun.lock expect.
FROM oven/bun:1 AS build

WORKDIR /app

# husky's "prepare" script (`husky install`) can be flaky when run inside a
# container build, even when a .git directory is present. HUSKY=0 makes it a no-op.
# Cheap insurance per the plan -- costs nothing, prevents a class of build failures (F13).
ENV HUSKY=0

# Copy only the manifest files first so `bun install` is cached in its own layer:
# it only re-runs when package.json or bun.lock actually change, not on every
# source edit. Same layer-caching rationale as the backend's Go module cache.
COPY package.json bun.lock ./
RUN bun install --frozen-lockfile

# Now copy the rest of the source, including the populated `realworld/` git
# submodule -- `ng build` sources global styles/assets from realworld/assets
# (see angular.json). .dockerignore deliberately does NOT exclude realworld/.
COPY . .

# Emits to dist/angular-conduit/{browser,server-adjacent files}. The Angular
# "application" builder splits the output into a browser/ subfolder -- confirmed
# empirically in Step 1.8 -- so stage 2 copies from dist/angular-conduit/browser/,
# never from dist/angular-conduit/ itself (that level also holds server-side
# artifacts like 3rdpartylicenses.txt and prerendered-routes.json, not just the
# servable app).
RUN bun run build

# ---- Stage 2: runtime ----
# nginxinc/nginx-unprivileged already runs its master process as the built-in
# "nginx" user (uid 101) and listens on 8080 by default -- verified via
# `docker inspect` (Config.User=101, ExposedPorts=8080/tcp) -- so no extra USER/
# permission plumbing is needed to satisfy "non-root, port > 1024". Using the
# purpose-built unprivileged image is simpler and less error-prone than manually
# re-permissioning stock nginx:alpine's root-owned paths (pid file, temp dirs).
FROM nginxinc/nginx-unprivileged:1.27-alpine AS runtime

# Full replacement of the image's default nginx.conf: adds the SPA fallback,
# differentiated cache headers, /healthz, gzip, and security headers (see nginx.conf
# for the reasoning behind each). Runs fine as-is under uid 101 -- /etc/nginx is
# group-writable by nginx:root in this base image, and the file only needs to be
# readable at runtime, which default COPY permissions already provide.
COPY nginx.conf /etc/nginx/nginx.conf

# Copy exactly the browser output -- see the stage-1 comment on why "browser/" and
# not the parent dist/angular-conduit/ directory.
COPY --from=build /app/dist/angular-conduit/browser/ /usr/share/nginx/html/

EXPOSE 8080

# Lets `docker ps` / orchestrators see container health without an external prober;
# hits the same no-disk-touch /healthz location the acceptance tests use.
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8080/healthz || exit 1
