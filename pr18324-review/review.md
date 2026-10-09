# Review: OpenZFS PR #18324, "raidz: fix space accounting after expansion"

Reviewed at head `3f6f238be5cf4788717982f12b4076f7c0196c7e` (parent `eb1738b`, master). The diff matches the PR: 22 files, +1552/-23. Line numbers below refer to files **at the head commit**, so they can be checked with `git show 3f6f238:<path>`.

How this was checked: I read the diff and the code around it (allocator, DSL, dnode, BRT, DDT and raidz reflow code). Nothing was built or run at that stage; later build and kernel test results are in [fixes.md](fixes.md). The capacity numbers come from the PR's own formulas, computed for raidz1 with ashift=12 going from 3 to 4 disks:

| | asize of a 128K block | deflate ratio |
|---|---|---|
| 3-wide (legacy / txg 0) | 192 KiB | **341** |
| 4-wide (current) | 176 KiB | **372** |

So post-expansion geometry stores about 9.1% more per raw byte.

---

## (a) Verdict: **unsafe as written**

The PR has two halves:

1. **The capacity-reporting change** (`spa_update_dspace()`, and pool props in `spa_prop_get_config()`). On its own, with the feature *not* active, it is sound. By my derivation it never over-reports beyond a small embedded-log over-count (bug 6). It runs on **every expanded pool as soon as the new code is installed**, with or without `zpool upgrade` (`module/zfs/spa_misc.c:2044` is gated only on `spa_deflate()`, not on the feature).
2. **The per-block feature `raidz_expansion_accounting`.** It has a born/free mismatch in the enable txg (bug 1) and a second one when the feature activates late (bug 3). It also contradicts half 1's model, so once active, `zfs available` under-reports by ~8% of everything written afterwards (bug 2). Activation is permanent, and so are the wrong per-block charges it writes to disk.

Verdict for half 1 alone: safe with caveats. Verdict for the PR as a whole, which is what `zpool upgrade` turns on: **unsafe** until bugs 1 to 3 are fixed.

---

## (b) Bugs and risks, ranked by severity

### 1. HIGH: Blocks born in the enable txg are charged at the legacy ratio but freed at the new ratio
- `module/zfs/zfeature.c:409-414`: when the feature is enabled on an already-expanded pool, `feature_enable_sync()` sets `spa->spa_raidz_expand_acct_txg = dmu_tx_get_txg(tx)`, which is the **current** txg E.
- `feature_enable_sync()` runs as a regular sync task (from `zpool upgrade` / `zpool set feature@…=enabled`, via `spa_sync_props`). In `dsl_pool_sync()`, regular sync tasks run **after** every dirty dataset and the MOS have been written in pass 1 (`module/zfs/dsl_pool.c:835-848`, after the `dsl_dataset_sync`/`zio_wait` loop starting at :712).
- So every block written in txg E before the task ran was charged with `acct_txg == 0`, the legacy ratio (`module/zfs/vdev.c:5400-5401`). This goes through `dsl_dataset_block_born`, `dbuf_write_ready` → `dnode_diduse_space` (`module/zfs/dbuf.c:4687-4688`), and `dsl_pool_mos_diduse_space`.
- When such a block is later freed, `birth_txg (E) >= acct_txg (E)` holds, so `vdev_get_deflate_ratio()` (`module/zfs/vdev.c:5403-5405`) returns the post-expansion ratio. The free subtracts 372/341 of what was added, about **9% more than was born**.
- On re-import the boundary is `enabled_txg` = E again (`module/zfs/spa.c:5350-5355`), so the mismatch is permanent.
- Consequences:
  - Persistent under-count of `used`/`referenced`/`usedbysnapshots` and of user/group/project usage, which over-reports `available` by ~9% of the data written in txg E.
  - Underflow is guarded only by debug ASSERTs: `module/zfs/dnode.c:2524`, `module/zfs/dsl_dataset.c:367`, `module/zfs/dsl_destroy.c:797`. In production builds the counters wrap. Example: a file whose only block was born in txg E and is later truncated (not unlinked) has `dn_used` go below zero. That is 120032 − 130944 for one 128K block, which wraps to ~16 EiB in `st_blocks`/`du` and in userused accounting.
  - Even on an idle pool, MOS blocks born in pass 1 of txg E and rewritten in later passes of the same txg hit this.
- Fix: make the boundary `enabled_txg + 1` in **both** places. Set it to `txg + 1` in `feature_enable_sync()` and to `enabled_txg + 1` on import, so nothing born in E uses the new path. Or record a dedicated activation txg in the MOS instead of reusing `enabled_txg`.

### 2. HIGH: With the feature active, the free-only correction and per-birth charging contradict each other, so available space under-reports and rewrites reclaim almost nothing
- The correction in `module/zfs/spa_misc.c:2044-2066` (and the duplicate in `module/zfs/spa.c:501-525`) gives `spa_rdspace = alloc × legacy + free × current`. Its own justification (`spa_misc.c:2025-2036`) assumes every allocated block is charged in `dd_used_bytes` at the legacy ratio.
- With the feature active, every block born after the boundary is charged at its birth ratio, which equals current (`vdev.c:5403-5405`). The root dataset's available is `spa_get_dspace() − slop − dd_used_bytes` (`module/zfs/dsl_pool.c:917-926`, `module/zfs/dsl_dir.c:1199-1245`). It therefore comes out low by `asize_of_post_activation_blocks × (current − legacy) / 512`. That is **8.3% of all data written after activation** in the user's geometry.
- Worked through per 128K block, from the formulas above:
  - Writing new data costs 141,856 bytes of `available` per 131,072 bytes written. Writing until "full" leaves about 7.7% of the free raw space unusable (ENOSPC/EDQUOT at the DSL layer while `zpool list` still shows free space).
  - Rewriting old 3-wide data (`zfs rewrite`, or the copy-and-delete rebalance scripts people run after an expansion) raises `available` by **0.76%** of the data rewritten with the feature, against **9.1%** without it. The comment at `spa_misc.c:2033-2036` ("converging to the full correction after a complete rewrite") holds only when the feature is **off**.
- The same applies to raidz vdevs in the special/dedup class. `spa_dspace` adds their `dalloc` at the legacy ratio (`spa_misc.c:2091-2095`), while blocks there are charged at the birth ratio. The comment at `spa_misc.c:2039-2043` misses this.
- This fails safe (under-report, not over-report). But it is a regression compared with not enabling the feature, and it cannot be backed out because the feature never deactivates. `spa_rdspace` is computed at runtime, so later code could fix the reporting, provided it can tell how much allocated space was charged at which ratio. Nothing tracks that today.

### 3. HIGH (narrower trigger): Late activation reuses an old `enabled_txg`, so every block written between an earlier expansion and activation is mis-freed
- `module/zfs/vdev_raidz.c:5250-5259` activates the feature at attach and sets the boundary to `spa_feature_enabled_txg()`. That is correct only if no expansion completed between enablement and this attach.
- Trigger: the feature is enabled but inactive, which is the default for any pool created by the new release (`zpool create` enables all features), and an **older** OpenZFS that doesn't know the feature expands the pool. Older software can import a pool with an unknown feature that is enabled but inactive read-write. It bumps `raidz_expansion` and writes blocks at the legacy ratio. Back on new code, the next `zpool attach` activates with boundary = the original enable txg. Every block written on the older software after its expansion then frees at the new ratio, ~9% more than it was born with.
- That over-frees across a potentially large share of the pool, so `available` is over-reported. On a nearly full pool this can exceed slop (3.2%, `spa_misc.c:1970+`), which is exactly the ENOSPC-in-syncing-context risk the PR is meant to prevent.
- Fix: when `SPA_FEATURE_RAIDZ_EXPANSION` was already active before this attach, use the current txg + 1, as `feature_enable_sync()` should. A dedicated activation-txg object avoids both bug 1 and this one.

### 4. MEDIUM: `spa_raidz_expand_acct_txg` is never cleared
- It is set in three places (`spa.c:5354`, `zfeature.c:413`, `vdev_raidz.c:5258`) and never reset. `spa_load_retry()` (`module/zfs/spa.c:6377-6393`) reuses the same `spa_t` after `spa_unload()`.
- If a first load attempt saw the feature active and then a rewind (`zpool import -F`, `-T`, or a checkpoint rewind path) lands on an uberblock from before enablement, the stale boundary stays in memory. New blocks born at or after it get per-birth charges on a pool where the feature is not active, and later code charges them back at legacy, which is a mismatch.
- Fix: zero it in `spa_unload()`, and have `spa_ld_check_features()` always assign it (0 when inactive).

### 5. LOW-MEDIUM: `vdev_deflate_ratio_current` is not refreshed when an expansion finishes
- It is computed only in `vdev_set_deflate_ratio()` (`module/zfs/vdev.c:2112-2122`). That function is called from `vdev_load` (`vdev.c:3910`) and `vdev_expand` (`vdev.c:5876`).
- At attach, `spa_config_update()` → `vdev_expand()` runs while the reflow is still in progress. At that point `vdev_raidz_get_logical_width(UINT64_MAX)` still returns the old width, because the completion node is added only in `raidz_reflow_complete_sync()` (`module/zfs/vdev_raidz.c:4224-4229`). I found no call that recomputes the ratio on completion. So the correction stays at zero until the next import, reopen or autoexpand.
- This fails safe (under-report only) and does not affect a pool like yours that was expanded long ago. It does mean the "after expansion" assertions in `raidz_expand_008_pos.ksh` are not testing the new ratio before the export/import step. The >33% check at line 171 is satisfied by the added raw capacity alone.

### 6. LOW: The correction counts the embedded-log metaslab's free space
- `vs_space`/`vs_alloc` in the top-level vdev stats include the vdev's embedded-log metaslab (`vdev_space_update()` is called for every metaslab group, `module/zfs/metaslab.c:2878-2893`). `metaslab_class_get_dspace(normal)` excludes it.
- The correction uses the whole-vdev numbers (`spa_misc.c:2056-2058`, `spa.c:513-515`), so it adds `(current − legacy)` worth of that metaslab, up to 16 GiB, to normal-class capacity.
- Fix: use the normal metaslab group's own space and alloc, or subtract the log metaslab group.

### 7. LOW: Performance and locking in the hot path
- Once the feature is active, every `bp_get_dsize_sync()` on a raidz DVA calls `vdev_psize_to_asize_txg()` → `vdev_raidz_get_logical_width()`. That takes the per-vdev `vd_expand_lock` mutex and does an AVL search (`module/zfs/vdev_raidz.c:2285-2305`).
- Per written block, `dbuf_write_ready` (`dbuf.c:4687-4688`, two calls) runs in the parallel zio taskqs, plus born/kill accounting. That adds about 3–4 acquisitions of a mutex the raidz I/O path already takes (`vdev_raidz.c:2712`). On a single-raidz pool like yours, all of them serialize on one lock.
- It is correct: nodes are only added while the pool is imported, and `bp_get_dsize_sync` callers hold `SCL_VDEV` or are in syncing context. But it is avoidable:
  - Short-circuit when `vdev_deflate_ratio_current == vdev_deflate_ratio`. Today mirrors and never-expanded vdevs also take the slow path after activation (`vdev.c:5400-5405`).
  - Cache the ratio per reflow node.
  - Use a read-mostly lock.
- No benchmark is included in the PR.

### 8. LOW: Documentation mismatch
- `man/man7/zpool-features.7:933` declares `READ-ONLY COMPATIBLE: no`. The code registers `ZFEATURE_FLAG_READONLY_COMPAT` (`module/zcommon/zfeature_common.c:782-787`). The code is the right choice (a read-only import performs no frees), so the man page is wrong.
- The man text says the feature "becomes active when a RAIDZ expansion is initiated". It omits that enabling it on an already-expanded pool activates it immediately (`zfeature.c:409-414`). That is the case that matters for existing users, because it decides whether they can roll back.

### 9. LOW / maintainability
- The ~25-line correction loop is duplicated in `spa.c:501-525` and `spa_misc.c:2044-2066`. Factor it into one helper so the two can't drift (bug 6 has to be fixed in both).
- `fspace = space − aspace` has no guard against a torn read giving `aspace > space`. The stats are read without `vdev_stat_lock`. That is unlikely, but the result would be a huge unsigned value.

### Checked and fine
- **Choosing physical birth** (`spa_misc.c:2381`, `:2393`) keeps the per-block ratio consistent for:
  - dedup hits (same physical birth);
  - block cloning/BRT, where addref uses `bre_bp` (`brt.c:1349`) and decref uses the freed bp (`brt.c:1131`), both with the same physical birth;
  - `zfs rewrite -P`, whose new physical birth is set at allocation (`zio.c:4463-4471`);
  - nopwrite;
  - gang blocks (one birth per bp);
  - embedded bps (`BP_GET_PHYSICAL_BIRTH` returns 0 and NDVAS is 0).
- **Snapshots, clones and deadlists:** these re-derive dsize from the bp each time, so they are consistent wherever the ratio function is deterministic. It is deterministic except across bugs 1, 3 and 4.
- **Reflow completion boundary:** the completion node is placed at `tx_txg + TXG_CONCURRENT_STATES` (`vdev_raidz.c:4225`), so blocks in flight at completion keep the old width both at birth and at free.
- **Mirrors and dRAID:** `psize_to_asize` ignores the txg, so the per-birth ratio equals the cached ratio. This matters for mixed raidz-plus-mirror pools.
- **DDT stats** (`ddt_stats.c:59-69`): the approximation for extra copies affects only histograms. The histograms are internally consistent because both sides use the same function.
- **The feature can activate immediately on your kind of pool:** `raidz_expansion` is incremented at attach (`vdev_raidz.c:5242`) and never decremented anywhere in `module/`.
- **Send/receive:** untouched by the diff. Streams are logical, and received blocks are born on the receiver with its geometry.
- **ABI:**
  - `spa_feature_t` is appended at the end (`include/zfeature_common.h:94`, value 48, `SPA_FEATURES` = 49).
  - `libzfs.abi` is updated consistently (`spa_feature_table` 2688 → 2744 bytes, which is 49 × 56).
  - `cmd/zpool/compatibility.d/openzfs-2.4` does not list the feature, so pools with `compatibility=openzfs-2.4` won't enable it.
  - Kernel side: the exported `dva_get_dsize_sync()` changes signature (`include/sys/spa.h:1157`, `EXPORT_SYMBOL` at `spa_misc.c:3267`), which breaks any out-of-tree caller at compile time. `vdev_get_deflate_ratio` is newly exported. `struct spa` and `struct vdev` grow by one field each, which is internal only.
- **Quotas and reservations** (`dsl_dir.c:1217-1245`):
  - These compare against dsize-charged `dd_used_bytes`. On master today, post-expansion blocks are charged ~8% below their logical size, so a 1 TB quota holds about 1.09 TB.
  - With the feature, new writes are charged correctly. A dataset near its quota will therefore hit EDQUOT sooner than it does today. That is a visible behavior change and should be in the release notes.
  - `refreservation=auto` for zvols is computed in libzfs from the vdev's current child count (`lib/libzfs/libzfs_dataset.c:5362-5395`). The PR doesn't touch it.

---

## Answers to the specific questions

**Can available space be over-reported?**
- Without the feature: no, beyond bug 6 (~1 GB, absorbed by slop). The free portion is valued at the ratio new writes are actually charged at, and `available` falls by exactly `asize × current / 512` per write.
- With the feature: it is usually *under*-reported (bug 2). Over-reporting happens through bug 1 (bounded by one txg of data) and bug 3 (potentially large).

**Is a block always freed with the size it was born with?** Yes for dedup, BRT, snapshots, clones, gang, rewrite and nopwrite, with three exceptions:
- blocks born in the enable txg (bug 1);
- blocks written between an older-software expansion and late activation (bug 3);
- rewind retries (bug 4).

Blocks born between a pre-patch expansion and enabling are fine. Their birth is before the boundary, so they stay at the legacy ratio at both ends (`vdev.c:5400`).

**Feature lifecycle.**
- *Enable on an expanded pool:* activates in the same txg (`zfeature.c:409-414`).
- *Never-expanded pool:* activates at the next attach (`vdev_raidz.c:5250-5259`).
- *Export/import:* the boundary is reloaded from `enabled_txg` (`spa.c:5350-5355`). It is consistent with runtime, but inherits bug 1.
- *Older ZFS:* read-only import only, once the feature is active. If it is enabled but inactive, older ZFS can import read-write, which is the bug 3 trigger.
- *Rollback:* none. The feature never returns to `enabled`.

**Multiple expansions:** per-block charging handles them, because each birth txg maps to its width. The capacity correction only knows "txg 0" and "now", so bug 2 compounds across expansions.

**Mixed vdevs:**
- Mirrors are unaffected.
- A special/dedup raidz shares bug 2.
- Log vdevs are excluded, except for the embedded-log over-count (bug 6).

---

## (d) Questions to raise on the PR

1. Sync tasks run after dataset sync in `dsl_pool_sync()` (`dsl_pool.c:835-848`). Shouldn't the boundary be `enabled_txg + 1` both at runtime (`zfeature.c:413`) and on import (`spa.c:5350-5355`)? Can a test write data in the same txg as `zpool set feature@raidz_expansion_accounting=enabled` and then truncate or destroy it?
2. Once blocks are charged at their birth ratio, how should `spa_rdspace` value allocated space? The free-only correction assumes all allocated blocks are legacy-charged (`spa_misc.c:2025-2036`). Can we track the asize charged at the legacy ratio per vdev, or otherwise reconcile the two?
3. In `vdev_raidz_attach_sync()` (`vdev_raidz.c:5250-5259`), if `raidz_expansion` was already active (for example, older software expanded the pool while this feature was enabled but inactive), shouldn't the boundary be the current txg rather than `enabled_txg`?
4. Should `spa_raidz_expand_acct_txg` be cleared in `spa_unload()` and always assigned in `spa_ld_check_features()`, to cover `spa_load_retry()` rewinds?
5. Should `vdev_set_deflate_ratio()` be called when reflow completes (`raidz_reflow_complete_sync()`), so the correction applies without re-importing?
6. Should the correction use the normal metaslab group's own space instead of whole-vdev `vs_space`, to exclude the embedded-log metaslab?
7. Is there a measurement of `bp_get_dsize_sync()` overhead with the extra `vd_expand_lock` acquisitions on a busy single-raidz pool? Can `vdev_get_deflate_ratio()` short-circuit when the two cached ratios are equal?
8. The man page says the feature is not read-only compatible, but the code says it is. Which is intended? Can the man page also document immediate activation on already-expanded pools?
9. Has ztest/zloop been run with this feature enabled, toggled mid-run, and across raidz expansion?

### Tests that don't cover what they claim, and tests that are missing
- `raidz_expand_012_pos.ksh:120-137` (`verify_near_empty`) and `verify_accounting` use `zpool list` allocated/free/size. Those are raw allocations and do not depend on deflate ratios, so they **cannot** detect a born/free dsize mismatch. The only dsize-level checks are the coarse `referenced` thresholds (2% of the dataset size) at :220-225 and :269.
- Scenario B (`raidz_expand_012_pos.ksh:278-318`) enables the feature on an idle pool and never writes, deletes or re-imports afterwards. That is exactly the window where bug 1 lives.
- `raidz_expand_010_pos.ksh:193` accepts a 30% fill error, which hides bug 2's ~8%.
- Missing tests:
  - Exact `used`/`referenced` return to baseline after create, write, enable (in the same txg), destroy.
  - Truncate a file written in the enable txg and check `du`/`st_blocks`.
  - Rewrite after expansion with the feature active, and assert that `zfs available` grows by about `current/legacy − 1`.
  - Quota, refquota and userquota at the boundary.
  - Snapshot, clone and `cp --reflink` (BRT) of pre-boundary blocks, then delete.
  - Dedup across the boundary.
  - Forced gang blocks (`metaslab_force_ganging`).
  - Raidz plus a mirror in the same pool, and a raidz special vdev.
  - Read-only import, and checkpoint rewind across enablement.
  - Two expansions with the feature enabled in between.
