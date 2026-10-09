# Proposed fixes on top of OpenZFS PR #18324

The patch is [0001-raidz-fix-born-free-boundary-of-raidz_expansion_acco.patch](vmtest/fix.patch). It is one commit on top of the PR head `3f6f238`: 14 files, +310/−107. The bug numbers below match [review.md](review.md).

## What changed and why

### Bugs 1 and 3: a new boundary txg for per-block accounting

The PR used the feature's `enabled_txg` as the cutoff: blocks born before it keep the old 3-wide charge, blocks born at or after it get the new per-block charge. That cutoff was wrong in two ways:

- **Bug 1, blocks born in the enabling txg.** Sync tasks run only after all dirty datasets have been written (`dsl_pool_sync()`, `dsl_pool.c:835-848`). So blocks born earlier in the activating txg were already charged at the legacy ratio, and they would later be freed at the new ratio.
- **Bug 3, a stale `enabled_txg`.** `enabled_txg` can be far older than activation. That happens when the feature was enabled, then an expansion completed on software that lacks it (an "enabled" unknown feature still allows a read-write import), and then activation happened at a later attach.

The fix:

- A new helper, `spa_raidz_expand_acct_activate()` in `vdev_raidz.c`, sets the boundary to **activation txg + 1**. It persists it in the MOS directory as `org.openzfs:raidz_expansion_accounting_txg` and increments the feature.
- Both activation paths call it: `feature_enable_sync()` and `vdev_raidz_attach_sync()`.
- On import, `spa_ld_check_features()` reads the stored boundary. If the feature is active and the key is missing, the import fails with EIO rather than guessing. The only pools that would hit this were made by the unpatched PR code, which has not shipped.
- The feature no longer depends on `enabled_txg` (`zfeature_common.c`).

Why +1 is safe:

- **Enabling path (already-expanded pool):** blocks born in txg ≤ T were charged at the legacy ratio and still resolve to it. Blocks born at ≥ T+1 are charged at their birth ratio both ways.
- **Attach path (first expansion after enabling):** blocks born at ≥ T+1 but before reflow completes resolve to the original width, which equals the legacy ratio, so nothing changes for them.

### Bug 4: stale boundary across load retries

`spa_ld_check_features()` now always assigns the field (0 when the feature is inactive), and `spa_unload()` clears it. The `spa_t` is reused by `spa_load_retry()`, so a rewind could otherwise keep a stale boundary from an earlier attempt.

### Bug 5: current ratio not refreshed after expansion

`vdev_set_deflate_ratio()` is no longer static. `raidz_reflow_complete_sync()` calls it right after inserting the new logical width, so the capacity correction applies without an export/import.

The new node's txg is `tx_txg + TXG_CONCURRENT_STATES`. Blocks still in flight keep the old width, so per-block charges are unaffected.

### Bug 6 and cleanup: one shared capacity correction

`spa_raidz_expand_dspace_correction()` in `spa_misc.c` replaces the two duplicated loops in `spa_update_dspace()` and `spa_prop_get_config()`. It:

- reads `vs_space` and `vs_alloc` under `vdev_stat_lock`, and clamps free space at 0;
- subtracts the free space of the vdev's embedded log metaslabs. It walks `vdev_log_mg->mg_metaslab_tree` under `mg_lock`. The established lock order is ms_lock → mg_lock (`metaslab_group_sort_impl`), and this is safe to call from `metaslab_sync_done()` with `ms_lock` held;
- only ever adds a positive correction.

### Bug 7: avoid the per-block lock on non-RAIDZ vdevs

`vdev_get_deflate_ratio()` now returns the cached ratio for non-RAIDZ vdevs instead of taking `vd_expand_lock`. Mirror and dRAID asize does not depend on the txg.

RAIDZ vdevs still take the lock on every call. A lock-free fast path would need a RAIDZ-internal check, so I left it as an open question.

### Bug 8: man page

- The feature is marked read-only compatible, matching the code.
- The man page now documents that the feature activates immediately when enabled on an already-expanded pool, and that older software can then import the pool only read-only.

### New test: `raidz_expand_013_pos`

1. Expand a pool with the feature disabled.
2. With a long txg timeout, dirty 32 MB and enable the feature, so both land in the same txg.
3. Write more data, delete everything, and check that the dataset's `used` returns to its baseline within 1 MB.
4. Repeat the check after an export/import.

With the original PR, `used` should fall about 8% of 32 MB below baseline, or wrap, or trip the debug ASSERTs.

## What was tested, and what wasn't

- **Built** userspace with `--with-config=user --enable-debug` on both the PR head and the patched tree. Both are warning-free. `cstyle.pl` is clean on all changed C files.
- **`ztest -X -T 300`** (dedicated raidz expansion test, including a kill mid-reflow and resume): passes on both trees.
- **`ztest -K raidz -T 900`** (random workload with raidz expansions): see the thread for the result.
- **ZFS Test Suite on a real kernel** (Lima VM on an Apple Silicon Mac, Ubuntu 24.04, kernel 6.8, `--enable-debug`, each set in a fresh boot):

  | Test | Original PR (`3f6f238`) | With this patch |
  |---|---|---|
  | `raidz_expand_013_pos` (new) | **Kernel panic** about 1 min in | PASS |
  | `raidz_expand_008`–`012` | all 5 PASS | all 5 PASS |

  The original PR's 013 run hit:

  ```
  VERIFY3U(bytesfreed, <=, DN_USED_BYTES(dn->dn_phys)) failed (29995794 <= 29875692)
  PANIC at dnode_sync.c:148:free_blocks()
  ```

  That is bug 1: blocks born in the enabling txg were charged at the legacy ratio and freed at the new one, about 120 KB too much here. The txg sync thread then hung. A non-debug build would silently miscount `used` instead.

  With the patch, 013 ended at `used` 32360 vs baseline 31372 (within the 1 MiB tolerance) both after the delete and after export/import, and the final scrub was clean. No VERIFY, ASSERT or panic appeared in the kernel log for any patched run. In 008, capacity after expansion was essentially the same on both trees (1313740365 vs 1313709765 bytes usable).
- **No direct reproduction of bugs 2 to 4.** ztest creates pools with every feature enabled, so it only exercises the attach-time activation path. 013 covers bug 1 only.

## Not fixed: bug 2 (available space under-reported once the feature is active)

The free-only correction gives `rdspace = alloc × legacy + free × current`. That matches `dd_used_bytes` only while every allocated block is charged at the legacy ratio. Once the feature is active, new blocks are charged at their birth ratio, so `available` falls short by `(birth ratio − legacy ratio)` for every such block. For raidz1 going from 3 to 4 disks, that is about 8% of all data written after activation.

I added an XXX comment in `spa_update_dspace()` instead of a fix. The two options below need a decision from the author and maintainers.

1. **Track the deflated allocated space per vdev.** Keep a per-top-level-vdev counter `D = Σ asize × ratio(birth)` over allocated blocks, persisted in the vdev's top-level ZAP and synced with the space maps, and use `rdspace = D + free × current`.
   - Hooks: allocate (+, txg = birth), free (−, from the bp's physical birth), ZIL claim (+), and unalloc/undo (−).
   - Transient disagreement with `vs_alloc` (deferred frees) only ever under-reports.
   - Cost: a new on-disk counter and changes to the allocator's hot paths.
2. **Drop the per-block feature from this PR.** Ship only the capacity correction, which is exact while the feature is off (available = free × current ratio, whatever the block sizes). Handle per-block `used` and quota accuracy separately, together with option 1.
   - The cost: `used` and quotas keep under-charging post-expansion blocks by about 8%, as they do today.

My recommendation is option 2 for this PR. The capacity correction is self-contained and gives correct numbers today, while option 1 is a format-affecting change that deserves its own review.

## Questions for a second reviewer

1. Is activation txg + 1 correct for every block born in the activating txg? That includes MOS blocks rewritten in later sync passes, `dmu_sync()`/ZIL-override blocks, and BRT clones applied in `brt_pending_apply()`.
2. Is failing the import with EIO the right behaviour when the feature is active but the boundary key is missing? The alternative is to fall back to `enabled_txg + 1`.
3. Taking `mg_lock` from `spa_update_dspace()`: any path that holds `mg_lock` and then reaches `spa_get_slop_space()` → `spa_update_dspace()` would deadlock. I checked the call site at `metaslab.c:4597-4599` (`ms_lock` held, not `mg_lock`), but not every caller.
4. Does `raidz_reflow_complete_sync()` calling `vdev_set_deflate_ratio()` race with anything that reads `vdev_deflate_ratio_current` in open context? The value is a single aligned 64-bit store.
5. Option 1 or option 2 for bug 2?
