FROM ruby:3.2-slim

# Install system dependencies
RUN apt-get update && apt-get install -y build-essential libsqlite3-dev && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy Gemfiles
COPY Gemfile Gemfile.lock ./

# Install Gems (with Linux platform fix)
RUN bundle lock --add-platform x86_64-linux
RUN bundle config set --local without 'development test' && bundle install

# Copy Code
COPY . .

# Persistence & User Setup
RUN mkdir -p /app/data
ENV DB_PATH=/app/data/processed_tickets.db
RUN useradd -m botuser && chown -R botuser:botuser /app
USER botuser

CMD ["bundle", "exec", "ruby", "bin/start_bot"]