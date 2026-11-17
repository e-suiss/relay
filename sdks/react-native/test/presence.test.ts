import { describe, expect, it } from 'vitest';
import { DeviceStatusWriter, statusTtl, validSignals } from '../src/presence';
import { DEVICE_ID } from './fakes';
import { fakeClock, json, problem, recordingLogger, testHttp } from './helpers';

const status = { object: 'device_status', device_id: DEVICE_ID, version: 'v1', signals: {} };

function setup(respond: () => Response = () => json(200, status)) {
  const clock = fakeClock();
  const logger = recordingLogger();
  const harness = testHttp(respond, { clock, logger });
  const writer = new DeviceStatusWriter(
    harness.http,
    () => Promise.resolve(DEVICE_ID),
    clock,
    logger,
  );
  return { ...harness, writer, clock, logger };
}

describe('IN-47 IN-48 IN-53 device status signals', () => {
  it('IN-53 writes only dictionary v1 booleans with a clamped time to live', () => {
    expect(validSignals({ worn: true, locked: 'yes', mood: true, focus: false })).toEqual({
      worn: true,
      focus: false,
    });
    expect(statusTtl()).toBe('PT300S');
    expect(statusTtl(5000)).toBe('PT900S');
    expect(statusTtl(0)).toBe('PT1S');
  });

  it('IN-53 writes at most once a second and merges changes made in between', async () => {
    const { writer, requests, clock } = setup();
    writer.update({ locked: true });
    await clock.advance(0);
    writer.update({ headphones: true });
    writer.update({ focus: true });
    await clock.advance(500);
    expect(requests).toHaveLength(1);
    await clock.advance(500);
    expect(requests).toHaveLength(2);
    expect(requests[0]?.body).toEqual({ version: 'v1', signals: { locked: true }, ttl: 'PT300S' });
    expect(requests[1]?.body).toEqual({
      version: 'v1',
      signals: { headphones: true, focus: true },
      ttl: 'PT300S',
    });
    expect(requests[0]?.method).toBe('PATCH');
    expect(requests[0]?.path).toBe(`/v1/subscriber/devices/${DEVICE_ID}/status`);
  });

  it('IN-47 takes no Idempotency-Key and keeps nothing on the device', async () => {
    const { writer, requests, clock, store } = setup();
    writer.update({ worn: true }, 60);
    await clock.advance(0);
    expect(requests[0]?.headers['Idempotency-Key']).toBeUndefined();
    expect(store.entries.size).toBe(0);
  });

  it('IN-48 never logs a status value, even when the write fails', async () => {
    const { writer, clock, logger } = setup(() => problem(422, 'unknown_field'));
    writer.update({ worn: true, locked: false, headphones: true, focus: false, break: true });
    await clock.advance(0);
    const logged = JSON.stringify(logger.events);
    for (const name of ['worn', 'locked', 'headphones', 'focus', 'break', 'true', 'false']) {
      expect(logged).not.toContain(name);
    }
    expect(logger.events.length).toBeGreaterThan(0);
  });

  it('IN-53 a rate-limited write is merged into the next slot', async () => {
    let calls = 0;
    const { writer, requests, clock } = setup(() => {
      calls += 1;
      return calls === 1 ? problem(429, 'rate_limited') : json(200, status);
    });
    writer.update({ locked: true });
    await clock.advance(0);
    writer.update({ focus: true });
    await clock.advance(1000);
    expect(requests).toHaveLength(2);
    expect(requests[1]?.body).toMatchObject({ signals: { locked: true, focus: true } });
  });
});
