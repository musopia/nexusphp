<?php

namespace App\Support;

use App\Models\User;
use Nexus\Database\NexusDB;
use Nexus\Database\NexusLock;

/**
 * Shoutbox @mention: store as (@uid_username), render by uid+_ then name.
 */
class ShoutboxMention
{
    public const TOKEN_RE = '/\(@(\d+)_([^)]+)\)/';

    public const SEARCH_CACHE_PREFIX = 'mention_suggest:';

    public const SEARCH_CACHE_TTL = 10;

    public const SEARCH_LIMIT = 8;

    /**
     * Rewrite @username → (@uid_username) before INSERT.
     * Only exact existing confirmed+enabled users; leave other @text untouched.
     */
    public static function rewriteForStore(string $text): string
    {
        if ($text === '' || strpos($text, '@') === false) {
            return $text;
        }
        if (!preg_match_all('/(?:^|[^A-Za-z0-9_])@([A-Za-z0-9]{3,20})(?![A-Za-z0-9_])/', $text, $matches, PREG_OFFSET_CAPTURE | PREG_SET_ORDER)) {
            return $text;
        }

        $names = [];
        foreach ($matches as $m) {
            $names[$m[1][0]] = true;
        }
        if (!$names) {
            return $text;
        }

        $rows = User::query()
            ->whereIn('username', array_keys($names))
            ->where('status', User::STATUS_CONFIRMED)
            ->where('enabled', User::ENABLED_YES)
            ->get(['id', 'username']);

        if ($rows->isEmpty()) {
            return $text;
        }

        // longest name first to reduce partial overlaps
        $map = [];
        foreach ($rows as $row) {
            $map[$row->username] = (int)$row->id;
        }
        uksort($map, function ($a, $b) {
            return strlen($b) - strlen($a);
        });

        $out = $text;
        foreach ($map as $name => $uid) {
            $out = preg_replace(
                '/(^|[^A-Za-z0-9_])@' . preg_quote($name, '/') . '(?![A-Za-z0-9_])/',
                '$1(@' . $uid . '_' . $name . ')',
                $out
            );
        }
        return $out;
    }

    /**
     * Replace (@uid_username) tokens in already-escaped/formatted HTML.
     * Username shown from DB (rename-safe); link to /userdetails.php?id=.
     */
    public static function render(string $html, ?int $currentUid = null): string
    {
        if ($html === '' || strpos($html, '(@') === false) {
            return $html;
        }
        if (!preg_match_all(self::TOKEN_RE, $html, $matches, PREG_SET_ORDER)) {
            return $html;
        }

        $uids = [];
        foreach ($matches as $m) {
            $uids[(int)$m[1]] = true;
        }
        if (!$uids) {
            return $html;
        }

        $users = User::query()
            ->whereIn('id', array_keys($uids))
            ->get(['id', 'username'])
            ->keyBy('id');

        return preg_replace_callback(self::TOKEN_RE, function ($m) use ($users, $currentUid) {
            $uid = (int)$m[1];
            $storedName = $m[2];
            $user = $users->get($uid);
            if (!$user) {
                // unknown/deleted: keep plain text token, do not link
                return htmlspecialchars('(@' . $uid . '_' . $storedName . ')', ENT_QUOTES, 'UTF-8');
            }
            $name = $user->username;
            $isSelf = $currentUid !== null && $uid === (int)$currentUid;
            $cls = $isSelf ? 'mention mention-self' : 'mention';
            $title = $isSelf ? '提到了你自己 @' . $name : '查看 ' . $name;
            return sprintf(
                '<a class="%s" href="/userdetails.php?id=%d" target="_blank" title="%s">@%s</a>',
                $cls,
                $uid,
                htmlspecialchars($title, ENT_QUOTES, 'UTF-8'),
                htmlspecialchars($name, ENT_QUOTES, 'UTF-8')
            );
        }, $html);
    }

    /**
     * Prefix username search for autocomplete. Cached 10s in Redis via NexusDB.
     */
    public static function searchPrefix(string $prefix, int $limit = self::SEARCH_LIMIT): array
    {
        $prefix = trim($prefix);
        if (!preg_match('/^[A-Za-z0-9]{2,20}$/', $prefix)) {
            return [];
        }
        if ($limit < 1 || $limit > 20) {
            $limit = self::SEARCH_LIMIT;
        }

        $cacheKey = self::SEARCH_CACHE_PREFIX . strtolower($prefix);
        $cached = NexusDB::cache_get($cacheKey);
        if (is_array($cached)) {
            return $cached;
        }

        global $CURUSER;
        $uid = (int)($CURUSER['id'] ?? 0);
        $lock = null;
        if ($uid > 0) {
            $lock = new NexusLock('mention_search:' . $uid, 10);
            if (!$lock->acquire()) {
                // rate limited: return empty rather than hammer DB
                return is_array($cached) ? $cached : [];
            }
        }

        $rows = User::query()
            ->where('username', 'like', $prefix . '%')
            ->where('status', User::STATUS_CONFIRMED)
            ->where('enabled', User::ENABLED_YES)
            ->orderBy('username')
            ->limit($limit)
            ->get(['id', 'username']);

        $list = [];
        foreach ($rows as $row) {
            $list[] = [
                'id' => (int)$row->id,
                'username' => $row->username,
            ];
        }

        NexusDB::cache_put($cacheKey, $list, self::SEARCH_CACHE_TTL);
        return $list;
    }

    /**
     * Recent distinct speakers from shoutbox (for @ empty state).
     */
    public static function recentSpeakers(int $limit = 5): array
    {
        $cacheKey = 'mention_recent_speakers';
        $cached = NexusDB::cache_get($cacheKey);
        if (is_array($cached)) {
            return $cached;
        }

        $rows = NexusDB::table('shoutbox')
            ->where('userid', '>', 0)
            ->orderBy('date', 'desc')
            ->limit(80)
            ->get(['userid']);

        $seen = [];
        $uids = [];
        foreach ($rows as $row) {
            $id = (int)$row->userid;
            if ($id <= 0 || isset($seen[$id])) {
                continue;
            }
            $seen[$id] = true;
            $uids[] = $id;
            if (count($uids) >= $limit) {
                break;
            }
        }
        if (!$uids) {
            NexusDB::cache_put($cacheKey, [], 60);
            return [];
        }

        $users = User::query()->whereIn('id', $uids)->get(['id', 'username']);
        $byId = [];
        foreach ($users as $u) {
            $byId[(int)$u->id] = [
                'id' => (int)$u->id,
                'username' => $u->username,
            ];
        }
        $list = [];
        foreach ($uids as $id) {
            if (isset($byId[$id])) {
                $list[] = $byId[$id];
            }
        }

        NexusDB::cache_put($cacheKey, $list, 60);
        return $list;
    }
}
