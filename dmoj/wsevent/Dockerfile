FROM node:26.5.0-alpine3.24

WORKDIR /app/
RUN npm install qu@0.1.0 ws@8.21.1 simplesets@1.2.0 && \
    chown -R node:node /app

EXPOSE 15100
EXPOSE 15101
EXPOSE 15102

USER node

ENTRYPOINT node /app/site/websocket/daemon.js
