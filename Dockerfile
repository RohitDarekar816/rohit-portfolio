# Use an official PHP 8 image with common extensions
FROM php:8.2-cli

# Install system dependencies
RUN apt-get update && apt-get install -y \
    git \
    unzip \
    zip \
    curl \
    libicu-dev \
    libzip-dev \
    libonig-dev \
    libpq-dev \
    && docker-php-ext-install intl pdo pdo_mysql zip opcache

# Install Composer globally
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

# Set working directory
WORKDIR /var/www/project

# Copy project files to the container
COPY . .

# Install PHP dependencies using Composer
RUN composer install

RUN curl -sS https://get.symfony.com/cli/installer | bash && \
    mv /root/.symfony*/bin/symfony /usr/local/bin/symfony

# Expose port used by Symfony server
EXPOSE 8000

# Start Symfony local server
CMD ["symfony", "server:start", "--no-tls", "--allow-http"]
