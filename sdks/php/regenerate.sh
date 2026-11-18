#!/usr/bin/env bash
# X-48
# X-53
set -euo pipefail

cd "$(dirname "$0")"
composer install --no-interaction --no-progress --no-plugins --no-scripts
php codegen/generate.php
