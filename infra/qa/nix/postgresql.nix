{ lib }:
rec {
  forbiddenSetting =
    k:
    lib.elem k [
      "listen_addresses"
      "hba_file"
      "ident_file"
    ]
    || lib.hasPrefix "unix_socket_" k
    || lib.hasPrefix "log_" k;

  baseSettings = {
    listen_addresses = "";
    unix_socket_permissions = 504;
    max_connections = 40;
    superuser_reserved_connections = 3;
    shared_buffers = "256MB";
    work_mem = "8MB";
    maintenance_work_mem = "64MB";
    effective_cache_size = "1GB";
    huge_pages = "off";
    dynamic_shared_memory_type = "posix";
    wal_level = "replica";
    max_wal_size = "1GB";
    min_wal_size = "80MB";
    checkpoint_timeout = "15min";
    fsync = "on";
    synchronous_commit = "on";
    full_page_writes = "on";
    password_encryption = "scram-sha-256";
    jit = "off";
    timezone = "UTC";
    log_timezone = "UTC";
    idle_in_transaction_session_timeout = "60s";
    log_destination = "stderr";
    logging_collector = "off";
    log_line_prefix = "%m [%p] %q%u@%d ";
    log_statement = "none";
    log_min_duration_statement = -1;
    log_min_error_statement = "panic";
    log_error_verbosity = "terse";
    log_parameter_max_length = 0;
    log_parameter_max_length_on_error = 0;
    log_connections = "off";
    log_disconnections = "off";
    log_checkpoints = "on";
    log_lock_waits = "on";
    shared_preload_libraries = "";
  };

  renderValue =
    v:
    if builtins.isInt v then
      toString v
    else if builtins.isBool v then
      (if v then "on" else "off")
    else
      "'" + lib.replaceStrings [ "'" ] [ "''" ] (toString v) + "'";

  renderConf =
    {
      settings,
      socketDir,
      hbaFile,
      identFile,
    }:
    let
      all = settings // {
        unix_socket_directories = socketDir;
        hba_file = "${hbaFile}";
        ident_file = "${identFile}";
      };
    in
    lib.concatStrings (
      lib.mapAttrsToList (k: v: "${k} = ${renderValue v}\n") (lib.filterAttrs (_: v: v != null) all)
    );

  hba = ''
    # TYPE  DATABASE  USER            ADDRESS    METHOD
    local   all       hasala_su                  peer map=hasala
    local   hasala    hasala_migrate             peer map=hasala
    local   hasala    hasala_runtime             peer map=hasala
    local   hasala    hasala_backup              peer map=hasala
    local   all       all                        reject
    host    all       all             0.0.0.0/0  reject
    host    all       all             ::/0       reject
  '';

  ident =
    { console }:
    ''
      # MAP    SYSTEM-USERNAME  PG-USERNAME
      hasala   hasala-pg        hasala_su
      hasala   hasala-migrate   hasala_migrate
      hasala   hasala           hasala_runtime
      hasala   hasala-backup    hasala_backup
    ''
    + lib.optionalString console ''
      hasala   hasala-console   hasala_runtime
    '';
}
