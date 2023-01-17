ARG RUBY_VERSION=3.1
ARG GEM_VERSION=2.0.7

FROM ruby:${RUBY_VERSION}

RUN gem install prometheus_exporter --version=${GEM_VERSION}

EXPOSE 9394
ENTRYPOINT ["prometheus_exporter", "-b", "ANY"]
