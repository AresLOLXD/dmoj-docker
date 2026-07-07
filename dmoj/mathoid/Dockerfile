FROM node:24-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates && \
    rm -rf /var/lib/apt/lists/* && \
    git clone https://gitlab.wikimedia.org/repos/mediawiki/services/mathoid.git /node_modules/mathoid && \
    cd /node_modules/mathoid && \
    git checkout 3eeedbb879dd2316eac7d0c0b8a5da02c6601050 && \
    rm -rf .git && \
    npm ci --omit=dev && \
    ln -sfv /node_modules/mathoid/app.js /node_modules/app.js

EXPOSE 10044
WORKDIR /node_modules/mathoid
CMD /node_modules/mathoid/server.js
