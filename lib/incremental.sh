#!/usr/bin/env bash
# Pull-run counters (sourced by common.sh).

INC_FILE_CHANGES=0
INC_MYSQL_SKIP=0
INC_MYSQL_IMPORT=0
INC_CFG_CHANGES=0
INC_SKIPPED=0

log_incremental_summary() {
  log_info "Incremental summary: files=${INC_FILE_CHANGES} mysql_import=${INC_MYSQL_IMPORT} mysql_skip=${INC_MYSQL_SKIP} config=${INC_CFG_CHANGES} skipped_steps=${INC_SKIPPED}"
}
