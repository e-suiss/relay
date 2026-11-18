package app.suiss.relay;

import java.time.Duration;

/** Waits between retries and polls. Replace it in tests to run without waiting. */
@FunctionalInterface
public interface Sleeper {
  /** The sleeper that blocks the calling thread. */
  Sleeper SYSTEM = duration -> Thread.sleep(duration.toMillis());

  /**
   * Waits for the duration.
   *
   * @param duration how long to wait
   * @throws InterruptedException when the thread is interrupted
   */
  void sleep(Duration duration) throws InterruptedException;
}
