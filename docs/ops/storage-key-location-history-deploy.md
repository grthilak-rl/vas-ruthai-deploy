# Deploy: camera storage key + location history (HPCL)

Two separate deploys: **VAS first, then Ruth**. Nothing moves on disk.
HPCL footage must stay exactly where it is; steps 1 and 4 prove that.

Run all commands from `vas-ruthai-deploy/` on the HPCL host.

## What changes

- **VAS:** each camera's folder is a frozen `storage_key`. Renaming a camera
  changes only its label. Names are unique ignoring case, and folder names
  are unique. VAS also keeps each camera's location history ("location" is
  shown as Manway in Ruth), adds a Move camera action, and answers "where
  was camera X at time T" and "which cameras were at location Y, when".
- **Ruth:** each new violation stores its manway, side and display name at
  write time. Reports, filters, incident cards and exports read the stored
  values. A manway edit in Ruth is a Move camera in VAS.

## VAS deploy

1. **Backups.** Taken on 2026-11-17, before any migration:
   - `backups/vas_db_pre-storage-key_20261117_103052.dump`
   - `backups/ruth_ai_pre-storage-key_20261117_103052.dump`
   - `backups/hot_filelist_pre-storage-key_20261117_103052.tsv.gz` (1,568,562 files)

   Retake them right before deploying if time has passed:
   ```sh
   TS=$(date +%Y%m%d_%H%M%S)
   docker exec vas-ms-v2-db pg_dump -U vas -d vas_db -Fc > backups/vas_db_pre-deploy_$TS.dump
   docker exec ruth-ai-vas-postgres pg_dump -U ruth -d ruth_ai -Fc > backups/ruth_ai_pre-deploy_$TS.dump
   docs/ops/hot_filelist.sh snapshot backups/hot_filelist_pre-deploy_$TS.tsv.gz
   ```
2. **Preflight.** This is read-only. Sections 1–3 must be empty.
   ```sh
   docker exec -i vas-ms-v2-db psql -U vas -d vas_db -At \
     < ../vas-ms-v2/backend/scripts/storage_key_preflight.sql
   ```
   On 2026-11-17 all three sections were empty, and every camera's key is
   its current folder name (`74004`, …, `Test_Camera`).
3. **Deploy.** `vas-backend` runs `../vas-ms-v2/backend` mounted into the
   container and runs `alembic upgrade head` on every start, so a restart is
   the deploy:
   ```sh
   docker compose restart vas-backend
   docker compose build vas-frontend && docker compose up -d vas-frontend
   docker logs vas-ms-v2-backend 2>&1 | grep -E "Running upgrade|NOT applied|startup"
   ```
   Revision `a9d3e5f72c18` checks that every key equals the camera's current
   folder before it adds the constraints. If it prints `storage_key
   constraints NOT applied`, the backend stops without changing anything.
   Fix the devices it lists, or restore the dump, then restart.
4. **Verify nothing moved:**
   ```sh
   docs/ops/hot_filelist.sh compare backups/hot_filelist_pre-storage-key_20261117_103052.tsv.gz
   ```
   This must print `missing/changed: 0`. New segments are expected.
5. **Smoke test:**
   - `curl -s localhost:8085/api/v1/devices | grep storage_key`
   - Open a camera's playback for a day before the deploy.

## Ruth deploy (after VAS is verified)

1. Take a fresh Ruth dump, as in VAS step 1.
2. ```sh
   docker compose build ruth-ai-backend && docker compose up -d ruth-ai-backend
   ```
   This applies migration `violation_location_stamp`, which adds columns
   only.
3. Check that new violations are stamped:
   ```sql
   select location_source, count(*) from violations
   where location_stamped_at is not null group by 1;
   ```

## Backfill old HPCL violations (only after the site confirms)

No system recorded a manway change during the project. VAS's seeded
history assumes every camera has been at its current manway since it was
created.

1. List the cameras and their history. The Ruth image does not include
   `scripts/` (BL-14), so copy the script in first and remove it at the end:
   ```sh
   docker cp ../ruth-ai-vas-ms-v2/ruth-ai-backend/scripts/backfill_violation_locations.py \
     ruth-ai-vas-backend:/tmp/backfill.py
   B="docker exec -w /app -e PYTHONPATH=/app ruth-ai-vas-backend python /tmp/backfill.py"
   $B report
   ```
2. Confirm with the site which cameras moved, and when.
   - For each camera that moved, correct its history in VAS. This needs
     an API key or a token with `streams:write`:
     `PUT /api/v1/devices/{id}/placements`
   - Cameras that did not move are confirmed by name in the next step.
3. Run a dry run, then apply:
   ```sh
   $B apply --confirmed 75080,75088,... --dry-run   # or --all-confirmed
   $B apply --confirmed 75080,75088,...
   docker exec -u root ruth-ai-vas-backend rm /tmp/backfill.py
   ```
   The script touches only violations that are not stamped yet, so it is
   safe to re-run. Cameras that are not confirmed are skipped and keep
   showing their current manway.

## Deployed on HPCL: 2026-11-17

- Backups: `backups/*_pre-deploy_20261117_112226.*`.
- VAS migrated to `a9d3e5f72c18`. All 19 keys equal their existing folders.
  The hot file list compared against both backups: 0 missing or changed.
- Ruth migrated to `violation_location_stamp`.
- Backfill: the site confirmed no manway edits during the project
  (74004→75129 was a replacement; 75089 and 75107 are new cameras). Run
  with `--all-confirmed`: 34,450 violations on 13 cameras stamped, 0 outside
  a placement, and a rerun stamped 0.

## Rollback

All database changes are additive.

- **VAS:** `alembic downgrade d5a9c3e18f40` inside the container, or
  restore the dump. Then put `../vas-ms-v2/backend` back to the previous
  commit and restart. The container runs whatever code is in that folder,
  and it runs the migrations again on every start.
- **Ruth:** `alembic downgrade auto_reports`, or restore the dump.

No files need to be put back, because none were moved.
