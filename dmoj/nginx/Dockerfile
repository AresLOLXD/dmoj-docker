FROM nginx:alpine

COPY docker-entrypoint-resolver.sh /docker-entrypoint.d/00-resolver.sh
RUN chmod +x /docker-entrypoint.d/00-resolver.sh
