<?php
declare(strict_types=1);
final class Database
{
    public static function connect(): PDO
    {
        return new PDO(
            'mysql:host=' . IdentitySession::env('DB_HOST') . ';dbname=alumni;charset=utf8mb4',
            'demo', IdentitySession::env('DB_PASSWORD'),
            [PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION, PDO::ATTR_EMULATE_PREPARES=>false, PDO::ATTR_DEFAULT_FETCH_MODE=>PDO::FETCH_ASSOC]
        );
    }
}
