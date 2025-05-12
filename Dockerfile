# Multi-stage build Dockerfile for Symfony with development and production support

# PHP dependencies build stage
FROM composer:2 AS composer

WORKDIR /app

# Copy only the files needed for composer install to leverage Docker cache
COPY composer.json composer.lock symfony.lock ./
# Copy importmap.php if it exists
RUN mkdir -p /tmp/app
COPY . /tmp/app
RUN if [ -f /tmp/app/importmap.php ]; then cp /tmp/app/importmap.php ./; fi
RUN rm -rf /tmp/app

# Install dependencies but no scripts as we don't have the complete app yet
RUN composer install --prefer-dist --no-dev --no-scripts --no-progress --no-interaction

# Base PHP stage
FROM php:8.2-fpm AS base

# Install system dependencies and PHP extensions
RUN apt-get update && apt-get install -y \
    git \
    unzip \
    zip \
    curl \
    libicu-dev \
    libzip-dev \
    libonig-dev \
    libpq-dev \
    nginx \
    supervisor \
    gnupg \
    && docker-php-ext-install \
    intl \
    pdo \
    pdo_pgsql \
    zip \
    opcache

# Install Node.js for asset handling
RUN mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list && \
    apt-get update && apt-get install -y nodejs

# Copy composer binary
COPY --from=composer /usr/bin/composer /usr/bin/composer

# Set working directory
WORKDIR /var/www/project

# Dev stage
FROM base AS dev

# Install Symfony CLI for development
RUN curl -sS https://get.symfony.com/cli/installer | bash && \
    mv /root/.symfony*/bin/symfony /usr/local/bin/symfony

# Install development dependencies
COPY --from=composer /app/vendor /var/www/project/vendor
COPY . .
RUN composer install --prefer-dist

# Configure PHP-FPM for development
RUN echo 'memory_limit = 256M' >> /usr/local/etc/php/conf.d/docker-php-ram-limit.ini && \
    echo 'opcache.revalidate_freq = 0' >> /usr/local/etc/php/conf.d/docker-php-opcache.ini && \
    echo 'opcache.validate_timestamps = 1' >> /usr/local/etc/php/conf.d/docker-php-opcache.ini

# Expose port
EXPOSE 8000

# Start Symfony dev server
CMD ["symfony", "server:start", "--no-tls", "--allow-http", "--allow-all-ip"]

# Production stage
FROM base AS prod

# Copy vendor from build stages
COPY --from=composer /app/vendor /var/www/project/vendor

# Copy application files
COPY . .

# Set production environment
ENV APP_ENV=prod
ENV APP_DEBUG=0

# Optimize Composer autoloader and run production scripts
RUN composer dump-autoload --no-dev --classmap-authoritative && \
    composer run-script post-install-cmd --no-dev

# Build assets
RUN bin/console importmap:install

# Configure PHP-FPM for production
RUN echo 'memory_limit = 256M' >> /usr/local/etc/php/conf.d/docker-php-ram-limit.ini && \
    echo 'opcache.memory_consumption = 256' >> /usr/local/etc/php/conf.d/docker-php-opcache.ini && \
    echo 'opcache.max_accelerated_files = 20000' >> /usr/local/etc/php/conf.d/docker-php-opcache.ini && \
    echo 'opcache.validate_timestamps = 0' >> /usr/local/etc/php/conf.d/docker-php-opcache.ini && \
    echo 'realpath_cache_size = 4096K' >> /usr/local/etc/php/conf.d/docker-php-opcache.ini && \
    echo 'realpath_cache_ttl = 600' >> /usr/local/etc/php/conf.d/docker-php-opcache.ini

# Configure Nginx
COPY docker/nginx.conf /etc/nginx/sites-available/default

# Configure Supervisor to run PHP-FPM and Nginx
COPY docker/supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Create required directories and fix permissions
RUN mkdir -p var/cache var/log /var/log/nginx /var/log/supervisor && \
    touch /var/log/nginx/access.log /var/log/nginx/error.log && \
    chown -R www-data:www-data var && \
    chown -R www-data:www-data /var/log/nginx

# Warmup the cache
RUN bin/console cache:warmup --env=prod

# Expose port
EXPOSE 80

# Start supervisor (which manages Nginx and PHP-FPM)
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
