<?php
/**
 * tg_shot/send.php — Endpoint penerima screenshot dari EA ChartShotSender.mq5
 * (WebRequest POST JSON: {key, chat, caption, img(base64)}) lalu kirim ke Telegram.
 *
 * KONFIGURASI SUDAH TERISI: token bot Kingatasolutions, chat_id channel -1002068767074,
 * secret key KGSd2825161d5eacbae1ef6beb8 (harus sama dengan webKey di EA).
 */
error_reporting(E_ALL);
ini_set('display_errors', '0');
header('Content-Type: application/json; charset=utf-8');

/* ============ KONFIGURASI ============ */
const TG_BOT_TOKEN = '6703128222:AAEubiC-f_ovvZqZFc-Qj8lTMWNdXJRnHR8';
const TG_CHAT_ID   = '-1002068767074';            // channel Kingatasolutions
const SECRET_KEY   = 'KGSd2825161d5eacbae1ef6beb8'; // sama dengan webKey di EA
const MAX_BYTES    = 8 * 1024 * 1024;              // 8 MB
const LOG_FILE     = __DIR__ . '/sent.log';
/* ==================================== */

function respond(int $code, string $msg, array $extra = []): void
{
    http_response_code($code);
    echo json_encode(array_merge(['ok' => ($code === 200), 'msg' => $msg], $extra), JSON_UNESCAPED_UNICODE);
    exit;
}

function is_weekend(): bool
{
    // Mengikuti zona server; pasar forex tutup Sabtu & Minggu.
    $d = (int)date('N'); // 1=Senin .. 7=Minggu
    return $d >= 6;
}

/** Simbol yang jalan 24/7 (crypto) — TETAP dikirim walau Sabtu/Minggu. */
function is_crypto_symbol(string $s): bool
{
    return (bool)preg_match('/BTC|ETH|SOL|XRP|ADA|DOGE|LTC|BNB|AVAX|DOT|TRX|MATIC|TON|SHIB|PEPE|USDT|BCH|LINK|XLM|ATOM|NEAR|CRYPTO/i', $s);
}

/** Hapus semua pesan screenshot yang tercatat di sent.log (dipakai cleanup.php & auto weekend). */
function cleanup_all(): array
{
    $deleted = 0; $failed = 0; $total = 0; $dropped = 0;
    if (!is_file(LOG_FILE)) {
        return ['deleted' => 0, 'failed' => 0, 'total' => 0, 'dropped' => 0];
    }
    $lines = file(LOG_FILE, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
    $keep = [];
    $maxDel = 20;   // batasi percobaan hapus per request: respons tetap cepat (< webTimeout EA 10 dtk)
    foreach ($lines as $ln) {
        $parts = explode('|', $ln);
        if (count($parts) < 2) { $keep[] = $ln; continue; }
        if ($total >= $maxDel) { $keep[] = $ln; continue; }   // sisanya dicoba di request berikutnya
        $chatId = $parts[0]; $msgId = (int)$parts[1];
        $ts = (int)($parts[2] ?? 0);
        // Telegram MENOLAK hapus pesan lebih tua dari 48 jam -> buang dari log tanpa panggilan API
        if ($ts > 0 && $ts < time() - 48 * 3600) { $dropped++; continue; }
        $total++;
        $ch = curl_init('https://api.telegram.org/bot' . TG_BOT_TOKEN . '/deleteMessage');
        curl_setopt_array($ch, [
            CURLOPT_POST           => true,
            CURLOPT_POSTFIELDS     => ['chat_id' => $chatId, 'message_id' => $msgId],
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_TIMEOUT        => 20,
        ]);
        $resp = curl_exec($ch);
        curl_close($ch);
        $r = json_decode((string)$resp, true);
        if (($r['ok'] ?? false) === true) { $deleted++; }
        // error 400 = PERMANEN (pesan tak ditemukan / tak bisa dihapus krn >48 jam)
        // -> buang dari log, jangan diulang tiap request (dulu: failed:62 terus-menerus
        //    bikin respons >10 dtk & EA melapor WebRequest timeout padahal normal)
        elseif (($r['error_code'] ?? 0) === 400) { $dropped++; }
        else { $failed++; $keep[] = $ln; }
    }
    @file_put_contents(LOG_FILE, implode(PHP_EOL, $keep) . (empty($keep) ? '' : PHP_EOL));
    return ['deleted' => $deleted, 'failed' => $failed, 'total' => $total, 'dropped' => $dropped];
}

// ---------- route: cleanup.php bisa diakses langsung ----------
$path = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH);
if (substr($path, -12) === '/cleanup.php') {
    if (($_GET['key'] ?? '') !== SECRET_KEY && ($_POST['key'] ?? '') !== SECRET_KEY) {
        respond(403, 'Kunci salah');
    }
    if (($_SERVER['REQUEST_METHOD'] ?? 'GET') === 'POST') {
        $_POST = json_decode(file_get_contents('php://input'), true) ?: $_POST;
    }
    $res = cleanup_all();
    respond(200, 'Bersih selesai', $res);
}

if (($_SERVER['REQUEST_METHOD'] ?? 'GET') !== 'POST') {
    respond(405, 'Metode harus POST');
}

$raw = file_get_contents('php://input');
if ($raw === false || $raw === '') {
    respond(400, 'Body kosong');
}
$data = json_decode($raw, true);
if (!is_array($data)) {
    respond(400, 'JSON tidak valid');
}

if (($data['key'] ?? '') !== SECRET_KEY) {
    respond(403, 'Kunci salah');
}

// ---------- weekend: forex & logam libur, CRYPTO (24/7) TETAP dikirim ----------
// Simbol dibaca dari field "sym" (EA v1.03+) atau dari caption ("BTCUSD H1 | ... GMT | SVR ..").
// Dulu blok ini jalan SEBELUM cek kunci & tanpa lihat simbol -> SC Bitcoin hari Sabtu
// ikut dibuang padahal pasar crypto jalan.
$symHint = (string)($data['sym'] ?? '') . ' ' . (string)($data['caption'] ?? '');
if (is_weekend() && !is_crypto_symbol($symHint)) {
    $res = cleanup_all();
    respond(200, 'Market libur (Sabtu/Minggu): forex & logam tutup — pesan lama dibersihkan, kirim baru dilewati. (Simbol crypto tetap dikirim.)', $res);
}

$imgB64 = (string)($data['img'] ?? '');
if ($imgB64 === '') {
    respond(400, 'Field img kosong');
}
$img = base64_decode($imgB64, true);
if ($img === false || strlen($img) === 0) {
    respond(400, 'base64 gambar tidak valid');
}
if (strlen($img) > MAX_BYTES) {
    respond(413, 'Gambar terlalu besar');
}

$caption = (string)($data['caption'] ?? '');
$caption = mb_substr($caption, 0, 1000, 'UTF-8');

// chat boleh berisi BEBERAPA id: "-1001583828319, -1002222222222" (koma / titik-koma / spasi)
// -> satu POST dari EA bisa dikirim ke beberapa grup sekaligus (fan-out).
$chat = (string)($data['chat'] ?? '');
$targets = preg_split('/[,;\s]+/', $chat, -1, PREG_SPLIT_NO_EMPTY);
if (empty($targets)) {
    $targets = [TG_CHAT_ID];
}
$targets = array_slice($targets, 0, 5);   // maks 5 tujuan: jaga respons tetap di bawah webTimeout EA

$tmp = tempnam(sys_get_temp_dir(), 'tgsh_') . '.png';
file_put_contents($tmp, $img);

$sent = []; $failed = [];
foreach ($targets as $chatId) {
    $post = [
        'chat_id' => $chatId,
        'photo'   => new CURLFile($tmp, 'image/png', 'chart.png'),
        'protect_content' => true, // anggota tidak bisa screenshot/copy/forward (privacy safety)
    ];
    if ($caption !== '') {
        $post['caption'] = $caption;
    }

    $ch = curl_init('https://api.telegram.org/bot' . TG_BOT_TOKEN . '/sendPhoto');
    curl_setopt_array($ch, [
        CURLOPT_POST           => true,
        CURLOPT_POSTFIELDS     => $post,
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT        => 15,
    ]);
    $resp = curl_exec($ch);
    $err  = curl_error($ch);
    curl_close($ch);

    if ($resp === false) {
        $failed[] = $chatId . ' (curl: ' . $err . ')';
        continue;
    }
    $r = json_decode($resp, true);
    if (($r['ok'] ?? false) !== true) {
        $failed[] = $chatId . ' (' . ($r['description'] ?? 'gagal') . ')';
        continue;
    }
    // Simpan chat_id|message_id|ts per tujuan — dipakai cleanup weekend
    if (!empty($r['result']['message_id'])) {
        $line = $chatId . '|' . (int)$r['result']['message_id'] . '|' . time() . PHP_EOL;
        @file_put_contents(LOG_FILE, $line, FILE_APPEND | LOCK_EX);
    }
    $sent[] = $chatId;
}
@unlink($tmp);

if (empty($sent)) {
    respond(502, 'Telegram menolak semua tujuan: ' . implode('; ', $failed));
}

respond(200, 'Terkirim ke Telegram', [
    'tg_code' => 200,
    'chat'    => implode(',', $sent),
    'sent'    => count($sent),
    'failed'  => count($failed),
    'detail'  => $failed,
]);