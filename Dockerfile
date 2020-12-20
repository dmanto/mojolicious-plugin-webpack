FROM perl:5.32.0-slim-buster
RUN apt-get update && \
    apt-get install -y curl && \
    curl -sL https://deb.nodesource.com/setup_14.x | bash - && \
    apt-get install -y nodejs
COPY . /app
WORKDIR /app
RUN cpanm --installdeps .