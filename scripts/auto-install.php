<?php
/**
 * NexusPHP CLI auto-install. Uses existing .env + compose; no web wizard.
 *
 *   docker exec -w /var/www/html nexusphp-php php scripts/auto-install.php
 *   ADMIN_USERNAME=admin ADMIN_EMAIL=a@b.c ADMIN_PASSWORD=xxx php scripts/auto-install.php
 */

error_reporting(E_ALL);
ini_set('display_errors', '1');
fwrite(STDOUT, "[boot] auto-install start\n");

$root = dirname(__DIR__);
if (!defined('ROOT_PATH')) {
    define('ROOT_PATH', $root . '/');
}
if (!defined('INSTALL_SKIP_REQUIREMENT_CHECK')) {
    define('INSTALL_SKIP_REQUIREMENT_CHECK', true);
}
fwrite(STDOUT, "[boot] ROOT_PATH=" . ROOT_PATH . "\n");

if (!is_readable(ROOT_PATH . '.env')) {
    fwrite(STDERR, "[boot] .env missing\n");
    exit(1);
}
fwrite(STDOUT, "[boot] .env ok\n");

require ROOT_PATH . 'nexus/Install/install_update_start.php';
fwrite(STDOUT, "[boot] laravel=" . (defined('WITH_LARAVEL') && WITH_LARAVEL ? 'yes' : 'no') . "\n");

if (!function_exists('ai_log')) {
    function ai_log(string $msg): void
    {
        fwrite(STDOUT, sprintf("[%s] %s\n", date('Y-m-d H:i:s'), $msg));
    }
}
if (!function_exists('ai_die')) {
    function ai_die(string $msg, int $code = 1): void
    {
        fwrite(STDERR, sprintf("[%s] ERROR: %s\n", date('Y-m-d H:i:s'), $msg));
        exit($code);
    }
}
if (!function_exists('ai_env')) {
    function ai_env(string $key, string $default = ''): string
    {
        $v = getenv($key);
        if ($v !== false && $v !== '') {
            return (string)$v;
        }
        static $envMap = null;
        if ($envMap === null) {
            $envMap = [];
            $path = ROOT_PATH . '.env';
            foreach (file($path, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
                $line = trim($line);
                if ($line === '' || $line[0] === '#') {
                    continue;
                }
                $pos = strpos($line, '=');
                if ($pos === false) {
                    continue;
                }
                $envMap[substr($line, 0, $pos)] = trim(substr($line, $pos + 1), " \t\"'");
            }
        }
        return $envMap[$key] ?? $default;
    }
}
if (!function_exists('ai_random_password')) {
    function ai_random_password(int $length = 16): string
    {
        $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789';
        $max = strlen($alphabet) - 1;
        $out = '';
        for ($i = 0; $i < $length; $i++) {
            $out .= $alphabet[random_int(0, $max)];
        }
        return $out . '!1';
    }
}

ai_log('=== NexusPHP auto-install ===');
ai_log('PHP ' . PHP_VERSION);

try {
    $ver = \Nexus\Database\NexusDB::select('select version() as v')[0]['v'] ?? 'unknown';
    ai_log('MySQL ok: ' . $ver);
} catch (Throwable $e) {
    ai_die('MySQL: ' . $e->getMessage());
}

try {
    $redisHost = ai_env('REDIS_HOST', '127.0.0.1');
    $redisPort = (int)ai_env('REDIS_PORT', '6379') ?: 6379;
    $redisPass = ai_env('REDIS_PASSWORD', '');
    $redisDb = (int)ai_env('REDIS_DB', '0');
    $redis = new \Redis();
    $redis->connect($redisHost, $redisPort, 3.0);
    if ($redisPass !== '') {
        $redis->auth($redisPass);
    }
    $redis->select($redisDb);
    $redis->ping();
    ai_log("Redis ok: {$redisHost}:{$redisPort}/{$redisDb}");
} catch (Throwable $e) {
    ai_die('Redis: ' . $e->getMessage());
}

$install = new \Nexus\Install\Install();

ai_log('--- migrate ---');
try {
    $ran = array_map(function ($row) {
        return is_object($row) ? $row->migration : $row['migration'];
    }, \Nexus\Database\NexusDB::select('select migration from migrations'));
} catch (Throwable $e) {
    $ran = [];
    ai_log('migrations table not ready: ' . $e->getMessage());
}
$files = glob(ROOT_PATH . 'database/migrations/*.php') ?: [];
$expect = array_map(fn($f) => basename($f, '.php'), $files);
$pending = count(array_diff($expect, $ran));
ai_log(sprintf('migrations ran=%d expect=%d pending=%d', count($ran), count($expect), $pending));
if ($pending > 0 || count($ran) === 0) {
    $install->runMigrate();
    ai_log('migrate done');
} else {
    ai_log('migrate skipped');
}

ai_log('--- settings / symlink / seeder ---');
try {
    $settingTableRows = $install->listSettingTableRows();
    $settings = $settingTableRows['settings'];
    $symbolicLinks = $settingTableRows['symbolic_links'] ?? [];
    $install->createSymbolicLinks($symbolicLinks);
    ai_log('symbolic links ok: ' . count($symbolicLinks));
    $install->saveSettings($settings);
    ai_log('settings saved');
} catch (Throwable $e) {
    ai_die('settings/symlink: ' . $e->getMessage());
}

try {
    $install->runDatabaseSeeder();
    ai_log('seeder done');
} catch (Throwable $e) {
    $msg = $e->getMessage();
    if (stripos($msg, 'already') !== false || stripos($msg, 'Duplicate') !== false || stripos($msg, 'exists') !== false) {
        ai_log('seeder continue: ' . $msg);
    } else {
        ai_die('seeder: ' . $msg);
    }
}

try {
    $install->migrateSearchBoxModeRelated();
    ai_log('searchbox related done');
} catch (Throwable $e) {
    ai_log('searchbox warn: ' . $e->getMessage());
}

try {
    $install->initTrackerUrl('install');
    ai_log('tracker url done');
} catch (Throwable $e) {
    ai_log('tracker url warn: ' . $e->getMessage());
}

ai_log('--- admin ---');
$adminClass = \App\Models\User::CLASS_STAFF_LEADER;
try {
    $rows = \Nexus\Database\NexusDB::select('select count(*) as c from users where class = ' . (int)$adminClass);
    $exists = (int)($rows[0]->c ?? $rows[0]['c'] ?? 0);
} catch (Throwable $e) {
    ai_die('users table: ' . $e->getMessage());
}

if ($exists > 0) {
    ai_log('administrator already exists, skip');
} else {
    $username = ai_env('ADMIN_USERNAME', 'admin');
    $email = ai_env('ADMIN_EMAIL', $username . '@example.com');
    $password = ai_env('ADMIN_PASSWORD', '');
    $generated = false;
    if ($password === '') {
        $password = ai_random_password();
        $generated = true;
    }
    try {
        $install->createAdministrator($username, $email, $password, $password);
        ai_log('administrator created: ' . $username . ' <' . $email . '>');
        if ($generated) {
            ai_log('ADMIN_PASSWORD(generated)=' . $password);
        }
    } catch (Throwable $e) {
        ai_die('create administrator: ' . $e->getMessage());
    }
}

ai_log('--- passport ---');
$keyPath = ROOT_PATH . 'storage/oauth-private.key';
if (is_readable($keyPath) && filesize($keyPath) > 0) {
    ai_log('passport keys exists, skip');
} else {
    $cmd = 'cd ' . escapeshellarg(ROOT_PATH) . ' && php artisan passport:keys --force 2>&1';
    exec($cmd, $output, $code);
    ai_log(implode("\n", $output));
    if ($code !== 0) {
        ai_die('passport:keys exit=' . $code);
    }
    ai_log('passport keys generated');
}

ai_log('--- lock ---');
$lockFile = ROOT_PATH . \Nexus\Install\Install::INSTALL_LOCK_FILE;
file_put_contents($lockFile, date('c') . "\n");
ai_log('lock: ' . $lockFile);

$publicInstall = ROOT_PATH . 'public/install';
if (is_dir($publicInstall)) {
    exec('rm -rf ' . escapeshellarg($publicInstall), $o, $rc);
    ai_log('remove public/install rc=' . $rc);
} else {
    ai_log('public/install already absent');
}

try {
    $tables = count(\Nexus\Database\NexusDB::select('show tables'));
    $urows = \Nexus\Database\NexusDB::select('select count(*) as c from users');
    $users = (int)($urows[0]->c ?? $urows[0]['c'] ?? 0);
    ai_log("summary tables={$tables} users={$users}");
} catch (Throwable $e) {
    ai_log('summary warn: ' . $e->getMessage());
}

ai_log('=== done ===');
exit(0);
