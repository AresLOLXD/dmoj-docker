FROM python:3.11-slim-bookworm

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        texlive-binaries texlive-latex-base texlive-latex-extra texlive-latex-recommended \
        texlive-pictures texlive-pstricks librsvg2-bin xxd imagemagick dvisvgm git && \
    rm -rf /var/lib/apt/lists/* && \
    useradd -m texoid

COPY texoid/policy.xml /etc/ImageMagick-6/policy.xml

RUN git clone https://github.com/DMOJ/texoid/ && \
    cd texoid && git checkout f482221061e0d5e33296e60c77a0ead2c985f649 && rm -rf .git
WORKDIR /texoid/
RUN pip3 install -e .

EXPOSE 8888
USER texoid
ENTRYPOINT texoid --address=texoid --port=8888
