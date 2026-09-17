<?php

return [
    'default' => nexus_env('CAPTCHA_DRIVER', 'image'),

    'drivers' => [
        'image' => [
            'class' => \App\Services\Captcha\Drivers\ImageCaptchaDriver::class,
        ],

        'cloudflare_turnstile' => [
            'class' => \App\Services\Captcha\Drivers\TurnstileCaptchaDriver::class,
            'site_key' => nexus_env('TURNSTILE_SITE_KEY'),
            'secret_key' => nexus_env('TURNSTILE_SECRET_KEY'),
            'theme' => nexus_env('TURNSTILE_THEME', 'auto'),
            'size' => nexus_env('TURNSTILE_SIZE', 'auto'),
        ],

        'google_recaptcha_v2' => [
            'class' => \App\Services\Captcha\Drivers\RecaptchaV2CaptchaDriver::class,
            'site_key' => nexus_env('RECAPTCHA_SITE_KEY'),
            'secret_key' => nexus_env('RECAPTCHA_SECRET_KEY'),
            'theme' => nexus_env('RECAPTCHA_THEME', 'light'),
            'size' => nexus_env('RECAPTCHA_SIZE', 'normal'),
        ],
    ],

    'attendance' => [
        // 签到验证码：支持 1/0、true/false 等写法，未设置时默认关闭
        'enabled' => filter_var(nexus_env('CAPTCHA_ATTENDANCE_ENABLED', false), FILTER_VALIDATE_BOOLEAN),
    ],
];
