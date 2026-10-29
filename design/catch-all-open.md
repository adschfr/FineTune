# Catch-all: open items and lead decisions (commits 11 to 12c)

Working notes kept between the catch-all commits. They record decisions that
the design doc (`catch-all-tap.md`, §16) does not describe yet, accepted
residuals, and inputs for the next commits. Commit 17 folds them into the
design doc. References to `scratchpad/...` reports point to temporary review
reports that are not kept.


From fix report (design questions, not fixed in 11):
1. Spins outside the coordinator: a CA built inside a per-app activate spin started from an engine Task is released at once; that app briefly doubles until its exclusion applies. Proposal: beginSpin()/endSpin() around the decorator's inner calls (commit 13).
2. changedDevices is live-only (§16.4). Since fix 1, a shrink on a building CA returns a ticket, but handover C takes no hold for it. Proposal: changedDevices also names building CAs whose list would shrink.
3. Dormant CA and removeClaim: returns nil (pinned by dormantSkipped). Commit 12: on a shrink bump dormant devices too and complete the wait after the rebuild's list applied, or push to the dormant tap when the ID is unchanged.
4. Owner released without removeClaim: pruned only at next flush (runs on every process-list change). Alternative: isolated deinit in decorator calls removeClaim (commit 13).
5. Commit 12:
   - pushStillFails -> E, then R, complete waiters.
   - Watchdog for a new CA held because its post-build push failed twice.
   - Grow watchdog must not release while a target's applied list lacks the claim's live processes.
   - After G and runControl.stop(), reset runControlStarted.
   - stop() does not complete waits (needs G).

Implementer's questions 1-6 (spec reviewer answered: yes to 2-4, no generation bump for 5, rebuild for 6):
1. Waits on dormant/retiring CAs: per-phase switch in isApplied: dormant done at once, retirement tickets for retiring(caHeld:false), done at once for retiring(caHeld:true).
2. G removes the entry then calls checkWaiters(): yes.
3. stop() also calls bounded runControl.stop() together with G: yes.
4. CA whose post-build push fails (stays held) goes through retry, E rebuild, R: yes.
5. After onServiceRestarted: re-send listed, clear C9 reports and graces, re-read self object, check claims via env.tapExists. No generation bump.
6. CA built with old self object: rebuild (not I1 repair).

Full reports: scratchpad/c11-impl.md, c11-safety.md, c11-spec.md, c11-fix.md, c11-recheck.md, c11-fix2.md

# Open after commit 12a (4f66653), inputs for 12b and 13

From 12a implementer:
1. Dormant entry/exit: rebuild() must start from dormant (attach new CA, then phase live). R, G and E already skip the detach for a CA that is not attached (outgoingAttached, EndingCatchAll.attached).
2. Dormant shrink: should a shrink bump dormant devices' generation? Today waits on dormant end at once and removeClaim returns nil. Safety reviewer 12a: a dormant shrink must not let the decorator invalidate the per-app tap while the dormant tap still excludes the process.
3. Backoff seam: coverageEnded is empty; without backoff the next reconcile rebuilds immediately after an R for pushFailed.
5. Format hold: CatchAllHoldReason.format still to add; completeRebuildIfReady already respects other hold reasons.
6. stop() timeout counting: only logged now.
7. Unreadable process list: flush retries every 100 ms even with no device (commit 11 behavior); could be capped.
From 12a fix round:
- isAbsent treats a listed UID that Core Audio cannot resolve as gone (G). Design says G only for an absent (unlisted) UID; lead's lean: move the listed-but-unresolvable case into E12 in 12b.
- Count IO failures once per aggregate (onRebuild repeats).
- Gate the next build after a run-queue-timeout R on afterQueuedWork.
- With an unreadable process list, a new CA's initial hold lasts up to 3 s before R (silent, bounded). Accepted.
For commit 13:
- beginSpin/endSpin around the decorator's inner calls must also defer runTurn, so R2 and builds never run inside an engine-started spin (applyPersistedSettings -> activate).
- changedDevices should also name building CAs whose list would shrink (handover C hold).
- Owner released without removeClaim: isolated deinit in the decorator calls removeClaim.

# After 12a round 3 (79c7622)
- isApplied guard for unconfirmed lists: not added (recheck found no counterexample).
- Design doc does not describe the watchdog young-push guard (grow G, shrink S) nor listUnconfirmed: note in commit 17 (docs).
- 12b split: 12b = E12 dormant, IO failures, counting, backoff, give-up, breaker (workflow w3p5s6ess).
- 12c = E15 format (.format hold, 2 s watchdog, formatUnchanged ignored during own rebuild, 16.12 item 3 incl. run-control rate check on the liveness tick, two ticks), E20 restart (forget without destroy, reset C9 state, re-resolve self, re-send listed, tapExists claim check, onClaimsVoided, setClaim check for owners registered before the restart, requestReevaluation at once, rebuild after list refresh or 1 s with backend.deviceID(forUID:) and UID-keyed gain, R on failure, never dormant, no generation bump), old self object -> rebuild. onServiceRestarted hop must use DispatchQueue.main.async (FIFO with onRebuild hop from 12b).
- Open: R from a dormant, not-alive device (breaker) runs R2, which activates taps on a dead device (notReady up to 2 s). Engine question for commit 14.

# 12b committed (dc445ff, 1162 tests), round 2 running (wywf7u9vs)
Lead decisions for round 2 (document in design doc, commit 17):
- D1 dormant shrink waits for takeover/R/G (dormant tap still excludes the process; wake would play it raw). Grow on dormant still at once.
- D2 IO failure counts only if 1 s after the report the device is still listed under the same ID and alive.
- D3 blocked run queue is global: no build/rebuild on any device while a timed-out detach is queued; a run-queue timeout retires every live catch-all.
- D4 IO failures count toward per-ID give-up only; a give-up counts once toward the breaker (with build failures and queue timeouts).
Accepted from 12b: changedDevices names building and dormant-with-rebuild catch-alls when processes leave (matches the commit-13 plan); listed-but-unresolvable UID in R/rebuild ends in G plus reconcile and re-evaluation.
For 12c: reset givenUp, ioFailureTimes, countedAggregates and pending IO-count checks at ServiceRestarted; drop IO reports for old handles; E15 on a dormant device; never dormant for forgotten catch-alls.
For commit 14: R2 on a dead device after the breaker; reachability of V4 races (turns run from main-actor Tasks).

# 12b round 2 committed (2183140, 1180 tests); round 3 running (w0rkn5rzs)
- D1 narrowed after recheck: dormant shrink only for owners targeting the device (mode on); observe never waits.
- giveUpWindow 600 s (design says 2 min; update doc in 17). Breaker opens 1 s after the third counted failure.
- D5: failures on a device that reads alive (failed rebuild, waiting rebuild IO failure) decided after the 1 s settle: usable -> count, R, backoff; else E12 path, uncounted. Avoids R2 on a dying TV at every display sleep.
- D6: dormant alters also while its rebuild is requested/postponed/building (wake gap for mixdown taps).
- Accepted residuals: process whose tap plays elsewhere but output is the sleeping TV loses its tap at once (E11 window at wake); pre-dormancy ticket without push waits until takeover.
- Design doc out of date at lines ~1031, 1105, 1231, 1238, 1239 (dormant waits, counting, breaker inputs, global queue gate): commit 17.

## After 12b round 3 (commit 1912a12)
- Commit 17 (design doc §16): D5 (failures on an alive-reading device decided after the 1 s settle; old catch-all serves meanwhile; dropFailedRebuild restores the old record), D6 (dormant alters also while rebuilding or settling; shrinksForRebuild ends such waits when the device stays dormant), diedMeanwhile, queueBlocked skips devices with a pending settle, dropFailedRebuild timeout uncounted. E13 reason list, 16.6 rows for failed build and failed rebuild, E12/E14 text.
- Accepted residual: a tap on another device whose claim changes while a rebuilt catch-all from dormant waits to take over; if that one fails to start and the settle ends dead, the wait lasts until the TV wakes (falls under "ticket from before dormancy waits until takeover").
- Accepted: queueBlocked skip means a live catch-all with a pending settle stays attached to a blocked queue up to 1 s longer and retires with the failed rebuild's reason.
- Round 4 (D7-D9, runTurn pop) follows before 12c.

## After 12b round 4 (commit 41f554f)
- Accepted: a settle keeps its IsAlive observation while the device retires (handler only marks; exception to 16.12 item 7).
- Accepted: the observation follows the listed ID; a settle on an ID no longer listed counts nothing anyway.
- Accepted: any notification from the current registration during a settle marks it (false mark costs one uncounted failure and one more attempt); endAbsent marks an unresolvable UID as gone.
- Accepted residual: a first build failing as not usable does not mark a pending IO settle of the same UID (needs a tier flip within 1 s).
- Commit 17 doc: D7 (diedMeanwhile), D8 (IO settles), D9 (observe while settling, serials, late notifications), R1 (runTurn pop), fix2 marks (gone, endAbsent).
- Round 5 (D10) follows: observe IsAlive of every catch-all device (building, live, dormant) and a lookback for ioDead reports.

## After 12b round 5 (commit 18894bb, 1202 tests)
- D10: every catch-all entry (building, live, dormant) observes IsAlive of its listed ID from the build on; live false edge -> dormant at once, uncounted.
- D11: ioDead lookback window livenessTimeout + 2 x tickInterval + tickLeeway (0.5 s, from CatchAllRunControl.updateTimer) = 5.5 s; recorded only while building or live; startFailed and build failures unaffected.
- Accepted: D10i breaker keeps observations of building/live/dormant until R1; lookback record survives dormancy and G (bounded); rebuild moves the observation before its wait; dropFailedRebuild keeps the observation on the listed ID; timer re-arm at interval change and the main hop can stretch detection past 5.5 s (residual).
- Rejected with probe: main-queue IsAlive blocks never run inside a build's CFRunLoop spin within a main-queue job (scratchpad r5f2probe/spin.swift).
- Commit 17 doc: D10, D11 and the observation lifecycle.
- Split: 12c = E15 format plus the run-control rate check (16.12 item 3); 12d = E20 ServiceRestarted with the resets.

## After 12c (format hold, rate check; 1239 tests)
No further round (user asked for reliable, shorter runs). Lead decisions:
- Accepted: a takeover keeps the format hold until a verdict (formatUnchanged, formatChanged, watchdog); silence up to 2 s instead of the wrong format.
- Accepted: no watchdog re-arm after a failed format rebuild; the settle's end bounds the hold.
- Accepted: formatChanged during a settle without an earlier one sets no serial; the 2 s watchdog bounds it.
- Commit 14: second change during the format rebuild (fix2 Q1), decide together with row 28 and the engine defer.
- For 12d or 14: rate rebuild loop if a fresh aggregate never matches the nominal rate (about every 4 s, uncounted). Lean: count a second rate rebuild without a match in between toward give-up.
- Residual (recheck2, minor): stale formatRebuildSerial when a dormant device's failed rebuild settles on a dead device (needs V4 plus a death within the 1 s settle). One-line fix candidate: dropFormatHold when the settle finds the device already dormant.
- Commit 17 doc: §16.6 format row (hold lasts through the rebuild), takeover rule, formatChangeBound, re-arm rule, initial hold kept through a waiting rebuild, rate-check order.

## Paused after 12c (2026-10-29), lean mode for the rest
The user paused the catch-all work after 12c (ad3ffba) and chose a lean mode for the remaining commits:
- One round per commit: implement, one review, one fix, then the lead's own `./scripts/test.sh`. No further rounds without asking the user.
- Rare cases left after that round go into this file and are fixed only if they show up in daily use or in a report.
- If a commit overruns its estimate by more than half, stop and ask.
- 12d becomes the simple variant: on ServiceRestarted, forget every catch-all without destroy calls and rebuild from scratch as at launch, instead of carrying state across the restart (the E20 list above). The resets of 12b state (givenUp, ioFailureTimes, countedAggregates, settles, observations) still apply.
- Estimates: 12d 1.5 to 2 h, 13 about 2 h, 14 about 3 h, 15 about 3 h, listening session about 1 h with the user, a week in mode on, 17 docs 1 to 2 h.
