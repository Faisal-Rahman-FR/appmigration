<?php
declare(strict_types=1);

final class SignInRejected extends RuntimeException
{
    public function __construct(public readonly string $reason)
    {
        parent::__construct($reason);
    }
}

/** Maps a verified Entra ID token plus the signed-in user's Graph profile to the Alumni identity. */
final class EntraProfile
{
    /**
     * @param array<string,mixed>|null $graph
     * @return array{uid:string,attributes:array<string,mixed>}
     */
    public static function identity(object $claims, ?array $graph, string $tenant): array
    {
        if (($claims->tid ?? null) !== $tenant) {
            error_log('Entra ID token tenant claim does not match the configured tenant');
            throw new SignInRejected('invalid_tenant');
        }
        $present = static fn(string $key): bool => $graph !== null && is_string($graph[$key] ?? null) && trim($graph[$key]) !== '';
        $objectIdMatches = $graph !== null && isset($claims->oid) && ($graph['id'] ?? null) === $claims->oid;
        if (!$objectIdMatches || !$present('mailNickname') || !$present('mail') || !$present('displayName')
            || strlen($graph['mailNickname']) > 64) {
            error_log(sprintf(
                'Entra employee profile rejected: objectIdMatches=%s nicknamePresent=%s mailPresent=%s displayNamePresent=%s',
                var_export($objectIdMatches, true), var_export($present('mailNickname'), true),
                var_export($present('mail'), true), var_export($present('displayName'), true)
            ));
            throw new SignInRejected('invalid_employee_profile');
        }
        $roles = $claims->roles ?? [];
        $roles = is_array($roles) ? array_values(array_filter($roles, 'is_string')) : [];
        return [
            'uid' => $graph['mailNickname'],
            'attributes' => [
                'mail' => $graph['mail'],
                'displayName' => $graph['displayName'],
                'eduPersonAffiliation' => $roles,
            ],
        ];
    }

    /** @return array<string,mixed> */
    public static function fetchGraphProfile(string $accessToken): array
    {
        $curl = curl_init('https://graph.microsoft.com/v1.0/me?$select=id,mailNickname,mail,displayName');
        curl_setopt_array($curl, [
            CURLOPT_RETURNTRANSFER => true, CURLOPT_CONNECTTIMEOUT => 5, CURLOPT_TIMEOUT => 10,
            CURLOPT_FOLLOWLOCATION => false,
            CURLOPT_HTTPHEADER => ['Authorization: Bearer ' . $accessToken, 'Accept: application/json'],
        ]);
        $body = curl_exec($curl);
        $status = curl_getinfo($curl, CURLINFO_RESPONSE_CODE);
        curl_close($curl);
        $data = is_string($body) ? json_decode($body, true) : null;
        if ($status !== 200 || !is_array($data)) {
            error_log("Entra profile lookup failed (HTTP $status)");
            throw new SignInRejected('profile_lookup_failed');
        }
        return $data;
    }
}
