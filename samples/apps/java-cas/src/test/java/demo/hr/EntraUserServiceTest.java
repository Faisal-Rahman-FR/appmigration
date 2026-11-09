package demo.hr;

import java.time.Instant;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;
import org.springframework.security.oauth2.core.OAuth2AuthenticationException;
import org.springframework.security.oauth2.core.oidc.OidcIdToken;
import org.springframework.security.oauth2.core.oidc.user.DefaultOidcUser;
import static org.junit.jupiter.api.Assertions.*;

class EntraUserServiceTest {
    private DefaultOidcUser user() {
        return new DefaultOidcUser(List.of(), new OidcIdToken("test-token", Instant.now(),
            Instant.now().plusSeconds(300), Map.of("sub", "subject", "oid", "object-id", "tid", "test-tenant",
                "roles", List.of("hr-admins"))));
    }

    @Test void mapsOnlyRequiredProfileAttributesAndTokenRoles() {
        var enriched = EntraUserService.withProfile(user(),
            new EntraUserService.GraphProfile("object-id", "testuser1", "10001", "testuser1@example.test", "Test User"));
        var identity = EntraUserService.identity(enriched);
        assertEquals("subject", enriched.getName());
        assertEquals("testuser1", identity.uid());
        assertEquals(List.of("10001"), identity.values("employeeNumber"));
        assertEquals(List.of("hr-admins"), identity.values("memberOf"));
        assertEquals(4, identity.attributes().size());
        assertFalse(identity.attributes().containsKey("oid"));
    }

    @Test void failsClosedForMissingEmployeeIdOrMismatchedObjectId() {
        assertThrows(OAuth2AuthenticationException.class, () -> EntraUserService.withProfile(user(),
            new EntraUserService.GraphProfile("object-id", "testuser1", null, "test@example.test", "Test")));
        assertThrows(OAuth2AuthenticationException.class, () -> EntraUserService.withProfile(user(),
            new EntraUserService.GraphProfile("another-object", "testuser1", "10001", "test@example.test", "Test")));
        assertThrows(OAuth2AuthenticationException.class, () -> EntraUserService.withProfile(user(), null));
    }

    @Test void requiresConfiguredTenantInValidatedIdToken() {
        assertDoesNotThrow(() -> EntraUserService.validateTenant(user(), "test-tenant"));
        assertThrows(OAuth2AuthenticationException.class, () -> EntraUserService.validateTenant(user(), "other-tenant"));
    }
}
