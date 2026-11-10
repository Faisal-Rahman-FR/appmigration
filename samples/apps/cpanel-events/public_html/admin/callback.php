<?php
declare(strict_types=1);
// Reached only through the sign-in mechanism: entra_guard.php handles the OIDC callback and exits before this runs.
http_response_code(204);
