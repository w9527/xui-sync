#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="xui-sync"
DEFAULT_DB="/etc/x-ui/x-ui.db"
DEFAULT_WORKDIR="/var/lib/xui-sync"
DEFAULT_SERVICE="x-ui"

DB_PATH="${DB_PATH:-$DEFAULT_DB}"
WORKDIR="${WORKDIR:-$DEFAULT_WORKDIR}"
STATE_DB="${STATE_DB:-$WORKDIR/state.db}"
MASTER_STATE_DB="${MASTER_STATE_DB:-$WORKDIR/master/state.db}"
SYNC_INBOUND_TRAFFIC="${SYNC_INBOUND_TRAFFIC:-0}"
CONFIG_SYNC_ENABLED="${CONFIG_SYNC_ENABLED:-0}"
CONFIG_MASTER_NODE="${CONFIG_MASTER_NODE:-}"
SERVICE_NAME="${SERVICE_NAME:-$DEFAULT_SERVICE}"
SERVER_ID="${SERVER_ID:-$(hostname -f 2>/dev/null || hostname)}"
STOP_SERVICE_ON_APPLY="${STOP_SERVICE_ON_APPLY:-1}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-5}"
SSH_BASE_OPTS=(-o BatchMode=yes -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" -o ServerAliveInterval=5 -o ServerAliveCountMax=1 -o ConnectionAttempts=1)

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/xui-sync.conf}"

log() {
  printf '[%s] %s\n' "$APP_NAME" "$*" >&2
}

die() {
  log "ERROR: $*"
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

quote_sql_literal() {
  local value="${1//\'/\'\'}"
  printf "'%s'" "$value"
}

quote_sql_ident() {
  local value="${1//\"/\"\"}"
  printf '"%s"' "$value"
}

has_table() {
  local db="$1" table="$2"
  sqlite3 "$db" "SELECT 1 FROM sqlite_master WHERE type='table' AND name=$(quote_sql_literal "$table") LIMIT 1;" | grep -qx 1
}

has_column() {
  local db="$1" table="$2" column="$3"
  sqlite3 "$db" "PRAGMA table_info($table);" | awk -F'|' '{print $2}' | grep -qx "$column"
}

table_columns() {
  local db="$1" table="$2"
  sqlite3 "$db" "PRAGMA table_info($(quote_sql_ident "$table"));" | awk -F'|' '{print $2}'
}

common_table_columns() {
  local target_db="$1" target_table="$2" source_db="$3" source_table="$4"
  declare -A source_cols=()
  local column common=()

  while IFS= read -r column; do
    [[ -n "$column" ]] && source_cols["$column"]=1
  done < <(table_columns "$source_db" "$source_table")

  while IFS= read -r column; do
    [[ -n "$column" && -n "${source_cols[$column]:-}" ]] && common+=("$column")
  done < <(table_columns "$target_db" "$target_table")

  printf '%s\n' "${common[@]}"
}

sql_ident_list_from_args() {
  local column quoted=()
  for column in "$@"; do
    quoted+=("$(quote_sql_ident "$column")")
  done
  local IFS=,
  printf '%s' "${quoted[*]}"
}

sql_literal_list_from_args() {
  local value quoted=()
  for value in "$@"; do
    quoted+=("$(quote_sql_literal "$value")")
  done
  local IFS=,
  printf '%s' "${quoted[*]}"
}

normalize_user_key() {
  local value="$1"
  printf '%s' "${value%%@*}"
}

find_node_spec() {
  local needle="$1" node
  for node in "${NODES[@]}"; do
    if [[ "$(node_field "$node" 1)" == "$needle" ]]; then
      printf '%s\n' "$node"
      return 0
    fi
  done
  return 1
}

generate_login_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 16
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then
    tr -d '-' < /proc/sys/kernel/random/uuid
  else
    printf '%s' "$RANDOM-$RANDOM-$(date -u +%s%N)" | sha256sum | awk '{print substr($1, 1, 32)}'
  fi
}

sqlite_backup() {
  local src="$1" dest="$2"
  sqlite3 "$src" ".timeout 5000" ".backup '$dest'"
}

require_local_db() {
  [[ -f "$DB_PATH" ]] || die "database not found: $DB_PATH"
  sqlite3 "$DB_PATH" "PRAGMA quick_check;" | grep -qx "ok" || die "database quick_check failed: $DB_PATH"
}

cmd_export() {
  need_cmd sqlite3
  need_cmd tar
  require_local_db

  local ts snapshot_dir snapshot_db snapshot_state manifest archive
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  snapshot_dir="$WORKDIR/exports/$SERVER_ID/$ts"
  snapshot_db="$snapshot_dir/x-ui.db"
  snapshot_state="$snapshot_dir/xui-sync-state.db"
  manifest="$snapshot_dir/manifest.env"
  archive="$WORKDIR/exports/${SERVER_ID}_${ts}.tar.gz"

  mkdir -p "$snapshot_dir"
  sqlite_backup "$DB_PATH" "$snapshot_db"
  if [[ -f "$STATE_DB" ]]; then
    sqlite3 "$STATE_DB" "PRAGMA quick_check;" | grep -qx "ok" || die "state database quick_check failed: $STATE_DB"
    sqlite_backup "$STATE_DB" "$snapshot_state"
  fi

  {
    printf 'server_id=%q\n' "$SERVER_ID"
    printf 'created_at=%q\n' "$ts"
    printf 'hostname=%q\n' "$(hostname -f 2>/dev/null || hostname)"
    printf 'db_path=%q\n' "$DB_PATH"
    printf 'state_db=%q\n' "$STATE_DB"
    printf 'tables=%q\n' "$(sqlite3 "$snapshot_db" ".tables")"
  } > "$manifest"

  if [[ -f "$snapshot_state" ]]; then
    tar -C "$snapshot_dir" -czf "$archive" x-ui.db xui-sync-state.db manifest.env
  else
    tar -C "$snapshot_dir" -czf "$archive" x-ui.db manifest.env
  fi
  printf '%s\n' "$archive"
}

write_merge_sql() {
  local out="$1"
  cat > "$out" <<'SQL'
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;

CREATE TABLE IF NOT EXISTS client_traffic_totals (
  user_key TEXT PRIMARY KEY,
  up INTEGER NOT NULL DEFAULT 0,
  down INTEGER NOT NULL DEFAULT 0,
  all_time INTEGER NOT NULL DEFAULT 0,
  last_online INTEGER NOT NULL DEFAULT 0,
  seen_count INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS inbound_traffic_totals (
  tag TEXT PRIMARY KEY,
  up INTEGER NOT NULL DEFAULT 0,
  down INTEGER NOT NULL DEFAULT 0,
  seen_count INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS merge_client_bases (
  server_id TEXT NOT NULL,
  user_key TEXT NOT NULL,
  base_up INTEGER NOT NULL DEFAULT 0,
  base_down INTEGER NOT NULL DEFAULT 0,
  base_all_time INTEGER NOT NULL DEFAULT 0,
  entries INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(server_id, user_key)
);

CREATE TABLE IF NOT EXISTS merge_inbound_bases (
  server_id TEXT NOT NULL,
  tag TEXT NOT NULL,
  base_up INTEGER NOT NULL DEFAULT 0,
  base_down INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(server_id, tag)
);
SQL
}

write_master_state_sql() {
  cat <<'SQL'
CREATE TABLE IF NOT EXISTS global_client_state (
  user_key TEXT PRIMARY KEY,
  synced_up INTEGER NOT NULL DEFAULT 0,
  synced_down INTEGER NOT NULL DEFAULT 0,
  synced_all_time INTEGER NOT NULL DEFAULT 0,
  synced_last_online INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS global_inbound_state (
  tag TEXT PRIMARY KEY,
  synced_up INTEGER NOT NULL DEFAULT 0,
  synced_down INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS node_client_base (
  server_id TEXT NOT NULL,
  user_key TEXT NOT NULL,
  base_up INTEGER NOT NULL DEFAULT 0,
  base_down INTEGER NOT NULL DEFAULT 0,
  base_all_time INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(server_id, user_key)
);

CREATE TABLE IF NOT EXISTS node_inbound_base (
  server_id TEXT NOT NULL,
  tag TEXT NOT NULL,
  base_up INTEGER NOT NULL DEFAULT 0,
  base_down INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(server_id, tag)
);
SQL
}

write_local_state_sql() {
  local schema_prefix="${1:-}"
  cat <<SQL
CREATE TABLE IF NOT EXISTS ${schema_prefix}xui_sync_client_state (
  user_key TEXT PRIMARY KEY,
  synced_up INTEGER NOT NULL DEFAULT 0,
  synced_down INTEGER NOT NULL DEFAULT 0,
  synced_all_time INTEGER NOT NULL DEFAULT 0,
  synced_last_online INTEGER NOT NULL DEFAULT 0,
  base_up INTEGER NOT NULL DEFAULT 0,
  base_down INTEGER NOT NULL DEFAULT 0,
  base_all_time INTEGER NOT NULL DEFAULT 0,
  entries INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS ${schema_prefix}xui_sync_inbound_state (
  tag TEXT PRIMARY KEY,
  synced_up INTEGER NOT NULL DEFAULT 0,
  synced_down INTEGER NOT NULL DEFAULT 0,
  base_up INTEGER NOT NULL DEFAULT 0,
  base_down INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL DEFAULT 0
);
SQL
}

merge_one_snapshot() {
  local aggregate_db="$1" node_db="$2" node_name="$3"
  local sql_file
  sql_file="$(mktemp)"
  local client_all_time_expr client_last_online_expr
  client_all_time_expr="COALESCE(up, 0) + COALESCE(down, 0)"
  client_last_online_expr="0"

  {
    printf "ATTACH DATABASE %s AS node;\n" "$(quote_sql_literal "$node_db")"
    printf "ATTACH DATABASE %s AS mst;\n" "$(quote_sql_literal "$MASTER_STATE_DB")"

    if has_table "$node_db" "client_traffics"; then
      if has_column "$node_db" "client_traffics" "all_time"; then
        client_all_time_expr="COALESCE(all_time, COALESCE(up, 0) + COALESCE(down, 0))"
      fi
      if has_column "$node_db" "client_traffics" "last_online"; then
        client_last_online_expr="COALESCE(last_online, 0)"
      fi
      cat <<SQL
DROP TABLE IF EXISTS temp.node_client_current;
CREATE TEMP TABLE node_client_current AS
SELECT
  CASE
    WHEN instr(email, '@') > 0 THEN substr(email, 1, instr(email, '@') - 1)
    ELSE email
  END AS user_key,
  SUM(COALESCE(up, 0)) AS up,
  SUM(COALESCE(down, 0)) AS down,
  SUM($client_all_time_expr) AS all_time,
  MAX($client_last_online_expr) AS last_online,
  COUNT(*) AS entries
FROM node.client_traffics
WHERE email IS NOT NULL AND email <> ''
  AND (
    CASE
      WHEN instr(email, '@') > 0 THEN substr(email, 1, instr(email, '@') - 1)
      ELSE email
    END
  ) <> ''
GROUP BY user_key;
SQL
      cat <<SQL
INSERT INTO client_traffic_totals(user_key, up, down, all_time, last_online, seen_count)
SELECT
  cur.user_key,
  CASE WHEN cur.up - COALESCE(st.base_up, 0) > 0 THEN cur.up - COALESCE(st.base_up, 0) ELSE 0 END,
  CASE WHEN cur.down - COALESCE(st.base_down, 0) > 0 THEN cur.down - COALESCE(st.base_down, 0) ELSE 0 END,
  CASE WHEN cur.all_time - COALESCE(st.base_all_time, 0) > 0 THEN cur.all_time - COALESCE(st.base_all_time, 0) ELSE 0 END,
  cur.last_online,
  1
FROM node_client_current cur
LEFT JOIN mst.node_client_base st ON st.server_id = $(quote_sql_literal "$node_name") AND st.user_key = cur.user_key
WHERE 1
ON CONFLICT(user_key) DO UPDATE SET
  up = client_traffic_totals.up + excluded.up,
  down = client_traffic_totals.down + excluded.down,
  all_time = client_traffic_totals.all_time + excluded.all_time,
  last_online = MAX(client_traffic_totals.last_online, excluded.last_online),
  seen_count = client_traffic_totals.seen_count + 1;

INSERT INTO merge_client_bases(server_id, user_key, base_up, base_down, base_all_time, entries)
SELECT $(quote_sql_literal "$node_name"), user_key, up, down, all_time, entries
FROM node_client_current
WHERE 1
ON CONFLICT(server_id, user_key) DO UPDATE SET
  base_up = excluded.base_up,
  base_down = excluded.base_down,
  base_all_time = excluded.base_all_time,
  entries = excluded.entries;
SQL
    else
      log "skip $node_name: table client_traffics not found"
    fi

    if [[ "$SYNC_INBOUND_TRAFFIC" == "1" ]] && has_table "$node_db" "inbounds"; then
      cat <<'SQL'
DROP TABLE IF EXISTS temp.node_inbound_current;
CREATE TEMP TABLE node_inbound_current AS
SELECT tag, COALESCE(up, 0) AS up, COALESCE(down, 0) AS down
FROM node.inbounds
WHERE tag IS NOT NULL AND tag <> '';
SQL
      cat <<SQL
INSERT INTO inbound_traffic_totals(tag, up, down, seen_count)
SELECT
  cur.tag,
  CASE WHEN cur.up - COALESCE(st.base_up, 0) > 0 THEN cur.up - COALESCE(st.base_up, 0) ELSE 0 END,
  CASE WHEN cur.down - COALESCE(st.base_down, 0) > 0 THEN cur.down - COALESCE(st.base_down, 0) ELSE 0 END,
  1
FROM node_inbound_current cur
LEFT JOIN mst.node_inbound_base st ON st.server_id = $(quote_sql_literal "$node_name") AND st.tag = cur.tag
WHERE 1
ON CONFLICT(tag) DO UPDATE SET
  up = inbound_traffic_totals.up + excluded.up,
  down = inbound_traffic_totals.down + excluded.down,
  seen_count = inbound_traffic_totals.seen_count + 1;

INSERT INTO merge_inbound_bases(server_id, tag, base_up, base_down)
SELECT $(quote_sql_literal "$node_name"), tag, up, down
FROM node_inbound_current
WHERE 1
ON CONFLICT(server_id, tag) DO UPDATE SET
  base_up = excluded.base_up,
  base_down = excluded.base_down;
SQL
    else
      log "skip $node_name: table inbounds not found"
    fi

    printf "DETACH DATABASE mst;\n"
    printf "DETACH DATABASE node;\n"
  } > "$sql_file"

  sqlite3 "$aggregate_db" < "$sql_file"
  rm -f "$sql_file"
}

save_master_state() {
  local aggregate_db="$1"
  local sql_file
  sql_file="$(mktemp)"
  {
    write_master_state_sql
    printf "ATTACH DATABASE %s AS agg;\n" "$(quote_sql_literal "$aggregate_db")"
    cat <<'SQL'
BEGIN IMMEDIATE;

DELETE FROM global_client_state;
INSERT INTO global_client_state(user_key, synced_up, synced_down, synced_all_time, synced_last_online, updated_at)
SELECT user_key, up, down, all_time, last_online, CAST(strftime('%s', 'now') AS INTEGER)
FROM agg.client_traffic_totals;

DELETE FROM global_inbound_state;
INSERT INTO global_inbound_state(tag, synced_up, synced_down, updated_at)
SELECT tag, up, down, CAST(strftime('%s', 'now') AS INTEGER)
FROM agg.inbound_traffic_totals;

INSERT INTO node_client_base(server_id, user_key, base_up, base_down, base_all_time, updated_at)
SELECT server_id, user_key, base_up, base_down, base_all_time, CAST(strftime('%s', 'now') AS INTEGER)
FROM agg.merge_client_bases
WHERE 1
ON CONFLICT(server_id, user_key) DO UPDATE SET
  base_up = excluded.base_up,
  base_down = excluded.base_down,
  base_all_time = excluded.base_all_time,
  updated_at = excluded.updated_at;

INSERT INTO node_inbound_base(server_id, tag, base_up, base_down, updated_at)
SELECT server_id, tag, base_up, base_down, CAST(strftime('%s', 'now') AS INTEGER)
FROM agg.merge_inbound_bases
WHERE 1
ON CONFLICT(server_id, tag) DO UPDATE SET
  base_up = excluded.base_up,
  base_down = excluded.base_down,
  updated_at = excluded.updated_at;

COMMIT;
DETACH DATABASE agg;
SQL
  } > "$sql_file"

  sqlite3 "$MASTER_STATE_DB" < "$sql_file"
  rm -f "$sql_file"
}

mark_node_applied() {
  local aggregate_db="$1" node_name="$2"
  local sql_file
  sql_file="$(mktemp)"
  {
    write_master_state_sql
    printf "ATTACH DATABASE %s AS agg;\n" "$(quote_sql_literal "$aggregate_db")"
    cat <<SQL
BEGIN IMMEDIATE;

UPDATE node_client_base
SET
  base_up = COALESCE((
    SELECT totals.up * bases.entries
    FROM agg.merge_client_bases bases
    JOIN agg.client_traffic_totals totals ON totals.user_key = bases.user_key
    WHERE bases.server_id = $(quote_sql_literal "$node_name")
      AND bases.server_id = node_client_base.server_id
      AND bases.user_key = node_client_base.user_key
  ), base_up),
  base_down = COALESCE((
    SELECT totals.down * bases.entries
    FROM agg.merge_client_bases bases
    JOIN agg.client_traffic_totals totals ON totals.user_key = bases.user_key
    WHERE bases.server_id = $(quote_sql_literal "$node_name")
      AND bases.server_id = node_client_base.server_id
      AND bases.user_key = node_client_base.user_key
  ), base_down),
  base_all_time = COALESCE((
    SELECT totals.all_time * bases.entries
    FROM agg.merge_client_bases bases
    JOIN agg.client_traffic_totals totals ON totals.user_key = bases.user_key
    WHERE bases.server_id = $(quote_sql_literal "$node_name")
      AND bases.server_id = node_client_base.server_id
      AND bases.user_key = node_client_base.user_key
  ), base_all_time),
  updated_at = CAST(strftime('%s', 'now') AS INTEGER)
WHERE server_id = $(quote_sql_literal "$node_name")
  AND EXISTS (
    SELECT 1
    FROM agg.merge_client_bases bases
    WHERE bases.server_id = node_client_base.server_id
      AND bases.user_key = node_client_base.user_key
  );

UPDATE node_inbound_base
SET
  base_up = COALESCE((
    SELECT totals.up
    FROM agg.merge_inbound_bases bases
    JOIN agg.inbound_traffic_totals totals ON totals.tag = bases.tag
    WHERE bases.server_id = $(quote_sql_literal "$node_name")
      AND bases.server_id = node_inbound_base.server_id
      AND bases.tag = node_inbound_base.tag
  ), base_up),
  base_down = COALESCE((
    SELECT totals.down
    FROM agg.merge_inbound_bases bases
    JOIN agg.inbound_traffic_totals totals ON totals.tag = bases.tag
    WHERE bases.server_id = $(quote_sql_literal "$node_name")
      AND bases.server_id = node_inbound_base.server_id
      AND bases.tag = node_inbound_base.tag
  ), base_down),
  updated_at = CAST(strftime('%s', 'now') AS INTEGER)
WHERE server_id = $(quote_sql_literal "$node_name")
  AND EXISTS (
    SELECT 1
    FROM agg.merge_inbound_bases bases
    WHERE bases.server_id = node_inbound_base.server_id
      AND bases.tag = node_inbound_base.tag
  );

COMMIT;
DETACH DATABASE agg;
SQL
  } > "$sql_file"

  sqlite3 "$MASTER_STATE_DB" < "$sql_file"
  rm -f "$sql_file"
}

cmd_merge_dir() {
  need_cmd sqlite3
  need_cmd tar

  local snapshots_dir="${1:-$WORKDIR/master/snapshots}"
  local output_db="${2:-$WORKDIR/master/merged-traffic.db}"
  [[ -d "$snapshots_dir" ]] || die "snapshots directory not found: $snapshots_dir"

  mkdir -p "$(dirname "$output_db")"
  mkdir -p "$(dirname "$MASTER_STATE_DB")"
  local state_sql
  state_sql="$(mktemp)"
  write_master_state_sql > "$state_sql"
  sqlite3 "$MASTER_STATE_DB" < "$state_sql"
  rm -f "$state_sql"

  rm -f "$output_db"
  local init_sql
  init_sql="$(mktemp)"
  write_merge_sql "$init_sql"
  sqlite3 "$output_db" < "$init_sql"
  rm -f "$init_sql"

  sqlite3 "$output_db" \
    "ATTACH DATABASE $(quote_sql_literal "$MASTER_STATE_DB") AS mst;
     INSERT INTO client_traffic_totals(user_key, up, down, all_time, last_online, seen_count)
     SELECT user_key, synced_up, synced_down, synced_all_time, synced_last_online, 0
     FROM mst.global_client_state
     WHERE 1
     ON CONFLICT(user_key) DO UPDATE SET
       up = MAX(client_traffic_totals.up, excluded.up),
       down = MAX(client_traffic_totals.down, excluded.down),
       all_time = MAX(client_traffic_totals.all_time, excluded.all_time),
       last_online = MAX(client_traffic_totals.last_online, excluded.last_online);
     INSERT INTO inbound_traffic_totals(tag, up, down, seen_count)
     SELECT tag, synced_up, synced_down, 0
     FROM mst.global_inbound_state
     WHERE 1
     ON CONFLICT(tag) DO UPDATE SET
       up = MAX(inbound_traffic_totals.up, excluded.up),
       down = MAX(inbound_traffic_totals.down, excluded.down);
     DETACH DATABASE mst;"

  local found=0 archive extract_dir db node_name
  while IFS= read -r -d '' archive; do
    found=1
    extract_dir="$(mktemp -d)"
    tar -C "$extract_dir" -xzf "$archive"
    db="$extract_dir/x-ui.db"
    [[ -f "$db" ]] || die "archive has no x-ui.db: $archive"
    node_name="$(basename "$archive" .tar.gz)"
    merge_one_snapshot "$output_db" "$db" "$node_name"
    rm -rf "$extract_dir"
  done < <(find "$snapshots_dir" -type f -name '*.tar.gz' -print0 | sort -z)

  [[ "$found" -eq 1 ]] || die "no snapshot archives found in $snapshots_dir"
  sqlite3 "$output_db" "PRAGMA quick_check;" | grep -qx "ok" || die "merged database quick_check failed"
  save_master_state "$output_db"
  log "merged traffic database: $output_db"
  sqlite3 -header -column "$output_db" \
    "SELECT COUNT(*) AS clients, COALESCE(SUM(up),0) AS up, COALESCE(SUM(down),0) AS down FROM client_traffic_totals;"
  printf '%s\n' "$output_db"
}

service_stop() {
  [[ "$STOP_SERVICE_ON_APPLY" == "1" ]] || return 0
  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files "${SERVICE_NAME}.service" >/dev/null 2>&1; then
    systemctl stop "$SERVICE_NAME" || die "failed to stop service: $SERVICE_NAME"
  fi
}

service_start() {
  [[ "$STOP_SERVICE_ON_APPLY" == "1" ]] || return 0
  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files "${SERVICE_NAME}.service" >/dev/null 2>&1; then
    systemctl start "$SERVICE_NAME" || die "failed to start service: $SERVICE_NAME"
  fi
}

cmd_apply_traffic() {
  need_cmd sqlite3
  local aggregate_db="${1:-}"
  [[ -n "$aggregate_db" ]] || die "usage: $0 apply-traffic /path/to/merged-traffic.db"
  [[ -f "$aggregate_db" ]] || die "merged traffic database not found: $aggregate_db"
  require_local_db

  has_table "$aggregate_db" "client_traffic_totals" || die "merged db missing client_traffic_totals"
  has_table "$aggregate_db" "inbound_traffic_totals" || die "merged db missing inbound_traffic_totals"

  local backup_dir backup_db sql_file
  backup_dir="$WORKDIR/backups/$(date -u +%Y%m%dT%H%M%SZ)"
  backup_db="$backup_dir/x-ui.db"
  mkdir -p "$backup_dir"
  mkdir -p "$(dirname "$STATE_DB")"

  log "backup current database to $backup_db"
  sqlite_backup "$DB_PATH" "$backup_db"
  if [[ -f "$STATE_DB" ]]; then
    sqlite_backup "$STATE_DB" "$backup_dir/state.db"
  fi

  sql_file="$(mktemp)"
  local client_all_time_expr client_last_online_expr
  client_all_time_expr="COALESCE(up, 0) + COALESCE(down, 0)"
  client_last_online_expr="0"
  if has_table "$DB_PATH" "client_traffics"; then
    if has_column "$DB_PATH" "client_traffics" "all_time"; then
      client_all_time_expr="COALESCE(all_time, COALESCE(up, 0) + COALESCE(down, 0))"
    fi
    if has_column "$DB_PATH" "client_traffics" "last_online"; then
      client_last_online_expr="COALESCE(last_online, 0)"
    fi
  fi

  {
    printf "ATTACH DATABASE %s AS agg;\n" "$(quote_sql_literal "$aggregate_db")"
    printf "ATTACH DATABASE %s AS st;\n" "$(quote_sql_literal "$STATE_DB")"
    printf "BEGIN IMMEDIATE;\n"
    write_local_state_sql "st."

    if has_table "$DB_PATH" "client_traffics"; then
      if has_column "$DB_PATH" "client_traffics" "up"; then
        cat <<'SQL'
UPDATE client_traffics
SET up = COALESCE((
  SELECT up FROM agg.client_traffic_totals
  WHERE user_key = CASE
    WHEN instr(client_traffics.email, '@') > 0 THEN substr(client_traffics.email, 1, instr(client_traffics.email, '@') - 1)
    ELSE client_traffics.email
  END
), up)
WHERE EXISTS (
  SELECT 1 FROM agg.client_traffic_totals
  WHERE user_key = CASE
    WHEN instr(client_traffics.email, '@') > 0 THEN substr(client_traffics.email, 1, instr(client_traffics.email, '@') - 1)
    ELSE client_traffics.email
  END
);
SQL
      fi
      if has_column "$DB_PATH" "client_traffics" "down"; then
        cat <<'SQL'
UPDATE client_traffics
SET down = COALESCE((
  SELECT down FROM agg.client_traffic_totals
  WHERE user_key = CASE
    WHEN instr(client_traffics.email, '@') > 0 THEN substr(client_traffics.email, 1, instr(client_traffics.email, '@') - 1)
    ELSE client_traffics.email
  END
), down)
WHERE EXISTS (
  SELECT 1 FROM agg.client_traffic_totals
  WHERE user_key = CASE
    WHEN instr(client_traffics.email, '@') > 0 THEN substr(client_traffics.email, 1, instr(client_traffics.email, '@') - 1)
    ELSE client_traffics.email
  END
);
SQL
      fi
      if has_column "$DB_PATH" "client_traffics" "all_time"; then
        cat <<'SQL'
UPDATE client_traffics
SET all_time = COALESCE((
  SELECT all_time FROM agg.client_traffic_totals
  WHERE user_key = CASE
    WHEN instr(client_traffics.email, '@') > 0 THEN substr(client_traffics.email, 1, instr(client_traffics.email, '@') - 1)
    ELSE client_traffics.email
  END
), all_time)
WHERE EXISTS (
  SELECT 1 FROM agg.client_traffic_totals
  WHERE user_key = CASE
    WHEN instr(client_traffics.email, '@') > 0 THEN substr(client_traffics.email, 1, instr(client_traffics.email, '@') - 1)
    ELSE client_traffics.email
  END
);
SQL
      fi
      if has_column "$DB_PATH" "client_traffics" "last_online"; then
        cat <<'SQL'
UPDATE client_traffics
SET last_online = COALESCE((
  SELECT last_online FROM agg.client_traffic_totals
  WHERE user_key = CASE
    WHEN instr(client_traffics.email, '@') > 0 THEN substr(client_traffics.email, 1, instr(client_traffics.email, '@') - 1)
    ELSE client_traffics.email
  END
), last_online)
WHERE EXISTS (
  SELECT 1 FROM agg.client_traffic_totals
  WHERE user_key = CASE
    WHEN instr(client_traffics.email, '@') > 0 THEN substr(client_traffics.email, 1, instr(client_traffics.email, '@') - 1)
    ELSE client_traffics.email
  END
);
SQL
      fi
      cat <<SQL
INSERT INTO st.xui_sync_client_state(
  user_key,
  synced_up,
  synced_down,
  synced_all_time,
  synced_last_online,
  base_up,
  base_down,
  base_all_time,
  entries,
  updated_at
)
SELECT
  cur.user_key,
  agg_totals.up,
  agg_totals.down,
  agg_totals.all_time,
  agg_totals.last_online,
  cur.up,
  cur.down,
  cur.all_time,
  cur.entries,
  CAST(strftime('%s', 'now') AS INTEGER)
FROM (
  SELECT
    CASE
      WHEN instr(email, '@') > 0 THEN substr(email, 1, instr(email, '@') - 1)
      ELSE email
    END AS user_key,
    SUM(COALESCE(up, 0)) AS up,
    SUM(COALESCE(down, 0)) AS down,
    SUM($client_all_time_expr) AS all_time,
    COUNT(*) AS entries
  FROM client_traffics
  WHERE email IS NOT NULL AND email <> ''
  GROUP BY user_key
) cur
JOIN agg.client_traffic_totals agg_totals ON agg_totals.user_key = cur.user_key
WHERE cur.user_key <> ''
ON CONFLICT(user_key) DO UPDATE SET
  synced_up = excluded.synced_up,
  synced_down = excluded.synced_down,
  synced_all_time = excluded.synced_all_time,
  synced_last_online = excluded.synced_last_online,
  base_up = excluded.base_up,
  base_down = excluded.base_down,
  base_all_time = excluded.base_all_time,
  entries = excluded.entries,
  updated_at = excluded.updated_at;
SQL
    fi

    if [[ "$SYNC_INBOUND_TRAFFIC" == "1" ]] && has_table "$DB_PATH" "inbounds"; then
      if has_column "$DB_PATH" "inbounds" "up"; then
        cat <<'SQL'
UPDATE inbounds
SET up = COALESCE((SELECT up FROM agg.inbound_traffic_totals WHERE tag = inbounds.tag), up)
WHERE EXISTS (SELECT 1 FROM agg.inbound_traffic_totals WHERE tag = inbounds.tag);
SQL
      fi
      if has_column "$DB_PATH" "inbounds" "down"; then
        cat <<'SQL'
UPDATE inbounds
SET down = COALESCE((SELECT down FROM agg.inbound_traffic_totals WHERE tag = inbounds.tag), down)
WHERE EXISTS (SELECT 1 FROM agg.inbound_traffic_totals WHERE tag = inbounds.tag);
SQL
      fi
      cat <<'SQL'
INSERT INTO st.xui_sync_inbound_state(
  tag,
  synced_up,
  synced_down,
  base_up,
  base_down,
  updated_at
)
SELECT
  inbounds.tag,
  agg_totals.up,
  agg_totals.down,
  COALESCE(inbounds.up, 0),
  COALESCE(inbounds.down, 0),
  CAST(strftime('%s', 'now') AS INTEGER)
FROM inbounds
JOIN agg.inbound_traffic_totals agg_totals ON agg_totals.tag = inbounds.tag
WHERE inbounds.tag IS NOT NULL AND inbounds.tag <> ''
ON CONFLICT(tag) DO UPDATE SET
  synced_up = excluded.synced_up,
  synced_down = excluded.synced_down,
  base_up = excluded.base_up,
  base_down = excluded.base_down,
  updated_at = excluded.updated_at;
SQL
    fi

    printf "COMMIT;\n"
    printf "DETACH DATABASE st;\n"
    printf "DETACH DATABASE agg;\n"
  } > "$sql_file"

  service_stop
  sqlite3 "$DB_PATH" < "$sql_file" || {
    rm -f "$sql_file"
    service_start || true
    die "failed to apply merged traffic; restore from $backup_db if needed"
  }
  rm -f "$sql_file"
  sqlite3 "$DB_PATH" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 || true
  service_start
  log "traffic applied successfully"
}

cmd_reset_traffic() {
  need_cmd sqlite3
  require_local_db
  local user_keys=() user_key arg
  for arg in "$@"; do
    user_key="$(normalize_user_key "$arg")"
    [[ -n "$user_key" ]] || continue
    user_keys+=("$user_key")
  done

  local backup_dir backup_db sql_file
  backup_dir="$WORKDIR/backups/$(date -u +%Y%m%dT%H%M%SZ)"
  backup_db="$backup_dir/x-ui.db"
  mkdir -p "$backup_dir"
  mkdir -p "$(dirname "$STATE_DB")"

  if [[ "${#user_keys[@]}" -gt 0 ]]; then
    log "reset selected user traffic: ${user_keys[*]}"
  else
    log "reset all user traffic"
  fi

  log "backup current database to $backup_db"
  sqlite_backup "$DB_PATH" "$backup_db"
  if [[ -f "$STATE_DB" ]]; then
    sqlite_backup "$STATE_DB" "$backup_dir/state.db"
  fi

  sql_file="$(mktemp)"
  {
    printf "BEGIN IMMEDIATE;\n"

    if has_table "$DB_PATH" "client_traffics"; then
      local sets=()
      local where_clause=""
      if has_column "$DB_PATH" "client_traffics" "up"; then
        sets+=("up=0")
      fi
      if has_column "$DB_PATH" "client_traffics" "down"; then
        sets+=("down=0")
      fi
      if has_column "$DB_PATH" "client_traffics" "all_time"; then
        sets+=("all_time=0")
      fi
      if has_column "$DB_PATH" "client_traffics" "last_online"; then
        sets+=("last_online=0")
      fi
      if [[ "${#user_keys[@]}" -gt 0 ]]; then
        where_clause=" WHERE CASE WHEN instr(email, '@') > 0 THEN substr(email, 1, instr(email, '@') - 1) ELSE email END IN ($(sql_literal_list_from_args "${user_keys[@]}"))"
      fi
      if [[ "${#sets[@]}" -gt 0 ]]; then
        printf 'UPDATE client_traffics SET %s%s;\n' "$(IFS=,; echo "${sets[*]}")" "$where_clause"
      else
        log "skip reset: client_traffics has no supported traffic columns"
      fi
    else
      log "skip reset: table client_traffics not found"
    fi

    printf "COMMIT;\n"
  } > "$sql_file"

  service_stop
  sqlite3 "$DB_PATH" < "$sql_file" || {
    rm -f "$sql_file"
    service_start || true
    die "failed to reset traffic; restore from $backup_db if needed"
  }
  rm -f "$sql_file"
  sqlite3 "$DB_PATH" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 || true
  service_start

  if [[ "${#user_keys[@]}" -gt 0 ]]; then
    if [[ -f "$STATE_DB" ]] && has_table "$STATE_DB" "xui_sync_client_state"; then
      local state_sql
      state_sql="$(mktemp)"
      {
        printf "BEGIN IMMEDIATE;\n"
        printf "DELETE FROM xui_sync_client_state WHERE user_key IN (%s);\n" "$(sql_literal_list_from_args "${user_keys[@]}")"
        printf "COMMIT;\n"
      } > "$state_sql"
      sqlite3 "$STATE_DB" < "$state_sql"
      rm -f "$state_sql"
    fi
  else
    if [[ -f "$STATE_DB" ]]; then
      log "remove local sync state db: $STATE_DB"
      rm -f "$STATE_DB"
    fi
  fi

  log "traffic reset successfully"
}

cmd_reset_traffic_all() {
  need_cmd sqlite3
  require_local_db

  [[ "$#" -eq 0 ]] || die "usage: $0 reset-traffic-all"

  local backup_dir backup_db sql_file
  backup_dir="$WORKDIR/backups/$(date -u +%Y%m%dT%H%M%SZ)"
  backup_db="$backup_dir/x-ui.db"
  mkdir -p "$backup_dir"
  mkdir -p "$(dirname "$STATE_DB")"

  log "backup current database to $backup_db"
  sqlite_backup "$DB_PATH" "$backup_db"
  if [[ -f "$STATE_DB" ]]; then
    sqlite_backup "$STATE_DB" "$backup_dir/state.db"
  fi

  sql_file="$(mktemp)"
  {
    printf "BEGIN IMMEDIATE;\n"

    if has_table "$DB_PATH" "client_traffics"; then
      local sets=()
      if has_column "$DB_PATH" "client_traffics" "up"; then
        sets+=("up=0")
      fi
      if has_column "$DB_PATH" "client_traffics" "down"; then
        sets+=("down=0")
      fi
      if has_column "$DB_PATH" "client_traffics" "all_time"; then
        sets+=("all_time=0")
      fi
      if has_column "$DB_PATH" "client_traffics" "last_online"; then
        sets+=("last_online=0")
      fi
      if [[ "${#sets[@]}" -gt 0 ]]; then
        printf 'UPDATE client_traffics SET %s;\n' "$(IFS=,; echo "${sets[*]}")"
      else
        log "skip reset: client_traffics has no supported traffic columns"
      fi
    else
      log "skip reset: table client_traffics not found"
    fi

    if has_table "$DB_PATH" "inbounds"; then
      local inbound_sets=()
      if has_column "$DB_PATH" "inbounds" "up"; then
        inbound_sets+=("up=0")
      fi
      if has_column "$DB_PATH" "inbounds" "down"; then
        inbound_sets+=("down=0")
      fi
      if has_column "$DB_PATH" "inbounds" "all_time"; then
        inbound_sets+=("all_time=0")
      fi
      if [[ "${#inbound_sets[@]}" -gt 0 ]]; then
        printf 'UPDATE inbounds SET %s;\n' "$(IFS=,; echo "${inbound_sets[*]}")"
      else
        log "skip reset: inbounds has no supported traffic columns"
      fi
    else
      log "skip reset: table inbounds not found"
    fi

    printf "COMMIT;\n"
  } > "$sql_file"

  service_stop
  sqlite3 "$DB_PATH" < "$sql_file" || {
    rm -f "$sql_file"
    service_start || true
    die "failed to reset traffic; restore from $backup_db if needed"
  }
  rm -f "$sql_file"
  sqlite3 "$DB_PATH" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 || true
  service_start

  if [[ -f "$STATE_DB" ]]; then
    log "remove local sync state db: $STATE_DB"
    rm -f "$STATE_DB"
  fi

  log "traffic reset successfully"
}

cmd_master_reset_traffic() {
  need_cmd ssh
  need_cmd sqlite3
  load_config

  local user_keys=() user_key arg
  for arg in "$@"; do
    user_key="$(normalize_user_key "$arg")"
    [[ -n "$user_key" ]] || continue
    user_keys+=("$user_key")
  done

  local backup_dir
  backup_dir="$WORKDIR/backups/$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$backup_dir"
  mkdir -p "$(dirname "$MASTER_STATE_DB")"

  if [[ "${#user_keys[@]}" -gt 0 ]]; then
    log "master reset selected user traffic: ${user_keys[*]}"
  else
    log "master reset all user traffic"
  fi

  if [[ -f "$MASTER_STATE_DB" ]]; then
    log "backup master state db to $backup_dir/master-state.db"
    sqlite_backup "$MASTER_STATE_DB" "$backup_dir/master-state.db"
  fi

  local node name host user port remote_script failed=0
  for node in "${NODES[@]}"; do
    name="$(node_field "$node" 1)"
    host="$(node_field "$node" 2)"
    user="$(node_field "$node" 3)"
    port="$(node_field "$node" 4)"
    remote_script="$(node_field "$node" 5)"
    [[ -n "$name" && -n "$host" && -n "$user" && -n "$port" && -n "$remote_script" ]] || die "bad node spec: $node"

    log "reset traffic on $name"
    if [[ "${#user_keys[@]}" -gt 0 ]]; then
      if ! ssh "${SSH_BASE_OPTS[@]}" -p "$port" "$user@$host" "bash '$remote_script' reset-traffic $(printf '%q ' "${user_keys[@]}")"; then
        log "skip $name: reset failed"
        failed=1
      fi
    else
      if ! ssh "${SSH_BASE_OPTS[@]}" -p "$port" "$user@$host" "bash '$remote_script' reset-traffic"; then
        log "skip $name: reset failed"
        failed=1
      fi
    fi
  done

  if [[ "$failed" -ne 0 ]]; then
    log "master traffic reset aborted; master state db kept so the next sync can still reconcile"
    return 1
  fi

  if [[ "${#user_keys[@]}" -gt 0 ]]; then
    if [[ -f "$MASTER_STATE_DB" ]] && has_table "$MASTER_STATE_DB" "global_client_state"; then
      local state_sql
      state_sql="$(mktemp)"
      {
        printf "BEGIN IMMEDIATE;\n"
        printf "DELETE FROM global_client_state WHERE user_key IN (%s);\n" "$(sql_literal_list_from_args "${user_keys[@]}")"
        printf "DELETE FROM node_client_base WHERE user_key IN (%s);\n" "$(sql_literal_list_from_args "${user_keys[@]}")"
        printf "COMMIT;\n"
      } > "$state_sql"
      sqlite3 "$MASTER_STATE_DB" < "$state_sql"
      rm -f "$state_sql"
    fi
  else
    if [[ -f "$MASTER_STATE_DB" ]]; then
      log "remove master sync state db: $MASTER_STATE_DB"
      rm -f "$MASTER_STATE_DB"
    fi
  fi

  log "master traffic reset completed"
}

cmd_master_reset_traffic_all() {
  need_cmd ssh
  need_cmd sqlite3
  load_config

  [[ "$#" -eq 0 ]] || die "usage: $0 master-reset-traffic-all"

  local backup_dir
  backup_dir="$WORKDIR/backups/$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$backup_dir"
  mkdir -p "$(dirname "$MASTER_STATE_DB")"

  if [[ -f "$MASTER_STATE_DB" ]]; then
    log "backup master state db to $backup_dir/master-state.db"
    sqlite_backup "$MASTER_STATE_DB" "$backup_dir/master-state.db"
  fi

  local node name host user port remote_script failed=0
  for node in "${NODES[@]}"; do
    name="$(node_field "$node" 1)"
    host="$(node_field "$node" 2)"
    user="$(node_field "$node" 3)"
    port="$(node_field "$node" 4)"
    remote_script="$(node_field "$node" 5)"
    [[ -n "$name" && -n "$host" && -n "$user" && -n "$port" && -n "$remote_script" ]] || die "bad node spec: $node"

    log "reset traffic (client + inbound) on $name"
    if ! ssh "${SSH_BASE_OPTS[@]}" -p "$port" "$user@$host" "bash '$remote_script' reset-traffic-all"; then
      log "skip $name: reset failed"
      failed=1
    fi
  done

  if [[ "$failed" -ne 0 ]]; then
    log "master traffic reset aborted; master state db kept so the next sync can still reconcile"
    return 1
  fi

  if [[ -f "$MASTER_STATE_DB" ]]; then
    log "remove master sync state db: $MASTER_STATE_DB"
    rm -f "$MASTER_STATE_DB"
  fi

  log "master traffic reset completed"
}

load_config() {
  [[ -f "$CONFIG_FILE" ]] || die "config file not found: $CONFIG_FILE"
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
  declare -p NODES >/dev/null 2>&1 || die "config must define NODES array"
}

node_field() {
  local spec="$1" idx="$2"
  awk -F'|' -v i="$idx" '{print $i}' <<<"$spec"
}

cmd_master() {
  need_cmd ssh
  need_cmd scp
  need_cmd sqlite3
  need_cmd tar
  load_config

  local run_id snapshots_dir merged_db aggregate_remote
  run_id="$(date -u +%Y%m%dT%H%M%SZ)"
  snapshots_dir="$WORKDIR/master/snapshots/$run_id"
  mkdir -p "$snapshots_dir"

  local node name host user port remote_script archive remote_archive local_archive exported_nodes
  exported_nodes=()
  for node in "${NODES[@]}"; do
    name="$(node_field "$node" 1)"
    host="$(node_field "$node" 2)"
    user="$(node_field "$node" 3)"
    port="$(node_field "$node" 4)"
    remote_script="$(node_field "$node" 5)"
    [[ -n "$name" && -n "$host" && -n "$user" && -n "$port" && -n "$remote_script" ]] || die "bad node spec: $node"

    log "export $name"
    if ! remote_archive="$(ssh "${SSH_BASE_OPTS[@]}" -p "$port" "$user@$host" "SERVER_ID='$name' bash '$remote_script' export" | tail -n 1)"; then
      log "skip $name: export failed"
      continue
    fi
    if [[ -z "$remote_archive" ]]; then
      log "skip $name: empty export path"
      continue
    fi
    local_archive="$snapshots_dir/${name}.tar.gz"
    if ! scp "${SSH_BASE_OPTS[@]}" -P "$port" "$user@$host:$remote_archive" "$local_archive" >/dev/null; then
      log "skip $name: failed to download snapshot"
      rm -f "$local_archive"
      continue
    fi
    exported_nodes+=("$node")
  done

  [[ "${#exported_nodes[@]}" -gt 0 ]] || die "no nodes exported successfully"

  merged_db="$WORKDIR/master/merged-traffic-$run_id.db"
  cmd_merge_dir "$snapshots_dir" "$merged_db" >/dev/null

  for node in "${NODES[@]}"; do
    name="$(node_field "$node" 1)"
    host="$(node_field "$node" 2)"
    user="$(node_field "$node" 3)"
    port="$(node_field "$node" 4)"
    remote_script="$(node_field "$node" 5)"
    aggregate_remote="/tmp/xui-sync-merged-traffic-$run_id.db"

    log "push merged traffic to $name"
    if ! scp "${SSH_BASE_OPTS[@]}" -P "$port" "$merged_db" "$user@$host:$aggregate_remote" >/dev/null; then
      log "skip $name: failed to upload merged traffic"
      continue
    fi
    if ! ssh "${SSH_BASE_OPTS[@]}" -p "$port" "$user@$host" "bash '$remote_script' apply-traffic '$aggregate_remote' && rm -f '$aggregate_remote'"; then
      log "skip $name: failed to apply merged traffic"
      continue
    fi
    mark_node_applied "$merged_db" "$name"
  done

  log "master sync completed: $run_id"
}

cmd_summary() {
  need_cmd sqlite3
  local db="${1:-$DB_PATH}"
  [[ -f "$db" ]] || die "db not found: $db"
  if has_table "$db" "client_traffics"; then
    local all_time_expr last_online_expr
    all_time_expr="up + down"
    last_online_expr="0"
    if has_column "$db" "client_traffics" "all_time"; then
      all_time_expr="COALESCE(all_time, up + down)"
    fi
    if has_column "$db" "client_traffics" "last_online"; then
      last_online_expr="last_online"
    fi
    if [[ -f "$STATE_DB" ]] && has_table "$STATE_DB" "xui_sync_client_state"; then
      sqlite3 -header -column "$db" \
        "ATTACH DATABASE $(quote_sql_literal "$STATE_DB") AS st; WITH cur AS (SELECT CASE WHEN instr(email, '@') > 0 THEN substr(email, 1, instr(email, '@') - 1) ELSE email END AS user_key, SUM(up) AS up, SUM(down) AS down, SUM($all_time_expr) AS all_time, MAX($last_online_expr) AS last_online, COUNT(*) AS entries FROM client_traffics WHERE email IS NOT NULL AND email <> '' GROUP BY user_key) SELECT cur.user_key, COALESCE(sync.synced_up, 0) + CASE WHEN cur.up - COALESCE(sync.base_up, 0) > 0 THEN cur.up - COALESCE(sync.base_up, 0) ELSE 0 END AS up, COALESCE(sync.synced_down, 0) + CASE WHEN cur.down - COALESCE(sync.base_down, 0) > 0 THEN cur.down - COALESCE(sync.base_down, 0) ELSE 0 END AS down, COALESCE(sync.synced_all_time, 0) + CASE WHEN cur.all_time - COALESCE(sync.base_all_time, 0) > 0 THEN cur.all_time - COALESCE(sync.base_all_time, 0) ELSE 0 END AS all_time, MAX(cur.last_online, COALESCE(sync.synced_last_online, 0)) AS last_online, cur.entries FROM cur LEFT JOIN st.xui_sync_client_state sync ON sync.user_key = cur.user_key ORDER BY (up + down) DESC LIMIT 20; DETACH DATABASE st;"
    else
      sqlite3 -header -column "$db" \
        "SELECT CASE WHEN instr(email, '@') > 0 THEN substr(email, 1, instr(email, '@') - 1) ELSE email END AS user_key, SUM(up) AS up, SUM(down) AS down, SUM($all_time_expr) AS all_time, MAX($last_online_expr) AS last_online, COUNT(*) AS entries FROM client_traffics WHERE email IS NOT NULL AND email <> '' GROUP BY user_key ORDER BY (SUM(up) + SUM(down)) DESC LIMIT 20;"
    fi
  elif has_table "$db" "client_traffic_totals"; then
    sqlite3 -header -column "$db" \
      "SELECT user_key, up, down, all_time, last_online, seen_count FROM client_traffic_totals ORDER BY (up + down) DESC LIMIT 20;"
  else
    die "no supported traffic table in $db"
  fi
}

cmd_config_export() {
  need_cmd sqlite3
  need_cmd tar
  require_local_db

  local ts snapshot_dir snapshot_db manifest archive
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  snapshot_dir="$WORKDIR/config-exports/$SERVER_ID/$ts"
  snapshot_db="$snapshot_dir/config.db"
  manifest="$snapshot_dir/manifest.env"
  archive="$WORKDIR/config-exports/${SERVER_ID}_${ts}.tar.gz"

  mkdir -p "$snapshot_dir"
  local sql_file
  sql_file="$(mktemp)"

  {
    printf "ATTACH DATABASE %s AS src;\n" "$(quote_sql_literal "$DB_PATH")"
    cat <<'SQL'
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;

BEGIN IMMEDIATE;

CREATE TABLE IF NOT EXISTS users (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  username TEXT,
  password TEXT,
  login_secret TEXT
);

CREATE TABLE IF NOT EXISTS inbounds (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER,
  up INTEGER,
  down INTEGER,
  total INTEGER,
  remark TEXT,
  enable NUMERIC,
  expiry_time INTEGER,
  listen TEXT,
  port INTEGER,
  protocol TEXT,
  settings TEXT,
  stream_settings TEXT,
  tag TEXT,
  sniffing TEXT,
  allocate TEXT,
  all_time INTEGER DEFAULT 0,
  traffic_reset TEXT DEFAULT "never",
  last_traffic_reset_time INTEGER DEFAULT 0,
  CONSTRAINT uni_inbounds_tag UNIQUE (tag)
);

CREATE TABLE IF NOT EXISTS settings (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  key TEXT,
  value TEXT
);

DELETE FROM users;
INSERT INTO users SELECT * FROM src.users;

DELETE FROM inbounds;
INSERT INTO inbounds SELECT * FROM src.inbounds;

DELETE FROM settings;
INSERT INTO settings SELECT * FROM src.settings;

COMMIT;
DETACH DATABASE src;
SQL
  } > "$sql_file"
  
  sqlite3 "$snapshot_db" < "$sql_file"
  rm -f "$sql_file"

  {
    printf 'server_id=%q\n' "$SERVER_ID"
    printf 'created_at=%q\n' "$ts"
    printf 'hostname=%q\n' "$(hostname -f 2>/dev/null || hostname)"
    printf 'db_path=%q\n' "$DB_PATH"
  } > "$manifest"

  tar -C "$snapshot_dir" -czf "$archive" config.db manifest.env
  printf '%s\n' "$archive"
}

cmd_config_apply() {
  need_cmd sqlite3
  local config_db="${1:-}"
  [[ -n "$config_db" ]] || die "usage: $0 config-apply /path/to/config.db"
  [[ -f "$config_db" ]] || die "config database not found: $config_db"
  require_local_db

  has_table "$config_db" "users" || die "config db missing users table"
  has_table "$config_db" "inbounds" || die "config db missing inbounds table"
  has_table "$config_db" "settings" || die "config db missing settings table"

  local backup_dir backup_db sql_file
  backup_dir="$WORKDIR/backups/$(date -u +%Y%m%dT%H%M%SZ)"
  backup_db="$backup_dir/x-ui.db"
  mkdir -p "$backup_dir"

  log "backup current database to $backup_db"
  sqlite_backup "$DB_PATH" "$backup_db"

  sql_file="$(mktemp)"
  {
    printf "ATTACH DATABASE %s AS cfg;\n" "$(quote_sql_literal "$config_db")"
    printf "BEGIN IMMEDIATE;\n"

    if has_table "$DB_PATH" "users"; then
      local user_columns
      user_columns="$(common_table_columns "$DB_PATH" "users" "$config_db" "users" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
      [[ -n "$user_columns" ]] || die "no common columns between live users table and config snapshot"
      cat <<'SQL'
DELETE FROM users;
SQL
      printf 'INSERT INTO users(%s) SELECT %s FROM cfg.users;\n' "$(sql_ident_list_from_args $user_columns)" "$(sql_ident_list_from_args $user_columns)"
    fi

    if has_table "$DB_PATH" "inbounds"; then
      local inbound_columns preserve_columns preserve_select_list preserve_update_set
      inbound_columns="$(common_table_columns "$DB_PATH" "inbounds" "$config_db" "inbounds" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
      [[ -n "$inbound_columns" ]] || die "no common columns between live inbounds table and config snapshot"
      preserve_columns=()
      if [[ " $inbound_columns " == *" id "* ]] && has_column "$DB_PATH" "inbounds" "id"; then
        preserve_columns+=("id")
        for preserve in listen enable remark; do
          if has_column "$DB_PATH" "inbounds" "$preserve"; then
            preserve_columns+=("$preserve")
          fi
        done
      fi
      if [[ "${#preserve_columns[@]}" -gt 0 ]]; then
        preserve_select_list="$(sql_ident_list_from_args "${preserve_columns[@]}")"
        printf 'CREATE TEMP TABLE local_inbound_state AS SELECT %s FROM inbounds;\n' "$preserve_select_list"
      fi
      printf 'DELETE FROM inbounds;\n'
      printf 'INSERT INTO inbounds(%s) SELECT %s FROM cfg.inbounds;\n' "$(sql_ident_list_from_args $inbound_columns)" "$(sql_ident_list_from_args $inbound_columns)"
      if [[ " ${preserve_columns[*]} " == *" id "* ]]; then
        preserve_update_set=()
        for preserve in listen enable remark; do
          if [[ " ${preserve_columns[*]} " == *" $preserve "* ]]; then
            preserve_update_set+=("$(quote_sql_ident "$preserve") = (SELECT $(quote_sql_ident "$preserve") FROM local_inbound_state WHERE local_inbound_state.id = inbounds.id)")
          fi
        done
        if [[ "${#preserve_update_set[@]}" -gt 0 ]]; then
          printf 'UPDATE inbounds SET %s WHERE id IN (SELECT id FROM local_inbound_state);\n' "$(IFS=,; echo "${preserve_update_set[*]}")"
        fi
      fi
    fi

    if has_table "$DB_PATH" "settings"; then
      local settings_columns
      settings_columns="$(common_table_columns "$DB_PATH" "settings" "$config_db" "settings" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
      [[ -n "$settings_columns" ]] || die "no common columns between live settings table and config snapshot"
      cat <<'SQL'
DELETE FROM settings;
SQL
      printf 'INSERT INTO settings(%s) SELECT %s FROM cfg.settings;\n' "$(sql_ident_list_from_args $settings_columns)" "$(sql_ident_list_from_args $settings_columns)"
    fi

    printf "COMMIT;\n"
    printf "DETACH DATABASE cfg;\n"
  } > "$sql_file"

  service_stop
  sqlite3 "$DB_PATH" < "$sql_file" || {
    rm -f "$sql_file"
    service_start || true
    die "failed to apply config; restore from $backup_db if needed"
  }
  rm -f "$sql_file"
  sqlite3 "$DB_PATH" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 || true
  service_start
  log "config applied successfully"
}

cmd_config_merge() {
  need_cmd sqlite3
  need_cmd tar

  local config_master_node="${1:-}"
  local snapshots_dir="${2:-$WORKDIR/master/config-snapshots}"
  local output_db="${3:-$WORKDIR/master/config-merged.db}"

  [[ -n "$config_master_node" ]] || die "usage: $0 config-merge <master_node_name> [snapshots_dir] [output_db]"
  [[ -d "$snapshots_dir" ]] || die "snapshots directory not found: $snapshots_dir"

  mkdir -p "$(dirname "$output_db")"
  rm -f "$output_db"

  local found=0 archive extract_dir db node_name
  while IFS= read -r -d '' archive; do
    extract_dir="$(mktemp -d)"
    tar -C "$extract_dir" -xzf "$archive"
    db="$extract_dir/config.db"
    [[ -f "$db" ]] || continue
    
    node_name="$(basename "$archive" .tar.gz)"
    
    if [[ "$node_name" == "$config_master_node" ]]; then
      found=1
      log "using config from $node_name"

      sqlite3 "$output_db" "ATTACH DATABASE $(quote_sql_literal "$db") AS src;
        BEGIN IMMEDIATE;
        CREATE TABLE IF NOT EXISTS users (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          username TEXT,
          password TEXT,
          login_secret TEXT
        );
        CREATE TABLE IF NOT EXISTS inbounds (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          user_id INTEGER,
          up INTEGER,
          down INTEGER,
          total INTEGER,
          remark TEXT,
          enable NUMERIC,
          expiry_time INTEGER,
          listen TEXT,
          port INTEGER,
          protocol TEXT,
          settings TEXT,
          stream_settings TEXT,
          tag TEXT,
          sniffing TEXT,
          allocate TEXT,
          all_time INTEGER DEFAULT 0,
          traffic_reset TEXT DEFAULT \"never\",
          last_traffic_reset_time INTEGER DEFAULT 0,
          CONSTRAINT uni_inbounds_tag UNIQUE (tag)
        );
        CREATE TABLE IF NOT EXISTS settings (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          key TEXT,
          value TEXT
        );
        DELETE FROM users;
        INSERT INTO users SELECT * FROM src.users;
        DELETE FROM inbounds;
        INSERT INTO inbounds SELECT * FROM src.inbounds;
        DELETE FROM settings;
        INSERT INTO settings SELECT * FROM src.settings;
        COMMIT;
        DETACH DATABASE src;"
    fi
    
    rm -rf "$extract_dir"
  done < <(find "$snapshots_dir" -type f -name '*.tar.gz' -print0 | sort -z)

  [[ "$found" -eq 1 ]] || die "config master node not found: $config_master_node"
  sqlite3 "$output_db" "PRAGMA quick_check;" | grep -qx "ok" || die "merged config database quick_check failed"
  log "merged config database: $output_db"
  printf '%s\n' "$output_db"
}

cmd_config_sync() {
  need_cmd ssh
  need_cmd scp
  need_cmd sqlite3
  need_cmd tar
  load_config

  [[ -z "$CONFIG_MASTER_NODE" ]] && die "CONFIG_MASTER_NODE not set in $CONFIG_FILE"

  local run_id snapshots_dir merged_db aggregate_remote
  run_id="$(date -u +%Y%m%dT%H%M%SZ)"
  snapshots_dir="$WORKDIR/master/config-snapshots/$run_id"
  mkdir -p "$snapshots_dir"

  local node name host user port remote_script archive remote_archive local_archive exported_nodes
  exported_nodes=()
  for node in "${NODES[@]}"; do
    name="$(node_field "$node" 1)"
    host="$(node_field "$node" 2)"
    user="$(node_field "$node" 3)"
    port="$(node_field "$node" 4)"
    remote_script="$(node_field "$node" 5)"
    [[ -n "$name" && -n "$host" && -n "$user" && -n "$port" && -n "$remote_script" ]] || die "bad node spec: $node"

    log "config export $name"
    if ! remote_archive="$(ssh "${SSH_BASE_OPTS[@]}" -p "$port" "$user@$host" "SERVER_ID='$name' bash '$remote_script' config-export" | tail -n 1)"; then
      log "skip $name: config export failed"
      continue
    fi
    if [[ -z "$remote_archive" ]]; then
      log "skip $name: empty config export path"
      continue
    fi
    local_archive="$snapshots_dir/${name}.tar.gz"
    if ! scp "${SSH_BASE_OPTS[@]}" -P "$port" "$user@$host:$remote_archive" "$local_archive" >/dev/null; then
      log "skip $name: failed to download config snapshot"
      rm -f "$local_archive"
      continue
    fi
    exported_nodes+=("$node")
  done

  [[ "${#exported_nodes[@]}" -gt 0 ]] || die "no nodes exported config successfully"

  merged_db="$WORKDIR/master/config-merged-$run_id.db"
  cmd_config_merge "$CONFIG_MASTER_NODE" "$snapshots_dir" "$merged_db" >/dev/null

  for node in "${NODES[@]}"; do
    name="$(node_field "$node" 1)"
    host="$(node_field "$node" 2)"
    user="$(node_field "$node" 3)"
    port="$(node_field "$node" 4)"
    remote_script="$(node_field "$node" 5)"
    aggregate_remote="/tmp/xui-sync-config-$run_id.db"

    if [[ "$name" == "$CONFIG_MASTER_NODE" ]]; then
      log "skip $name: is config master node"
      continue
    fi

    log "push config to $name"
    if ! scp "${SSH_BASE_OPTS[@]}" -P "$port" "$merged_db" "$user@$host:$aggregate_remote" >/dev/null; then
      log "skip $name: failed to upload config"
      continue
    fi
    if ! ssh "${SSH_BASE_OPTS[@]}" -p "$port" "$user@$host" "bash '$remote_script' config-apply '$aggregate_remote' && rm -f '$aggregate_remote'"; then
      log "skip $name: failed to apply config"
      continue
    fi
  done

  log "config sync completed: $run_id"
}

cmd_config_add_user() {
  local username="${1:-}"
  local password="${2:-}"
  local login_secret="${3:-}"

  [[ -n "$username" && -n "$password" ]] || die "usage: $0 config-add-user <username> <password> [login_secret]"

  if [[ -f "$DB_PATH" ]]; then
    need_cmd sqlite3
    require_local_db

    if [[ -z "$login_secret" ]]; then
      login_secret="$(generate_login_secret)"
    fi

    local backup_dir backup_db sql_file
    backup_dir="$WORKDIR/backups/$(date -u +%Y%m%dT%H%M%SZ)"
    backup_db="$backup_dir/x-ui.db"
    mkdir -p "$backup_dir"

    log "backup current database to $backup_db"
    sqlite_backup "$DB_PATH" "$backup_db"

    sql_file="$(mktemp)"
    {
      printf "BEGIN IMMEDIATE;\n"
      if has_table "$DB_PATH" "users"; then
        cat <<SQL
UPDATE users
SET password = $(quote_sql_literal "$password"),
    login_secret = $(quote_sql_literal "$login_secret")
WHERE username = $(quote_sql_literal "$username");

INSERT INTO users(username, password, login_secret)
SELECT $(quote_sql_literal "$username"), $(quote_sql_literal "$password"), $(quote_sql_literal "$login_secret")
WHERE changes() = 0;
SQL
      else
        die "table users not found in $DB_PATH"
      fi
      printf "COMMIT;\n"
    } > "$sql_file"

    service_stop
    sqlite3 "$DB_PATH" < "$sql_file" || {
      rm -f "$sql_file"
      service_start || true
      die "failed to add user; restore from $backup_db if needed"
    }
    rm -f "$sql_file"
    sqlite3 "$DB_PATH" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 || true
    service_start

    log "user added or updated successfully: $username"
    printf '%s\n' "$username"
    return 0
  fi

  need_cmd ssh
  load_config
  [[ -n "$CONFIG_MASTER_NODE" ]] || die "CONFIG_MASTER_NODE not set in $CONFIG_FILE"

  local node_spec host user port remote_script remote_cmd
  node_spec="$(find_node_spec "$CONFIG_MASTER_NODE")" || die "config master node not found: $CONFIG_MASTER_NODE"
  host="$(node_field "$node_spec" 2)"
  user="$(node_field "$node_spec" 3)"
  port="$(node_field "$node_spec" 4)"
  remote_script="$(node_field "$node_spec" 5)"

  remote_cmd="SERVER_ID=$(printf '%q' "$CONFIG_MASTER_NODE") bash $(printf '%q' "$remote_script") config-add-user $(printf '%q' "$username") $(printf '%q' "$password")"
  if [[ -n "$login_secret" ]]; then
    remote_cmd+=" $(printf '%q' "$login_secret")"
  fi

  log "add user on config master: $CONFIG_MASTER_NODE"
  if ! ssh "${SSH_BASE_OPTS[@]}" -p "$port" "$user@$host" "$remote_cmd"; then
    die "failed to add user on config master: $CONFIG_MASTER_NODE"
  fi

  cmd_config_sync
}

cmd_delete_user_node() {
  local user_key="$(normalize_user_key "${1:-}")"
  [[ -n "$user_key" ]] || die "usage: $0 delete-user-node <user_key>"

  need_cmd sqlite3
  require_local_db

  local backup_dir backup_db sql_file
  backup_dir="$WORKDIR/backups/$(date -u +%Y%m%dT%H%M%SZ)"
  backup_db="$backup_dir/x-ui.db"
  mkdir -p "$backup_dir"
  mkdir -p "$(dirname "$STATE_DB")"

  log "backup current database to $backup_db"
  sqlite_backup "$DB_PATH" "$backup_db"
  if [[ -f "$STATE_DB" ]]; then
    sqlite_backup "$STATE_DB" "$backup_dir/state.db"
  fi

  sql_file="$(mktemp)"
  {
    printf "BEGIN IMMEDIATE;\n"
    if has_table "$DB_PATH" "users"; then
      cat <<SQL
DELETE FROM users
WHERE CASE
  WHEN instr(username, '@') > 0 THEN substr(username, 1, instr(username, '@') - 1)
  ELSE username
END = $(quote_sql_literal "$user_key");
SQL
    fi
    if has_table "$DB_PATH" "client_traffics"; then
      cat <<SQL
DELETE FROM client_traffics
WHERE CASE
  WHEN instr(email, '@') > 0 THEN substr(email, 1, instr(email, '@') - 1)
  ELSE email
END = $(quote_sql_literal "$user_key");
SQL
    fi
    if has_table "$DB_PATH" "inbound_client_ips"; then
      cat <<SQL
DELETE FROM inbound_client_ips
WHERE CASE
  WHEN instr(client_email, '@') > 0 THEN substr(client_email, 1, instr(client_email, '@') - 1)
  ELSE client_email
END = $(quote_sql_literal "$user_key");
SQL
    fi
    printf "COMMIT;\n"
  } > "$sql_file"

  service_stop
  sqlite3 "$DB_PATH" < "$sql_file" || {
    rm -f "$sql_file"
    service_start || true
    die "failed to delete user; restore from $backup_db if needed"
  }
  rm -f "$sql_file"
  sqlite3 "$DB_PATH" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 || true
  service_start

  if [[ -f "$STATE_DB" ]] && has_table "$STATE_DB" "xui_sync_client_state"; then
    local state_sql
    state_sql="$(mktemp)"
    {
      printf "BEGIN IMMEDIATE;\n"
      printf "DELETE FROM xui_sync_client_state WHERE user_key = %s;\n" "$(quote_sql_literal "$user_key")"
      printf "COMMIT;\n"
    } > "$state_sql"
    sqlite3 "$STATE_DB" < "$state_sql"
    rm -f "$state_sql"
  fi

  log "user deleted on node: $user_key"
  printf '%s\n' "$user_key"
}

cmd_delete_user() {
  local user_key="$(normalize_user_key "${1:-}")"
  [[ -n "$user_key" ]] || die "usage: $0 delete-user <user_key>"

  need_cmd ssh
  need_cmd sqlite3
  load_config

  local backup_dir
  backup_dir="$WORKDIR/backups/$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$backup_dir"
  mkdir -p "$(dirname "$MASTER_STATE_DB")"

  log "delete user family: $user_key"
  local node name host user port remote_script failed=0
  for node in "${NODES[@]}"; do
    name="$(node_field "$node" 1)"
    host="$(node_field "$node" 2)"
    user="$(node_field "$node" 3)"
    port="$(node_field "$node" 4)"
    remote_script="$(node_field "$node" 5)"
    [[ -n "$name" && -n "$host" && -n "$user" && -n "$port" && -n "$remote_script" ]] || die "bad node spec: $node"

    log "delete user on $name"
    if ! ssh "${SSH_BASE_OPTS[@]}" -p "$port" "$user@$host" "bash '$remote_script' delete-user-node $(printf '%q' "$user_key")"; then
      log "skip $name: delete failed"
      failed=1
    fi
  done

  if [[ "$failed" -ne 0 ]]; then
    die "delete-user aborted because one or more nodes failed"
  fi

  if [[ -f "$MASTER_STATE_DB" ]] && has_table "$MASTER_STATE_DB" "global_client_state"; then
    local state_sql
    state_sql="$(mktemp)"
    {
      printf "BEGIN IMMEDIATE;\n"
      printf "DELETE FROM global_client_state WHERE user_key = %s;\n" "$(quote_sql_literal "$user_key")"
      printf "DELETE FROM node_client_base WHERE user_key = %s;\n" "$(quote_sql_literal "$user_key")"
      printf "COMMIT;\n"
    } > "$state_sql"
    sqlite3 "$MASTER_STATE_DB" < "$state_sql"
    rm -f "$state_sql"
  fi

  log "re-sync configuration after user deletion"
  cmd_config_sync
}

cmd_user_status_node() {
  local user_key="$(normalize_user_key "${1:-}")"
  [[ -n "$user_key" ]] || die "usage: $0 user-status-node <user_key>"

  need_cmd sqlite3
  require_local_db

  if ! has_table "$DB_PATH" "client_traffics"; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$SERVER_ID" "$user_key" "not-found" "" "" "" "" "" ""
    return 0
  fi

  local all_time_expr last_online_expr
  all_time_expr="COALESCE(up, 0) + COALESCE(down, 0)"
  last_online_expr="0"
  if has_column "$DB_PATH" "client_traffics" "all_time"; then
    all_time_expr="COALESCE(all_time, COALESCE(up, 0) + COALESCE(down, 0))"
  fi
  if has_column "$DB_PATH" "client_traffics" "last_online"; then
    last_online_expr="COALESCE(last_online, 0)"
  fi

  local ips_cte="SELECT NULL AS ips_list"
  if has_table "$DB_PATH" "inbound_client_ips"; then
    ips_cte="
      SELECT group_concat(DISTINCT client_email || ':' || ips) AS ips_list
      FROM inbound_client_ips
      WHERE client_email IS NOT NULL AND client_email <> ''
        AND (
          CASE
            WHEN instr(client_email, '@') > 0 THEN substr(client_email, 1, instr(client_email, '@') - 1)
            ELSE client_email
          END
        ) = $(quote_sql_literal "$user_key")
    "
  fi

  sqlite3 -noheader -separator $'\t' "$DB_PATH" "
    WITH cur AS (
      SELECT
        CASE
          WHEN instr(email, '@') > 0 THEN substr(email, 1, instr(email, '@') - 1)
          ELSE email
        END AS user_key,
        group_concat(DISTINCT email) AS matched_emails,
        SUM(COALESCE(up, 0)) AS up,
        SUM(COALESCE(down, 0)) AS down,
        SUM($all_time_expr) AS all_time,
        MAX($last_online_expr) AS last_online
      FROM client_traffics
      WHERE email IS NOT NULL AND email <> ''
        AND (
          CASE
            WHEN instr(email, '@') > 0 THEN substr(email, 1, instr(email, '@') - 1)
            ELSE email
          END
        ) = $(quote_sql_literal "$user_key")
      GROUP BY user_key
    ),
    ips AS (
      $ips_cte
    )
    SELECT
      $(quote_sql_literal "$SERVER_ID") AS server_id,
      $(quote_sql_literal "$user_key") AS user_key,
      CASE
        WHEN cur.user_key IS NULL THEN 'not-found'
        WHEN COALESCE(ips.ips_list, '') <> '' THEN 'online'
        WHEN COALESCE(cur.last_online, 0) > 0 THEN 'seen'
        ELSE 'offline'
      END AS status,
      COALESCE(cur.matched_emails, '') AS matched_emails,
      COALESCE(ips.ips_list, '') AS ips,
      COALESCE(cur.last_online, 0) AS last_online,
      COALESCE(cur.up, 0) AS up,
      COALESCE(cur.down, 0) AS down,
      COALESCE(cur.all_time, 0) AS all_time
    FROM ips
    LEFT JOIN cur ON 1=1;
  "
}

cmd_user_status() {
  local user_key="$(normalize_user_key "${1:-}")"
  [[ -n "$user_key" ]] || die "usage: $0 user-status <user_key>"

  need_cmd ssh
  need_cmd sqlite3
  load_config

  local online_lines=() seen_lines=() offline_lines=() not_found_lines=() connection_error_lines=()
  local node name host user port remote_script remote_line ssh_err_file ssh_err_text
  for node in "${NODES[@]}"; do
    name="$(node_field "$node" 1)"
    host="$(node_field "$node" 2)"
    user="$(node_field "$node" 3)"
    port="$(node_field "$node" 4)"
    remote_script="$(node_field "$node" 5)"
    [[ -n "$name" && -n "$host" && -n "$user" && -n "$port" && -n "$remote_script" ]] || die "bad node spec: $node"

    ssh_err_file="$(mktemp)"
    if ! remote_line="$(ssh "${SSH_BASE_OPTS[@]}" -p "$port" "$user@$host" "bash '$remote_script' user-status-node $(printf '%q' "$user_key")" 2>"$ssh_err_file" | tail -n 1)"; then
      ssh_err_text="$(tr '\n' ' ' < "$ssh_err_file" | sed 's/[[:space:]]*$//')"
      offline_lines+=("$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$name" "offline" "" "" "" "" "" "")")
      [[ -n "$ssh_err_text" ]] && connection_error_lines+=("$(printf '%s\t%s' "$name" "$ssh_err_text")")
      rm -f "$ssh_err_file"
      continue
    fi
    rm -f "$ssh_err_file"
    if [[ -n "$remote_line" ]]; then
      IFS=$'\t' read -r remote_server remote_user_key remote_status remote_matched remote_ips remote_last_online remote_up remote_down remote_all_time <<< "$remote_line"
      case "$remote_status" in
        online) online_lines+=("$remote_line") ;;
        seen) seen_lines+=("$remote_line") ;;
        offline) offline_lines+=("$remote_line") ;;
        not-found|*) not_found_lines+=("$remote_line") ;;
      esac
    else
      not_found_lines+=("$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$name" "not-found" "" "" "" "" "" "")")
    fi
  done

  printf 'server\tstatus\tmatched_emails\tips\tlast_online\tup\tdown\tall_time\n'
  printf '== current online ==\n'
  if [[ "${#online_lines[@]}" -gt 0 ]]; then
    printf '%s\n' "${online_lines[@]}"
  else
    printf '(none)\n'
  fi
  printf '== recently seen ==\n'
  if [[ "${#seen_lines[@]}" -gt 0 ]]; then
    printf '%s\n' "${seen_lines[@]}"
  else
    printf '(none)\n'
  fi
  printf '== offline ==\n'
  if [[ "${#offline_lines[@]}" -gt 0 ]]; then
    printf '%s\n' "${offline_lines[@]}"
  else
    printf '(none)\n'
  fi
  printf '== not found ==\n'
  if [[ "${#not_found_lines[@]}" -gt 0 ]]; then
    printf '%s\n' "${not_found_lines[@]}"
  else
    printf '(none)\n'
  fi
  printf '== connection errors ==\n'
  if [[ "${#connection_error_lines[@]}" -gt 0 ]]; then
    printf '%s\n' "${connection_error_lines[@]}"
  else
    printf '(none)\n'
  fi
}

cmd_user_last_online_node() {
  local user_key="$(normalize_user_key "${1:-}")"
  [[ -n "$user_key" ]] || die "usage: $0 user-last-online-node <user_key>"

  need_cmd sqlite3
  require_local_db

  if ! has_table "$DB_PATH" "client_traffics"; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$SERVER_ID" "$user_key" "not-found" "" "" ""
    return 0
  fi

  local last_online_expr last_online_utc_expr
  last_online_expr="0"
  last_online_utc_expr="''"
  if has_column "$DB_PATH" "client_traffics" "last_online"; then
    last_online_expr="COALESCE(last_online, 0)"
    last_online_utc_expr="CASE WHEN COALESCE(last_online, 0) > 0 THEN datetime(CAST(last_online / 1000 AS INTEGER), 'unixepoch') ELSE '' END"
  fi

  sqlite3 -noheader -separator $'\t' "$DB_PATH" "
    WITH cur AS (
      SELECT
        CASE
          WHEN instr(email, '@') > 0 THEN substr(email, 1, instr(email, '@') - 1)
          ELSE email
        END AS user_key,
        group_concat(DISTINCT email) AS matched_emails,
        MAX($last_online_expr) AS last_online
      FROM client_traffics
      WHERE email IS NOT NULL AND email <> ''
        AND (
          CASE
            WHEN instr(email, '@') > 0 THEN substr(email, 1, instr(email, '@') - 1)
            ELSE email
          END
        ) = $(quote_sql_literal "$user_key")
      GROUP BY user_key
    )
    SELECT
      $(quote_sql_literal "$SERVER_ID") AS server_id,
      $(quote_sql_literal "$user_key") AS user_key,
      CASE
        WHEN cur.user_key IS NULL THEN 'not-found'
        ELSE 'seen'
      END AS status,
      COALESCE(cur.matched_emails, '') AS matched_emails,
      COALESCE(cur.last_online, 0) AS last_online,
      COALESCE($last_online_utc_expr, '') AS last_online_utc
    FROM (SELECT 1) AS one
    LEFT JOIN cur ON 1=1;
  "
}

cmd_user_last_online() {
  local user_key="$(normalize_user_key "${1:-}")"
  [[ -n "$user_key" ]] || die "usage: $0 user-last-online <user_key>"

  need_cmd ssh
  need_cmd sqlite3
  load_config

  printf 'server\tuser_key\tstatus\tmatched_emails\tlast_online\tlast_online_utc\n'
  local node name host user port remote_script remote_line
  for node in "${NODES[@]}"; do
    name="$(node_field "$node" 1)"
    host="$(node_field "$node" 2)"
    user="$(node_field "$node" 3)"
    port="$(node_field "$node" 4)"
    remote_script="$(node_field "$node" 5)"
    [[ -n "$name" && -n "$host" && -n "$user" && -n "$port" && -n "$remote_script" ]] || die "bad node spec: $node"

    if ! remote_line="$(ssh "${SSH_BASE_OPTS[@]}" -p "$port" "$user@$host" "bash '$remote_script' user-last-online-node $(printf '%q' "$user_key")" | tail -n 1)"; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$user_key" "offline" "" "" ""
      continue
    fi
    if [[ -n "$remote_line" ]]; then
      printf '%s\n' "$remote_line"
    else
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$user_key" "not-found" "" "" ""
    fi
  done
}

usage() {
  cat <<EOF
Usage:

Traffic Sync (流量同步):
  $0 export
  $0 merge-dir [snapshots_dir] [output_db]
  $0 apply-traffic /path/to/merged-traffic.db
  $0 master
  $0 summary [db]

Traffic Reset (流量清零):
  $0 reset-traffic [user_key ...]
  $0 reset-traffic-all
  $0 master-reset-traffic [user_key ...]
  $0 master-reset-traffic-all

Config Sync (配置同步):
  $0 config-export
  $0 config-apply /path/to/config.db
  $0 config-merge <master_node_name> [snapshots_dir] [output_db]
  $0 config-sync
  $0 config-add-user <username> <password> [login_secret]
  $0 delete-user <user_key>
  $0 user-status <user_key>
  $0 user-last-online <user_key>

Environment:
  DB_PATH=$DEFAULT_DB
  WORKDIR=$DEFAULT_WORKDIR
  STATE_DB=\$WORKDIR/state.db
  MASTER_STATE_DB=\$WORKDIR/master/state.db
  SYNC_INBOUND_TRAFFIC=0
  CONFIG_SYNC_ENABLED=0
  CONFIG_MASTER_NODE=
  SERVICE_NAME=$DEFAULT_SERVICE
  SERVER_ID=$(hostname -f 2>/dev/null || hostname)
  CONFIG_FILE=$CONFIG_FILE
  STOP_SERVICE_ON_APPLY=1
EOF
}

main() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    export) cmd_export "$@" ;;
    merge-dir) cmd_merge_dir "$@" ;;
    apply-traffic) cmd_apply_traffic "$@" ;;
    master) cmd_master "$@" ;;
    summary) cmd_summary "$@" ;;
    reset-traffic) cmd_reset_traffic "$@" ;;
    reset-traffic-all) cmd_reset_traffic_all "$@" ;;
    master-reset-traffic) cmd_master_reset_traffic "$@" ;;
    master-reset-traffic-all) cmd_master_reset_traffic_all "$@" ;;
    config-export) cmd_config_export "$@" ;;
    config-apply) cmd_config_apply "$@" ;;
    config-merge) cmd_config_merge "$@" ;;
    config-sync) cmd_config_sync "$@" ;;
    config-add-user|add-user) cmd_config_add_user "$@" ;;
    delete-user) cmd_delete_user "$@" ;;
    user-status) cmd_user_status "$@" ;;
    user-last-online) cmd_user_last_online "$@" ;;
    delete-user-node) cmd_delete_user_node "$@" ;;
    user-status-node) cmd_user_status_node "$@" ;;
    user-last-online-node) cmd_user_last_online_node "$@" ;;
    -h|--help|help|"") usage ;;
    *) die "unknown command: $cmd" ;;
  esac
}

main "$@"
