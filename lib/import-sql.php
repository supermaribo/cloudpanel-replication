#!/usr/bin/env php
<?php
// Load a mysqldump file via unix socket root. CloudPanel's mysql CLI
// treats stdin as a password, so the CLI client cannot import dumps.
mysqli_report(MYSQLI_REPORT_OFF);

if ($argc < 3) {
    fwrite(STDERR, "usage: import-sql.php DATABASE dump.sql\n");
    exit(1);
}

$db = $argv[1];
$file = $argv[2];
if (!preg_match('/^[A-Za-z0-9_]+$/', $db)) {
    fwrite(STDERR, "bad database name\n");
    exit(1);
}
if (!is_readable($file)) {
    fwrite(STDERR, "cannot read {$file}\n");
    exit(1);
}

$sock = file_exists('/run/mysqld/mysqld.sock')
    ? '/run/mysqld/mysqld.sock'
    : '/var/run/mysqld/mysqld.sock';

$m = new mysqli('localhost', 'root', '', null, 0, $sock);
if ($m->connect_error) {
    fwrite(STDERR, $m->connect_error . "\n");
    exit(1);
}

$m->query("CREATE DATABASE IF NOT EXISTS `{$db}` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci");
$m->select_db($db);
$m->query('SET SESSION FOREIGN_KEY_CHECKS=0');
$m->query('SET SESSION UNIQUE_CHECKS=0');
$m->query("SET SESSION sql_log_bin=0");

$sql = file_get_contents($file);
if ($sql === false || $sql === '') {
    fwrite(STDERR, "empty dump\n");
    exit(1);
}

if (!$m->multi_query($sql)) {
    fwrite(STDERR, $m->error . "\n");
    exit(1);
}
do {
    if ($res = $m->store_result()) {
        $res->free();
    }
} while ($m->more_results() && $m->next_result());

if ($m->errno) {
    fwrite(STDERR, $m->error . "\n");
    exit(1);
}

$qdb = $m->real_escape_string($db);
$r = $m->query("SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '{$qdb}'");
$tables = $r ? $r->fetch_row()[0] : '?';
echo "ok tables={$tables}\n";
