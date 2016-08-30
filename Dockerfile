FROM rabbitmq:3.6.5-management

ENV RABBITMQ_DEFAULT_USER=guest
ENV RABBITMQ_DEFAULT_PASS=guest
ENV RABBITMQ_ERLANG_COOKIE=supersecretcookie
ENV SERVICE_15672_IGNORE=true
ENV SERVICE_5672_IGNORE=true

RUN apt-get update && apt-get install -y jq curl dnsutils

COPY docker-entrypoint.sh /usr/local/bin/
