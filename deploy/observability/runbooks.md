# Relay alert runbooks

Every alert rule in `alerts.yaml` links here with its `runbook_url`. Each entry says what the alert means, what to check first and what to do.

## RelayPartitionHorizon

- **Meaning:** A partitioned table has fewer premade partitions than its alarm horizon.
- **Check:** Check the `partition_maintenance` task's logs and leader; run the task by hand if it is stuck.
- **Action:** Restore the task; inserts fail once the last partition bound passes.

## RelaySingletonLeaderless

- **Meaning:** A singleton task has had no leader for five minutes.
- **Check:** Check that worker nodes run and reach PostgreSQL; read `relay_ops.singleton_leases`.
- **Action:** Restart a worker node or fix the database connection; the next leader continues from the saved state.

## RelayAuditCheckpointOverdue

- **Meaning:** An audit record was integrated after the declared checkpoint interval.
- **Check:** Check the `audit_checkpoint` task and the key store.
- **Action:** Restore the task; the interval is a published promise.

## RelayAuditCheckpointUnpublished

- **Meaning:** A signed checkpoint reached no publication target.
- **Check:** Check the object store and every configured publisher.
- **Action:** Restore at least one target; an unpublished checkpoint proves nothing.

## RelayAuditMismatch

- **Meaning:** Audit verification or read-back found a mismatch.
- **Check:** Compare the reported checkpoint with the published copy.
- **Action:** Treat it as a security incident; freeze the audit log and investigate.

## RelayQueuePolling

- **Meaning:** The job queue notifier or stager has fallen back to polling.
- **Check:** Check Valkey connectivity and the notifier logs.
- **Action:** Restore Valkey; jobs still run, with higher latency.

## RelayIntegrityViolation

- **Meaning:** The nightly integrity check found orphan or broken references.
- **Check:** Read the task's saved report for the table and check.
- **Action:** Find the writer that skipped the database function; never repair by deleting rows.

## RelayIntegrityStale

- **Meaning:** The nightly integrity check has not completed for 36 hours.
- **Check:** Check the `integrity_check` task and its leader.
- **Action:** Restore the task and let one run complete.

## RelayIntegrityUnreported

- **Meaning:** No node has reported a completed integrity check for 36 hours.
- **Check:** Check that worker nodes run with leadership enabled.
- **Action:** Start a worker node; the check runs on workers only.

## RelayProjectionDifference

- **Meaning:** The weekly rebuild found a delivery projection that differs from its ledger.
- **Check:** Read the rebuild report for the scope.
- **Action:** The ledger wins; find the code path that changed the projection without a ledger row.

## RelayQueryStatsMissing

- **Meaning:** PostgreSQL does not preload pg_stat_statements.
- **Check:** Check `shared_preload_libraries`.
- **Action:** Add the library and restart PostgreSQL in a maintenance window.

## RelayValkeyEvictionPolicy

- **Meaning:** Valkey runs with an eviction policy other than noeviction.
- **Check:** Run `CONFIG GET maxmemory-policy`.
- **Action:** Set `noeviction`; evicted keys break rate limits and signals.

## RelayAccessLinkDown

- **Meaning:** The Access link is not established or its keys are stale.
- **Check:** Check the Access discovery document, keys and the link logs.
- **Action:** Restore the link; requests that need Access fail closed.

## RelayFrequencyCounterUnavailable

- **Meaning:** The frequency counter is unavailable and frequency caps fail open.
- **Check:** Check Valkey latency and errors.
- **Action:** Restore Valkey; caps resume on the next read.

## RelayPushSigningUnavailable

- **Meaning:** The key store cannot sign push provider tokens.
- **Check:** Check the PKCS#11 port and the token's keys.
- **Action:** Restore signing within the hour the last token stays valid.

## RelaySloAcceptFastBurn

- **Meaning:** Accept latency of a class burns its error budget 14.4 times too fast.
- **Check:** Check API node load, PostgreSQL latency and admission rejections.
- **Action:** Scale API nodes on queue delay, not CPU; shed `marketing` first.

## RelaySloAcceptSlowBurn

- **Meaning:** Accept latency of a class burns its error budget six times too fast.
- **Check:** Compare request latency by route and the database pool queue time.
- **Action:** Find the slow step before scaling.

## RelaySloAcceptBudgetBurn

- **Meaning:** Accept latency of a class has used its budget over three days.
- **Check:** Review the latency trend of the class.
- **Action:** Open a ticket; plan the fix before the 28-day budget runs out.

## RelaySloHandoffFastBurn

- **Meaning:** Provider handoff latency of a class burns its error budget 14.4 times too fast.
- **Check:** Check the oldest job age of the lane, the provider breaker and rate limits.
- **Action:** Do not scale workers before the provider has capacity.

## RelaySloHandoffSlowBurn

- **Meaning:** Provider handoff latency of a class burns its error budget six times too fast.
- **Check:** Check lane backlog and provider latency.
- **Action:** Find the bottleneck lane or provider.

## RelaySloHandoffBudgetBurn

- **Meaning:** Provider handoff latency of a class has used its budget over three days.
- **Check:** Review handoff latency per channel and provider.
- **Action:** Open a ticket for the provider or capacity plan.

## RelaySloAvailabilityFastBurn

- **Meaning:** Provider acceptance of a class burns its error budget 14.4 times too fast.
- **Check:** Check the provider breaker, failure classes and provider status page.
- **Action:** Fail over to a fallback provider if one is configured.

## RelaySloAvailabilitySlowBurn

- **Meaning:** Provider acceptance of a class burns its error budget six times too fast.
- **Check:** Check rejections by failure class.
- **Action:** Fix configuration rejections; report provider faults.

## RelaySloAvailabilityBudgetBurn

- **Meaning:** Provider acceptance of a class has used its budget over three days.
- **Check:** Review the rejection trend.
- **Action:** Open a ticket with the provider.

## RelayProvenDeliveryDrop

- **Meaning:** The proven delivery rate of a channel and provider fell by 40% within an hour while the accept SLO may look green.
- **Check:** Check delivery receipts, the provider's event intake and the reconciliation lag.
- **Action:** Treat it as users receiving nothing until receipts prove otherwise.

## RelayKillSwitchSlow

- **Meaning:** A kill switch took longer than its target from the stop to the last queued job paused.
- **Check:** Check the sweep job's batches and the maintenance queue.
- **Action:** Confirm in the console that the scope is paused; find the slow batch.

## RelayTenantSloViolation

- **Meaning:** A tenant's SLO window missed its target.
- **Check:** Read the tenant SLO table for the channel and window.
- **Action:** Open a ticket for the tenant's account team.

## RelayFunnelDataLoss

- **Meaning:** Accepted deliveries never reached the queue: data loss.
- **Check:** Find the accepted deliveries without a job in the ledger.
- **Action:** Stop the deploy that changed the accepting transaction; enqueue the missing deliveries from the ledger.

## RelaySkipSpike

- **Meaning:** Skips by one rule rose to more than three times yesterday's rate.
- **Check:** Look at the rule's recent decisions and any preference, consent or suppression change.
- **Action:** Confirm the change was intended; a missing consent import shows up here first.

## RelayUnknownProviderCode

- **Meaning:** A provider reports codes without a mapping; they are classified unknown.
- **Check:** Read the raw codes in the ledger.
- **Action:** Add the code to the provider's code map data set.

## RelayQuietHourViolation

- **Meaning:** A delivery was handed off inside the recipient's quiet hours: a legal breach.
- **Check:** Find the delivery and its policy decision.
- **Action:** Pause the affected scope with a kill switch until the cause is fixed.

## RelayDuplicateDelivery

- **Meaning:** More than 1% of deliveries were duplicates or conflicts in the last hour.
- **Check:** Check retries after uncertain attempts and provider idempotency keys.
- **Action:** Fix the retry path; duplicates are visible to recipients.

## RelayEmptyDigest

- **Meaning:** More than 20% of digest flushes were empty.
- **Check:** Check the digest windows and their event filters.
- **Action:** Fix the digest definition.

## RelayCampaignOverrun

- **Meaning:** A campaign runs longer than 1.5 times its estimate.
- **Check:** Check the lane backlog, rate limits and the provider.
- **Action:** Inform the tenant; adjust the estimate or the rate.

## RelayAgentSilentWait

- **Meaning:** Agent waits ended without any answer.
- **Check:** Check the waitpoints and their channels.
- **Action:** Escalate the waits to a human.

## RelayAgentReplyDrop

- **Meaning:** Agent reply rate halved while agent message volume grew.
- **Check:** Check the agent's recent messages and recipients.
- **Action:** Pause the agent if it is spamming.

## RelayEspEventDelay

- **Meaning:** Delivery events of an email provider arrive more than 30 minutes after the handoff.
- **Check:** Check the provider's event queue and account status.
- **Action:** A suspended account still answers the API; check the provider console.

## RelayEspEventsSilent

- **Meaning:** An email provider accepted mail for an hour without sending any delivery event.
- **Check:** Check the event subscription and the intake queue.
- **Action:** Restore the event intake; reconciliation fills the gap.

## RelayReconciliationLag

- **Meaning:** Reconciliation is more than 30 minutes behind.
- **Check:** Check the reconciliation task and the provider's status API.
- **Action:** Restore the task; unknown deliveries stay unknown until reconciled.

## RelayQueueOldestJob

- **Meaning:** The oldest job of a lane waits longer than the lane's threshold.
- **Check:** Check the lane's backlog, load shedding and worker nodes.
- **Action:** Scale on the oldest job age once the provider has capacity.

## RelayProviderBreakerOpen

- **Meaning:** A provider breaker has been open for ten minutes.
- **Check:** Check the provider's status page and the failure classes.
- **Action:** Fail over if a fallback provider is configured; dead letters replay when the breaker closes.

## RelayProviderIncident

- **Meaning:** A provider's status page reports an incident; the provider's other alerts are grouped under this one.
- **Check:** Follow the provider's incident.
- **Action:** Fail over if possible; inform tenants.

## RelayNoisyNeighbour

- **Meaning:** One tenant or API client makes up more than half of a queue's jobs or of the API requests.
- **Check:** Find the tenant in the jobs per tenant counter.
- **Action:** Check the tenant's fairness weight and rate limits.

## RelayPerformanceBudget

- **Meaning:** More than 1% of a request type exceeds its latency or reduction budget.
- **Check:** Compare the breaches by resource and the recent deploys.
- **Action:** Measure before optimising; open an issue with the measurement.

## RelayWakeUpBudget

- **Meaning:** More than five alerts paged in the last twelve hours.
- **Check:** List the pages and whether each needed action.
- **Action:** Review the thresholds of the alerts that paged without action.

## RelayAtomGrowth

- **Meaning:** The atom table grows by more than 1000 atoms an hour.
- **Check:** Find the code that creates atoms from data.
- **Action:** Fix it before the table fills; a full table stops the node.

## RelayAtomLimit

- **Meaning:** The atom table is more than 80% full.
- **Check:** Find the source of atom growth.
- **Action:** Plan a restart after the fix; atoms are never freed.

## RelayProcessLimit

- **Meaning:** The process table is more than 80% full.
- **Check:** Find the supervisor whose children grow.
- **Action:** Fix the leak; a full table refuses new processes.

## RelayLongSchedule

- **Meaning:** A process reports long garbage collections or schedules repeatedly.
- **Check:** Inspect the process by its label.
- **Action:** Split its work or move it off the scheduler.

## RelayLongMessageQueue

- **Meaning:** A process has a long message queue.
- **Check:** Inspect the process by its label.
- **Action:** Apply backpressure upstream; never kill it to drop messages.

## RelayDirtySchedulerQueue

- **Meaning:** Dirty CPU scheduler work has been queued for five minutes.
- **Check:** Check native code calls and their durations.
- **Action:** Reduce dirty work on the send path.
