<?php

declare(strict_types=1);

require __DIR__ . '/../vendor/autoload.php';
require __DIR__ . '/Generator.php';

use Esuiss\Relay\Codegen\Generator;

$root = dirname(__DIR__, 3);
$generator = new Generator(
    $root . '/contracts/openapi/server.yaml',
    $root . '/contracts/errors.yaml',
);

$target = dirname(__DIR__) . '/src/Generated';
if (!is_dir($target)) {
    mkdir($target, 0o755, true);
}

foreach ($generator->files() as $name => $source) {
    file_put_contents($target . '/' . $name, $source);
}
