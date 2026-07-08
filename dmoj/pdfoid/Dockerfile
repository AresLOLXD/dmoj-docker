FROM python:3.11-slim-bookworm

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        curl gnupg git unzip xvfb libxi6 libgconf-2-4 exiftool && \
    curl -fsSL https://dl-ssl.google.com/linux/linux_signing_key.pub | gpg --dearmor -o /etc/apt/keyrings/google-chrome.gpg && \
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" >> /etc/apt/sources.list.d/google-chrome.list && \
    sed -i 's/^Components: main$/& contrib non-free/' /etc/apt/sources.list.d/debian.sources && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        google-chrome-stable=150.0.7871.100-1 fonts-noto ttf-mscorefonts-installer && \
    rm -rf /var/lib/apt/lists/* && \
    curl -fsSL https://storage.googleapis.com/chrome-for-testing-public/150.0.7871.49/linux64/chromedriver-linux64.zip -o chromedriver_linux64.zip && \
    unzip chromedriver_linux64.zip && \
    mv chromedriver-linux64/chromedriver /usr/bin/chromedriver && \
    chmod +x /usr/bin/chromedriver && \
    rm -rf chromedriver_linux64.zip chromedriver-linux64 && \
    useradd -m pdfoid

RUN git clone https://github.com/DMOJ/pdfoid.git pdfoid && \
    cd pdfoid && git checkout 55ebc64794d6531fc2837db28869e1b7c6cc6894 && rm -rf .git
WORKDIR /pdfoid/
RUN pip3 install -e .

ENV CHROME_PATH=/usr/bin/google-chrome-stable
ENV CHROMEDRIVER_PATH=/usr/bin/chromedriver
ENV EXIFTOOL_PATH=/usr/bin/exiftool

EXPOSE 8888
USER pdfoid
ENTRYPOINT pdfoid --address=pdfoid --port=8888
