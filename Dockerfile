ARG RUBY_VERSION=3.1
ARG GEM_VERSION=

FROM ruby:${RUBY_VERSION}-slim

RUN gem install --no-doc --version=${GEM_VERSION} prometheus_exporter

EXPOSE 9394
ENTRYPOINT ["prometheus_exporter", "-b", "ANY"]
