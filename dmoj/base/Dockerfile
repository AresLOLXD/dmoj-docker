FROM node:24-bookworm AS node

FROM python:3.11-slim-bookworm

RUN apt-get update && \
    apt-get install -y \
        git gcc g++ make curl gettext wget \
        libxml2-dev libxslt1-dev zlib1g-dev \
        mariadb-client libmariadb-dev \
        libjpeg-dev debconf-utils pkg-config && \
    apt-get autoremove -y && \
    rm -rf /var/lib/apt/lists/*

COPY --from=node /usr/local /usr/local

RUN npm install -g sass@1.83.0 postcss-cli@11.0.1 postcss@8.5.16 autoprefixer@10.5.2
RUN pip3 install \
        pymysql==1.2.0 mysqlclient==2.2.8 websocket-client==1.9.0 \
        uwsgi==2.0.31 django-redis==5.4.0 redis==5.2.1

COPY repo/requirements.txt .
RUN pip3 install -r requirements.txt
