<?php

declare(strict_types=1);

namespace Esuiss\Relay;

/**
 * ISO 8601 durations of fixed length (weeks, days, hours, minutes, seconds).
 */
final class Duration
{
    /**
     * The length of a duration in seconds, or null when it is malformed or uses years or months.
     */
    public static function seconds(string $duration): ?float
    {
        $pattern = '/^P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?)?$/';
        if ($duration === 'P' || str_ends_with($duration, 'T') || preg_match($pattern, $duration, $m) !== 1) {
            return null;
        }
        $part = static fn (int $index): float => isset($m[$index]) && $m[$index] !== '' ? (float) $m[$index] : 0.0;

        return $part(1) * 604800 + $part(2) * 86400 + $part(3) * 3600 + $part(4) * 60 + $part(5);
    }
}
