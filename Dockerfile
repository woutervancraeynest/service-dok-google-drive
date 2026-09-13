FROM ruby:3.3-slim

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY Gemfile Gemfile.lock ./
RUN bundle install --without development test --jobs 4 && \
    rm -rf /usr/local/bundle/cache

COPY . .

EXPOSE 8080

CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
